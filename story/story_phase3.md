## Phase 3 : Ajout de redondance de stockage pour garantir la conservation des données malgré la perte de machine

Soyons honnêtes, le contenu de cette phase a été choisi au départ de notre aventure, sans connaître le sujet. En réalité, nous avons bien senti la grande différence de difficulté en l'abordant. Jusqu'ici, les choses semblaient relativement faciles, même si nous sommes conscients que nous sommes probablement passés à côté de difficultés nombreuses qui ne manqueraient pas d'apparaître dans un vrai contexte de production. Mais, reconnaissons le, nous n'avons eu jusqu'à présent qu'à rajouter une petite couche de code qui tire parti des possibilités toutes faites fournies par la BEAM.

Nous n'allons pas raconter toutes nos tentatives et nos errements car ce serait long et fastidieux, mais plutôt tenter de présenter un chemin de découverte du problème (pas forcément de la solution, d'ailleur) qui soit passablement linéaire.

### Redondance, vous avez dit redondance ?

Notre approche est peu naïf: si on stocke plusieurs fois la données (la redondance), on se dit intuitivement qu'on doit pouvoir la retrouver en cas de perte d'un noeud. 

Essayons déjà de la stocker plusieurs fois et on verra si on peut la retrouver après. Pour se simplifier la vie, revenons dans le cas d'un cluster statique (nombre de machines constant hors moment de pannes) et oublions donc les notions de `HashRing` de la phase 2. Pour fixer les idées, prenons 5 machines comme initialement.

Comment choisir sur quelle machine stocker la donnée et stocker les copies ? Au début, influencés par cette façon de poser le problème, nous sommes partis de l'idée d'un noeud "maître" et de "réplicas". Par exemple, un maître et 2 réplicas. Dans cette hypothèse, la donnée est écrite 3 fois. 

Mais est-ce que cette disymétrie entre rôles de maître-réplica est finalement une bonne idée ? Que se passe-t-il si le maître tombe? Il faut se souvenir de quel noeud est le nouveau, et que cet connaissance se répande correctement au cluster tout entier à chaque événement (perte et retour). Et finalement, à quoi bon?

Ces tâtonnement ont fait émerger une idée beaucoup plus simple, celle de **groupe**. 

Un groupe est un ensemble de noeuds fixes, qui ont des rôles symétriques au sein du groupe. Dans le cas d'un cluster de 5 noeuds numérotés de 0 à 4, nous avons aussi 5 groupes numérotés de 0 à 4. Le groupe 0 aura les noeuds 0,1 & 2. Le groupe 4 aura les noeuds 4,0 & 1. De façon générale, le groupe `n` a les noeuds `n+1` et `n+2` modulo 5. Inversement, le noeud 0 appartiendra donc au groupe 0, 4 & 3. Tout groupe a 3 noeuds et tout noeud appartient à 3 groupes.

Cela se traduit dans le code par :
```elixir
defp nodes_in_group(group_number) do
n = Cluster.static_nb_nodes()
[group_number, rem(group_number + 1 + n, n), rem(group_number + 2 + n, n)]
end

defp groups_of_a_node(node_number) do
n = Cluster.static_nb_nodes()
[node_number, rem(node_number - 1, n), rem(node_number - 2, n)]
end
```
Petite parenthèse, nous avons adapté le code de `Apothik.Cluster`. Voici les éléments principaux: 
```elixir
defmodule Apothik.Cluster do
  alias Apothik.Cache
  use GenServer

  @nb_nodes 5

  @hosts for i <- 0..(@nb_nodes - 1), into: %{}, do: {i, :"apothik_#{i}@127.0.0.1"}

  def static_nb_nodes(), do: @nb_nodes

  def node_name(i), do: @hosts[i]

  def number_from_node_name(node) do
    Enum.find(@hosts, fn {_, v} -> v == node end) |> elem(0)
  end

  (...etc...)
end
```

Une clé est alors assignée à un **groupe** et **non** à un noeud. La fonction `key_to_node/1` devient:
```elixir
defp key_to_group_number(k), do: :erlang.phash2(k, Cluster.static_nb_nodes())
```


Que va-t-il se passer quand on écrit une valeur dans le cache ? On va l'écrire 3 fois.
Tout d'abord, on peut envoyer l'ordre d'écriture à n'importe quel noeud, qui va prendre un noeud au hasard, sauf s'il se trouve que c'est lui-même auquel cas il se privilégie (petite optimisation). Rappelons que l'on peut s'adresser au cache de n'importe quel noeud du cluster ((attention, dans ce texte, l'ordre des fonctions est guidé par la compréhension et ne suit pas nécessairement l'ordre dans le code lui-même))
```elixir
  def put(k, v) do
    alive_node = k |> key_to_group_number() |> pick_a_live_node() |> Cluster.node_name()
    GenServer.call({__MODULE__, alive_node}, {:put, k, v})
  end

  defp pick_a_live_node(group_number) do
    case live_nodes_in_a_group(group_number) do
      [] -> nil
      l -> pick_me_if_possible(l)
    end
  end

  defp live_nodes_in_a_group(group_number),
    do: group_number |> nodes_in_group() |> Enum.filter(&alive?/1)

  defp alive?(node_number) when is_integer(node_number),
    do: node_number |> Cluster.node_name() |> alive?()

  defp alive?(node_name), do: node_name == Node.self() or node_name in Node.list()

  def pick_me_if_possible(l) do
    case Enum.find(l, fn i -> Cluster.node_name(i) == Node.self() end) do
      nil -> Enum.random(l)
      i -> i
    end
  end
```

Notez que l'on n'a pas besoin de garder l'état du cluster par ailleurs. Nous avons une topologie statique et basée sur les noms, donc `Node.list/1` est bien suffisant pour nous renseigner sur l'état de tel ou tel noeud.

Maintenant, le coeur du sujet:
```elixir
  def handle_call({:put, k, v}, _from, state) do
    k
    |> key_to_group_number()
    |> live_nodes_in_a_group()
    |> Enum.reject(fn i -> Cluster.node_name(i) == Node.self() end)
    |> Enum.each(fn replica -> put_as_replica(replica, k, v) end)

    {:reply, :ok, Map.put(state, k, v)}
  end
```

Tout d'abord, on identifie les **autres** noeuds du groupe qui sont en fonction et on lance `put_as_replica/4` sur chacun (je sais pas si vous êtes comme nous, mais on adore les pipelines avec des belles séries de `|>` qui se lisent comme un roman) Ensuite, on modifie l'état du noeud courant avec un classique ` {:reply, :ok, Map.put(state, k, v)}`.

Quant à `put_replica/3`, c'est encore plus simple:
```elixir
  def put_as_replica(replica, k, v) do
    GenServer.cast({__MODULE__, Cluster.node_name(replica)}, {:put_as_replica, k, v})
  end
  def handle_cast({:put_as_replica, k, v}, state) do
    {:noreply, Map.put(state, k, v)}
  end
```

Il faut faire **très attention** à ce que nous avons subrepticement glissé ici. Ca n'a l'air de rien mais **c'est là que nous basculons dans l'enfer des applications distribuées**. Touchons en un mot avant d'y revenir. Nous avons utilisé `GenServer.cast`. Et pas `GenServer.call`. Ce qui signifie que nous envoyons une bouteille à la mer pour dire à nos voisins "met à jour ton cache" mais nous n'attendons pas de retour. Rien ne nous garantit que le message a été traité, nous n'avons pas d'acquittement. Ainsi, les noeuds du groupe n'ont **aucune garantie** d'avoir le même état. 

Pourquoi ne pas mettre un `call` alors? C'est ce que nous avons fait au début, naïfs que nous étions (et nous sommes encore; Il faut visiblement des années de déniaisement dans le monde distribué). Mais nous tombons sur l'enfer du **deadlock**. Si deux noeuds du groupe sont simumtanément sollicités pour mettre à jour le cache, ils peuvent s'attendre indéfiniment. Dans la réalité, il y a un `timeout` standard, que l'on peut changer dans les options de `GensServer.call`, et qui lancer une exception quand il est atteint. Ca y est, nous sommes entrés dans la cour des grands. Plus précisément, nous l'apercevons au travers du grillage.

Voilà ce que ça donne à la fin (notez `get/1`, qui fonctionne comme attendu, et l'absence de `delete` qui serait à l'image de `put`, mais parfois la flemme sort gagnante, voilà tout)
```elixir
defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster

  # Play with groups
  defp nodes_in_group(group_number) do
    n = Cluster.static_nb_nodes()
    [group_number, rem(group_number + 1 + n, n), rem(group_number + 2 + n, n)]
  end

  # Check if a node is alive based on its number
  defp alive?(node_number) when is_integer(node_number),
    do: node_number |> Cluster.node_name() |> alive?()

  # Checks if a node is alive based on its name
  defp alive?(node_name), do: node_name == Node.self() or node_name in Node.list()

  defp live_nodes_in_a_group(group_number),
    do: group_number |> nodes_in_group() |> Enum.filter(&alive?/1)

  def pick_me_if_possible(l) do
    case Enum.find(l, fn i -> Cluster.node_name(i) == Node.self() end) do
      nil -> Enum.random(l)
      i -> i
    end
  end

  defp pick_a_live_node(group_number) do
    case live_nodes_in_a_group(group_number) do
      [] -> nil
      l -> pick_me_if_possible(l)
    end
  end

  defp key_to_group_number(k), do: :erlang.phash2(k, Cluster.static_nb_nodes())

  #### GenServer Interface
  def get(k) do
    alive_node = k |> key_to_group_number() |> pick_a_live_node() |> Cluster.node_name()
    GenServer.call({__MODULE__, alive_node}, {:get, k})
  end

  # Put a {key, value} in the cache
  def put(k, v) do
    alive_node = k |> key_to_group_number() |> pick_a_live_node() |> Cluster.node_name()
    GenServer.call({__MODULE__, alive_node}, {:put, k, v})
  end

  def put_as_replica(replica, k, v) do
    GenServer.cast({__MODULE__, Cluster.node_name(replica)}, {:put_as_replica, k, v})
  end

  def stats(), do: GenServer.call(__MODULE__, :stats)

  def update_nodes(_nodes), do: nil

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  #### Implementation

  @impl true
  def init(_args), do: {:ok, %{}}

  @impl true

  def handle_cast({:put_as_replica, k, v}, state), do: {:noreply, Map.put(state, k, v)}

  @impl true
  def handle_call({:get, k}, _from, state), do: {:reply, Map.get(state, k), state}

  def handle_call({:put, k, v}, _from, state) do
    k
    |> key_to_group_number()
    |> live_nodes_in_a_group()
    |> Enum.reject(fn i -> Cluster.node_name(i) == Node.self() end)
    |> Enum.each(fn replica -> put_as_replica(replica, k, v) end)

    {:reply, :ok, Map.put(state, k, v)}
  end

  def handle_call(:stats, _from, state), do: {:reply, map_size(state), state}
end
```

Vite, vérifions que ça marche. `./scripts/start_cluster.sh` dans un terminal et dans un autre:
```
 % ./scripts/start_master.sh
iex(master@127.0.0.1)1> Master.put(1, :a_key, 100)
:ok
iex(master@127.0.0.1)2> Master.stat
[{0, 0}, {1, 1}, {2, 1}, {3, 1}, {4, 0}]
iex(master@127.0.0.1)3> Master.get(3, :a_key)
100
iex(master@127.0.0.1)4> Master.put(2, :another_key, 200)
:ok
iex(master@127.0.0.1)5> Master.get(3, :another_key)
200
iex(master@127.0.0.1)6> Master.stat
[{0, 1}, {1, 1}, {2, 1}, {3, 2}, {4, 1}]
iex(master@127.0.0.1)7> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)8> Master.stat
[{0, 2993}, {1, 2968}, {2, 3035}, {3, 3031}, {4, 2979}]
iex(master@127.0.0.1)9> Master.sum
15006
```

On voit bien que `:a_key` est sur 3 noeuds. On accède bien au cache de n'importe quel noeud et les données sont bien présentes et quand on a chargé les données sur le cluster, on a bien un total de `15006` valeurs stockées, qui est bien `5002 * 3`.

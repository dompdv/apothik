## Phase 2 : Un Cache distribué, sans redondance, mais avec un cluster dynamique (ajout et perte de machine)

### Comment enlever une machine d'un cluster ?

Une première tentative avec [`Node.stop/0`](https://hexdocs.pm/elixir/Node.html#stop/0).
```
% ./scripts/start_master.sh
iex(master@127.0.0.1)1>  :rpc.call(:"apothik_1@127.0.0.1", Node, :stop, [])
{:error, :not_allowed} 
```
Ca ne marche pas. Nous aurions dû lire la documentation avec plus d'attention car cela ne fonctionne qu'avec des noeuds 
lancés avec `Node.start/3` et pas des noeuds lancés en ligne de commande.

En fait, c'est [`System.stop/0`](https://hexdocs.pm/elixir/System.html#stop/1) qui fait l'affaire:
```
iex(master@127.0.0.1)2> :rpc.call(:"apothik_1@127.0.0.1", System, :stop, [])
:ok
iex(master@127.0.0.1)3> for i<-1..5, do: Master.stat(i)
[{:badrpc, :nodedown}, 0, 0, 0, 0]
```

Essayons de remplir le cache
```
iex(master@127.0.0.1)5> Master.fill(1, 5000)
:ok
iex(master@127.0.0.1)6> for i<-1..5, do: Master.stat(i)
[{:badrpc, :nodedown}, 0, 0, 0, 0]
```

Le cache n'est pas rempli ?? Après réflexion, c'est normal. `Master.fill(1,5000)` essaie de le remplir via le noeud 1 que nous avons arrêté!
Recommençons depuis le début. On relance le cluster dans le premier terminal `% ./scripts/start_cluster.sh`. Et dans le second:
```
% ./scripts/start_master.sh
iex(master@127.0.0.1)1> Master.fill(2, 5000)
:ok
iex(master@127.0.0.1)2> for i<-1..5, do: Master.stat(i)
[1023, 987, 1050, 993, 947]
iex(master@127.0.0.1)3> :rpc.call(:"apothik_1@127.0.0.1", System, :stop, [])
:ok
iex(master@127.0.0.1)4> for i<-1..5, do: Master.stat(i)
[{:badrpc, :nodedown}, 987, 1050, 993, 947]
```

On a bien perdu les 1023 clés du noeud 1.

### Monitorer dynamiquement l'état du serveur

Le problème, c'est que le nombre de machines était fixé dans `Apothik.Cluster` avec `@nb_nodes 5`. 
Ce que l'on souhaite, c'est que la fonction `key_to_node/1` s'adapte automatiquement au nombre de machines qui fonctionnent.

Pour cela, il faut que l'on puisse monitorer le fait que des machines sortent ou entrent dans le cluster. C'est possible grâce à la fonction [`:net_kernel.monitor_nodes/1`](https://www.erlang.org/docs/25/man/net_kernel#monitor_nodes-2) qui permet à un processus de s'abonner aux événements du cycle de vie des noeuds.

Nous faisons évoluer `apothik/cluster.ex` pour monitorer le cluster:
```elixir
defmodule Apothik.Cluster do
  alias Apothik.Cache
  use GenServer

  def nb_nodes(), do: GenServer.call(__MODULE__, :nb_nodes)

  def node_name(i), do: :"apothik_#{i}@127.0.0.1"

  def node_list(nb_node) do
    for i <- 1..nb_node, do: node_name(i)
  end

  def list_apothik_nodes() do
    [Node.self() | Node.list()] |> Enum.filter(&apothik?/1) |> Enum.sort()
  end

  def apothik?(node), do: node |> Atom.to_string() |> String.starts_with?("apothik")

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  def get_state(), do: GenServer.call(__MODULE__, :get_state)

  @impl true
  def init(_args) do
    :net_kernel.monitor_nodes(true)
    {:ok, list_apothik_nodes()}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {Node.self(), state}, state}
  end

  def handle_call(:nb_nodes, _from, state) do
    {:reply, length(state), state}
  end

  @impl true
  def handle_info({:nodedown, _node}, _state) do
    nodes = list_apothik_nodes()
    Cache.update_nodes(nodes)
    {:noreply, nodes}
  end

  def handle_info({:nodeup, _node}, _state) do
    nodes = list_apothik_nodes()
    Cache.update_nodes(nodes)
    {:noreply, nodes}
  end

  def handle_info(msg, state) do
    IO.inspect(msg)
    {:noreply, state}
  end
end

```

Ce n'est plus une simple librairie mais un `GenServer` qu'il faut lancer dans l'arbre de supervision, depuis `apothik/application.ex`
```elixir
children = [
    {Cluster.Supervisor, [topologies, [name: Apothik.ClusterSupervisor]]},
    Apothik.Cluster,
    Apothik.Cache
]
```

Ce `GenServer` maintient la liste des noeuds du cluster (on prend toute la liste de noeuds connectés et on ne retient 
que ceux dont le nom commence par `apothik`. C'est ce que fait `list_apothik_nodes/0`).

Le processus s'abonne aux événements dans `init/1` avec `:net_kernel.monitor_nodes(true)`. Puis il réagit aux événements `{:nodeup, node}` et `{:nodedown, _node}`. A ce stade, nous avons un GenServer qui connait la liste des noeuds du cluster à chaque instant.

### Adapter dynamiquement le nombre de machines

Nous avons choisi (est-ce la meilleure solution, le débat n'est pas tranché entre nous) que cette liste dynamique soit immédiatement communiquée à `Apothik.Cache`. 
Ce dernier évolue:
- son état est maintenant un couple `{liste de noeud du cluster, memoire cache}`. Voir l'initialisation dans `init/1`
- les fonctions `get` etc sont adaptées pour tenir compte de ce changement de structure de l'état
- une fonction `update_nodes/1` permet de mettre à jour la liste des noeuds. Elle est appelée par `Apothik.Cluster` à chaque événement
- la fonction `key_to_node/1` a bien changé. Elle n'est plus exécutée par le code appelant, mais exécutée dans le processus `Apothik.Cache`.
```elixir
defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster

  # Interface
  (... same as before ...)

  def update_nodes(nodes) do
    GenServer.call(__MODULE__, {:update_nodes, nodes})
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Implementation

  defp key_to_node(k), do: GenServer.call(__MODULE__, {:key_to_node, k})

  @impl true
  def init(_args) do
    {:ok, {Cluster.get_state(), %{}}}
  end

  @impl true
  def handle_call({:get, k}, _from, {_, mem} = state) do
    {:reply, Map.get(mem, k), state}
  end

  def handle_call({:put, k, v}, _from, {nodes, mem}) do
    new_mem = Map.put(mem, k, v)
    {:reply, :ok, {nodes, new_mem}}
  end

  def handle_call({:delete, k}, _from, {nodes, mem}) do
    new_mem = Map.delete(mem, k)
    {:reply, :ok, {nodes, new_mem}}
  end

  def handle_call(:stats, _from, {_nodes, mem} = state) do
    {:reply, map_size(mem), state}
  end

  def handle_call({:update_nodes, nodes}, _from, {_, mem}) do
    IO.inspect("Updating nodes: #{inspect(nodes)}")
    {:reply, :ok, {nodes, mem}}
  end

  def handle_call({:key_to_node, k}, _from, {nodes, _mem} = state) do
    node = Enum.at(nodes, :erlang.phash2(k, length(nodes)))
    {:reply, node, state}
  end

  @impl true
  def handle_info(msg, state) do
    IO.inspect(msg)
    {:noreply, state}
  end
end
```

Commentons un peu plus en détail
```elixir
  def handle_call({:key_to_node, k}, _from, {nodes, _mem} = state) do
    node = Enum.at(nodes, :erlang.phash2(k, length(nodes)))
    {:reply, node, state}
  end
```

`phash2` renvoie un nombre entre 0 et le nombre de noeuds du cluster - 1. 
Ce nombre ne correspond plus directement à un nom de serveur mais à un indice dans la liste de noeuds. On voit bien que la même clé avant et après le départ d'un serveur a toutes les chances de ne pas se retrouver au même endroit.


### Un petit essai: enlever une machine

Pour se simplifier la vie, on ajoute dans `.iex.exs`
```elixir
  def kill(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", System, :stop, [0])
  end
  def cluster(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cluster, :get_state, [])
  end

```

On relance le cluster (`/scripts/start_cluster.sh) et on se lance dans des expériences:
```
 % ./scripts/start_master.sh
iex(master@127.0.0.1)1> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)2> Master.stat
[{1, 1026}, {2, 996}, {3, 1012}, {4, 1021}, {5, 945}]
iex(master@127.0.0.1)3> (for {_, n} <- Master.stat, is_integer(n), do: n) |> Enum.sum
5000
iex(master@127.0.0.1)4> Master.kill(2)
:ok
iex(master@127.0.0.1)5> Master.stat
[{1, 1026}, {2, {:badrpc, :nodedown}}, {3, 1012}, {4, 1021}, {5, 945}]
iex(master@127.0.0.1)6> (for {_, n} <- Master.stat, is_integer(n), do: n) |> Enum.sum
4004
iex(master@127.0.0.1)7> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)8> (for {_, n} <- Master.stat, is_integer(n), do: n) |> Enum.sum
8056
```

Après avoir rempli le cache avec 5000 valeurs, on supprime le noeud 2. On a bien perdu environ 1000 valeurs (996 pour être précis). On reremplit le cache avec les mêmes 5000 valeurs. On voit alors qu'il n'y a pas 5000 valeurs en plus. En effet, certaines clés étaient au bon endroit. Il y a eu création de 8056-4004=4052 d'entrées dans la mémoire du cache, ce qui signifie que 5000-4052= 948 valeurs n'ont pas migré de noeud. C'est un peu normal, car lorsqu'on est passé de 5 à 4 machines, les clés se sont retrouvées rebalancées de façon aléatoire. Il y avait donc une probabilité de 20% (ou de 25%, je laisse les commentateurs nous dire) que des clés soient au bon endroit.

### Deuxième essai: ajouter une machine

Maintenant, nous pouvons faire l'expérience inverse, c'est à dire ajouter une machine. On repart de 0, en relançant le cluster dans un terminal `./scripts/start_cluster.sh` et, dans un autre terminal:
``` 
% ./scripts/start_master.sh 
iex(master@127.0.0.1)1> Master.kill(2)
:ok
iex(master@127.0.0.1)2> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)3> Master.stat
[{1, 1228}, {2, {:badrpc, :nodedown}}, {3, 1290}, {4, 1228}, {5, 1254}]
```

On a rempli le cache sur un cluster à 4 noeuds. Maintenant, on ouvre encore un autre terminal pour relancer le noeud `apothik_2` que l'on vient d'arrêter: `elixir --name apothik_2@127.0.0.1 -S mix run --no-halt`

On revient dans le terminal du master:
```
4> Master.stat
[  {1, 1228},  {2, 0},  {3, 1290},  {4, 1228},  {5, 1254}]
iex(master@127.0.0.1)5> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)6> Master.stat
[  {1, 2032},  {2, 996},  {3, 2027},  {4, 2027},  {5, 1970}]
```
C'est positif: le noeud a bien été réintégré au cluster automatiquement! Le but est donc atteint.

On constate bien un rebalancement aléatoire des clés sur les 5 noeuds, ce qui conduit les noeuds à garder en mémoire des clés inutiles (environ 1000).

On vous laisse essayer d'ajouter une nouvelle machine `apothik_6` et observer ce qui se passe.

### Interlude: nettoyer un peu

Nous sommes allés au plus vite quand nous avons ajouté le suivi des noeuds qui entrent et sortent du cluster. Souvenez-vous, `Apothik.Cluster` qui suit les entrées et sorties de noeuds dans le cluster informe `Apothik.Cache` à chaque changement. Celui-ci est un `GenServer` qui conserve l'état du cluster dans son état.

Mais cela conduit à quelque chose de très laid: à chaque fois que l'on fait une demande au cache, on fait une demande au process `Apothik.Cache` pour qu'il calcule le noeud pour la clé via un `GenServer.call`.

Précisément, lorsque l'on lance `:rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :get, [:a_key])` du master, un process est lancé sur `apothik_1` pour exécuter le code `Apothik.Cache.get/1`. Ce process demande alors au process nommé `Apothik.Cache` sur le noeud `apothik_1` sur quel noeud est stocké la clé `:a_key` (supposons par exemple le noeud `2`) puis demande au process `Apothik.Cache` du noeud `apothik_2` la valeur stockée pour `a_key`. Cette valeur est alors envoyée au process appelant du master qui exécute le `:rpc`. C'est assez vertigineux que tout cela fonctionne sans effort. La magie d'Erlang, une fois de plus.

Mais cet aller-retour initial de `key_to_node/1` peut être évité. Il faudrait que l'on puisse stocker des informations accessibles par tous les process du noeud. La solution existe depuis longtemps dans l'univers Erlang. C'est le fameux [Erlang Term Storage, dit `ets`](https://www.erlang.org/docs/23/man/ets). 

Après adaptation, le cache ressemble à ça:
```elixir
defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster
  require Logger

  (... same as before ...)

  def update_nodes(nodes) do
    GenServer.call(__MODULE__, {:update_nodes, nodes})
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Implementation

  defp key_to_node(k) do
    [{_, nodes}] = :ets.lookup(:cluster_nodes_list, :cluster_nodes)
    Enum.at(nodes, :erlang.phash2(k, length(nodes)))
  end

  @impl true
  def init(_args) do
    :ets.new(:cluster_nodes_list, [:named_table, :set, :protected])
    :ets.insert(:cluster_nodes_list, {:cluster_nodes, Cluster.get_state()})
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get, k}, _from, state) do
    {:reply, Map.get(state, k), state}
  end

  def handle_call({:put, k, v}, _from, state) do
    {:reply, :ok, Map.put(state, k, v)}
  end

  def handle_call({:delete, k}, _from, state) do
    {:reply, :ok, Map.delete(state, k)}
  end

  def handle_call(:stats, _from, state) do
    {:reply, map_size(state), state}
  end

  def handle_call({:update_nodes, nodes}, _from, state) do
    Logger.info("Updating nodes: #{inspect(nodes)}")
    :ets.insert(:cluster_nodes_list, {:cluster_nodes, nodes})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning(msg)
    {:noreply, state}
  end
end
```

Notez, dans `init/1`:
```elixir 
:ets.new(:cluster_nodes_list, [:named_table, :set, :protected])
:ets.insert(:cluster_nodes_list, {:cluster_nodes, Cluster.get_state()})
```
Nous utilisons une table nommée `:cluster_nodes_list`, dans laquelle seul le process créateur peut écrire mais qui est accessible par tous les processus du noeud. C'est le sens de l'option `:protected`. Dans cette table, qui se comporte comme une `map`, nous avons une seule clé `:cluster_nodes_list` qui contient la liste des noeuds du cluster. 

Nous sommes arrivés à notre but, car `key_to_node/1` peut s'exécuter directement:
```elixir
defp key_to_node(k) do
    [{_, nodes}] = :ets.lookup(:cluster_nodes_list, :cluster_nodes)
    Enum.at(nodes, :erlang.phash2(k, length(nodes)))
end
```

On vous laisse vérifier que tout marche bien. Fin de l'interlude !

### Critique du fonctionnement actuel et solution possible

Quelque chose ne nous plait pas. L'arrivée ou la sortie d'un noeud dans le cluster est un cataclysme. Toutes les clés sont rebalancées. Cela conduit à un cache qui va subitement baisser en performance à chaque fois qu'un tel événement survient, car les clés ne seront plus disponibles. Et à avoir des mémoires pleines de clés inutiles. Finalement, un événement qui devrait être local, voire insignifiant dans le cas d'un très grand cluster, chamboule la totalité du cluster. Comment rendre la distribution des clés  moins sensible à la structure du cluster ?

Après discussion entre nous et quelques pages de bloc-notes, une solution se forme. Comment souvent en informatique, la solution est d'ajouter un niveau d'indirection.

L'idée est de se donner des jetons ("tokens") (pour fixer les idées, prenons 1000 tokens, numérotés de 0 à 999). Nous allons distribuer les clés sur les tokens et non les machines, avec quelque chose comme `:erlang.phash2(k, @nb_tokens)`. Ce nombre de tokens est fixe. Il n'y a pas création ou suppression de tokens à l'arrivée ou à l'ajout d'un serveur dans le cluster. Les tokens sont distribués sur les machines. L'arrivée ou le départ d'une machine va conduire à une redistribution de tokens. Mais nous contrôlons cette redistribution, donc nous pouvons faire qu'elle affecte de façon minimale le rebalancement des clés.

### Mise en oeuvre de la solution

Première remarque, `Apothik.Cluster` ne change pas. Sa responsabilité est de suivre l'état du cluster et de prévenir `Apothik.Cache`. Point final.

A l'initialisation du cache, nous distribuons équitablement les `@nb_tokens` sur les machines. Avec 5 machines et 1000 tokens, `apothik_1` va recevoir les tokens de 0 à 199, etc. Les jetons sont stockés dans la table `:ets` en associant le nom du noeud à sa liste de jetons avec un `:ets.insert(:cluster_nodes_list, {node, tokens})`.

Le premier point important est `key_to_node/1`. On trouve d'abord le token associé à la clé. Puis on parcourt les noeuds jusqu'à trouver celui auquel est associé le token. Voici ce que cela donne:
```elixir
  defp key_to_node(k) do
    landing_token = :erlang.phash2(k, @nb_tokens)
    nodes_tokens = :ets.match(:cluster_nodes_list, {:"$1", :"$2"})

    Enum.reduce_while(nodes_tokens, nil, fn [node, tokens], _ ->
      if landing_token in tokens, do: {:halt, node}, else: {:cont, nil}
    end)
  end
```

Le deuxième point est la gestion des événements d'arrivée et sortie. La première étape est de déterminer quel type d'événement (arrivée ou départ). Cela se fait dans `def handle_call({:update_nodes, nodes}, _from, state)` en comparant la nouvelle liste de noeud fournie à celle présente dans la table `ets`.

Quand un noeud est supprimé du cluster, ses tokens sont distribués de façon la plus égale possible sur les autres noeuds. Quand un noeud est ajouté dans le cluster, on retire le même nombre de tokens de chaque noeud pour l'apporter au nouveau. Le nombre de token retiré est calculé pour que le nombre de tokens soit distribué de façon égale après la redistribution.

Voici ce que cela donne (le code, un peu commenté néammoins, n'est pas très élégant, il mériterait probablement une passe de nettoyage):
```elixir
defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster
  require Logger

  @nb_tokens 1000

  (... same as before ...)

  # Convenience function to access the current token distribution on the nodes
  def get_tokens(), do: :ets.match(:cluster_nodes_list, {:"$1", :"$2"})

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Implementation

  defp key_to_node(k) do
    # Find the token associated with the key k
    landing_token = :erlang.phash2(k, @nb_tokens)
    # Retrieve the tokens per node
    nodes_tokens = :ets.match(:cluster_nodes_list, {:"$1", :"$2"})

    Enum.reduce_while(nodes_tokens, nil, fn [node, tokens], _ ->
      if landing_token in tokens, do: {:halt, node}, else: {:cont, nil}
    end)
  end

  def add_node(added, previous_nodes_tokens) do
    added_node = hd(added)
    previous_nodes = for [node, _] <- previous_nodes_tokens, do: node
    target_tokens_per_node = div(@nb_tokens, length(previous_nodes) + 1)

    # Collect a "toll" from each node to give to the new node
    {tokens_for_added_node, tolled_nodes_tokens} =
      Enum.reduce(
        previous_nodes_tokens,
        # {collected tokens, adjusted list of tokens per nodes}
        {[], []},
        fn [node, tokens], {tolls, target_nodes_tokens} ->
          {remainder, toll} = Enum.split(tokens, target_tokens_per_node)
          {tolls ++ toll, [{node, remainder} | target_nodes_tokens]}
        end
      )

    # Update table : add the new node and update the tokens per node for existing ones
    [{added_node, tokens_for_added_node} | tolled_nodes_tokens]
    |> Enum.each(fn {node, tokens} ->
      :ets.insert(:cluster_nodes_list, {node, tokens})
    end)
  end

  def remove_node(removed, previous_nodes_tokens) do
    removed_node = hd(removed)

    # Retrieve  available tokens from the removed node and remove the node from the list
    {[[_, tokens_to_share]], remaining_nodes} =
      Enum.split_with(previous_nodes_tokens, fn [node, _] -> node == removed_node end)

    # Distribute the tokens evenly among the remaining nodes
    tokens_to_share
    |> split_evenly(length(remaining_nodes))
    |> Enum.zip(remaining_nodes)
    |> Enum.each(fn {tokens_chunk, [node, previous_tokens]} ->
      :ets.insert(:cluster_nodes_list, {node, previous_tokens ++ tokens_chunk})
    end)

    # remove the node from the table
    :ets.delete(:cluster_nodes_list, removed_node)
  end

  @impl true
  def init(_args) do
    # Initialize the :ets table
    :ets.new(:cluster_nodes_list, [:named_table, :set, :protected])
    # Retrieve the current list of nodes
    {_, nodes} = Cluster.get_state()
    # Distribute evenly the tokens over the nodes in the cluster and store them in the :ets table
    number_of_tokens_per_node = div(@nb_tokens, length(nodes))

    0..(@nb_tokens - 1)
    |> Enum.chunk_every(number_of_tokens_per_node)
    |> Enum.zip(nodes)
    |> Enum.each(fn {tokens, node} ->
      :ets.insert(:cluster_nodes_list, {node, tokens})
    end)

    {:ok, %{}}
  end
(...)

  def handle_call({:update_nodes, nodes}, _from, state) do
    previous_nodes_tokens = :ets.match(:cluster_nodes_list, {:"$1", :"$2"})
    previous_nodes = for [node, _] <- previous_nodes_tokens, do: node
    # Is it a nodedown or a nodeup event ? and identify the added or removed node
    added = MapSet.difference(MapSet.new(nodes), MapSet.new(previous_nodes)) |> MapSet.to_list()
    removed = MapSet.difference(MapSet.new(previous_nodes), MapSet.new(nodes)) |> MapSet.to_list()

    cond do
      length(added) == 1 -> add_node(added, previous_nodes_tokens)
      length(removed) == 1 -> remove_node(removed, previous_nodes_tokens)
      true -> :ok
    end

    {:reply, :ok, state}
  end

  (...)

  # Utility function
  # Split a list into chunks of same length
  def split_evenly([], acc, _), do: Enum.reverse(acc)
  def split_evenly(l, acc, 1), do: Enum.reverse([l | acc])

  def split_evenly(l, acc, n) do
    {chunk, rest} = Enum.split(l, max(1, div(length(l), n)))
    split_evenly(rest, [chunk | acc], n - 1)
  end

  def split_evenly(l, n), do: split_evenly(l, [], n)
end
```

(notez que le `split_evenly/2` a été ajouté car probablement mauvais usage de `Enum.chunk_every/3` nous faisait perdre des tokens. Parfois, il est plus facile de coder sa solution).

On ajoute dans `.iex.exs`de quoi vérifier comment bougent les tokens:
```elixir 
  def get_tokens(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :get_tokens, [])
  end
  def check_tokens(i) do
    tk = get_tokens(i)
     (for [_n,t]<-tk, do: t) |> List.flatten() |> Enum.uniq() |> length
  end
```

Momentanément, on change le nombre de tokens `@nb_tokens 10`.
```
% ./scripts/start_master.sh
iex(master@127.0.0.1)1> Master.get_tokens(1)
[
  [:"apothik_5@127.0.0.1", ~c"\b\t"],
  [:"apothik_4@127.0.0.1", [6, 7]],
  [:"apothik_3@127.0.0.1", [4, 5]],
  [:"apothik_2@127.0.0.1", [2, 3]],
  [:"apothik_1@127.0.0.1", [0, 1]]
]
```

On remet `@nb_tokens 1000` et on relance tout:
```
% ./scripts/start_master.sh
iex(master@127.0.0.1)1> Master.check_tokens(1)
1000
```

Ca marche, maintenant que se passe-t-il si on enlève un noeud ?

```
iex(master@127.0.0.1)2> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)3> Master.stat
[  {1, 1016},  {2, 971},  {3, 970},  {4, 985},  {5, 1058}]
iex(master@127.0.0.1)4> Master.kill(2)
:ok
iex(master@127.0.0.1)5> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)6> Master.stat
[  {1, 1265},  {2, {:badrpc, :nodedown}},  {3, 1238},  {4, 1224},  {5, 1273} ]
iex(master@127.0.0.1)7> Master.check_tokens(1)
1000
```

Dans un autre terminal, on relance `apothik_2`: `% elixir --name apothik_2@127.0.0.1 -S mix run --no-halt`. En revenant dans master:
```
iex(master@127.0.0.1)8> Master.stat
[  {1, 1265},  {2, 0},  {3, 1238},  {4, 1224},  {5, 1273} ]
iex(master@127.0.0.1)9> Master.fill(1,5000)
:ok
iex(master@127.0.0.1)10> Master.stat
[  {1, 1265},  {2, 971},  {3, 1238},  {4, 1224},  {5, 1273}]
iex(master@127.0.0.1)11> Master.check_tokens(1)
1000
iex(master@127.0.0.1)12> for [_n,t]<-Master.get_tokens(1), do: length(t)
[200, 200, 200, 200, 200]
```

On n'a pas perdu de token au passage, et ils sont bien répartis équitablement après le retour de `apothik_2`.

Que se passe-t-il dans les mémoires des serveurs? Les clés de `apothik_2` on bien été perdues quand il est mort. Quand on recharge alors le système avec les mêmes clés, on répartit environ 1000 clés sur les autres. Après son retour et un rechargement, on se retrouve avec un surplus de 265+238+224+273=1000 clés. Ce qui est cohérent. 

Une remarque: nous avons conçu notre système de redistribution de token sans trop y réfléchir. Nous soupçonnons d'abord qu'il pourrait dériver (c'est à dire que l'on pourrait s'éloigner d'une répartition équitable. En tout cas, cela reste à terster). Mais surtout, nous nous doutons bien qu'il doit y avoir une approche optimale de distribution des tokens pour garantir un minimum de changements.

C'est typiquement le moment où l'on se dit : "Je découvre un domaine et je bute sur une question bien compliquée. Des gens plus intelligents ont déjà réfléchi au problème et mis cela dans une librairie". Nous n'avons pas touvé la réponse, mais au moins, nous comprenons un peu la question !

Nous vous recommandons d'aller voir [libring](https://github.com/bitwalker/libring) ou bien [ex_hash_ring](https://hex.pm/packages/ex_hash_ring) de Discord.

###  Petit récapitulatif de la phase 2:

Nous avons un système distribué qui réagit automatiquement aux arrivées et départs de noeuds dans le cluster. Nous avons aussi amélioré la solution initiale pour le rendre moins sensible aux changements du cluster (arrivée et départs de noeuds). Au passage, notre solution n'est plus sensible au nom du noeud (tout noeud dont le nom commence par `apothik` peut rejoindre le cluster).

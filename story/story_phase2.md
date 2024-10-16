## Phase 2 : Un Cache distribué, sans redondance, mais avec un cluster dynamique (ajout et perte de machine)

### Comment enlever une machine d'un cluster ?

Une première tentative avec [`Node.stop/0`]( :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :stats, [])).
```
% ./scripts/start_master.sh
iex(master@127.0.0.1)1>  :rpc.call(:"apothik_1@127.0.0.1", Node, :stop, [])
{:error, :not_allowed} 
```
Ca ne marche pas. Nous aurions dû lire la documentation avec plus d'attention car cela fonction avec des noeuds 
lancés avec `Node.start/3` et pas des noeuds lancés en ligne de commande.

En fait, c'est `System.stop/0` qui fait l'affaire:
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

Pour cela, il faut que l'on puisse monitorer le fait que des machines sortent ou entrent dans le cluster. 
C'est possible grâce à la fonction [`:net_kernel.monitor_nodes/1`](https://www.erlang.org/docs/25/man/net_kernel#monitor_nodes-2) qui permet à un processus de s'abonner aux événements du cycle de vie des noeuds.

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

Ce n'est plus une simple librairie mais un `GenServer` qui faut lancer dans l'arbre de supervision, dans `apothik/application.ex`
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
- les fonctions `get` etc sont adaptée pour tenir compte de ce changement de structure de l'état
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

`phash2` renvoie un nombre entre 0 et le nombre de noeud du cluster - 1. 
Ce nombre ne correspond plus directement à un nom de serveur mais à un indice dans la liste de noeud. On voit bien que la même clé avant et après le départ d'un serveur a toutes les chances de ne pas se retrouver au même endroit.


### Un petit essai

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

Après avoir rempli le cache avec 5000 valeurs, on supprime le noeud 2. On a bien perdu environ 1000 valeurs (996 pour être précis). On reremplit le cache avec les mêmes 5000 valeurs. On voit alors qu'il n'y a pas 5000 valeurs en plus. En effet, certaines clés étaient au bon endroit. Il y a eu création de 8056-4004=4052 d'entrées dans la mémoire du cache, ce qui signifie que 5000-4052= 948 valeurs n'ont pas migré de noeud.



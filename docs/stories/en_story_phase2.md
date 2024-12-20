---
title: Discovering Distributed Applications with Elixir - Part 2
---

<a href="/apothik/">Home</a>
<a href="en_story_phase1.html"> Part 1</a>
<a href="en_story_phase3.html"> Part 3</a>


# Phase 2: A Distributed Cache, Without Redundancy, with a Dynamic Cluster

## How to Remove a Machine from a Cluster?

A first attempt with [`Node.stop/0`](https://hexdocs.pm/elixir/Node.html#stop/0).
```
% ./scripts/start_master.sh
1>  :rpc.call(:"apothik_1@127.0.0.1", Node, :stop, [])
{:error, :not_allowed} 
```
It doesn't work. We should have read the documentation more carefully because it only works with nodes started with `Node.start/3` and not nodes started from the command line.

In fact, it's [`System.stop/0`](https://hexdocs.pm/elixir/System.html#stop/1) that does the job:
```
2> :rpc.call(:"apothik_1@127.0.0.1", System, :stop, [])
:ok
3> for i<-1..5, do: Master.stat(i)
[{:badrpc, :nodedown}, 0, 0, 0, 0]
```

Let's try to fill the cache
```
5> Master.fill(1, 5000)
:ok
6> for i<-1..5, do: Master.stat(i)
[{:badrpc, :nodedown}, 0, 0, 0, 0]
```

The cache is not filled?? Upon reflection, it's normal. `Master.fill(1,5000)` tries to fill it via node 1 which we stopped!
Let's start over. Restart the cluster in the first terminal `% ./scripts/start_cluster.sh`. And in the second:
```
% ./scripts/start_master.sh
1> Master.fill(2, 5000)
:ok
2> for i<-1..5, do: Master.stat(i)
[1023, 987, 1050, 993, 947]
3> :rpc.call(:"apothik_1@127.0.0.1", System, :stop, [])
:ok
4> for i<-1..5, do: Master.stat(i)
[{:badrpc, :nodedown}, 987, 1050, 993, 947]
```

We have indeed lost the 1023 keys from node 1.

## Dynamically Monitoring the Server State

The problem is that the number of machines was fixed in `Apothik.Cluster` with `@nb_nodes 5`. 
What we want is for the `key_to_node/1` function to automatically adapt to the number of machines that are running.

To do this, we need to monitor the fact that machines are leaving or joining the cluster. This is possible thanks to the [`:net_kernel.monitor_nodes/1`](https://www.erlang.org/docs/25/man/net_kernel#monitor_nodes-2) function which allows a process to subscribe to node lifecycle events.

We update `apothik/cluster.ex` to monitor the cluster:
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

It's no longer a simple library but a `GenServer` that needs to be launched in the supervision tree, from `apothik/application.ex`
```elixir
children = [
    {Cluster.Supervisor, [topologies, [name: Apothik.ClusterSupervisor]]},
    Apothik.Cluster,
    Apothik.Cache
]
```

This `GenServer` maintains the list of nodes in the cluster (we take the entire list of connected nodes and only keep those whose name starts with `apothik`. This is what `list_apothik_nodes/0` does).

The process subscribes to events in `init/1` with `:net_kernel.monitor_nodes(true)`. Then it reacts to `{:nodeup, node}` and `{:nodedown, _node}` events. At this stage, we have a GenServer that knows the list of nodes in the cluster at any given time.

## Dynamically Adapting the Number of Machines

We have chosen (is it the best solution, the debate is not settled among us) that this dynamic list is immediately communicated to `Apothik.Cache`. 
The latter evolves:
- its state is now a tuple `{list of cluster nodes, cache memory}`. See the initialization in `init/1`
- the `get` etc functions are adapted to take into account this change in state structure
- an `update_nodes/1` function allows updating the list of nodes. It is called by `Apothik.Cluster` at each event
- the `key_to_node/1` function has indeed changed. It is no longer executed by the calling code, but executed in the `Apothik.Cache` process.
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

Let's comment a bit more in detail
```elixir
  def handle_call({:key_to_node, k}, _from, {nodes, _mem} = state) do
    node = Enum.at(nodes, :erlang.phash2(k, length(nodes)))
    {:reply, node, state}
  end
```

`phash2` returns a number between 0 and the number of cluster nodes - 1. 
This number no longer directly corresponds to a server name but to an index in the list of nodes. We can see that the same key before and after a server leaves is very likely to end up in a different place.


## A Small Test: Removing a Machine

To simplify our lives, we add in `.iex.exs`
```elixir
  def kill(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", System, :stop, [0])
  end
  def cluster(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cluster, :get_state, [])
  end

```

We restart the cluster (`/scripts/start_cluster.sh) and start experimenting:
```
 % ./scripts/start_master.sh
1> Master.fill(1,5000)
:ok
2> Master.stat
[{1, 1026}, {2, 996}, {3, 1012}, {4, 1021}, {5, 945}]
3> (for {_, n} <- Master.stat, is_integer(n), do: n) |> Enum.sum
5000
4> Master.kill(2)
:ok
5> Master.stat
[{1, 1026}, {2, {:badrpc, :nodedown}}, {3, 1012}, {4, 1021}, {5, 945}]
6> (for {_, n} <- Master.stat, is_integer(n), do: n) |> Enum.sum
4004
7> Master.fill(1,5000)
:ok
8> (for {_, n} <- Master.stat, is_integer(n), do: n) |> Enum.sum
8056
```

After filling the cache with 5000 values, we remove node 2. We have indeed lost about 1000 values (996 to be precise). We refill the cache with the same 5000 values. We then see that there are not 5000 additional values. Indeed, some keys were in the right place. There were 8056-4004=4052 entries created in the cache memory, which means that 5000-4052= 948 values did not migrate to a different node. This is somewhat normal, as when we went from 5 to 4 machines, the keys were randomly rebalanced. There was therefore a 20% (or 25%, I'll let the commentators tell us) probability that some keys were in the right place.
## Second Attempt: Adding a Machine

Now, we can do the reverse experiment, i.e., adding a machine. Let's start from scratch by restarting the cluster in one terminal with `./scripts/start_cluster.sh` and, in another terminal:
``` 
% ./scripts/start_master.sh 
1> Master.kill(2)
:ok
2> Master.fill(1,5000)
:ok
3> Master.stat
[{1, 1228}, {2, {:badrpc, :nodedown}}, {3, 1290}, {4, 1228}, {5, 1254}]
```

We have filled the cache on a 4-node cluster. Now, let's open another terminal to restart the `apothik_2` node that we just stopped: `elixir --name apothik_2@127.0.0.1 -S mix run --no-halt`

Back in the master terminal:
```
4> Master.stat
[  {1, 1228},  {2, 0},  {3, 1290},  {4, 1228},  {5, 1254}]
5> Master.fill(1,5000)
:ok
6> Master.stat
[  {1, 2032},  {2, 996},  {3, 2027},  {4, 2027},  {5, 1970}]
```
This is positive: the node has been automatically reintegrated into the cluster! The goal is achieved.

We can see a random rebalancing of keys across the 5 nodes, which leads the nodes to keep unnecessary keys in memory (about 1000).

We leave it to you to try adding a new machine `apothik_6` and observe what happens.

## Interlude: Cleaning Up a Bit

We went as fast as possible when we added node tracking to the cluster. Remember, `Apothik.Cluster` tracks nodes entering and leaving the cluster and informs `Apothik.Cache` of each change. The latter is a `GenServer` that maintains the cluster state in its state.

But this leads to something very ugly: every time we make a request to the cache, we make a request to the `Apothik.Cache` process to calculate the node for the key via a `GenServer.call`.

Specifically, when we run `:rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :get, [:a_key])` from the master, a process is launched on `apothik_1` to execute the `Apothik.Cache.get/1` code. This process then asks the process named `Apothik.Cache` on the `apothik_1` node which node stores the key `:a_key` (let's say node `2`), then asks the `Apothik.Cache` process on node `apothik_2` for the value stored for `a_key`. This value is then sent to the calling process on the master that executes the `:rpc`. It's quite dizzying that all this works effortlessly. The magic of Erlang, once again.

But this initial round trip of `key_to_node/1` can be avoided. We need to store information accessible by all processes on the node. The solution has long existed in the Erlang world. It's the famous [Erlang Term Storage, or `ets`](https://www.erlang.org/docs/23/man/ets).

After adaptation, the cache looks like this:
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

Note, in `init/1`:
```elixir 
:ets.new(:cluster_nodes_list, [:named_table, :set, :protected])
:ets.insert(:cluster_nodes_list, {:cluster_nodes, Cluster.get_state()})
```
We use a named table `:cluster_nodes_list`, in which only the creator process can write but which is accessible by all processes on the node. This is the meaning of the `:protected` option. In this table, which behaves like a `map`, we have a single key `:cluster_nodes_list` that contains the list of cluster nodes.

We have achieved our goal, as `key_to_node/1` can now execute directly:
```elixir
defp key_to_node(k) do
    [{_, nodes}] = :ets.lookup(:cluster_nodes_list, :cluster_nodes)
    Enum.at(nodes, :erlang.phash2(k, length(nodes)))
end
```

We leave it to you to verify that everything works well. End of the interlude!

## Critique of the Current Functionality and Possible Solution

Something doesn't sit right with us. The arrival or departure of a node in the cluster is catastrophic. All keys are rebalanced. This leads to a cache that will suddenly drop in performance each time such an event occurs, as the keys will no longer be available. Additionally, the memory will be filled with unnecessary keys. Ultimately, an event that should be local, or even insignificant in the case of a very large cluster, disrupts the entire cluster. How can we make the distribution of keys less sensitive to the cluster's structure?

After discussing among ourselves and jotting down a few pages of notes, a solution is forming. As is often the case in computing, the solution is to add a level of indirection.

The idea is to use tokens (let's fix the idea with 1000 tokens, numbered from 0 to 999). We will distribute the keys on the tokens and not the machines, with something like `:erlang.phash2(k, @nb_tokens)`. This number of tokens is fixed. There is no creation or deletion of tokens when a server joins or leaves the cluster. The tokens are distributed across the machines. The arrival or departure of a machine will lead to a redistribution of tokens. But we control this redistribution, so we can ensure it minimally affects the rebalancing of keys.

## Implementation of the Solution

First remark, `Apothik.Cluster` does not change. Its responsibility is to track the state of the cluster and notify `Apothik.Cache`. End of story.

At the initialization of the cache, we distribute the `@nb_tokens` equally among the machines. With 5 machines and 1000 tokens, `apothik_1` will receive tokens from 0 to 199, etc. The tokens are stored in the `:ets` table by associating the node name with its list of tokens using `:ets.insert(:cluster_nodes_list, {node, tokens})`.

The first important point is `key_to_node/1`. We first find the token associated with the key. Then we go through the nodes until we find the one associated with the token. Here is what it looks like:
```elixir
  defp key_to_node(k) do
    landing_token = :erlang.phash2(k, @nb_tokens)
    nodes_tokens = :ets.match(:cluster_nodes_list, {:"$1", :"$2"})

    Enum.reduce_while(nodes_tokens, nil, fn [node, tokens], _ ->
      if landing_token in tokens, do: {:halt, node}, else: {:cont, nil}
    end)
  end
```

The second point is the management of arrival and departure events. The first step is to determine the type of event (arrival or departure). This is done in `def handle_call({:update_nodes, nodes}, _from, state)` by comparing the new list of nodes provided to the one present in the `ets` table.

When a node is removed from the cluster, its tokens are distributed as equally as possible among the other nodes. When a node is added to the cluster, we remove the same number of tokens from each node to give to the new one. The number of tokens removed is calculated so that the number of tokens is equally distributed after the redistribution.

Here is what it looks like (the code, although somewhat commented, is not very elegant and would probably benefit from a cleanup pass):
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

(note that `split_evenly/2` was added because probably incorrect usage of `Enum.chunk_every/3` was causing us to lose tokens. Sometimes, it's easier to code your own solution).

We add in `.iex.exs` to check how the tokens move:
```elixir 
  def get_tokens(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :get_tokens, [])
  end
  def check_tokens(i) do
    tk = get_tokens(i)
     (for [_n,t]<-tk, do: t) |> List.flatten() |> Enum.uniq() |> length
  end
```

Temporarily, we change the number of tokens to `@nb_tokens 10`.
```
% ./scripts/start_master.sh
1> Master.get_tokens(1)
[
  [:"apothik_5@127.0.0.1", ~c"\b\t"],
  [:"apothik_4@127.0.0.1", [6, 7]],
  [:"apothik_3@127.0.0.1", [4, 5]],
  [:"apothik_2@127.0.0.1", [2, 3]],
  [:"apothik_1@127.0.0.1", [0, 1]]
]
```

We set `@nb_tokens 1000` back and restart everything:
```
% ./scripts/start_master.sh
1> Master.check_tokens(1)
1000
```

It works, now what happens if we remove a node?

```
2> Master.fill(1,5000)
:ok
3> Master.stat
[  {1, 1016},  {2, 971},  {3, 970},  {4, 985},  {5, 1058}]
4> Master.kill(2)
:ok
5> Master.fill(1,5000)
:ok
6> Master.stat
[  {1, 1265},  {2, {:badrpc, :nodedown}},  {3, 1238},  {4, 1224},  {5, 1273} ]
7> Master.check_tokens(1)
1000
```

In another terminal, we restart `apothik_2`: `% elixir --name apothik_2@127.0.0.1 -S mix run --no-halt`. Back in the master terminal:
```
8> Master.stat
[  {1, 1265},  {2, 0},  {3, 1238},  {4, 1224},  {5, 1273} ]
9> Master.fill(1,5000)
:ok
10> Master.stat
[  {1, 1265},  {2, 971},  {3, 1238},  {4, 1224},  {5, 1273}]
11> Master.check_tokens(1)
1000
12> for [_n,t]<-Master.get_tokens(1), do: length(t)
[200, 200, 200, 200, 200]
```

We haven't lost any tokens in the process, and they are evenly distributed after `apothik_2` returns.

What happens in the server memories? The keys of `apothik_2` were indeed lost when it died. When we reload the system with the same keys, we distribute about 1000 keys to the others. After its return and a reload, we end up with a surplus of 265+238+224+273=1000 keys. This is consistent.

## The Emergence of the "Hash Ring"

A remark: we designed our token redistribution system without much thought. We first suspect that it could drift (i.e., we could move away from an equitable distribution. In any case, this remains to be tested). But above all, we suspect that there must be an optimal approach to token distribution to ensure minimal changes.

This is typically the moment when we think: "I'm discovering a domain and stumbling upon a very complicated question. Smarter people have already thought about the problem and put it in a library." We haven't found the answer, but at least we understand the question a bit!

And of course, the answer exists. We recommend checking out [libring](https://github.com/bitwalker/libring) or [ex_hash_ring](https://hex.pm/packages/ex_hash_ring) from Discord.
It's called the "Hash ring". The idea is to imagine that the tokens (numbered from 0 to 999) are located on a circle. Each node will take care of an arc of contiguous values. This is what we did initially, with `apothik_1` taking care of the arc `0..199`, etc. We just need to remember a single reference number per node, for example, the upper bound of the arc. Here, it would be `199`. `apothik_5` would be at `0` because we reason modulo 1000. Hence the idea of the circle. To know the node that takes care of token `n`, we just need to find the node whose reference value is the first one greater than `n`.

One might wonder how to ensure a good distribution of nodes, meaning they have arcs of comparable sizes. The first idea is to use the same hash function on the node name. But there are other refinements, including ensuring that the arcs have unequal sizes, but in a controlled and desired way.

When a node joins the cluster, it is positioned somewhere on the circle and will share the work with the node in charge of the arc it lands on. If the node returns from the dead with the same name and its position is deterministic relative to its name, it will take the same place, which is optimal.

Let's remove all our token musings and use `libring` (add `{:libring, "~> 1.7"}` in the dependencies).

Here's what it looks like:
```elixir
defmodule Apothik.Cache do

(...remove everything related to tokens and update the functions below...)

  defp key_to_node(k) do
    [{_, ring}] = :ets.lookup(:cluster_nodes_list, :cluster_ring)
    HashRing.key_to_node(ring, k)
  end

  def init(_args) do
    :ets.new(:cluster_nodes_list, [:named_table, :set, :protected])
    {_, nodes} = Cluster.get_state()
    :ets.insert(:cluster_nodes_list, {:cluster_ring, HashRing.new() |> HashRing.add_nodes(nodes)})
    {:ok, %{}}
  end

  def handle_call({:update_nodes, nodes}, _from, state) do
    ring = HashRing.new() |> HashRing.add_nodes(nodes)
    :ets.insert(:cluster_nodes_list, {:cluster_ring, ring})

    {:reply, :ok, state}
  end

end

```

It's simpler, isn't it? Well, not sure if our idea of using `ets` is the best. In any case, it works and it's enough for us for now.

## A Brief Summary of Phase 2:

We have a distributed system that automatically reacts to nodes joining and leaving the cluster. We also improved the initial solution to make it less sensitive to changes (nodes joining and leaving). By the way, our solution is no longer sensitive to the node name (any node whose name starts with `apothik` can join the cluster).

<a href="/apothik/">Home</a>
<a href="en_story_phase1.html"> Part 1</a>
<a href="en_story_phase3.html"> Part 3</a>

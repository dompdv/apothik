---
title: Discovering Distributed Applications with Elixir - Part 3
---

<a href="/">Home</a>
<a href="en_story_phase1.html"> Part 1</a>
<a href="en_story_phase2.html"> Part 2</a>

# Phase 3: Ensuring Data Preservation Despite Machine Failure

Let's be honest, the content of this phase was chosen at the start of our adventure without knowing the subject. In reality, we felt the significant difference in difficulty when approaching it. Until now, things seemed relatively easy, even though we are aware that we probably missed numerous difficulties that would undoubtedly appear in a real production context. But, let's admit it, we have only had to add a small layer of code that takes advantage of the ready-made possibilities provided by the BEAM.

We are not going to recount all our attempts and errors because it would be long and tedious, but rather try to present a somewhat linear path of discovering the problem (not necessarily the solution, by the way).

## Redundancy, you said redundancy?

Our approach is a bit naive: if we store the data multiple times (redundancy), we intuitively think we should be able to retrieve it in case of a node failure.

Let's first try to store it multiple times and see if we can retrieve it afterward. To simplify our lives, let's go back to the case of a static cluster (constant number of machines except during failures) and therefore forget the notions of `HashRing` from phase 2. To set the ideas, let's take 5 machines as initially.

How to choose on which machine to store the data and store the copies?

Initially, influenced by this way of posing the problem, we started with the idea of a "master" node and "replicas." For example, one master and 2 replicas. In this hypothesis, the data is written 3 times.

But is this asymmetry between the roles of master and replicas ultimately a good idea? What happens if the master fails? We would then have to remember which node is the new master and ensure that this knowledge spreads correctly throughout the entire cluster with each event (loss and return). And ultimately, what's the point?

These gropings led to a much simpler idea, that of a **group**.

A group is a defined and fixed set of nodes that have symmetrical roles within the group. Here is what we chose. In the case of a cluster of 5 nodes numbered from 0 to 4, we also have 5 groups numbered from 0 to 4. Group 0 will have nodes 0, 1 & 2. Group 4 will have nodes 4, 0 & 1. Generally, group `n` has nodes `n+1` and `n+2` modulo 5. Conversely, node 0 will belong to groups 0, 4 & 3.

In summary, every group has 3 nodes, and every node belongs to 3 groups. This translates into code as:
```elixir
defp nodes_in_group(group_number) do
  n = Cluster.static_nb_nodes()
  [group_number, rem(group_number + 1 + n, n), rem(group_number + 2 + n, n)]
end

defp groups_of_a_node(node_number) do
  n = Cluster.static_nb_nodes()
  [node_number, rem(node_number - 1 + n, n), rem(node_number - 2 + n, n)]
end
```
A small parenthesis, we adapted the code of `Apothik.Cluster`. Here are the main elements:
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

A key is then assigned to a **group** and **not** to a node. The function `key_to_node/1` becomes:
```elixir
defp key_to_group_number(k), do: :erlang.phash2(k, Cluster.static_nb_nodes())
```

## Multiple Writes

What happens when we write a value to the cache? We write it three times.

First, we can send the write command to any node (remember that we can address the cache of any node in the cluster). That node will identify the group, then pick a random node in that group, unless it happens to be itself, in which case it chooses itself (a small optimization).

Here is what it looks like (note that in this text, the function order is guided by understanding and does not necessarily follow the exact code order):

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

Note that we don’t need to keep extra state about the cluster. We have a static topology based on names, so `Node.list/1` is enough to tell us a node’s status.

Now for the core topic: multiple writes.
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

First, we identify the other nodes in the group that are running and send them a `put_as_replica/3` (we love pipelines with neatly chained `|>` that read like a story). Then, we update the current node’s state with a simple `{:reply, :ok, Map.put(state, k, v)}` call.

As for `put_as_replica/3`, it is even simpler:
```elixir
  def put_as_replica(replica, k, v) do
    GenServer.cast({__MODULE__, Cluster.node_name(replica)}, {:put_as_replica, k, v})
  end
  def handle_cast({:put_as_replica, k, v}, state) do
    {:noreply, Map.put(state, k, v)}
  end
```

## Entering Deadlock Hell

Be aware of what we subtly introduced here. It may not look like much, but this is where we enter the world of distributed app complexity.

We used `GenServer.cast` instead of `GenServer.call`. That means we fire off a message to our neighbors, saying “update your cache,” but we do not wait for a response. We have no acknowledgment that the message was processed. So, group nodes have no guarantee of having the same state.

Why not use `call` then?

That’s what we did at first, naïve as we were (and we still are, because it obviously takes years of experience with distributed systems). But we fell into the pit of deadlocks. If two group nodes are simultaneously asked to update their caches, they can wait for each other indefinitely. In reality, `GenServer.call` has a default timeout, which can be changed, but it throws an exception once it’s hit.

And that’s it; we’ve stepped into the big leagues—or at least peeked through the fence.

## Summary and Tests
Here's what it looks like at the end (note `get/1`, which works as expected, and the absence of `delete`, which would be similar to `put`, but sometimes laziness wins, that's all):
```elixir
defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster

  defp nodes_in_group(group_number) do
    n = Cluster.static_nb_nodes()
    [group_number, rem(group_number + 1 + n, n), rem(group_number + 2 + n, n)]
  end

  defp alive?(node_number) when is_integer(node_number),
    do: node_number |> Cluster.node_name() |> alive?()

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

Quick, let's check that it works. `./scripts/start_cluster.sh` in one terminal, and let's do in another:
```
 % ./scripts/start_master.sh
1> Master.put(1, :a_key, 100)
:ok
2> Master.stat
[{0, 0}, {1, 1}, {2, 1}, {3, 1}, {4, 0}]
3> Master.get(3, :a_key)
100
4> Master.put(2, :another_key, 200)
:ok
5> Master.get(3, :another_key)
200
6> Master.stat
[{0, 1}, {1, 1}, {2, 1}, {3, 2}, {4, 1}]
7> Master.fill(1,5000)
:ok
8> Master.stat
[{0, 2993}, {1, 2968}, {2, 3035}, {3, 3031}, {4, 2979}]
9> Master.sum
15006
```

We can see that `:a_key` is on 3 nodes. We can access the cache from any node and the data is present, and when we loaded the data onto the cluster, we have a total of `15006` stored values, which is indeed `5002 * 3`.

## Data Recovery

What happens in case of a node failure? Well, we lose the data, of course!
```
% ./scripts/start_master.sh
1> Master.fill(1,5000)
:ok
2> Master.kill(2)
:ok
3> Master.stat
[  {0, 2992},  {1, 2967},  {2, {:badrpc, :nodedown}},  {3, 3029},  {4, 2978}]
```

In another terminal, `./scripts/start_instance.sh 2` (yes, we wrote a small script equivalent to `elixir --name apothik_$1@127.0.0.1 -S mix run --no-halt`) and return to the `master`:
```
4> Master.stat
[{0, 2992}, {1, 2967}, {2, 0}, {3, 3029}, {4, 2978}]
```
`apothik_2` is indeed empty as expected.

To recover the data, let's try a simple approach: when a node starts, it queries its neighbors to retrieve the missing information. This is called "rehydration."
```elixir
  def init(_args) do
    me = Node.self() |> Cluster.number_from_node_name()

    for g <- groups_of_a_node(me), peer <- nodes_in_group(g), peer != me, alive?(peer) do
      GenServer.cast({__MODULE__, Cluster.node_name(peer)}, {:i_am_thirsty, g, self()})
    end

    {:ok, %{}}
  end

  def handle_cast({:i_am_thirsty, group, from}, state) do
    filtered_on_group = Map.filter(state, fn {k, _} -> key_to_group_number(k) == group end)
    GenServer.cast(from, {:drink, filtered_on_group})
    {:noreply, state}
  end

  def handle_cast({:drink, payload}, state) do
    {:noreply, Map.merge(state, payload)}
  end
```

At the node's initialization, it requests the content from all nodes in all groups it belongs to (except itself). Note, not exactly all their content, only their content for a specific group. For example, if node 0, for group 0, requests the content from node 2, it does not want to retrieve node 2's content for group 2 (which consists of nodes 2, 3 & 4, not node 0).

Thus, `{:i_am_thirsty, g, self()})` indicates the group for which the request is made, as well as the return address `self()`. The responding node will need to filter the values in its memory, hence `key_to_group_number(k) == group`.

Upon reception, i.e., during rehydration (`:drink`), we simply merge the maps.

Does it work? Restart the cluster, then:
```
% ./scripts/start_master.sh
1> Master.fill(1,5000)
:ok
2> Master.stat
[{0, 2992}, {1, 2967}, {2, 3034}, {3, 3029}, {4, 2978}]
3> Master.kill(2)
:ok
4> Master.stat
[ {0, 2992},  {1, 2967},  {2, {:badrpc, :nodedown}},  {3, 3029},  {4, 2978}]
```
and in another terminal `% ./scripts/start_instance.sh 2`. Back in the `master`
```
5> Master.stat
[{0, 2992}, {1, 2967}, {2, 3034}, {3, 3029}, {4, 2978}]
```

## It works ...but it's so ugly, my god, it's so ugly

There are so many things to criticize that we don't know where to start.

Let's dive in:
- It's not very efficient: the node can receive multiple responses. To remedy this, it could, for example, ignore returns as soon as it has refreshed the data of a group. But even in this case, the damage is done, and each node in the group has already concocted a response or is in the process of doing so. So, it probably needs to be more subtle.
- We send a third of the node's memory in a single message. In the case of a real cache, this operation is probably not possible (what is the maximum size of a message in the BEAM? We don't know, but it must be limited). Moreover, it seems to us that sending a message involves copying its content before sending (not sure for inter-node processes, but it would be a handicap). Furthermore, the operation is likely to block all responding nodes for a noticeable time, which is unacceptable in the case of a highly active cluster.
- And above all, what happens if the cache is modified in parallel? Modifications (`put`) can occur in any sequence order. Nothing guarantees that the returns from the nodes of the same group (those captured in `:drink`) offer the same view of the world. One can easily imagine scenarios where they overwrite new data with their old values.

And that's not counting network issues, with latencies and disconnections that can isolate nodes for a few milliseconds and desynchronize the cluster's state on one or more groups.

## Does it really work?

This is when we went down a path that computer scientists know well, perfectly illustrated by [Scrat from the movie "Ice Age"](https://en.wikipedia.org/wiki/Scrat). We tried to patch the first breach, then the second, but the first opened a third, and so on.

Because, yes, we still had our initial ambition in mind. Remember, "Adding storage redundancy to ensure data preservation despite machine failure." Maybe the **"ensure"** was highly presumptuous, after all.

And then we remembered the phrase by [Johanna Larsonn](https://www.youtube.com/watch?v=7yU9mvwZKoY), who said something like, "Be careful, distributed applications are extremely difficult, but there are still cases where you can get started."

The word "ensure" led us too far.

After all these mistakes, we understood that what makes a distributed system difficult are the **qualities** expected from it. We unconsciously wanted to offer our distributed cache some of the qualities of a distributed database, which is clearly beyond our beginner's capabilities.

In summary, **no**, it doesn't work. At least not if we aim to complete our phase 3 with its grandiose and presumptuous title.

## Can we aim lower?

But maybe we could focus on the qualities expected from a **cache**, and nothing more.

And that's the main piece of wisdom our work has provided us so far. **We must first clearly specify the expected qualities of the distributed application.** Each quality comes at a high cost.

In this regard, we recall reading a famous theorem one day that explains it is mathematically impossible **to have everything at once**: the [CAP theorem](https://en.wikipedia.org/wiki/CAP_theorem). And it must not be the only impossibility theorem.

In distributed applications, "having your cake and eating it too" is even more unattainable than usual.

Let's return to our endeavor of cutting down our ambitions. What we want for our **cache** is:
- Minimize "misses" ("cache miss" in Franglais), that is, the number of times the cache cannot provide the value.
- Ensure in most "normal" cases that the value returned is indeed the last one provided to the cluster. At this point, we say "normal cases" because our recent failure has taught us to be modest, and we suspect that "all cases" will be far too difficult for us.

## Let's Try Rehydrating Sip by Sip

Let's backtrack: remove our massive hydration method at startup, as well as the associated `handle` functions. Remember this thing:
```elixir
for g <- groups_of_a_node(me), peer <- nodes_in_group(g), peer != me, alive?(peer) do
  GenServer.cast({__MODULE__, Cluster.node_name(peer)}, {:i_am_thirsty, g, self()})
end
```

Our idea is to start extremely modestly. At node startup, nothing special happens, no rehydration. The node will react to `put` and `put_as_replica` as usual. However, it will handle `get` differently. If it has the key in cache, it obviously returns the associated value. If it doesn't have the key, it will ask a node in the group for the value, store it, and return it.

This approach ensures progressive rehydration based on observed demand.

We will need the state of our `GenServer` to be richer than just the cache data. We add:
```elixir
defstruct cache: %{}, pending_gets: %{}
```
`cache` is for the cache data, `pending_gets` is explained below. All methods need to be slightly and trivially adapted to transform what was `state` into `state.cache`.

Here's what the `get` method looks like:
```elixir
  def handle_call({:get, k}, from, state) do
    %{cache: cache, pending_gets: pending_gets} = state

    case Map.get(cache, k) do
      nil ->
        peer =
          k
          |> key_to_group_number()
          |> live_nodes_in_a_group()
          |> Enum.reject(fn i -> Cluster.node_name(i) == Node.self() end)
          |> Enum.random()

        :ok = GenServer.cast({__MODULE__, Cluster.node_name(peer)}, {:hydrate_key, self(), k})

        {:noreply, %{state | pending_gets: [{k, from} | pending_gets]}}

      val ->
        {:reply, val, state}
    end
  end
```

Here we used a more sophisticated mechanism (we leave it to the readers to tell us if we could have used it earlier): a `:no_reply` in response to a `GenServer.handle_call/3`. Our goal is for this request (fetching the value from `peer`) not to block the node that is rehydrating. This is a possibility of `GenServer`: you can return `:noreply`, which leaves the calling process waiting but frees up execution. Later, the response is made by a [`GenServer.reply/2`](https://hexdocs.pm/elixir/GenServer.html#reply/2). Check out the example in the documentation, it's enlightening. However, you need to remember the pending calls, primarily the `pid` of the calling processes.

In summary (in the case of a missing key):
- randomly select an awake replica.
- asynchronously ask it for the desired value (and provide the return `pid`)
- store the request in `pending_gets`. Initially, we used a `map` for `pending_gets` of the type `%{k => pid}`. But there would be a problem in case of almost simultaneous calls from two different processes on the same key.
- put the caller on hold.

On its side, the replica responds very simply, always asynchronously:
```elixir
  def handle_cast({:hydrate_key, from, k}, %{cache: cache} = state) do
    :ok = GenServer.cast(from, {:drink_key, k, cache[k]})
    {:noreply, state}
  end
```

And when it returns:
```elixir
  def handle_cast({:drink_key, k, v}, state) do
    %{cache: cache, pending_gets: pending_gets} = state

    {to_reply, new_pending_gets} =
      Enum.split_with(pending_gets, fn {hk, _} -> k == hk end)

    Enum.each(to_reply, fn {_, client} -> GenServer.reply(client, v) end)

    new_cache =
      case Map.get(cache, k) do
        nil -> Map.put(cache, k, v)
        _ -> cache
      end

    {:noreply, %{state | cache: new_cache, pending_gets: new_pending_gets}}
  end
```

The steps:
- separate the requests concerning the key from other requests
- send a `reply` to the calling processes
- if the cache has not been updated in the meantime (with a suspicion that the data is fresher), update it

Let's try, with `./scripts/start_cluster.sh` in one terminal and in the other:
```
% ./scripts/start_master.sh
1> Master.put(4,"hello","world")
:ok
2> Master.stat
[{0, 1}, {1, 1}, {2, 0}, {3, 0}, {4, 1}]
3> Master.kill(0)
:ok
4> Master.stat
[{0, {:badrpc, :nodedown}}, {1, 1}, {2, 0}, {3, 0}, {4, 1}]
```
We kill node 0, which is part of group 4. In another terminal, restart it with `./scripts/start_instance.sh 0`, then:
```
5> Master.stat
[{0, 0}, {1, 1}, {2, 0}, {3, 0}, {4, 1}]
6> Master.get(4,"hello")
"world"
7> Master.stat
[{0, 0}, {1, 1}, {2, 0}, {3, 0}, {4, 1}]
8> Master.get(0,"hello")
"world"
9> Master.stat
[{0, 1}, {1, 1}, {2, 0}, {3, 0}, {4, 1}]
10> :rpc.call(:"apothik_0@127.0.0.1", :sys, :get_state, [Apothik.Cache]) 
%{cache: %{"hello" => "world"}, __struct__: Apothik.Cache, pending_gets: []}
```

Upon return, the node is empty. If we address node 4, it will be able to respond because it has the key available. This does not change the content of node 0. However, if we address node 0, we see that it gets the response and rehydrates. The list of `pending_gets` has indeed been emptied.

By the way, it's so convenient that we add to `.iex.exs`:
```elixir
  def inside(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", :sys, :get_state, [Apothik.Cache])
  end
```

Where are we?
- we avoid misses
- the state seems reasonably maintained coherent (we are not sure, though)
- no need to have a different operating mode ("I'm rehydrating", "I'm ready")
- there is a performance loss for each call on a non-hydrated key. This loss will decrease with the node's rehydration
- and a performance loss when the cache is queried for a normally absent key (which was not set previously). Indeed, it takes two nodes to agree to respond "we don't have that in stock."


## Hydration at Startup

Now that we've got the hang of it, let's see if we can improve our hydration system at startup. You remember that we asked all nodes in all groups to send the data all at once. Now, we will ask a random node from each group to send a small batch of data. Upon receipt, we will request another batch, and so on until the stock is exhausted.

At node startup, we initiate the requests:
```elixir 
  def init(_args) do
    peers = pick_a_live_node_in_each_group()
    for {group, peer} <- peers, do: ask_for_hydration(peer, group, 0, @batch_size)
    {:ok, %__MODULE__{}}
  end
```

`ask_for_hydration` is the request for a batch of data. It means "give me a batch of data of size `@batch_size`, starting from index `0`, for the group `group`."

The function `pick_a_live_node_in_each_group` does what its name suggests. There is a small trick to select only one node per group:
```elixir
  def pick_a_live_node_in_each_group() do
    me = Node.self() |> Cluster.number_from_node_name()
    for g <- groups_of_a_node(me), peer <- nodes_in_group(g), peer != me, alive?(peer), into: %{}, do: {g, peer}
  end
```

We use `cast` for requests and responses.
```elixir
  def ask_for_hydration(replica, group, start_index, batch_size) do
    GenServer.cast(
      {__MODULE__, Cluster.node_name(replica)},
      {:i_am_thirsty, group, self(), start_index, batch_size}
    )
  end
```

Upon receipt, the node (the one providing the data) will order its keys (only those of the requested group), use this order to number them, and send a batch. It returns the next index and a flag to indicate that it is the last batch, which will allow the requesting node to stop soliciting it.
```elixir
  def handle_cast({:i_am_thirsty, group, from, start_index, batch_size}, %{cache: cache} = state) do
    filtered_on_group = Map.filter(cache, fn {k, _} -> key_to_group_number(k) == group end)

    keys = filtered_on_group |> Map.keys() |> Enum.sort() |> Enum.slice(start_index, batch_size)
    filtered = for k <- keys, into: %{}, do: {k, filtered_on_group[k]}

    hydrate(from, group, filtered, start_index + map_size(filtered), length(keys) < batch_size)

    {:noreply, state}
  end
```

The `hydrate` is also a `cast`
```elixir
  def hydrate(peer_pid, group, cache_slice, next_index, last_batch) do
    GenServer.cast(peer_pid, {:drink, group, cache_slice, next_index, last_batch})
  end
```

Upon receipt:
```elixir
  def handle_cast({:drink, group, payload, next_index, final}, %{cache: cache} = state) do
    if not final do
      peer = pick_a_live_node_in_each_group() |> Map.get(group)
      ask_for_hydration(peer, group, next_index, @batch_size)
    end

    filtered_payload = Map.filter(payload, fn {k, _} -> not Map.has_key?(cache, k) end)
    {:noreply, %{state | cache: Map.merge(cache, filtered_payload)}}
  end
```
If we have not finished, we request the next batch from a random replica. In any case, we update the cache, retaining only the unknown keys among the provided batch.

Let's test. In one terminal `./scripts/start_cluster.sh` and in another:
```
% ./scripts/start_master.sh
1> Master.fill(1, 5000)
:ok
2> Master.stat
[{0, 2992}, {1, 2967}, {2, 3034}, {3, 3029}, {4, 2978}]
3> Master.kill(1)
:ok
4> Master.stat
[{0, 2992}, {1, {:badrpc, :nodedown}}, {2, 3034}, {3, 3029}, {4, 2978}]
```

Restart node 1 in another terminal `% ./scripts/start_instance.sh 1` and, in "master", the keys are back:
```
5> Master.stat
[{0, 2992}, {1, 2967}, {2, 3034}, {3, 3029}, {4, 2978}]
```

Quick summary:
- we have a gentle recovery of the node upon its return, without degrading the cluster's performance too much
- the process is quite fragile because a lost message stops it permanently. In fact, our first version was more complex, and the state of the recovery process was tracked by the node itself, allowing for error recovery. It's not complicated to implement
- the iteration system (`keys = filtered_on_group |> Map.keys() |> Enum.sort() |> Enum.slice(start_index, batch_size)`) needs to be reviewed for large cache sizes.
- we still haven't addressed the issue of key deletion (`delete`), and we are still too lazy to do it.

The most important question: do we have consistent states between nodes in the same group? Indeed, the cluster continues to live, especially with `put` operations occurring during the hydration process. It's not easy to ensure because the scenarios are numerous. For example:
- if a key is added among the batches not yet sent, it's not problematic. It will be part of the following batches. And here, we have two cases: either the `put` has already reached the recovering node, and the key will be ignored upon receipt, or the key will be updated by the batch receipt, then updated by the `put` message.
- if a key is added among the keys already received, it's not problematic either. The `put` will modify the value in the cache. And since there is a shift in the ordered keys, we will resend an already sent key in the next batch, which has no impact on consistency.

What to take away from this partial (and possibly inaccurate) analysis is that it is difficult to conduct. We must consider all scenarios of message arrivals on each process, without assuming any logical or chronological order, and examine if the cache consistency is damaged in each scenario.

## What if we call in the experts?

We can't shake the feeling that we've probably found rather crude solutions to very complicated questions.

As before, it's time to see what much more knowledgeable people have discovered. The good news is that such solutions exist, specifically CRDTs (Conflict-free Replicated Data Types). These are a whole family of solutions that allow for state synchronization in a distributed configuration. A quick search on the internet even talks about "eventual consistency." This means that if we stop modifying the cache, the nodes will converge to the same state after a certain period.

Well, we don't understand everything in detail, but we know that the excellent [Derek Kraan](https://github.com/derekkraan) has written a library that implements a variant (delta-CRDTs) for the needs of [Horde](https://github.com/derekkraan/horde), a distributed supervision and registry application.

The library is [delta_crdt_ex](https://github.com/derekkraan/delta_crdt_ex). The README is quite enticing! Here is an example from the documentation:

```elixir
{:ok, crdt1} = DeltaCrdt.start_link(DeltaCrdt.AWLWWMap)
{:ok, crdt2} = DeltaCrdt.start_link(DeltaCrdt.AWLWWMap)
DeltaCrdt.set_neighbours(crdt1, [crdt2])
DeltaCrdt.set_neighbours(crdt2, [crdt1])
DeltaCrdt.to_map(crdt1)
%{}
DeltaCrdt.put(crdt1, "CRDT", "is magic!")
Process.sleep(300) # need to wait for propagation
DeltaCrdt.to_map(crdt2)
%{"CRDT" => "is magic!"}
```

The `DeltaCrdt` is exactly what we want: a dictionary! We just need to launch `DeltaCrdt` processes. We introduce their neighbors to each process. Note that the link is unidirectional, so we need to introduce 1 to 2 and 2 to 1.

In short, it seems that we will mostly delete a lot of code. And indeed, that's what we will do!

## Naming the processes and supervising them

Let's recap: we have divided our cache into groups. Each group is present on 3 nodes. We want to have 3 `DeltaCrdt` processes that synchronize per group, each on a different node. We decide to name the processes related to group `n`: `apothik_crdt_#{n}`. For example, group `0` will be represented by 3 processes all named `apothik_crdt_0` distributed across 3 different nodes, `apothik_0`, `apothik_1`, and `apothik_2`. It is possible to introduce a neighbor without using a `pid` but by using the convention `{process name, node name}`:
```elixir 
  DeltaCrdt.set_neighbours(crdt, [{"apothik_crdt_0", :"apothik_1"}])
```

At the startup of a node, we need to instantiate 3 processes, one for each group carried by the node. We decide to have a supervisor handle this responsibility.

```elixir
defmodule Apothik.CrdtSupervisor do
  use Supervisor

  alias Apothik.Cache

  def start_link(init_arg), do: Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_init_args) do
    self = Cache.number_from_node_name(Node.self())
    groups = Cache.groups_of_a_node(self)

    children =
      for g <- groups do
        Supervisor.child_spec({Apothik.Cache, g}, id: "apothik_cache_#{g}")
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

Note that we do not directly launch a `DeltaCrdt` process but `{Apothik.Cache, g}`, named `apothik_cache_#{g}`. We will come back to this below.

And this supervisor is launched by the application (which also launches `libcluster`):
```elixir
defmodule Apothik.Application do
use Application

  @impl true
  def start(_type, _args) do
  (... same as before ...)

    children = [
      {Cluster.Supervisor, [topologies, [name: Apothik.ClusterSupervisor]]},
      Apothik.CrdtSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Apothik.Supervisor)
  end
end
```

## Introducing the neighbors at the right time

We need to introduce the 2 partners to each `DeltaCrdt`. To insert this behavior, we decided to create an intermediate process (`Apothik.Cache`) whose mission is to instantiate the `DeltaCrdt` and introduce its neighbors. Their fates will be linked via the use of `start_link`. Thus, if the `DeltaCrdt` process terminates abruptly, the `Cache` process will too, and the supervisor will restart it.

This results in:
```elixir
defmodule Apothik.Cache do
  use GenServer

  def crdt_name(i), do: :"apothik_crdt_#{i}"

  @impl true
  def init(g) do
    :net_kernel.monitor_nodes(true)
    {:ok, pid} =  DeltaCrdt.start_link(DeltaCrdt.AWLWWMap, name: crdt_name(g))
    {:ok, set_neighbours(%{group: g, pid: pid})}
  end

  def set_neighbours(state) do
    my_name = crdt_name(state.group)
    self = number_from_node_name(Node.self())

    neighbours = for n <- nodes_in_group(state.group), n != self, do:{my_name, node_name(n)}
    DeltaCrdt.set_neighbours(state.pid, neighbours)

    state
  end
end
```

Moreover, for added security, we must also introduce the neighbors as soon as a node joins the cluster. This explains the presence of `:net_kernel.monitor_nodes(true)`. We add:
```elixir
  @impl true
  def handle_info({:nodeup, node}, state) do
    Task.start(fn ->
      Process.sleep(1_000)
      set_neighbours(state)
    end)

    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state), do: {:noreply, state}
```
We added a small delay before setting the neighbors to allow the node to start up.

## Changing the cache access interface

Finally, the fundamental actions (`get` and `put`) become:
```elixir
  def get(k) do
    group = k |> key_to_group_number()
    alive_node = group |> pick_a_live_node() |> node_name()
    DeltaCrdt.get({:"apothik_crdt_#{group}", alive_node}, k)
  end

  def put(k, v) do
    group = k |> key_to_group_number()
    alive_node = group |> pick_a_live_node() |> node_name()
    DeltaCrdt.put({:"apothik_crdt_#{group}", alive_node}, k, v)
  end
```
As usual, the key determines the responsible group. Then we identify a node in the group, favoring the current node. Finally, we directly call the `DeltaCrdt` process by its name. And that's it.

## Let's Try

First, a small modification to collect statistics in `Apothik.CrdtSupervisor` by calling all the `DeltaCrdt` of the node's groups:
```elixir
def stats() do
  self = Cache.number_from_node_name(Node.self())
  groups = Cache.groups_of_a_node(self)

  for g <- groups do
    DeltaCrdt.to_map(:"apothik_crdt_#{g}") |> map_size()
  end
  |> Enum.sum()
end
```
And in `.iex.exs`:
```elixir
def stat(i) do
  :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.CrdtSupervisor, :stats, [])
end
def sum_stat() do
  {sum(), stat()}
end
```

As usual, start `./scripts/start_cluster.sh` in one terminal and in another:
```
% ./scripts/start_master.sh
1> Master.sum_stat
{0, [{0, 0}, {1, 0}, {2, 0}, {3, 0}, {4, 0}]}
2> Master.fill(1, 1)
:ok
3> Master.sum_stat
{3, [{0, 0}, {1, 1}, {2, 1}, {3, 1}, {4, 0}]}
4> Master.fill(1, 10)
:ok
5> Master.sum_stat
{30, [{0, 7}, {1, 5}, {2, 5}, {3, 6}, {4, 7}]}
6> Master.fill(1, 100)
:ok
7> Master.sum_stat
{300, [{0, 60}, {1, 62}, {2, 66}, {3, 58}, {4, 54}]}
```

Magic! We have automatic propagation across all nodes. The totals are consistent!

Now, let's kill 2 nodes to see if data is lost:
```
8> Master.kill(0)
:ok
9> Master.kill(1)
:ok
10> Master.sum_stat
{178, [   {0, {:badrpc, :nodedown}}, {1, {:badrpc, :nodedown}}, {2, 66}, {3, 58}, {4, 54}]}
```

And in two other separate terminals: `% ./scripts/start_instance.sh 0` for one and `% ./scripts/start_instance.sh 1` for the other. Back to the master:
```
11> Master.sum_stat
{300, [{0, 60}, {1, 62}, {2, 66}, {3, 58}, {4, 54}]}
```

And there you go! The keys are back!


## It works, but don't push it!

Let's restart the manipulation from scratch (restart the cluster), and:
```
% ./scripts/start_master.sh
1> Master.fill(1, 10000)
:ok
2> Master.sum_stat
{18384, [{0, 3564}, {1, 2968}, {2, 3555}, {3, 4148}, {4, 4149}]}
```

Ouch! We don't have 30,000 keys as expected, but 18,384.

We won't explain the few hours spent trying to understand what was happening. Suffice it to say that we consulted the internet, the "issues" of the GitHub repository, and of course, we delved into the code. We understood that 
```elixir
DeltaCrdt.start_link(DeltaCrdt.AWLWWMap, max_sync_size: 30_000, name: crdt_name(g))
``` 
allowed us to go further. But the synchronization was truncated at a certain level. In short, if there were too large differences ("delta") in a given time, the propagation was not complete. Using magic is great as long as everything works, but it becomes black magic when something goes wrong.

## General Conclusion

In summary, we have two solutions:
- A somewhat makeshift solution that probably doesn't handle complicated cases but is fully under our control, with identified and feasible improvement paths.
- A solution created by experts, but with limitations that we don't fully understand unless we become somewhat (or very) expert ourselves.

We come back to the conclusion that creating distributed applications is very delicate, with a wall effect: a small domain of feasible things is surrounded by very high walls when aiming for certain qualities for the distributed application. There are two ways to overcome these walls. Either invest massively in understanding the algorithms already invented by many researchers and implement these algorithms according to your needs. Or rely on ready-made libraries or products, but then it is essential to know precisely their operating domains.

## Epilogue

We hope these articles have entertained or inspired you. Feel free to comment, correct, or even request more!

Olivier and Dominique

<a href="/">Home</a>
<a href="en_story_phase1.html"> Part 1</a>
<a href="en_story_phase2.html"> Part 2</a>

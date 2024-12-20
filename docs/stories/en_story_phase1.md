---
title: Discovering Distributed Applications with Elixir - Part 1
---

<a href="/apothik/">Home</a>
<a href="en_story_phase2.html"> Part 2</a>
<a href="en_story_phase3.html"> Part 3</a>

# Part 1: A Distributed Cache, Without Redundancy, on 5 Fixed Machines

## Why?

Elixir and Erlang are very cool technologies that we have loved and practiced for a long time (as a hobby for now, unfortunately). Just the lightweight processes and message passing are the key to an infinite number of applications, even on a single server. Just think of the magic behind Liveview, Channels, Presence, and Pubsub, for example.

But the real promise has always been the hope that ordinary people like us could tackle the very difficult engineering problems that arise in the world of *distributed* applications.

Inspired by the excellent talk by [Johanna Larsonn at Code Beam Lite Mexico 2023](https://www.youtube.com/watch?v=7yU9mvwZKoY), we decided to be the living proof that her goal was achieved: to inspire some of us, mere mortals, to dare to tackle this mysterious world.

But starting alone was intimidating. We decided to team up (Olivier & Dominique, two old friends and Elixir enthusiasts) to tackle this challenge with four hands. And first, to reserve a weekly time slot to travel together.

This series of articles is the uncensored account of our attempts. It is not a course on decentralized programming, it is the story of how we tried, stumbled, and sometimes succeeded on this path.

## The Overall Plan

Because the subject is difficult, we couldn't just jump on our keyboards and code a fault-tolerant, massively scalable distributed database. We had to design a plan with a learning curve that we hope is smooth. Thanks to our initial readings and a first coat of paint, we designed a phased plan that looked something like this:
- *What application?* The question is not to create a complex application, but rather to give it the right qualities in a distributed context. Let's choose a simple key-value cache.
- *Phase 1:* A Distributed Cache, Without Redundancy, on 5 Fixed Machines.
- *Phase 2:* Same thing, but with a dynamic cluster (adding and losing machines). Explore the influence of key distribution functions.
- *Phase 3:* Adding storage redundancy (the key is copied to multiple machines) to ensure data retention despite machine loss. Manage a dynamic cluster and failures.

And of course, this involves developing small auxiliary tools to conduct experiments: load the cache, observe the state of the machines, add or remove machines, etc.

## Preparing the Ground

### The Nodes
But before we can write Elixir, we need to be able to run it on multiple machines. In reality, you don't need multiple machines to start. Indeed, the foundation of Erlang is a virtual machine, the **BEAM**, which runs the **Erlang Runtime System**, [details here](https://www.erlang.org/blog/a-brief-beam-primer/). It is possible to start multiple Erlang machines on a single computer. You might say that this is not representative of a cluster of 5 separate machines. Generally yes, but not for Erlang, which makes this transparent. A message will be sent in the same way between two processes whether they are located in the same virtual machine, in two different virtual machines, or even if the virtual machines are located on two different physical machines. The call will be the same but, of course, the system properties may be different, as you will have to account for latency, the possibility of network failures between physical machines, etc.

Erlang virtual machines that communicate are called nodes (see [introduction to distributed Erlang](https://www.erlang.org/docs/17/reference_manual/distributed)). In Elixir, a specific module allows you to manipulate it, the [Node module](https://hexdocs.pm/elixir/1.12/Node.html).

We will see how to start nodes that communicate with each other.

### Starting 5 Machines

Before the cluster, let's create our `apothik` application, with a little help from `mix`. `mix new apothik --sup`. Then `cd apothik && mix apothik` to check that everything is fine so far. We chose to create an application with supervision (`--sup`). To be honest, we initially did it without a supervisor, but we had to add one very quickly. In hindsight, an Elixir application without a supervisor is very rare.

Now, let's ask an AI to create a script to start 5 Erlang machines. After removing a lot of unnecessary code and adapting the comments, here is the result, in `/scripts/start_cluster.sh`:

```bash
#!/usr/bin/env bash

NUM_INSTANCES=5
APP_NAME="apothik"

start_instance() {
  local instance_id=$1
  local node_name="${APP_NAME}_${instance_id}@127.0.0.1"

  echo "Starting instance $instance_id with node $node_name..."

  # The node name and cookie need to be set for clustering
  # Here, there is no cookie: the standard ~/.erlang.cookie file is automatically used (and generated if there is none)
  elixir --name $node_name -S mix run --no-halt &
}

mix compile

for i in $(seq 1 $NUM_INSTANCES); do
  start_instance $i
done

wait
```

Everything happens when launching `elixir` (doing a `man elixir` is very instructive). Each node has a name in the form `name@ip_address`, indicated by `--name`. 
We launch the application by running the script `mix run --no-halt`.  

`--no-halt` keeps the Elixir virtual machine running even if the application terminates. Without this, and because our application does nothing yet, the virtual machine would stop immediately.

The `&` indicates to launch it on a child process (an OS process) of the bash script. Thus, the command does not block the script, and the machines will be stopped when the script stops. 
`wait` suspends the script. This allows stopping the script with `ctrl-C` and cascading all virtual machines.

We had to add `mix compile` upstream because launching multiple `mix run` in parallel could start compilations that would step on each other's toes.

A little `chmod u+x ./scripts/start_cluster.sh` to give execution rights to the bash script, and you can launch your 5 machines with `./scripts/start_cluster.sh`!

### Creating a Cluster

For now, the 5 machines do not know each other, they live their independent lives. To form a cluster, they need to recognize each other.
After launching your machines in one terminal, open another terminal and launch `iex`.

```
% iex                        
iex(1)> Node.ping(:"apothik_1@127.0.0.1")
:pang
```

The function [`Node.ping`](https://hexdocs.pm/elixir/1.12/Node.html#ping/1) allows connecting two nodes. 
It responds `:pang` in case of failure, and `:pong` in case of success. Similar to [`Node.connect`](https://hexdocs.pm/elixir/1.12/Node.html#connect/1) but funnier.

Important note, the full name of the node is an atom. We wrote `:"apothik_1@127.0.0.1"` and not `"apothik_1@127.0.0.1"`, prefixing with `:`.

After attempts and tests, we understood that we need to give a name to our `iex` session.

```
iex --name master@127.0.0.1
1> Node.ping(:"apothik_1@127.0.0.1")
:pong
```

**It works**! 

We take the opportunity to put `iex --name master@127.0.0.1` in `/scripts/start_master.sh`.

Let's continue:

```terminal
2> Node.list
[:"apothik_1@127.0.0.1"]
3> Node.ping(:"apothik_2@127.0.0.1")
:pong
4> Node.list
[:"apothik_1@127.0.0.1", :"apothik_2@127.0.0.1"]
6> :rpc.call(:"apothik_2@127.0.0.1", Node, :list, [])
[:"master@127.0.0.1", :"apothik_1@127.0.0.1"]
```

`Node.list` lists all nodes in the cluster, except the caller. As we connect a node, the cluster grows. 

It is possible to call a function remotely ("Remote procedure call") using the Erlang module [`rpc`](https://www.erlang.org/doc/apps/kernel/rpc.html). 
When we call `Node.list` on `apothik_2@127.0.0.1`, we see that this node has a complete view of all the nodes in the cluster. So, it is enough to connect to *one* node in the cluster to join it and have all other nodes automatically informed! The magic of Erlang!

But wait, it seems there is a security flaw: could we connect to a node from its name and then execute any code on it?
Not really, when you launch an Erlang virtual machine, it is associated with a `cookie` (a secret string). Only machines launched with the same `cookie` can connect to each other. You can specify the cookie with `--cookie`, but if you don't, the `~/.erlang.cookie` file is used (and generated if it doesn't exist). Since we launched the machines from the same user, they had the same cookie.

**Note**, the cookie is only a way to partition clusters on the same physical network (to deploy a dev cluster on the same machine as a qualification cluster, for example). It does not protect against malicious attacks! If the cluster is deployed on a public network, additional security measures will be needed: inter-node encryption, authentication, etc.

### Automatic Node Discovery

For the cluster to "assemble" automatically, the nodes need to connect to each other when the application starts.
In such a simple case, it's easy because we have a known list of nodes. Even if we need to account for the startup times of the different nodes.

But we might as well rely on the work of others (as long as it's not black magic to us) and use [`libcluster`](`https://github.com/bitwalker/libcluster`). 
This library manages a series of discovery policies, from simple to advanced (via DNS, multicast ...).

Let's add it in `mix.exs`
```elixir
  defp deps do
    [
      {:libcluster, "~> 3.4"}
    ]
```

(don't forget `mix deps.get`)
It starts in the supervision tree, in `/lib/apothik/application.ex`
```elixir
defmodule Apothik.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    hosts = for i <- 1..5, do: :"apothik_#{i}@127.0.0.1"

    topologies = [
      apothik_cluster_1: [
        strategy: Cluster.Strategy.Epmd,
        config: [hosts: hosts]
      ]
    ]

    children = [
      {Cluster.Supervisor, [topologies, [name: Apothik.ClusterSupervisor]]},
      Apothik.Cache
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Apothik.Supervisor)
  end
end
```

We use the simplest discovery strategy, via a finite list of node names, passed as a parameter to the `libcluster` supervisor:
```elixir
{Cluster.Supervisor, [topologies, [name: Apothik.ClusterSupervisor]]}
```

Launch `./scripts/start_cluster.sh` and you will see the nodes discover each other:
```
17:32:13.703 [info] [libcluster:apothik_cluster_1] connected to :"apothik_2@127.0.0.1"
etc...
```

In the other terminal, check that the cluster is assembled:
```
% ./scripts/start_master.sh
1> Node.ping(:"apothik_1@127.0.0.1")
:pong
2> Node.list
[:"apothik_1@127.0.0.1", :"apothik_2@127.0.0.1", :"apothik_5@127.0.0.1",
 :"apothik_3@127.0.0.1", :"apothik_4@127.0.0.1"]
```

There you go, we can launch an application on 5 servers that form an Elixir cluster!
We can start Phase 1

## Phase 1: A Distributed Cache, Without Redundancy, on 5 Fixed Machines.

### Adding a Cache System

This example is so classic that it is in the official Elixir tutorial.

```elixir
defmodule Apothik.Cache do
  use GenServer

  # Interface
  def get(k), do: GenServer.call(__MODULE__, {:get, k})

  def put(k, v), do: GenServer.call(__MODULE__, {:put, k, v})

  def delete(k), do: GenServer.call(__MODULE__, {:delete, k})

  def stats(), do: GenServer.call(__MODULE__, :stats)

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Implementation
  @impl true
  def init(_args), do: {:ok, %{}}

  @impl true
  def handle_call({:get, k}, _from, state), do: {:reply, Map.get(state, k), state}

  def handle_call({:put, k, v}, _from, state), do: {:reply, :ok, Map.put(state, k, v)}

  def handle_call({:delete, k}, _from, state), do: {:reply, :ok, Map.delete(state, k)}

  def handle_call(:stats, _from, state), do: {:reply, map_size(state), state}
end
```

Note the `stats` function which for now returns the cache size.

And in `application.ex`, we add the cache system in the supervision:
```elixir
children = [
    {Cluster.Supervisor, [topologies, [name: Apothik.ClusterSupervisor]]},
    Apothik.Cache
]
```

However, be careful with this seemingly simple code, as there are many important details to note. 

When adding `Apothik.Cache` to the supervision tree, the function `Apothik.Cache.start_link/1` is called, which in turn calls `GenServer.start_link/3`. The [documentation](https://hexdocs.pm/elixir/1.16.2/GenServer.html#start_link/3) is worth a read.

The crucial point here is the use of the `:name` option with a unique name, the module name. This name is registered in a dictionary **local to the virtual machine**. This allows sending a message to this `GenServer` process without knowing its process identifier (`pid`). See the [documentation](https://hexdocs.pm/elixir/1.16.2/GenServer.html#module-name-registration) for other possibilities.

This is what allows the following code to send the message to the correct process:
```elixir
def get(k), do: GenServer.call(__MODULE__, {:get, k})
```

Since this name is unique to the virtual machine, there will be 5 cache management processes with the same name, one per machine.

Now, back to the terminal:

```
% ./scripts/start_master.sh 
4> :rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :stats, [])
0
5> :rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :put, [:toto, 12])
:ok
6> :rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :stats, [])
1
```

Why use `:rpc`? We only did `iex`. The application is not running, so the `Apothik.Cache` module is unknown to this virtual machine. We could also launch the application by doing `iex -S mix run`, and use functions like `Apothik.Cache.get/1` directly, but we risk having our `master` considered part of the cluster. In fact, try launching it to see the error messages from `libcluster`.

Lastly, to simplify our lives, we created a `.iex.exs` file. This script is run at the start of `iex` and allows creating a context for `iex` sessions, including loading utility functions.

Here, we add functions to play with our caches.

```elixir
defmodule Master do
  def stat(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :stats, [])
  end
  def get(i, k) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :get, [k])
  end
  def put(i, k, v) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :put, [k, v])
  end
  def delete(i, k) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :delete, [k])
  end
  def fill(i, n) do
    Enum.each(1..n, fn j -> put(i, "k_#{i}_#{j}", j) end)
  end
end
```

Restart the cluster. Let's check that we can cache things on a given node:
```
% ./scripts/start_master.sh
1> Master.fill(1,1000)
:ok
2> Master.stat(1)
1000
```

There you go, now we have 5 caches on 5 machines. The next step is to have **one** cache **distributed** across 5 machines!

### The Overall Plan

For the cluster to behave as a single cache, we need to distribute the storage as evenly as possible across each of the 5 nodes. A {key, value} pair will then be present on only one of the nodes.

Additionally, we want to be able to query any node in the cluster to obtain a value. We do not want a specialized node to act as a particular entry point.

We need to solve two questions: how to send a message to a process located on another node and how to know that a particular key is on a particular server.

### Sending a Message to Another Node

We had to dig a bit. A first idea is to look at the documentation of [`Process`](https://hexdocs.pm/elixir/Process.html). 
It seems promising, the fundamental function [`Process.send/3`](https://hexdocs.pm/elixir/Process.html#send/3) allows sending a message based on the knowledge of the process name (local to the virtual machine) and the node name: `Process.send({name_of_the_process, node_name}, msg, options)`.

Before testing sending a message to the cache, let's add a few lines in `cache/cache.ex`
```elixir
  @impl true
  def handle_info(msg, state) do
    IO.inspect(msg)
    {:noreply, state}
  end
```
Indeed, if we send an arbitrary message to a `GenServer` (a message that is not a `call` or a `cast` for example), the callback `handle_info` is called.

Let's try:
``` 
% ./scripts/start_master.sh
1> Process.send({Apothik.Cache, :"apothik_1@127.0.0.1"}, "hey there", [])
:ok
```

And `"hey there"` appears in the cluster terminal. Let's try with `GenServer.call`:

```
2>GenServer.call({Apothik.Cache, :"apothik_1@127.0.0.1"}, {:put, 1, "something"})
:ok
3> GenServer.call({Apothik.Cache, :"apothik_1@127.0.0.1"}, :stats)
1
4> GenServer.call({Apothik.Cache, :"apothik_1@127.0.0.1"}, {:get,1})
"something"
```

Apparently, it works the same way with `GenServer.call/3`! We have the first missing piece.

### Sending the Message to the Right Node, from Any Node

In `cache/cache.ex`, we transform the interface calls into, for example: 
```elixir
def get(k) do
  node = key_to_node(k)
  GenServer.call({__MODULE__, node}, {:get, k})
end
```
Let's assume that `key_to_node` indicates which node the key is stored on.
If I call the function `Apothik.Cache.get("a_key")` (for example by doing `:rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :get, ["a_key"]))`, and `key_to_node("a_key)` returns `:"apothik_1@127.0.0.1"`, then a message will be sent from `apothik_1` to `apothik_2` and then return from `apothik_2` to `apothik_1` with the response. Thus, all nodes in the cluster play the same role and can respond to all requests.

### The Hashing Function

The key (pun intended!) to the solution is to use a hashing method. A hashing method is a deterministic mathematical function that takes a binary string (thus an arbitrarily large number) and returns an integer within a fixed interval (which can be small or large, depending on the applications). These functions also have well-chosen properties. For example, the property that two very close numbers in input will give very different results in output. And that the output interval is well "swept": mathematically, all elements of the arrival set have comparable numbers of antecedents.

Erlang offers a very convenient hashing method [`:erlang.phash2/2`](https://www.erlang.org/doc/apps/erts/erlang.html#phash2/2). It exists with 1 or 2 arguments. With two arguments, the output values are in the interval 0..argument.

Let's try:
```
% iex
iex(1)> :erlang.phash2(1)
2614250
iex(2)> :erlang.phash2(2)
27494836
iex(3)> :erlang.phash2(2,10)
8
iex(4)> :erlang.phash2(1,10)
2
iex(5)> (for i<-1..1000, do: :erlang.phash2(i, 5)) |> Enum.frequencies
%{0 => 214, 1 => 179, 2 => 207, 3 => 209, 4 => 191}
iex(6)> (for i<-1..100_000, do: :erlang.phash2(i, 5)) |> Enum.frequencies
%{0 => 20002, 1 => 20054, 2 => 20130, 3 => 19943, 4 => 19871}
```

We see that the output values are well distributed from 0 to 4.

### Distributing Keys Across Servers

First, let's clean up a bit. We gather the cluster knowledge in a specialized module: `apothik/cluster.ex`
```elixir
defmodule Apothik.Cluster do
  @nb_nodes 5

  def nb_nodes(), do: @nb_nodes

  def node_name(i), do: :"apothik_#{i}@127.0.0.1"

  def node_list() do
    for i <- 1..nb_nodes(), do: node_name(i)
  end
end
```

This changes the call in `apothik/application.ex`
```elixir
-    hosts = for i <- 1..5, do: :"apothik_#{i}@127.0.0.1"
+    hosts = Apothik.Cluster.node_list()
```

Everything is ready to implement `key_to_node/1` in `cache/cache.ex`
```elixir
defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster

  # Interface
  def get(k) do
    node = key_to_node(k)
    GenServer.call({__MODULE__, node}, {:get, k})
  end

  def put(k, v) do
    node = key_to_node(k)
    GenServer.call({__MODULE__, node}, {:put, k, v})
  end

  def delete(k) do
    node = key_to_node(k)
    GenServer.call({__MODULE__, node}, {:delete, k})
  end

  def stats(), do: GenServer.call(__MODULE__, :stats)

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Implementation

  defp key_to_node(k) do
    (:erlang.phash2(k, Cluster.nb_nodes()) + 1) |> Cluster.node_name()
  end

  (... same as before...)
end
```

The function is very simple: the key gives a node number between 0 and 4, and we find the cluster name from there.
We are not very proud of the function `def node_name(i), do: :"apothik_#{i}@127.0.0.1"` which could allocate too many atoms (maybe, not sure, it would need further investigation but that's not the point of this phase).

Now, let's fill the cache to see what happens:
```
% ./scripts/start_master.sh
1> Master.fill(1, 5000)
:ok
2> for i<-1..5, do: Master.stat(i)
[1026, 996, 1012, 1021, 945]
3> (for i<-1..5, do: Master.stat(i)) |> Enum.sum
5000
```

We sent 5000 values into the distributed cache via node 1. We see that the values have been distributed quite evenly across the 5 nodes. 

We have a cache distributed across 5 machines! Phase 1 accomplished!

<a href="/apothik/">Home</a>
<a href="en_story_phase2.html"> Part 2</a>
<a href="en_story_phase3.html"> Part 3</a>

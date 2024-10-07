# Phase 1

Step 1: `mix new apothik`

Step 2: Create a script to launch 5 nodes

We simply asked ChapGPT  to generate a bash script and modify it

`elixir --name $node_name -S mix run --no-halt &`

- Launch elixir
- -name long name for a node (like name@ip_address)
- -S : enable the execution of a .exs script
- mix run : launch environment setup by mix
- --no-halt : don't stop an application even if there is no running process
- & start the process in background


Step 3 : Launch a iex that can connect to the launched Nodes (the Master)

`iex -S mix run` does not work
`Node.ping(:"apothik@127.0.0.1")`
`:pang`
(does not work)
`https://hexdocs.pm/elixir/1.12/Node.html#ping/1``

Instead, give it a name
`iex --name master@127.0.0.1 -S mix run`
`Node.ping(:"apothik@127.0.0.1")`
`:pong``

Step 4: But they don't know each other?? Answer `libcluster`

`https://github.com/bitwalker/libcluster`

We add an application with a Supervisor to be able to launch a libcluster process.
Several techniques can be used.
epmd = Le service de base qui permet que chaque neoud connait tous les autres noeuds qui se connaissent.
On liste "en dur" tous les noeuds fixes du cluster

Test:
1. Start master
2. Node.list -> []
3. Node.connect(:"apothik_1@127.0.0.1")
2. Node.list -> toute la liste

Step 5: Adding a Cache Genserver

Put it in the supervisor Tree
The Apothik.Cache is a name uniquely registered on each node (start_link)

iex(master@127.0.0.1)4> :rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :stats, [])
0
iex(master@127.0.0.1)5> :rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :put, [:toto, 12])
:ok
iex(master@127.0.0.1)6> :rpc.call(:"apothik_1@127.0.0.1", Apothik.Cache, :stats, [])
1

.iex.exs => utils to be able to help the master
Create get, put, stats, etc and fill (to fill a node)
The idea is to use :rpc (remote procedure call. Module / Function / Arguments)
And the function calls a Process with a name Apothik.Cache

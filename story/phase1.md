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



defmodule Apothik.Cluster do
  @nb_nodes 5

  def nb_nodes(), do: @nb_nodes

  def node_name(i), do: :"apothik_#{i}@127.0.0.1"

  def node_list() do
    for i <- 1..nb_nodes(), do: node_name(i)
  end
end

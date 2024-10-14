defmodule Apothik.Cluster do
  def nb_nodes(), do: (Node.list() |> length()) + 1

  def node_name(i), do: :"apothik_#{i}@127.0.0.1"

  # def node_list() do
  #   for i <- 1..nb_nodes(), do: node_name(i)
  # end

  def node_list(nb_node) do
    for i <- 1..nb_node, do: node_name(i)
  end
end

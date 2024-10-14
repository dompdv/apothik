defmodule Apothik.Application do
  @moduledoc false

  use Application
  @nb_nodes 5

  @impl true
  def start(_type, _args) do
    hosts = Apothik.Cluster.node_list(@nb_nodes)

    topologies = [
      apothik_cluster_1: [
        strategy: Cluster.Strategy.Epmd,
        config: [hosts: hosts]
      ]
    ]

    children = [
      {Cluster.Supervisor, [topologies, [name: Apothik.ClusterSupervisor]]},
      Apothik.Cluster,
      Apothik.Cache
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Apothik.Supervisor)
  end
end

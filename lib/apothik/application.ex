defmodule Apothik.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    hosts = Apothik.Cache.node_list()

    topologies = [
      apothik_cluster_1: [
        strategy: Cluster.Strategy.Epmd,
        config: [hosts: hosts]
      ]
    ]

    children = [
      {Cluster.Supervisor, [topologies, [name: Apothik.ClusterSupervisor]]},
      Apothik.Crdt
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Apothik.Supervisor)
  end
end

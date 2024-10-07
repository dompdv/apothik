defmodule Apothik.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
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

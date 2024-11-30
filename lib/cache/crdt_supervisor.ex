defmodule Apothik.CrdtSupervisor do
  use Supervisor

  alias Apothik.Cache

  def stats() do
    self = Cache.number_from_node_name(Node.self())
    groups = Cache.groups_of_a_node(self)

    for g <- groups do
      DeltaCrdt.to_map(:"apothik_crdt_#{g}")
      |> map_size()
    end
    |> Enum.sum()
  end

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

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

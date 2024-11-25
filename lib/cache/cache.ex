defmodule Apothik.Cache do
  use GenServer
  require Logger

  #### Groups and Nodes
  @nb_nodes 5

  @hosts for i <- 0..(@nb_nodes - 1), into: %{}, do: {i, :"apothik_#{i}@127.0.0.1"}

  def static_nb_nodes(), do: @nb_nodes

  def node_name(i), do: @hosts[i]
  def crdt_name(i), do: :"apothik_crdt_#{i}"

  def number_from_node_name(node) do
    Enum.find(@hosts, fn {_, v} -> v == node end) |> elem(0)
  end

  def node_list(), do: Map.values(@hosts)

  def list_apothik_nodes() do
    [Node.self() | Node.list()] |> Enum.filter(&apothik?/1) |> Enum.sort()
  end

  def apothik?(node), do: node |> Atom.to_string() |> String.starts_with?("apothik")

  def groups_of_a_node(node_number) do
    n = static_nb_nodes()
    [node_number, rem(node_number - 1 + n, n), rem(node_number - 2 + n, n)]
  end

  defp nodes_in_group(group_number) do
    n = static_nb_nodes()
    [group_number, rem(group_number + 1, n), rem(group_number + 2, n)]
  end

  defp key_to_group_number(k), do: :erlang.phash2(k, static_nb_nodes())

  defp alive?(node_number) when is_integer(node_number),
    do: node_number |> node_name() |> alive?()

  defp alive?(node_name), do: node_name == Node.self() or node_name in Node.list()

  defp live_nodes_in_a_group(group_number),
    do: group_number |> nodes_in_group() |> Enum.filter(&alive?/1)

  def pick_me_if_possible(l) do
    case Enum.find(l, fn i -> node_name(i) == Node.self() end) do
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

  #### GenServer Interface
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

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  def set_neighbours(state) do
    my_name = crdt_name(state.group)
    self = number_from_node_name(Node.self())

    neighbours =
      for n <- nodes_in_group(state.group), n != self do
        {my_name, node_name(n)}
      end

    :ok = DeltaCrdt.set_neighbours(state.pid, neighbours)

    Logger.debug(
      "Setting neighbours for #{state.group} on node #{self} with neighbours #{inspect(neighbours)}"
    )

    state
  end

  #### Implementation

  @impl true
  def init(g) do
    {:ok, pid} =
      DeltaCrdt.start_link(DeltaCrdt.AWLWWMap,
        max_sync_size: 30_000,
        # max_sync_size: 500,
        name: crdt_name(g)
      )

    state =
      %{group: g, pid: pid}
      |> set_neighbours()

    Logger.debug("Starting cache #{state.group} on node #{Node.self()}")

    :net_kernel.monitor_nodes(true)
    {:ok, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.debug("Node up #{inspect(node)}")

    Task.start(fn ->
      Process.sleep(5_000)
      set_neighbours(state)
    end)

    {:noreply, state}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.debug("Node down #{inspect(node)}")
    {:noreply, state}
  end
end

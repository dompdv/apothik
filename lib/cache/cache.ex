defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster
  require Logger

  #### Groups and Nodes

  # Give the list of nodes of a group
  defp nodes_in_group(group_number) do
    n = Cluster.static_nb_nodes()
    [group_number, rem(group_number - 1 + n, n), rem(group_number - 2 + n, n)]
  end

  # Give the list of groups to which the node belongs
  defp groups_of_a_node(node_number) do
    n = Cluster.static_nb_nodes()
    [node_number, rem(node_number + 1, n), rem(node_number + 2, n)]
  end

  # Map a key to a group number
  defp key_to_group_number(k), do: :erlang.phash2(k, Cluster.static_nb_nodes())

  # Check if a node is alive based on its number
  defp alive?(node_number) when is_integer(node_number),
    do: node_number |> Cluster.node_name() |> alive?()

  # Checks if a node is alive based on its name
  defp alive?(node_name), do: node_name == Node.self() or node_name in Node.list()

  # Retrieve a live node in a group, if any
  defp pick_a_live_node(group_number) do
    case group_number |> nodes_in_group() |> Enum.filter(&alive?/1) do
      [] -> nil
      [a | _] -> a
    end
  end

  # Retrieve a live node in a group other than me, if any
  defp pick_a_live_peer(me, group_number) do
    case group_number |> nodes_in_group() |> Enum.reject(&(&1 == me)) |> Enum.filter(&alive?/1) do
      [] -> nil
      [a | _] -> a
    end
  end

  #### GenServer Interface
  def get(k) do
    # Find a live node and retrieve the value for the key
    alive_node = k |> key_to_group_number() |> pick_a_live_node()
    GenServer.call({__MODULE__, Cluster.node_name(alive_node)}, {:get, k})
  end

  # Put a {key, value} in the cache
  def put(k, v) do
    # Map a key to a group number
    group_number = key_to_group_number(k)
    # Find the first alive node belonging to the group
    alive_node = pick_a_live_node(group_number)
    GenServer.call({__MODULE__, Cluster.node_name(alive_node)}, {:put, group_number, k, v})
  end

  def stats(), do: GenServer.call(__MODULE__, :stats)

  def update_nodes(nodes), do: GenServer.call(__MODULE__, {:update_nodes, nodes})

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  #### Private Interface

  # Save a {key, value} on a node belonging to a group. A "private interface"
  def put_replica(replica, group, k, v) do
    node_name = Cluster.node_name(replica)
    GenServer.call({__MODULE__, node_name}, {:put_replica, group, k, v})
  end

  # Hydration (the process to ask other nodes for their data when starting up)
  def hydrate() do
    me = Node.self() |> Cluster.number_from_node_name()
    # For each Group to which the node belongs, find a live node and request its data
    Enum.each(
      groups_of_a_node(me),
      fn group ->
        peer = pick_a_live_peer(me, group)

        if peer != nil do
          GenServer.cast({__MODULE__, Cluster.node_name(peer)}, {:i_am_thirsty, group, self()})
        end
      end
    )
  end

  #### Implementation

  @impl true
  def init(_args) do
    {:ok, %{}, {:continue, nil}}
  end

  @impl true
  def handle_continue(_continue_args, state) do
    hydrate()
    {:noreply, state}
  end

  @impl true
  def handle_cast({:i_am_thirsty, group, from}, state) do
    filtered_on_groups = for {_, {^group, _}} = c <- state, into: %{}, do: c
    GenServer.cast(from, {:drink, filtered_on_groups})
    {:noreply, state}
  end

  def handle_cast({:drink, payload}, state) do
    {:noreply, Map.merge(state, payload)}
  end

  @impl true
  def handle_call({:update_nodes, _nodes}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:get, k}, _from, state) do
    {:reply, Map.get(state, k, {nil, nil}) |> elem(1), state}
  end

  def handle_call({:put, group, k, v}, _from, state) do
    group
    |> nodes_in_group()
    |> Enum.reject(fn i -> Cluster.node_name(i) == Node.self() end)
    |> Enum.filter(&alive?/1)
    |> Enum.each(fn replica -> :ok = put_replica(replica, group, k, v) end)

    {:reply, :ok, Map.put(state, k, {group, v})}
  end

  def handle_call({:put_replica, group, k, v}, _from, state) do
    {:reply, :ok, Map.put(state, k, {group, v})}
  end

  def handle_call(:stats, _from, state) do
    {:reply, map_size(state), state}
  end
end

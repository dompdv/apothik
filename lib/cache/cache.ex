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

  # Give the list of nodes belonging to a group
  defp groups_of_a_node(node_number) do
    n = Cluster.static_nb_nodes()
    [node_number, rem(node_number + 1, n), rem(node_number + 2, n)]
  end

  # Map a key to a group number
  defp key_to_group_number(k), do: :erlang.phash2(k, Cluster.static_nb_nodes()) + 1

  # Check if a node is alive based on its number
  defp node_alive?(node_number) when is_integer(node_number),
    do: node_number |> Cluster.node_name() |> node_alive?()

  # Checks if a node is alive based on its name
  defp node_alive?(node_name), do: node_name == Node.self() or node_name in Node.list()

  # Retrieve a live node in a group, if any
  defp alive_node_in_group(group_number) do
    case group_number |> nodes_in_group() |> Enum.filter(&node_alive?/1) do
      [] -> nil
      [a | _] -> a
    end
  end

  #### GenServer Interface
  def get(k) do
    # Find a live node and retrieve the value for the key
    alive_node = k |> key_to_group_number() |> alive_node_in_group()

    if alive_node == nil,
      do: :error,
      else: GenServer.call({__MODULE__, Cluster.node_name(alive_node)}, {:get, k})
  end

  # Put a {key, value} in the cache
  def put(k, v) do
    # Map a key to a group number
    group_number = key_to_group_number(k)
    # Find the first alive node belonging to the group
    alive_node = alive_node_in_group(group_number)

    if alive_node == nil,
      do: :error,
      else:
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

  #### Implementation

  def hydrate_from_group(me, group) do
    IO.inspect({me, group}, label: "hydrate_from_group")

    # Find another node in the group which is alive
    alive_node_in_group =
      group |> nodes_in_group() |> Enum.reject(&(&1 == me)) |> Enum.filter(&node_alive?/1)

    if alive_node_in_group == [] do
      %{}
    else
      node = hd(alive_node_in_group)

      try do
        GenServer.call({__MODULE__, Cluster.node_name(node)}, {:dump, group})
      catch
        _ -> %{}
      end
    end
  end

  @impl true
  def init(_args) do
    {:ok, %{}, {:continue, nil}}
  end

  @impl true
  def handle_continue(_continue_args, state) do
    me = Node.self() |> Cluster.number_from_node_name()

    me
    |> groups_of_a_node()
    |> Enum.reduce(
      state,
      fn group, acc -> Map.merge(acc, hydrate_from_group(me, group)) end
    )
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_call({:update_nodes, _nodes}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:dump, group}, _from, state) do
    filtered_on_groups = for {_, {^group, _}} = c <- state, into: %{}, do: c
    IO.inspect({:dump, group, filtered_on_groups}, label: "dump")
    {:reply, filtered_on_groups, state}
  end

  def handle_call({:get, k}, _from, state) do
    value =
      case Map.get(state, k) do
        nil ->
          nil

        {_, v} ->
          v
      end

    {:reply, value, state}
  end

  def handle_call({:put, group, k, v}, _from, state) do
    group
    |> nodes_in_group()
    |> Enum.reject(fn i -> Cluster.node_name(i) == Node.self() end)
    |> Enum.filter(&node_alive?/1)
    |> Enum.each(fn replica -> :ok = put_replica(replica, group, k, v) end)

    {:reply, :ok, Map.put(state, k, {group, v})}
  end

  def handle_call({:put_replica, group, k, v}, _from, state) do
    {:reply, :ok, Map.put(state, k, {group, v})}
  end

  def handle_call(:stats, _from, state) do
    {:reply, map_size(state), state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning(msg)
    {:noreply, state}
  end
end

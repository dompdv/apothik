defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster
  require Logger

  #### Groups and Nodes

  # Give the list of nodes of a group
  defp nodes_in_group(group_number) do
    n = Cluster.static_nb_nodes()
    [group_number, rem(group_number + 1 + n, n), rem(group_number + 2 + n, n)]
  end

  # Give the list of groups to which the node belongs
  #  defp groups_of_a_node(node_number) do
  #    n = Cluster.static_nb_nodes()
  #    [node_number, rem(node_number - 1, n), rem(node_number - 2, n)]
  #  end

  # Map a key to a group number
  defp key_to_group_number(k), do: :erlang.phash2(k, Cluster.static_nb_nodes())

  # Check if a node is alive based on its number
  defp alive?(node_number) when is_integer(node_number),
    do: node_number |> Cluster.node_name() |> alive?()

  # Checks if a node is alive based on its name
  defp alive?(node_name), do: node_name == Node.self() or node_name in Node.list()

  defp live_nodes_in_a_group(group_number),
    do: group_number |> nodes_in_group() |> Enum.filter(&alive?/1)

  def pick_me_if_possible(l) do
    case Enum.find(l, fn i -> Cluster.node_name(i) == Node.self() end) do
      nil -> Enum.random(l)
      i -> i
    end
  end

  # Retrieve a live node in a group, if any
  defp pick_a_live_node(group_number) do
    case live_nodes_in_a_group(group_number) do
      [] -> nil
      l -> pick_me_if_possible(l)
    end
  end

  # Retrieve a live node in a group other than me, if any
  #  defp pick_a_live_peer(me, group_number) do
  #    case group_number |> nodes_in_group() |> Enum.reject(&(&1 == me)) |> Enum.filter(&alive?/1) do
  #      [] -> nil
  #      [a | _] -> a
  #    end
  #  end

  #### GenServer Interface
  def get(k) do
    alive_node = k |> key_to_group_number() |> pick_a_live_node() |> Cluster.node_name()
    GenServer.call({__MODULE__, alive_node}, {:get, k})
  end

  # Put a {key, value} in the cache
  def put(k, v) do
    alive_node = k |> key_to_group_number() |> pick_a_live_node() |> Cluster.node_name()
    GenServer.call({__MODULE__, alive_node}, {:put, k, v})
  end

  def put_as_replica(replica, k, v) do
    GenServer.cast({__MODULE__, Cluster.node_name(replica)}, {:put_as_replica, k, v})
  end

  def stats(), do: GenServer.call(__MODULE__, :stats)

  def update_nodes(_nodes), do: nil

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  #### Implementation

  @impl true
  def init(_args) do
    # Hydration (the process to ask other nodes for their data when starting up)
    #    me = Node.self() |> Cluster.number_from_node_name()
    # For each Group to which the node belongs, find a live node and request its data
    #    Enum.each(
    #      groups_of_a_node(me),
    #      fn group ->
    #       peer = pick_a_live_peer(me, group)
    #
    #       if peer != nil do
    #          GenServer.cast({__MODULE__, Cluster.node_name(peer)}, {:i_am_thirsty, group, self()})
    #        end
    #      end
    #    )

    {:ok, %{}}
  end

  @impl true
  #  def handle_cast({:i_am_thirsty, group, from}, state) do
  #    filtered_on_groups = for {_, {^group, _}} = c <- state, into: %{}, do: c
  #    GenServer.cast(from, {:drink, filtered_on_groups})
  #    {:noreply, state}
  #  end

  # def handle_cast({:drink, payload}, state) do
  #   {:noreply, Map.merge(state, payload)}
  # end

  def handle_cast({:put_as_replica, k, v}, state) do
    {:noreply, Map.put(state, k, v)}
  end

  @impl true
  #  def handle_call({:update_nodes, _nodes}, _from, state), do: {:reply, :ok, state}

  def handle_call({:get, k}, _from, state), do: {:reply, Map.get(state, k), state}

  def handle_call({:put, k, v}, _from, state) do
    k
    |> key_to_group_number()
    |> live_nodes_in_a_group()
    |> Enum.reject(fn i -> Cluster.node_name(i) == Node.self() end)
    |> Enum.each(fn replica -> put_as_replica(replica, k, v) end)

    {:reply, :ok, Map.put(state, k, v)}
  end

  def handle_call(:stats, _from, state) do
    {:reply, map_size(state), state}
  end
end

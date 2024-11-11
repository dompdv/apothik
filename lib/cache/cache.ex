defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster
  require Logger

  defstruct cache: %{}

  #### Groups and Nodes

  defp nodes_in_group(group_number) do
    n = Cluster.static_nb_nodes()
    [group_number, rem(group_number + 1 + n, n), rem(group_number + 2 + n, n)]
  end

  defp groups_of_a_node(node_number) do
    n = Cluster.static_nb_nodes()
    [node_number, rem(node_number - 1, n), rem(node_number - 2, n)]
  end

  defp key_to_group_number(k), do: :erlang.phash2(k, Cluster.static_nb_nodes())

  defp alive?(node_number) when is_integer(node_number),
    do: node_number |> Cluster.node_name() |> alive?()

  defp alive?(node_name), do: node_name == Node.self() or node_name in Node.list()

  defp live_nodes_in_a_group(group_number),
    do: group_number |> nodes_in_group() |> Enum.filter(&alive?/1)

  def pick_me_if_possible(l) do
    case Enum.find(l, fn i -> Cluster.node_name(i) == Node.self() end) do
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
    alive_node = k |> key_to_group_number() |> pick_a_live_node() |> Cluster.node_name()
    GenServer.call({__MODULE__, alive_node}, {:get, k})
  end

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
    me = Node.self() |> Cluster.number_from_node_name()

    for g <- groups_of_a_node(me), peer <- nodes_in_group(g), peer != me, alive?(peer) do
      GenServer.cast({__MODULE__, Cluster.node_name(peer)}, {:i_am_thirsty, g, self()})
    end

    {:ok, %__MODULE__{cache: %{}}}
  end

  @impl true
  def handle_cast({:i_am_thirsty, group, from}, %{cache: cache} = state) do
    filtered_on_group = Map.filter(cache, fn {k, _} -> key_to_group_number(k) == group end)
    GenServer.cast(from, {:drink, filtered_on_group})
    {:noreply, state}
  end

  def handle_cast({:drink, payload}, %{cache: cache} = state) do
    {:noreply, %{state | cache: Map.merge(cache, payload)}}
  end

  def handle_cast({:put_as_replica, k, v}, %{cache: cache} = state) do
    {:noreply, %{state | cache: Map.put(cache, k, v)}}
  end

  @impl true
  def handle_call({:get, k}, _from, %{cache: cache} = state) do
    {:reply, Map.get(cache, k), state}
  end

  def handle_call({:put, k, v}, _from, %{cache: cache} = state) do
    k
    |> key_to_group_number()
    |> live_nodes_in_a_group()
    |> Enum.reject(fn i -> Cluster.node_name(i) == Node.self() end)
    |> Enum.each(fn replica -> put_as_replica(replica, k, v) end)

    {:reply, :ok, %{state | cache: Map.put(cache, k, v)}}
  end

  def handle_call(:stats, _from, %{cache: cache} = state) do
    {:reply, map_size(cache), state}
  end
end

defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster
  require Logger

  @batch_size 100

  defstruct cache: %{}, pending_gets: [], hydration: nil

  #### Groups and Nodes

  defp nodes_in_group(group_number) do
    n = Cluster.static_nb_nodes()
    [group_number, rem(group_number + 1 + n, n), rem(group_number + 2 + n, n)]
  end

  defp groups_of_a_node(node_number) do
    n = Cluster.static_nb_nodes()
    [node_number, rem(node_number - 1 + n, n), rem(node_number - 2 + n, n)]
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

  def pick_a_live_node_in_each_group() do
    me = Node.self() |> Cluster.number_from_node_name()

    for g <- groups_of_a_node(me),
        peer <- nodes_in_group(g),
        peer != me,
        alive?(peer),
        into: %{},
        do: {g, peer}
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
    peers = pick_a_live_node_in_each_group()

    Enum.each(peers, fn {group, peer} ->
      GenServer.cast(
        {__MODULE__, Cluster.node_name(peer)},
        {:i_am_thirsty, group, self(), 0, @batch_size}
      )
    end)

    starting_indexes = for {g, _} <- peers, into: %{}, do: {g, 0}
    start = %__MODULE__{}
    {:ok, %{start | hydration: starting_indexes}}
  end

  @impl true
  def handle_cast({:i_am_thirsty, group, from, start_index, batch_size}, state) do
    %{cache: cache} = state
    filtered_on_group = Map.filter(cache, fn {k, _} -> key_to_group_number(k) == group end)

    keys = filtered_on_group |> Map.keys() |> Enum.sort() |> Enum.slice(start_index, batch_size)
    final = length(keys) < batch_size
    filtered = for k <- keys, into: %{}, do: {k, filtered_on_group[k]}

    GenServer.cast(from, {:drink, group, filtered, final})

    {:noreply, state}
  end

  def handle_cast({:drink, group, payload, final}, state) do
    %{cache: cache, hydration: hydration} = state
    filtered_payload = Map.filter(payload, fn {k, _} -> not Map.has_key?(cache, k) end)
    batch_size = map_size(payload)

    new_hydration =
      if final do
        Map.delete(hydration, group)
      else
        start_index = hydration[group]
        peers = pick_a_live_node_in_each_group()

        GenServer.cast(
          {__MODULE__, Cluster.node_name(peers[group])},
          {:i_am_thirsty, group, self(), start_index + batch_size, @batch_size}
        )

        Map.put(hydration, group, start_index + batch_size)
      end

    {:noreply, %{state | cache: Map.merge(cache, filtered_payload), hydration: new_hydration}}
  end

  def handle_cast({:put_as_replica, k, v}, %{cache: cache} = state) do
    {:noreply, %{state | cache: Map.put(cache, k, v)}}
  end

  def handle_cast({:hydrate_key, from, k}, %{cache: cache} = state) do
    :ok = GenServer.cast(from, {:drink_key, k, cache[k]})
    {:noreply, state}
  end

  def handle_cast({:drink_key, k, v}, state) do
    %{cache: cache, pending_gets: pending_gets} = state

    {to_reply, new_pending_gets} =
      Enum.split_with(pending_gets, fn {hk, _} -> k == hk end)

    Enum.each(to_reply, fn {_, client} -> GenServer.reply(client, v) end)

    new_cache =
      case Map.get(cache, k) do
        nil -> Map.put(cache, k, v)
        _ -> cache
      end

    {:noreply, %{state | cache: new_cache, pending_gets: new_pending_gets}}
  end

  @impl true
  def handle_call({:get, k}, from, state) do
    %{cache: cache, pending_gets: pending_gets} = state

    case Map.get(cache, k) do
      nil ->
        peer =
          k
          |> key_to_group_number()
          |> live_nodes_in_a_group()
          |> Enum.reject(fn i -> Cluster.node_name(i) == Node.self() end)
          |> Enum.random()

        :ok = GenServer.cast({__MODULE__, Cluster.node_name(peer)}, {:hydrate_key, self(), k})

        {:noreply, %{state | pending_gets: [{k, from} | pending_gets]}}

      val ->
        {:reply, val, state}
    end
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

defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster
  require Logger

  # Interface
  def get(k) do
    node_name = k |> key_to_group() |> first_alive() |> Cluster.node_name()
    GenServer.call({__MODULE__, node_name}, {:get, k})
  end

  def put(k, v) do
    group = key_to_group(k)
    node_name = group |> first_alive() |> Cluster.node_name()
    GenServer.call({__MODULE__, node_name}, {:put, group, k, v})
  end

  def put_replica(replica, group, k, v) do
    node_name = Cluster.node_name(replica)
    GenServer.call({__MODULE__, node_name}, {:put_replica, group, k, v})
  end

  def stats(), do: GenServer.call(__MODULE__, :stats)

  def update_nodes(nodes) do
    GenServer.call(__MODULE__, {:update_nodes, nodes})
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Implementation
  defp node_alive?(node) when is_integer(node) do
    node_name = Cluster.node_name(node)
    node_name == Node.self() or node_name in Node.list()
  end

  defp node_alive?(node) do
    node == Node.self() or node in Node.list()
  end

  def first_alive(group_number) do
    case group_number |> get_replicas() |> Enum.filter(&node_alive?/1) do
      [] -> nil
      [a | _] -> a
    end
  end

  defp get_replicas(i) do
    n = Cluster.static_nb_nodes()
    [i, rem(i - 2 + n, n) + 1, rem(i - 3 + n, n) + 1]
  end

  defp get_groups(i) do
    n = Cluster.static_nb_nodes()
    [i, rem(i, n) + 1, rem(i + 1, n) + 1]
  end

  defp key_to_group(k) do
    :erlang.phash2(k, Cluster.static_nb_nodes()) + 1
  end

  def hydrate_from_group(me, group) do
    IO.inspect({me, group}, label: "hydrate_from_group")

    first_alive =
      group |> get_replicas() |> Enum.reject(&(&1 == me)) |> Enum.filter(&node_alive?/1)

    case first_alive do
      [] ->
        %{}

      [node | _] ->
        IO.inspect(node, label: "Hydrate from:")
        node_name = Cluster.node_name(node) |> IO.inspect(label: "Hydrate from name:")
        %{}

        try do
          GenServer.call({__MODULE__, node_name}, {:dump, group})
          |> IO.inspect(label: "extracted")
        catch
          _ -> nil
        end
    end
  end

  @impl true
  def init(_args) do
    {:ok, %{}, {:continue, nil}}
  end

  @impl true
  def handle_continue(_continue_args, state) do
    me = Node.self() |> Cluster.number_from_node_name() |> IO.inspect(label: "me")

    me
    |> get_groups()
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
    IO.inspect({:dump, group, state}, label: "dump")
    #    filtered_on_groups = for {_, {^group, _}} = c <- state, into: %{}, do: c
    #    {:reply, filtered_on_groups, state}
    {:reply, %{}, state}
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
    |> get_replicas()
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

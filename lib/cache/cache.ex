defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster
  require Logger

  # Interface
  def get(k) do
    node = key_to_node(k)
    GenServer.call({__MODULE__, node}, {:get, k})
  end

  def put(k, v) do
    node = key_to_node(k)
    GenServer.call({__MODULE__, node}, {:put, k, v})
  end

  def delete(k) do
    node = key_to_node(k)
    GenServer.call({__MODULE__, node}, {:delete, k})
  end

  def stats(), do: GenServer.call(__MODULE__, :stats)

  def update_nodes(nodes) do
    GenServer.call(__MODULE__, {:update_nodes, nodes})
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Implementation

  defp key_to_node(k) do
    [{_, ring}] = :ets.lookup(:cluster_nodes_list, :cluster_ring)
    HashRing.key_to_node(ring, k)
  end

  @impl true
  def init(_args) do
    :ets.new(:cluster_nodes_list, [:named_table, :set, :protected])
    {_, nodes} = Cluster.get_state()
    :ets.insert(:cluster_nodes_list, {:cluster_ring, HashRing.new() |> HashRing.add_nodes(nodes)})
    {:ok, %{}}
  end

  @impl true
  def handle_call({:update_nodes, nodes}, _from, state) do
    ring = HashRing.new() |> HashRing.add_nodes(nodes)
    :ets.insert(:cluster_nodes_list, {:cluster_ring, ring})

    {:reply, :ok, state}
  end

  def handle_call({:get, k}, _from, state) do
    {:reply, Map.get(state, k), state}
  end

  def handle_call({:put, k, v}, _from, state) do
    {:reply, :ok, Map.put(state, k, v)}
  end

  def handle_call({:delete, k}, _from, state) do
    {:reply, :ok, Map.delete(state, k)}
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

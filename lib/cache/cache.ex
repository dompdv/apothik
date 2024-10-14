defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster

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

  defp key_to_node(k), do: GenServer.call(__MODULE__, {:key_to_node, k})

  @impl true
  def init(_args) do
    {:ok, {Cluster.get_state(), %{}}}
  end

  @impl true
  def handle_call({:get, k}, _from, {_, mem} = state) do
    {:reply, Map.get(mem, k), state}
  end

  def handle_call({:put, k, v}, _from, {nodes, mem}) do
    new_mem = Map.put(mem, k, v)
    {:reply, :ok, {nodes, new_mem}}
  end

  def handle_call({:delete, k}, _from, {nodes, mem}) do
    new_mem = Map.delete(mem, k)
    {:reply, :ok, {nodes, new_mem}}
  end

  def handle_call(:stats, _from, {_nodes, mem} = state) do
    {:reply, map_size(mem), state}
  end

  def handle_call({:update_nodes, nodes}, _from, {_, mem}) do
    IO.inspect("Updating nodes: #{inspect(nodes)}")
    {:reply, :ok, {nodes, mem}}
  end

  def handle_call({:key_to_node, k}, _from, {nodes, _mem} = state) do
    node = Enum.at(nodes, :erlang.phash2(k, length(nodes)))
    {:reply, node, state}
  end

  @impl true
  def handle_info(msg, state) do
    IO.inspect(msg)
    {:noreply, state}
  end
end

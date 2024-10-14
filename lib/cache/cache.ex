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

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Implementation

  defp key_to_node(k) do
    (:erlang.phash2(k, Cluster.nb_nodes()) + 1)
    |> Cluster.node_name()
  end

  @impl true
  def init(_args) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get, k}, _from, state) do
    {:reply, Map.get(state, k), state}
  end

  def handle_call({:put, k, v}, _from, state) do
    new_state = Map.put(state, k, v)
    {:reply, :ok, new_state}
  end

  def handle_call({:delete, k}, _from, state) do
    new_state = Map.delete(state, k)
    {:reply, :ok, new_state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, map_size(state), state}
  end

  @impl true
  def handle_info(msg, state) do
    IO.inspect(msg)
    {:noreply, state}
  end
end

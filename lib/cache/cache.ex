defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster
  require Logger

  @nb_tokens 1000

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
    landing_token = :erlang.phash2(k, @nb_tokens)
    nodes_tokens = :ets.match(:cluster_nodes_list, {:"$1", :"$2"})
    IO.inspect(landing_token)

    Enum.reduce_while(nodes_tokens, nil, fn [node, tokens], _ ->
      if landing_token in tokens, do: {:halt, node}, else: {:cont, nil}
    end)
  end

  @impl true
  def init(_args) do
    :ets.new(:cluster_nodes_list, [:named_table, :set, :protected])
    {_, nodes} = Cluster.get_state()

    nodes
    |> Enum.zip(Enum.chunk_every(1..@nb_tokens, div(@nb_tokens, length(nodes))))
    |> Enum.each(fn {node, tokens} ->
      :ets.insert(:cluster_nodes_list, {node, tokens})
    end)

    {:ok, %{}}
  end

  @impl true
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

  def handle_call({:update_nodes, nodes}, _from, state) do
    Logger.info("Updating nodes: #{inspect(nodes)}")
    :ets.insert(:cluster_nodes_list, {:cluster_nodes, nodes})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning(msg)
    {:noreply, state}
  end
end

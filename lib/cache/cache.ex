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

  def get_tokens() do
    :ets.match(:cluster_nodes_list, {:"$1", :"$2"})
  end

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  # Implementation

  defp key_to_node(k) do
    landing_token = :erlang.phash2(k, @nb_tokens)
    nodes_tokens = :ets.match(:cluster_nodes_list, {:"$1", :"$2"})

    Enum.reduce_while(nodes_tokens, nil, fn [node, tokens], _ ->
      if landing_token in tokens, do: {:halt, node}, else: {:cont, nil}
    end)
  end

  @impl true
  def init(_args) do
    :ets.new(:cluster_nodes_list, [:named_table, :set, :protected])
    {_, nodes} = Cluster.get_state()

    nodes
    |> Enum.zip(Enum.chunk_every(0..(@nb_tokens - 1), div(@nb_tokens, length(nodes))))
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
    previous_nodes_tokens = :ets.match(:cluster_nodes_list, {:"$1", :"$2"})
    previous_nodes = for [node, _] <- previous_nodes_tokens, do: node

    added = MapSet.difference(MapSet.new(nodes), MapSet.new(previous_nodes)) |> MapSet.to_list()
    removed = MapSet.difference(MapSet.new(previous_nodes), MapSet.new(nodes)) |> MapSet.to_list()

    if length(added) == 1 do
      added_node = hd(added)
      target_tokens_per_node = div(@nb_tokens, length(previous_nodes) + 1)

      {tokens_for_added_node, tolled_nodes_tokens} =
        Enum.reduce(previous_nodes_tokens, {[], []}, fn [node, tokens],
                                                        {tolls, target_nodes_tokens} ->
          {remainder, toll} = Enum.split(tokens, target_tokens_per_node)
          {tolls ++ toll, [{node, remainder} | target_nodes_tokens]}
        end)

      Enum.each([{added_node, tokens_for_added_node} | tolled_nodes_tokens], fn {node, tokens} ->
        :ets.insert(:cluster_nodes_list, {node, tokens})
      end)
    end

    if length(removed) == 1 do
      removed_node = hd(removed)

      {[[_, tokens_to_share]], remaining_nodes} =
        Enum.split_with(previous_nodes_tokens, fn [node, _] -> node == removed_node end)

      size_of_chunks = max(div(length(tokens_to_share), length(remaining_nodes)), 1)

      tokens_to_share
      |> Enum.chunk_every(size_of_chunks)
      |> Enum.zip(remaining_nodes)
      |> Enum.each(fn {tokens_chunk, [node, previous_tokens]} ->
        :ets.insert(:cluster_nodes_list, {node, previous_tokens ++ tokens_chunk})
      end)

      :ets.delete(:cluster_nodes_list, removed_node)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning(msg)
    {:noreply, state}
  end
end

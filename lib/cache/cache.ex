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
    # Find the token associated with the key k
    landing_token = :erlang.phash2(k, @nb_tokens)
    # Retrieve the tokens per node
    nodes_tokens = :ets.match(:cluster_nodes_list, {:"$1", :"$2"})

    Enum.reduce_while(nodes_tokens, nil, fn [node, tokens], _ ->
      if landing_token in tokens, do: {:halt, node}, else: {:cont, nil}
    end)
  end

  def add_node(added, previous_nodes_tokens) do
    added_node = hd(added)
    previous_nodes = for [node, _] <- previous_nodes_tokens, do: node
    target_tokens_per_node = div(@nb_tokens, length(previous_nodes) + 1)

    # Collect a "toll" from each node to give to the new node
    {tokens_for_added_node, tolled_nodes_tokens} =
      Enum.reduce(
        previous_nodes_tokens,
        # {collected tokens, adjusted list of tokens per nodes}
        {[], []},
        fn [node, tokens], {tolls, target_nodes_tokens} ->
          {remainder, toll} = Enum.split(tokens, target_tokens_per_node)
          {tolls ++ toll, [{node, remainder} | target_nodes_tokens]}
        end
      )

    # Update table : add the new node and update the tokens per node for existing ones
    [{added_node, tokens_for_added_node} | tolled_nodes_tokens]
    |> Enum.each(fn {node, tokens} ->
      :ets.insert(:cluster_nodes_list, {node, tokens})
    end)
  end

  def remove_node(removed, previous_nodes_tokens) do
    removed_node = hd(removed)

    # Retrieve  available tokens from the removed node and remove the node from the list
    {[[_, tokens_to_share]], remaining_nodes} =
      Enum.split_with(previous_nodes_tokens, fn [node, _] -> node == removed_node end)

    # Distribute the tokens evenly among the remaining nodes
    tokens_to_share
    |> split_evenly(length(remaining_nodes))
    |> Enum.zip(remaining_nodes)
    |> Enum.each(fn {tokens_chunk, [node, previous_tokens]} ->
      :ets.insert(:cluster_nodes_list, {node, previous_tokens ++ tokens_chunk})
    end)

    # remove the node from the table
    :ets.delete(:cluster_nodes_list, removed_node)
  end

  @impl true
  def init(_args) do
    # Initialize the :ets table
    :ets.new(:cluster_nodes_list, [:named_table, :set, :protected])
    # Retrieve the current list of nodes
    {_, nodes} = Cluster.get_state()
    # Distribute evenly the tokens over the nodes in the cluster and store them in the :ets table
    number_of_tokens_per_node = div(@nb_tokens, length(nodes))

    0..(@nb_tokens - 1)
    |> Enum.chunk_every(number_of_tokens_per_node)
    |> Enum.zip(nodes)
    |> Enum.each(fn {tokens, node} ->
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

    cond do
      length(added) == 1 -> add_node(added, previous_nodes_tokens)
      length(removed) == 1 -> remove_node(removed, previous_nodes_tokens)
      true -> :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning(msg)
    {:noreply, state}
  end

  # Utility function
  # Split a list into chunks of same length
  def split_evenly([], acc, _), do: Enum.reverse(acc)
  def split_evenly(l, acc, 1), do: Enum.reverse([l | acc])

  def split_evenly(l, acc, n) do
    {chunk, rest} = Enum.split(l, max(1, div(length(l), n)))
    split_evenly(rest, [chunk | acc], n - 1)
  end

  def split_evenly(l, n), do: split_evenly(l, [], n)
end

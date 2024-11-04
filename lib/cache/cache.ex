defmodule Apothik.Cache do
  use GenServer
  alias Apothik.Cluster
  require Logger

  #### Groups and Nodes

  # Give the list of nodes of a group
  defp nodes_in_group(group_number) do
    n = Cluster.static_nb_nodes()
    [group_number, rem(group_number - 1 + n, n), rem(group_number - 2 + n, n)]
  end

  # Give the list of groups to which the node belongs
  defp groups_of_a_node(node_number) do
    n = Cluster.static_nb_nodes()
    [node_number, rem(node_number + 1, n), rem(node_number + 2, n)]
  end

  # Map a key to a group number
  defp key_to_group_number(k), do: :erlang.phash2(k, Cluster.static_nb_nodes())

  # Check if a node is alive based on its number
  defp alive?(node_number) when is_integer(node_number),
    do: node_number |> Cluster.node_name() |> alive?()

  # Checks if a node is alive based on its name
  defp alive?(node_name), do: node_name == Node.self() or node_name in Node.list()

  # Retrieve a live node in a group, if any
  defp peer(group_number) do
    case group_number |> nodes_in_group() |> Enum.filter(&alive?/1) do
      [] -> nil
      [a | _] -> a
    end
  end

  defp backup_nodes(group_number) do
    group_number
    |> nodes_in_group()
    |> Enum.map(&Cluster.node_name/1)
    |> Enum.reject(&(&1 == Node.self()))
  end

  defp request_backups(challenge) do
    groups = groups_of_a_node(Node.self() |> Cluster.number_from_node_name()) |> dbg

    for g <- groups, p <- backup_nodes(g) do
      :ok =
        GenServer.cast({__MODULE__, p}, {:get_backup, g, challenge, self()})
    end
  end

  #### GenServer Interface
  def get(k) do
    # Find a live node and retrieve the value for the key
    alive_node = k |> key_to_group_number() |> peer()
    GenServer.call({__MODULE__, Cluster.node_name(alive_node)}, {:get, k})
  end

  # Put a {key, value} in the cache
  def put(k, v) do
    # Map a key to a group number
    group_number = key_to_group_number(k)
    # Find the first alive node belonging to the group
    alive_node = peer(group_number)
    GenServer.call({__MODULE__, Cluster.node_name(alive_node)}, {:put, group_number, k, v})
  end

  def dump(node, for_group),
    do: GenServer.call({__MODULE__, Cluster.node_name(node)}, {:dump, for_group})

  def stats(), do: GenServer.call(__MODULE__, :stats)

  def update_nodes(nodes), do: GenServer.call(__MODULE__, {:update_nodes, nodes})

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  #### Private Interface

  # Save a {key, value} on a node belonging to a group. A "private interface"
  def put_replica(replica, group, k, v) do
    node_name = Cluster.node_name(replica)
    GenServer.call({__MODULE__, node_name}, {:put_replica, group, k, v})
  end

  #### State struc
  # cache is a map of key -> {group, value}
  # backup_challenge is a counter to avoid getting responses from the same backup nodes accounting for 2 backup answers
  # backup_answers is a map of group -> list of values from backup nodes
  defstruct cache: %{}, backup_challenge: 0, backup_answers: %{}

  #### Implementation

  @impl true
  def init(_args) do
    {:ok, %__MODULE__{}, {:continue, nil}}
  end

  @impl true
  def handle_continue(_continue_args, state) do
    # BUG: Populate the backup answers with the current group
    Process.send_after(self(), :new_request, 500)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:get_backup, group, challenge, from}, state) do
    group_backup =
      state.cache
      |> Enum.filter(fn {_k, {g, _}} -> g == group end)
      |> Enum.map(fn {k, {_, v}} -> {k, v} end)

    :ok = GenServer.cast(from, {:resp_backup, challenge, group, group_backup})
    {:noreply, state}
  end

  def handle_cast({:resp_backup, challenge, group, group_backup}, state)
      when challenge == state.backup_challenge and state.backup_challenge != :node_started do
    state =
      case Map.get(state.backup_answers, group, []) do
        [] ->
          # First response from a backup, store it and wait for an additional response
          %{state | backup_answers: Map.put(state.backup_answers, group, [group_backup])}

        [current] ->
          if MapSet.new(current) == MapSet.new(group_backup) do
            # 2 backups with the same challenge responded with the same answer
            # Assume this is the current state for this group
            group_cache =
              group_backup |> Enum.map(fn {k, v} -> {k, {group, v}} end) |> Map.new()

            new_backup_answers = Map.delete(state.backup_answers, group)

            if map_size(new_backup_answers) == 0 do
              # All groups have responded
              Logger.info("All groups have responded")

              %{
                state
                | cache: Map.merge(state.cache, group_cache),
                  backup_challenge: :node_started,
                  backup_answers: nil
              }
            else
              %{
                state
                | cache: Map.merge(state.cache, group_cache),
                  backup_answers: new_backup_answers
              }
            end
          else
            # Different answers from backups
            # Trouble ahead
            Logger.error("Different answers from backups, conflict resolution needed")
            state
          end
      end

    {:noreply, state}
  end

  # Discard responses when challenge is not the current one OR the node is already ready
  def handle_cast({:resp_backup, _challenge, _group, _group_backup}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call({:update_nodes, _nodes}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:dump, group}, _from, state) do
    filtered_on_groups = for {_, {^group, _}} = c <- state.cache, into: %{}, do: c
    {:reply, filtered_on_groups, state}
  end

  def handle_call({:get, k}, _from, state)
      when state.backup_challenge != :node_started do
    value =
      case Map.get(state.cache, k) do
        nil ->
          nil

        {_, v} ->
          v
      end

    {:reply, value, state}
  end

  def handle_call({:put, group, k, v}, _from, state)
      when state.backup_challenge != :node_started do
    group
    |> nodes_in_group()
    |> Enum.reject(fn i -> Cluster.node_name(i) == Node.self() end)
    |> Enum.filter(&alive?/1)
    |> Enum.each(fn replica -> :ok = put_replica(replica, group, k, v) end)

    state = %{state | cache: Map.put(state.cache, k, {group, v})}
    {:reply, :ok, state}
  end

  def handle_call({:put_replica, group, k, v}, _from, state) do
    state = %{state | cache: Map.put(state.cache, k, {group, v})}
    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, map_size(state.cache), state}
  end

  @impl true
  def handle_info(:new_request, state) when state.backup_challenge != :node_started do
    Logger.info("New request")
    state = %{state | backup_challenge: state.backup_challenge + 1, backup_answers: %{}}
    Process.send_after(self(), :new_request, 2000)
    request_backups(state.backup_challenge)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end

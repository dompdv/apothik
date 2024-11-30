defmodule Testing.Master do
  use GenServer
  alias Apothik.Cluster
  require Logger

  defstruct nodes: [], started: []

  def master_state(), do: GenServer.call(__MODULE__, :state)

  def start_node(node), do: GenServer.call(__MODULE__, {:start, node})
  def kill_node(node), do: GenServer.call(__MODULE__, {:kill, node})

  def cluster_stats(), do: GenServer.call(__MODULE__, :stats)

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  @impl true
  def init(args) do
    {:ok, %__MODULE__{nodes: Enum.to_list(0..(args - 1))}}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:start, node}, _from, %{nodes: nodes, started: started} = state) do
    cond do
      node not in nodes ->
        {:reply, :unknown_node, state}

      node in started ->
        {:reply, :node_already_started, state}

      true ->
        start_beam(node)
        {:reply, :ok, %{state | started: [node | started]}}
    end
  end

  def handle_call({:kill, node}, _from, %{started: started} = state) do
    Logger.debug("Killing node #{node}")

    kill_beam(node)
    {:reply, :ok, %{state | started: List.delete(started, node)}}
  end

  def handle_call(:stats, _from, %{nodes: nodes, started: started} = state) do
    {stopped, stats} =
      for(node <- nodes, do: {node, stat(node)})
      |> Enum.split_with(fn {_, x} -> x == {:badrpc, :nodedown} end)

    stopped = for {node, _} <- stopped, do: node
    s = Enum.sum(for {_, x} <- stats, do: x)

    {:reply, %{nodes: nodes, started: started, stats: Map.new(stats), stopped: stopped, sum: s},
     state}
  end

  # Cluster state management

  def start_beam(node) do
    node_name = Cluster.node_name(node)
    Logger.debug("Starting node #{node}")

    {:ok, _} =
      Task.start(fn ->
        IO.inspect("Launch")
        System.shell("elixir --name #{Atom.to_string(node_name)} -S mix run --no-halt")
      end)

    Process.sleep(100)
    Node.connect(node_name)
  end

  def stat(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :stats, [])
  end

  def kill_beam(i) do
    :rpc.call(Cluster.node_name(i), System, :stop, [0])
  end
end

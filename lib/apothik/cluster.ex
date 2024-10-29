defmodule Apothik.Cluster do
  alias Apothik.Cache
  use GenServer

  @nb_nodes 5

  @hosts for i <- 0..(@nb_nodes - 1), into: %{}, do: {i, :"apothik_#{i}@127.0.0.1"}

  def static_nb_nodes(), do: @nb_nodes

  def nb_nodes(), do: GenServer.call(__MODULE__, :nb_nodes)

  def node_name(i), do: @hosts[i]

  def number_from_node_name(node) do
    Enum.find(@hosts, fn {_, v} -> v == node end) |> elem(0)
  end

  def node_list(), do: Map.values(@hosts)

  def list_apothik_nodes() do
    [Node.self() | Node.list()] |> Enum.filter(&apothik?/1) |> Enum.sort()
  end

  def apothik?(node), do: node |> Atom.to_string() |> String.starts_with?("apothik")

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  def get_state(), do: GenServer.call(__MODULE__, :get_state)
  @impl true
  def init(_args) do
    :net_kernel.monitor_nodes(true)
    {:ok, list_apothik_nodes()}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {Node.self(), state}, state}
  end

  def handle_call(:nb_nodes, _from, state) do
    {:reply, length(state), state}
  end

  @impl true
  def handle_info({:nodedown, _node}, _state) do
    nodes = list_apothik_nodes()
    Cache.update_nodes(nodes)
    {:noreply, nodes}
  end

  def handle_info({:nodeup, _node}, _state) do
    nodes = list_apothik_nodes()
    Cache.update_nodes(nodes)
    {:noreply, nodes}
  end

  def handle_info(msg, state) do
    IO.inspect(msg)
    {:noreply, state}
  end
end

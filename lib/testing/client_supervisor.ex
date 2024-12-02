defmodule Testing.ClientSupervisor do
  require Logger
  use DynamicSupervisor

  def start_link(num_clients) do
    res = DynamicSupervisor.start_link(__MODULE__, nil, name: __MODULE__)
    start_children(num_clients)
    res
  end

  @impl true
  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_children(num_clients) do
    Logger.debug("Starting ClientSupervisor with #{num_clients}")

    Enum.each(1..num_clients, fn i ->
      child_spec = {Testing.Client, i}
      DynamicSupervisor.start_child(__MODULE__, child_spec)
    end)
  end
end

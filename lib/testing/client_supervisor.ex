defmodule Testing.ClientSupervisor do
  require Logger
  use DynamicSupervisor

  def start_link(args) do
    DynamicSupervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(num_clients) do
    Logger.debug("Starting ClientSupervisor with #{num_clients}")

    Enum.each(1..num_clients, fn i ->
      child_spec = {Testing.Client, i}
      DynamicSupervisor.start_child(__MODULE__, child_spec)
    end)

    # Use the default DynamicSupervisor init
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

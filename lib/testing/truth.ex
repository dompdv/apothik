defmodule Testing.Truth do
  use GenServer
  require Logger

  @table_size 100_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def init(:ok) do
    Logger.debug(">>> Fill Truth table: start")
    :ets.new(:truth_table, [:named_table, :set, :protected])

    Enum.each(0..(@table_size - 1), fn i ->
      :ets.insert(:truth_table, {i, UUID.uuid4()})
    end)

    Logger.debug(">>> Fill Truth table: end")

    {:ok, nil}
  end

  def get(key) do
    case :ets.lookup(:truth_table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :not_found
    end
  end

  def put(key, value) do
    GenServer.cast(__MODULE__, {:put, key, value})
  end

  def handle_cast({:put, key, value}, _) do
    :ets.insert(:truth_table, {key, value})
    {:noreply, nil}
  end
end

defmodule Testing.Truth do
  use GenServer
  require Logger

  @table_size 100_000

  def start_link(_) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def table_size(), do: @table_size

  def random_sample() do
    i = :rand.uniform(@table_size) - 1
    {i, get(i)}
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
      [{^key, value}] -> value
      [] -> :not_found
    end
  end

  def put(key, value) do
    GenServer.call(__MODULE__, {:put, key, value})
  end

  def handle_call({:put, key, value}, _, _) do
    :ets.insert(:truth_table, {key, value})
    {:reply, :ok, nil}
  end
end

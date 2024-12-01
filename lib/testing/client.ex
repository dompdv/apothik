defmodule Testing.Client do
  use GenServer
  alias Testing.Truth
  require Logger

  @max_waiting_time 1000
  @puts_over_100_ops 5

  def start_link(n) do
    Logger.debug("Starting client #{n}")
    GenServer.start_link(__MODULE__, n)
  end

  @impl true
  def init(n) do
    Logger.debug("Init client #{n}")
    schedule_next_operation()
    {:ok, %{cliend_id: n}}
  end

  @impl true
  def handle_info(:perform_operation, %{cliend_id: n} = state) do
    Logger.debug("Init client #{n}")
    operation = if :rand.uniform(100) > @puts_over_100_ops, do: :get, else: :put

    case operation do
      :get ->
        {key, value} = Truth.random_sample()
        IO.puts("Get: Key #{key}, Value #{value}")

      :put ->
        {key, value} = Truth.random_sample()
        IO.puts("Put: Key #{key}, Value #{value}")
    end

    schedule_next_operation()
    {:noreply, state}
  end

  defp schedule_next_operation() do
    Process.send_after(self(), :perform_operation, :rand.uniform(@max_waiting_time))
  end
end

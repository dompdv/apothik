defmodule Testing.Client do
  use GenServer
  alias Testing.Truth
  alias Apothik.Cache
  alias Testing.Statistician
  require Logger

  @max_waiting_time 20
  @puts_over_100_ops 5

  def start_link(n) do
    Logger.debug("Starting client #{n}")
    GenServer.start_link(__MODULE__, n)
  end

  @impl true
  def init(n) do
    schedule_next_operation()
    {:ok, %{cliend_id: n}}
  end

  @impl true
  def handle_info(:perform_operation, %{cliend_id: n} = state) do
    operation = if :rand.uniform(100) > @puts_over_100_ops, do: :get, else: :put

    case operation do
      :get ->
        {key, value} = Truth.random_sample()

        case Cache.get(key) do
          ^value ->
            Statistician.report(n, :success)

          nil ->
            Statistician.report(n, :miss)
            Cache.put(key, value)

          _ ->
            Statistician.report(n, :error)
        end

      :put ->
        {key, value} = Truth.random_sample()
        Cache.put(key, value)
    end

    schedule_next_operation()
    {:noreply, state}
  end

  defp schedule_next_operation() do
    Process.send_after(self(), :perform_operation, :rand.uniform(@max_waiting_time))
  end
end

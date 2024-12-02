defmodule Testing.Statistician do
  use GenServer
  @stat_interval 1000

  require Logger

  defstruct nb_miss: 0, nb_success: 0, nb_error: 0

  def start_link(args), do: GenServer.start_link(__MODULE__, args, name: __MODULE__)

  def raz(), do: %__MODULE__{}

  def report(reporter, event), do: GenServer.cast(__MODULE__, {:report, reporter, event})

  def stop(), do: GenServer.stop(__MODULE__, :normal)
  @impl true
  def init(_args) do
    schedule_next_stat()
    {:ok, raz()}
  end

  def noreply(x), do: {:noreply, x}

  @impl true
  def handle_cast({:report, _reporter, event}, state) do
    case event do
      :error -> %{state | nb_error: state.nb_error + 1}
      :miss -> %{state | nb_miss: state.nb_miss + 1}
      :success -> %{state | nb_success: state.nb_success + 1}
    end
    |> noreply()
  end

  @impl true
  def handle_info(:perform_stat, state) do
    %__MODULE__{nb_miss: nb_miss, nb_success: nb_success, nb_error: nb_error} = state

    Logger.info("Nb miss = #{nb_miss}, Nb success = #{nb_success}, Nb error = #{nb_error}")
    schedule_next_stat()
    {:noreply, raz()}
  end

  defp schedule_next_stat() do
    Process.send_after(self(), :perform_stat, @stat_interval)
  end
end

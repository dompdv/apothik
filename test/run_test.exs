defmodule ApothikTest.Run do
  use ExUnit.Case, async: false
  alias Apothik.Cluster
  alias Testing.Master
  alias Testing.Truth
  alias Testing.ClientSupervisor
  alias Testing.Statistician

  setup_all do
    Master.start_cluster()
    Statistician.start_link(nil)
    {:ok, _} = Truth.start_link(nil)
    {:ok, supervisor} = ClientSupervisor.start_link(20)

    on_exit(fn ->
      Statistician.stop()
      Master.stop_cluster()
    end)

    %{nb_nodes: Cluster.static_nb_nodes(), sup: supervisor}
  end

  test "Launch", %{nb_nodes: _nb_nodes} do
    Process.sleep(10_000)
    assert true
  end
end

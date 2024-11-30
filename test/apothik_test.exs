defmodule ApothikTest do
  use ExUnit.Case
  alias Testing.Master
  alias Apothik.Cluster

  setup_all do
    nb_nodes = Cluster.static_nb_nodes()
    on_exit(fn -> Enum.each(0..(nb_nodes - 1), fn i -> Master.kill_node(i) end) end)
    %{nb_bnodes: nb_nodes}
  end

  test "Start and kill", %{nb_bnodes: nb_nodes} do
    IO.inspect("start test")

    assert Master.master_state() == %Testing.Master{
             nodes: Enum.to_list(0..(nb_nodes - 1)),
             started: []
           }

    assert Node.list() == []
    Master.start_node(1)
    Process.sleep(1000)
    stats = Master.cluster_stats()
    assert stats.started == [1]
    assert Node.list() == [:"apothik_1@127.0.0.1"]
    Master.kill_node(1)
    Process.sleep(2000)
    assert Node.list() == []
    IO.inspect("end test")
  end
end

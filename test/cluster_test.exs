defmodule ApothikTest.Cluster do
  use ExUnit.Case, async: false
  alias Testing.Master
  alias Apothik.Cluster

  setup_all do
    on_exit(&Master.stop_cluster/0)
    %{nb_bnodes: Cluster.static_nb_nodes()}
  end

  test "Start and kill", %{nb_bnodes: nb_nodes} do
    assert Master.master_state() == %Testing.Master{
             nodes: Enum.to_list(0..(nb_nodes - 1)),
             started: []
           }

    assert Node.list() == []
    Master.start_node(1)
    stats = Master.cluster_stats()
    assert stats.started == [1]
    assert Node.list() == [:"apothik_1@127.0.0.1"]
    Master.kill_node(1)
    assert Node.list() == []
  end

  test "Start a cluster" do
    Master.start_cluster()
    Master.stop_cluster()
  end
end

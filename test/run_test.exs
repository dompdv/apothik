defmodule ApothikTest.Run do
  use ExUnit.Case, async: false
  alias Apothik.Cluster
  alias Testing.Truth
  alias Testing.ClientSupervisor

  setup_all do
    {:ok, _} = Truth.start_link(nil)
    {:ok, supervisor} = ClientSupervisor.start_link(5)
    %{nb_nodes: Cluster.static_nb_nodes(), sup: supervisor}
  end

  test "Launch" do
    assert true
  end
end

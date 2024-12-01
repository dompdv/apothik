defmodule ApothikTest.Truth do
  use ExUnit.Case, async: false
  alias Apothik.Cluster
  alias Testing.Truth

  setup_all do
    {:ok, _} = Truth.start_link(nil)
    %{nb_bnodes: Cluster.static_nb_nodes()}
  end

  test "Filled ?" do
    for(i <- 0..1000, do: {i, Truth.get(i)})
    |> Enum.each(fn {i, v1} ->
      [{_, v2}] = :ets.lookup(:truth_table, i)
      assert v1 == v2
    end)
  end

  test "Get and put" do
    Truth.put(:key1, true)
    assert Truth.get(:key1) == true

    Truth.put(:key2, false)
    assert Truth.get(:key2) == false
  end
end

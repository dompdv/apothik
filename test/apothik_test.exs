defmodule ApothikTest do
  use ExUnit.Case
  doctest Apothik

  test "greets the world" do
    assert Apothik.hello() == :world
  end
end

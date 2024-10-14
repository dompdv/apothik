defmodule Master do
  def stat(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :stats, [])
  end
  def get(i, k) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :get, [k])
  end
  def put(i, k, v) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :put, [k, v])
  end
  def delete(i, k) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :delete, [k])
  end
  def fill(i, n) do
    Enum.each(1..n, fn j -> put(i, "k_#{i}_#{j}", j) end)
  end

  def stat() do
    Enum.map(1..5, fn i -> {i,stat(i)} end)
  end
end

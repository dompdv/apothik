defmodule Master do
  @nb_nodes 5
  def inside(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", :sys, :get_state, [Apothik.Cache])
  end

  def stat(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.CrdtSupervisor, :stats, [])
  end
  def sum_stat() do
    {sum(), stat()}
  end

  def get_tokens(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cache, :get_tokens, [])
  end
  def check_tokens(i) do
    tk = get_tokens(i)
     (for [_n,t]<-tk, do: t) |> List.flatten() |> Enum.uniq() |> length
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
    Enum.map(0..(@nb_nodes-1), fn i -> {i,stat(i)} end)
  end
  def sum() do
    (for {_,s} <- stat(), is_integer(s), do: s) |> Enum.sum()
  end

  def kill(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", System, :stop, [0])
  end
  def cluster(i) do
    :rpc.call(:"apothik_#{i}@127.0.0.1", Apothik.Cluster, :get_state, [])
  end
end

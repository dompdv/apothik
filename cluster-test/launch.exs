 {:ok, p} = Task.start(fn -> System.shell("elixir --name apothik_1@127.0.0.1 -S mix run  --no-halt") end)

 Process.alive?(p) |> IO.inspect()

defmodule Testing.Fixtures do
  alias Testing.Master
  alias Apothik.Cluster
  require Logger

  def start_cluster() do
    Logger.debug("Starting cluster")
    nb_nodes = Cluster.static_nb_nodes()
    Enum.each(0..(nb_nodes - 1), fn i -> Master.start_node(i) end)
  end

  def stop_cluster() do
    Logger.debug("Stopping cluster")
    nb_nodes = Cluster.static_nb_nodes()
    Enum.each(0..(nb_nodes - 1), fn i -> Master.kill_node(i) end)
  end
end

defmodule LassoWeb.ClusterHealthHTTPIntegrationTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint LassoWeb.Endpoint
  @moduletag :integration

  setup do
    previous_expected = Application.get_env(:lasso, :expected_cluster_nodes)

    on_exit(fn ->
      if is_nil(previous_expected) do
        Application.delete_env(:lasso, :expected_cluster_nodes)
      else
        Application.put_env(:lasso, :expected_cluster_nodes, previous_expected)
      end
    end)

    :ok
  end

  test "health reports missing configured peers without failing local liveness" do
    # Distributed fixtures can leave responding peers connected between cases.
    expected_nodes = 4 * Lasso.Cluster.Topology.get_coverage().connected
    Application.put_env(:lasso, :expected_cluster_nodes, expected_nodes)
    topology = Process.whereis(Lasso.Cluster.Topology)
    send(topology, :tick)
    :sys.get_state(topology)

    response = build_conn() |> get("/api/health") |> json_response(200)

    assert response["status"] == "healthy"
    assert response["cluster"]["nodes_configured"] == expected_nodes
    assert response["cluster"]["nodes_total"] == expected_nodes
    assert response["cluster"]["nodes_connected"] < expected_nodes
    assert response["cluster"]["status"] == "critical"
  end

  test "health uses the last local snapshot while topology is suspended" do
    topology = Process.whereis(Lasso.Cluster.Topology)
    send(topology, :tick)
    :sys.get_state(topology)
    :ok = :sys.suspend(topology)

    task = Task.async(fn -> build_conn() |> get("/api/health") |> json_response(200) end)

    try do
      assert {:ok, response} = Task.yield(task, 250)
      assert response["status"] == "healthy"
      assert is_integer(response["cluster"]["snapshot_age_ms"])
    after
      :sys.resume(topology)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "missing topology remains visible as unavailable for configured clusters" do
    Application.put_env(:lasso, :expected_cluster_nodes, 4)
    :ok = Supervisor.terminate_child(Lasso.Supervisor, Lasso.Cluster.Topology)

    try do
      response = build_conn() |> get("/api/health") |> json_response(200)

      assert response["status"] == "healthy"
      assert response["cluster"]["enabled"]
      assert response["cluster"]["status"] == "unavailable"
      assert response["cluster"]["nodes_total"] == 4
      assert is_nil(response["cluster"]["snapshot_age_ms"])
    after
      {:ok, _} = Supervisor.restart_child(Lasso.Supervisor, Lasso.Cluster.Topology)
    end
  end
end

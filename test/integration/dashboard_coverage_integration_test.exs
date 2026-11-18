defmodule LassoWeb.DashboardCoverageIntegrationTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Lasso.Cluster.Topology
  alias LassoWeb.Dashboard.{EventStream, MetricsStore, TrafficCounters}

  @endpoint LassoWeb.Endpoint
  @moduletag :integration

  setup do
    previous = Application.get_env(:lasso, :expected_cluster_nodes)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:lasso, :expected_cluster_nodes),
        else: Application.put_env(:lasso, :expected_cluster_nodes, previous)

      refresh_topology()
    end)

    :ok
  end

  test "missing configured nodes stay in metrics totals and live dashboard coverage" do
    assert Topology.get_coverage().connected == 1
    Application.put_env(:lasso, :expected_cluster_nodes, 3)

    {_data, coverage} =
      MetricsStore.fetch_from_cluster(
        Lasso.Benchmarking.BenchmarkStore,
        :get_provider_leaderboard,
        [
          "public",
          1
        ]
      )

    assert %{responding: 1, total: 3} = coverage

    assert %{coverage: %{responding: 1, total: 3}} =
             TrafficCounters.cluster_windows("public", [:profile])

    :ok = EventStream.subscribe("public")
    refresh_topology()
    assert_receive {:dashboard_snapshot, _snapshot}, 1_000
    assert_receive {:dashboard_batch, %{cluster: %{responding: 1, expected: 3}}}, 1_000

    {:ok, view, _html} = live(build_conn(), "/dashboard/public")
    assert has_element?(view, "div.fixed", "1/3 cluster nodes reporting")

    Application.put_env(:lasso, :expected_cluster_nodes, 4)
    refresh_topology()
    assert_receive {:dashboard_batch, %{cluster: %{responding: 1, expected: 4}}}, 1_000
    assert has_element?(view, "div.fixed", "1/4 cluster nodes reporting")
  end

  test "without configured expectations the total remains connected nodes" do
    Application.delete_env(:lasso, :expected_cluster_nodes)
    connected = Topology.get_coverage().connected

    {_data, coverage} =
      MetricsStore.fetch_from_cluster(
        Lasso.Benchmarking.BenchmarkStore,
        :get_provider_leaderboard,
        [
          "public",
          1
        ]
      )

    assert coverage.total == connected
    assert TrafficCounters.cluster_windows("public", [:profile]).coverage.total == connected
  end

  defp refresh_topology do
    # Publish a topology notification using the real single-node coverage.
    # This exercises live updates without manufacturing distributed peers.
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "cluster:topology",
      {:topology_event,
       %{
         event: :health_update,
         coverage: Topology.get_coverage(),
         node_ids: Topology.get_node_ids()
       }}
    )
  end
end

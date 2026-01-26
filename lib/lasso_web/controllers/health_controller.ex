defmodule LassoWeb.HealthController do
  use LassoWeb, :controller

  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    # Calculate uptime in seconds since application start
    uptime_ms =
      System.monotonic_time(:millisecond) -
        Application.get_env(:lasso, :start_time, System.monotonic_time(:millisecond))

    uptime_seconds = div(uptime_ms, 1000)

    # Get cluster state from Topology
    topology = get_topology_info()

    health_status = %{
      status: "healthy",
      timestamp: DateTime.utc_now(),
      uptime_seconds: uptime_seconds,
      version: Application.spec(:lasso, :vsn) |> to_string(),
      cluster: %{
        enabled: topology.enabled,
        nodes_connected: topology.coverage.connected,
        nodes_responding: topology.coverage.responding,
        nodes_total: topology.coverage.expected,
        regions: topology.regions,
        status: determine_cluster_status(topology)
      }
    }

    json(conn, health_status)
  end

  defp get_topology_info do
    try do
      topology = Lasso.Cluster.Topology.get_topology()

      %{
        enabled: true,
        coverage: topology.coverage,
        regions: topology.regions
      }
    catch
      :exit, _ ->
        %{enabled: false, coverage: %{connected: 1, responding: 1, expected: 1}, regions: []}
    end
  end

  defp determine_cluster_status(topology) do
    cond do
      not topology.enabled ->
        "standalone"

      topology.coverage.responding >= topology.coverage.connected ->
        "healthy"

      topology.coverage.responding >= div(topology.coverage.connected, 2) ->
        "degraded"

      true ->
        "critical"
    end
  end
end

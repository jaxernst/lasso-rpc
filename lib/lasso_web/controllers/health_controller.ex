defmodule LassoWeb.HealthController do
  use LassoWeb, :controller

  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    # Calculate uptime in seconds since application start
    uptime_ms =
      System.monotonic_time(:millisecond) -
        Application.get_env(:lasso, :start_time, System.monotonic_time(:millisecond))

    uptime_seconds = div(uptime_ms, 1000)

    # Get cluster state
    cluster_info = Lasso.ClusterMonitor.get_cluster_info()

    health_status = %{
      status: "healthy",
      timestamp: DateTime.utc_now(),
      uptime_seconds: uptime_seconds,
      version: Application.spec(:lasso, :vsn) |> to_string(),
      cluster: %{
        enabled: cluster_info.enabled,
        nodes_connected: cluster_info.nodes_connected,
        nodes_total: cluster_info.nodes_total,
        regions: cluster_info.regions,
        status: determine_cluster_status(cluster_info)
      }
    }

    json(conn, health_status)
  end

  defp determine_cluster_status(info) do
    cond do
      not info.enabled ->
        "standalone"

      info.nodes_connected + 1 >= info.nodes_total ->
        "healthy"

      info.nodes_connected + 1 >= div(info.nodes_total, 2) ->
        "degraded"

      true ->
        "critical"
    end
  end
end

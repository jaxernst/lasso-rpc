defmodule LassoWeb.HealthController do
  @moduledoc """
  Health check endpoint for load balancers and monitoring.

  Returns cluster topology status, node counts, regions, and overall service health.
  """

  use LassoWeb, :controller

  alias Lasso.Cluster.HealthTopology

  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    uptime_ms =
      System.monotonic_time(:millisecond) -
        Application.get_env(:lasso, :start_time, System.monotonic_time(:millisecond))

    uptime_seconds = div(uptime_ms, 1000)
    topology = HealthTopology.get()

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
        status: HealthTopology.cluster_status(topology)
      }
    }

    json(conn, health_status)
  end
end

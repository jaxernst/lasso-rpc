defmodule LassoWeb.HealthController do
  use LassoWeb, :controller

  def health(conn, _params) do
    # Check basic health indicators
    health_status = %{
      status: "healthy",
      timestamp: DateTime.utc_now(),
      uptime: System.monotonic_time(:second),
      version: Application.spec(:lasso, :vsn) |> to_string()
    }

    json(conn, health_status)
  end
end

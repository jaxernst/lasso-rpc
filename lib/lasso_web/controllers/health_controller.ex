defmodule LassoWeb.HealthController do
  use LassoWeb, :controller

  @spec health(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def health(conn, _params) do
    # Calculate uptime in seconds since application start
    uptime_ms =
      System.monotonic_time(:millisecond) -
        Application.get_env(:lasso, :start_time, System.monotonic_time(:millisecond))

    uptime_seconds = div(uptime_ms, 1000)

    health_status = %{
      status: "healthy",
      timestamp: DateTime.utc_now(),
      uptime_seconds: uptime_seconds,
      version: Application.spec(:lasso, :vsn) |> to_string()
    }

    json(conn, health_status)
  end
end

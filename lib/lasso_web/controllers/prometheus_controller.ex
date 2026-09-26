defmodule LassoWeb.PrometheusController do
  @moduledoc "Node-local Prometheus scrape, protected by the deployment proxy."

  use LassoWeb, :controller

  alias Lasso.Observability.Prometheus

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/plain", "utf-8")
    |> send_resp(:ok, Prometheus.scrape())
  end
end

defmodule LassoWeb.PageController do
  use LassoWeb, :controller

  @spec redirect_to_dashboard(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def redirect_to_dashboard(conn, _params) do
    redirect(conn, to: ~p"/dashboard")
  end
end

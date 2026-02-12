defmodule LassoWeb.PageController do
  use LassoWeb, :controller

  def redirect_to_dashboard(conn, _params) do
    redirect(conn, to: ~p"/dashboard")
  end
end

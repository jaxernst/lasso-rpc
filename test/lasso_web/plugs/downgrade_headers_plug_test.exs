defmodule LassoWeb.Plugs.DowngradeHeadersPlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias LassoWeb.Plugs.DowngradeHeadersPlug

  test "adds effective strategy header when strategy is normalized" do
    conn =
      conn(:post, "/rpc/public/ethereum")
      |> assign(:requested_provider_strategy, :fastest)
      |> assign(:provider_strategy, :load_balanced)
      |> assign(:downgraded, false)
      |> assign(:profile_slug, "public")
      |> DowngradeHeadersPlug.call([])
      |> send_resp(200, "ok")

    assert get_resp_header(conn, "x-lasso-profile") == ["public"]
    assert get_resp_header(conn, "x-lasso-effective-strategy") == ["load_balanced"]
  end

  test "adds downgrade headers when downgraded" do
    conn =
      conn(:post, "/rpc/public/ethereum")
      |> assign(:downgraded, true)
      |> assign(:profile_slug, "public")
      |> DowngradeHeadersPlug.call([])
      |> send_resp(200, "ok")

    assert get_resp_header(conn, "x-lasso-downgraded") == ["true"]
    assert get_resp_header(conn, "x-lasso-profile") == ["public"]
    assert get_resp_header(conn, "x-lasso-balance-warning") == ["true"]
  end
end

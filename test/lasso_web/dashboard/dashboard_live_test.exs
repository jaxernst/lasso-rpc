defmodule LassoWeb.DashboardLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint LassoWeb.Endpoint

  test "keeps the LiveView alive when block events use chain_id" do
    {:ok, view, _html} = live(build_conn(), "/dashboard/public?tab=overview")

    assert has_element?(view, "details#profile-selector:not([open])")
    assert has_element?(view, "summary#profile-selector-trigger")
    assert has_element?(view, "#profile-dropdown")

    batch = %{
      health: %{},
      circuit_states: %{},
      block_states: %{},
      cluster: nil,
      metrics: nil,
      node_ids: [],
      heartbeat: false,
      routing_events: [],
      circuit_events: [],
      provider_events: [],
      subscription_events: [],
      block_events: [
        %{
          chain_id: 42_161,
          block_number: 491_521_999,
          provider_first: "arbitrum_publicnode",
          margin_ms: nil
        }
      ],
      sync_updates: [],
      block_cache_updates: []
    }

    send(view.pid, {:dashboard_batch, batch})

    render(view)

    state = :sys.get_state(view.pid)

    assert [%{chain: 42_161, block_number: 491_521_999} | _] =
             state.socket.assigns.latest_blocks

    assert Process.alive?(view.pid)
  end

  test "serves the logo referenced by the public profile" do
    conn = get(build_conn(), "/images/lasso-logo.png")

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/png"]
  end
end

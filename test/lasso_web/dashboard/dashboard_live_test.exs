defmodule LassoWeb.DashboardLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint LassoWeb.Endpoint

  test "keeps the LiveView alive when block events use chain_id" do
    {:ok, view, _html} = live(build_conn(), "/dashboard/public?tab=overview")

    assert has_element?(view, "details#profile-selector")
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

  test "accepts live block state and removes it after a stale tombstone" do
    {:ok, view, _html} = live(build_conn(), "/dashboard/public?tab=overview")
    key = {"height-provider", "sjc-node"}

    send(
      view.pid,
      {:dashboard_batch,
       dashboard_batch(%{
         key => %{
           provider_id: "height-provider",
           node_id: "sjc-node",
           height: 25_000_000,
           lag: 0,
           stale?: nil
         }
       })}
    )

    _html = render(view)

    assert :sys.get_state(view.pid).socket.assigns.cluster_block_heights[key] == %{
             height: 25_000_000,
             lag: 0
           }

    send(
      view.pid,
      {:dashboard_batch,
       dashboard_batch(%{
         key => %{
           provider_id: "height-provider",
           node_id: "sjc-node",
           height: nil,
           lag: nil,
           stale?: true
         }
       })}
    )

    _html = render(view)
    refute Map.has_key?(:sys.get_state(view.pid).socket.assigns.cluster_block_heights, key)
    assert Process.alive?(view.pid)
  end

  defp dashboard_batch(block_states) do
    %{
      health: %{},
      circuit_states: %{},
      block_states: block_states,
      cluster: nil,
      metrics: nil,
      node_ids: [],
      heartbeat: false,
      routing_events: [],
      circuit_events: [],
      provider_events: [],
      subscription_events: [],
      block_events: [],
      sync_updates: [],
      block_cache_updates: []
    }
  end
end

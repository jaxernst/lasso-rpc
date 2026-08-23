defmodule LassoWeb.Dashboard.ProviderDetailsPanelTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias Lasso.Core.BlockSync.BlockTimeMeasurement
  alias LassoWeb.Dashboard.Components.ProviderDetailsPanel

  setup do
    TestHelper.ensure_test_environment_ready()

    chain_id = 9_700_000 + rem(System.unique_integer([:positive]), 100_000)
    instance_id = "#{chain_id}:http:instance"
    Lasso.BlockSync.Registry.clear_chain(chain_id)

    on_exit(fn -> Lasso.BlockSync.Registry.clear_chain(chain_id) end)

    {:ok, chain_id: chain_id, instance_id: instance_id}
  end

  test "uses the instance identity to display a consistent estimated height", %{
    chain_id: chain_id,
    instance_id: instance_id
  } do
    now = System.system_time(:millisecond)

    :ets.insert(:block_sync_registry, [
      {{:height, chain_id, instance_id}, {990, now - 5_500, :http, %{latency_ms: 10}}},
      {{:height, chain_id, "#{chain_id}:ws:peer"}, {1_000, now, :ws, %{}}},
      {{:block_time, chain_id},
       %BlockTimeMeasurement{
         ema_ms: 1_000.0,
         sample_count: 5,
         last_height: 1_000,
         last_mono_ms: System.monotonic_time(:millisecond)
       }}
    ])

    html =
      draw(
        chain_id,
        instance_id,
        chain_consensus_height: 1_000,
        cluster_block_heights: %{{"p1", "iad-node"} => %{height: 990, lag: -3}}
      )

    assert html =~ "Estimated Height:"
    assert html =~ "995"
    assert html =~ "-5"
    refute html =~ ">990<"
  end

  test "recomputes raw lag against the displayed consensus", %{chain_id: chain_id} do
    html =
      draw(
        chain_id,
        "#{chain_id}:missing:instance",
        chain_consensus_height: 1_000,
        cluster_block_heights: %{{"p1", "iad-node"} => %{height: 990, lag: -3}}
      )

    assert html =~ "Block Height:"
    assert html =~ "990"
    assert html =~ "-10"
    refute html =~ ">-3<"
  end

  defp draw(chain_id, instance_id, opts) do
    connection = %{
      id: "p1",
      name: "Provider",
      url: "https://example.test",
      ws_url: nil,
      chain: "test-chain",
      chain_id: chain_id,
      instance_id: instance_id,
      block_height: 990,
      consensus_height: 1_000,
      blocks_behind: 10
    }

    base = %{
      id: "provider-details-p1",
      provider_id: "p1",
      connections: [connection],
      selected_profile: "public",
      selected_provider_unified_events: [],
      selected_provider_metrics: %{},
      live_provider_metrics: %{},
      cluster_circuit_states: %{},
      cluster_health_counters: %{},
      cluster_block_heights: %{},
      chain_consensus_height: nil,
      available_node_ids: []
    }

    render_component(ProviderDetailsPanel, Map.merge(base, Map.new(opts)))
  end
end

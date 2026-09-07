defmodule LassoWeb.Dashboard.MetricsHelpersTest do
  use ExUnit.Case, async: true

  alias LassoWeb.Dashboard.MetricsHelpers

  test "subscription lifecycle events do not count as RPC requests" do
    events = [%{type: :ws_lifecycle, ts_ms: System.system_time(:millisecond), chain: 1}]
    assert MetricsHelpers.routing_sample_count(events) == 0
    assert MetricsHelpers.rpc_calls_per_second(events) == 0.0
    assert MetricsHelpers.success_rate_percent(events) == nil

    metrics =
      MetricsHelpers.get_chain_performance_metrics(
        %{selected_profile: "public", routing_events: events, connections: []},
        1
      )

    assert metrics.total_calls == 0
    assert metrics.decision_share == []
  end

  test "headline routing metrics exclude system-owned maintenance traffic" do
    now = System.system_time(:millisecond)

    events = [
      %{ts_ms: now, result: :success, duration_ms: 10, failovers: 0, request_origin: :client},
      %{ts_ms: now, result: :error, duration_ms: 30, failovers: 1, request_origin: :client},
      %{ts_ms: now, result: :error, duration_ms: 5_000, failovers: 8, request_origin: :system},
      %{ts_ms: now, result: :error, duration_ms: 5_000, failovers: 8, request_origin: "system"}
    ]

    assert MetricsHelpers.success_rate_percent(events) == 50.0
    assert MetricsHelpers.error_rate_percent(events) == 50.0
    assert MetricsHelpers.failovers_last_minute(events) == 1
    assert MetricsHelpers.avg_latency_ms(events) == 20
    assert MetricsHelpers.rpc_calls_per_second(events) == 2.0
    assert MetricsHelpers.routing_sample_count(events) == 2
  end

  test "events without an origin retain the legacy client interpretation" do
    now = System.system_time(:millisecond)
    assert MetricsHelpers.success_rate_percent([%{ts_ms: now, result: :success}]) == 100.0
  end

  test "routing sample count uses the same client-only one-minute window as success rate" do
    now = System.system_time(:millisecond)

    events = [
      %{ts_ms: now, result: :success, request_origin: :client},
      %{ts_ms: now, result: :error, request_origin: :client},
      %{ts_ms: now, result: :error, request_origin: :system},
      %{ts_ms: now - 60_001, result: :success, request_origin: :client}
    ]

    assert MetricsHelpers.routing_sample_count(events) == 2
    assert MetricsHelpers.success_rate_percent(events) == 50.0
  end

  describe "rpc_calls_per_second/1" do
    test "returns 0 with no events" do
      assert MetricsHelpers.rpc_calls_per_second([]) == 0.0
    end

    test "reports the burst rate instead of averaging it over idle history" do
      now = System.system_time(:millisecond)

      idle_history =
        for i <- 1..20, do: %{ts_ms: now - 55_000 + i * 100, request_origin: :client}

      burst = for i <- 1..60, do: %{ts_ms: now - 3_000 + i * 50, request_origin: :client}

      assert MetricsHelpers.rpc_calls_per_second(burst ++ idle_history) >= 10.0
    end

    test "falls back to a wider window when traffic is sparse" do
      now = System.system_time(:millisecond)
      events = for i <- 1..3, do: %{ts_ms: now - 40_000 + i * 1_000, request_origin: :client}

      rps = MetricsHelpers.rpc_calls_per_second(events)
      assert rps > 0.0
      assert rps < 1.0
    end

    test "ignores events older than the widest window" do
      now = System.system_time(:millisecond)
      events = for i <- 1..50, do: %{ts_ms: now - 120_000 - i * 100, request_origin: :client}

      assert MetricsHelpers.rpc_calls_per_second(events) == 0.0
    end
  end

  describe "weighted_field/2" do
    test "returns nil for empty input" do
      assert MetricsHelpers.weighted_field([], & &1.avg_duration_ms) == nil
    end

    test "returns nil when no entry has positive total_calls" do
      stats = [%{avg_duration_ms: 100, total_calls: 0}]
      assert MetricsHelpers.weighted_field(stats, & &1.avg_duration_ms) == nil
    end

    test "weighted average favours high-traffic methods" do
      stats = [
        %{avg_duration_ms: 100.0, total_calls: 1},
        %{avg_duration_ms: 1.0, total_calls: 99}
      ]

      result = MetricsHelpers.weighted_field(stats, & &1.avg_duration_ms)
      # (100 + 99) / 100 = 1.99
      assert_in_delta result, 1.99, 0.001
    end

    test "skips entries with nil values" do
      stats = [
        %{avg_duration_ms: nil, total_calls: 100},
        %{avg_duration_ms: 50.0, total_calls: 10}
      ]

      assert MetricsHelpers.weighted_field(stats, & &1.avg_duration_ms) == 50.0
    end
  end

  describe "build_provider_metrics_from_bulk/4" do
    test "drops the synthetic 'no_channel' provider id" do
      result =
        MetricsHelpers.build_provider_metrics_from_bulk(
          ["no_channel", "real_provider"],
          [%{id: "real_provider", name: "Real"}],
          [],
          [
            %{
              provider_id: "real_provider",
              method: "eth_blockNumber",
              avg_duration_ms: 50.0,
              percentiles: %{p50: 40, p95: 70, p99: 100},
              success_rate: 0.99,
              total_calls: 100
            }
          ]
        )

      ids = Enum.map(result, & &1.id)
      assert "no_channel" not in ids
      assert "real_provider" in ids
    end

    test "drops providers with zero total_calls" do
      result =
        MetricsHelpers.build_provider_metrics_from_bulk(
          ["a", "b"],
          [%{id: "a", name: "A"}, %{id: "b", name: "B"}],
          [],
          [
            %{
              provider_id: "a",
              method: "x",
              avg_duration_ms: 50.0,
              percentiles: %{p50: 40, p95: 70, p99: 100},
              success_rate: 0.9,
              total_calls: 10
            }
          ]
        )

      assert Enum.map(result, & &1.id) == ["a"]
    end

    test "sorts unhealthy (success<50%) below healthy" do
      stats = fn id, success_rate, latency ->
        %{
          provider_id: id,
          method: "x",
          avg_duration_ms: latency,
          percentiles: %{p50: latency, p95: latency * 2, p99: latency * 3},
          success_rate: success_rate,
          total_calls: 100
        }
      end

      result =
        MetricsHelpers.build_provider_metrics_from_bulk(
          ["unhealthy_fast", "healthy_slow"],
          [
            %{id: "unhealthy_fast", name: "U"},
            %{id: "healthy_slow", name: "H"}
          ],
          [],
          [stats.("unhealthy_fast", 0.1, 1.0), stats.("healthy_slow", 0.99, 999.0)]
        )

      assert Enum.map(result, & &1.id) == ["healthy_slow", "unhealthy_fast"]
    end
  end

  describe "build_method_metrics_from_bulk/2" do
    test "groups by method and sorts by total_calls desc" do
      bulk = [
        %{
          provider_id: "p1",
          method: "rare",
          avg_duration_ms: 10.0,
          percentiles: %{p50: 10, p95: 15, p99: 20},
          success_rate: 1.0,
          total_calls: 5
        },
        %{
          provider_id: "p1",
          method: "popular",
          avg_duration_ms: 20.0,
          percentiles: %{p50: 20, p95: 30, p99: 40},
          success_rate: 1.0,
          total_calls: 1000
        }
      ]

      result =
        MetricsHelpers.build_method_metrics_from_bulk(
          [%{id: "p1", name: "P1"}],
          bulk
        )

      assert Enum.map(result, & &1.method) == ["popular", "rare"]
      assert Enum.find(result, &(&1.method == "popular")).total_calls == 1000
    end

    test "drops 'no_channel' synthetic entries" do
      bulk = [
        %{
          provider_id: "no_channel",
          method: "fake",
          avg_duration_ms: 0.0,
          percentiles: %{p50: 0, p95: 0, p99: 0},
          success_rate: 1.0,
          total_calls: 1
        }
      ]

      assert MetricsHelpers.build_method_metrics_from_bulk([], bulk) == []
    end
  end
end

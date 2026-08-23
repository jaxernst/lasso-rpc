defmodule LassoWeb.Dashboard.MetricsHelpersTest do
  use ExUnit.Case, async: true

  alias LassoWeb.Dashboard.MetricsHelpers

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
end

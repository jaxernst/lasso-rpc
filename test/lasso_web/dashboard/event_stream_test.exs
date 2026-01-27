defmodule LassoWeb.Dashboard.EventStreamTest do
  use ExUnit.Case, async: false

  alias Lasso.Events.RoutingDecision

  @max_batch_size 100
  @seen_request_id_ttl_ms 120_000
  @max_seen_request_ids 50_000

  setup do
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  describe "request ID deduplication" do
    test "duplicate request IDs are filtered out" do
      seen = %{}
      now = System.monotonic_time(:millisecond)

      # First event should be accepted
      {seen1, accepted1} = check_and_record_request("req-1", seen, now)
      assert accepted1 == true
      assert Map.has_key?(seen1, "req-1")

      # Duplicate should be rejected
      {_seen2, accepted2} = check_and_record_request("req-1", seen1, now + 100)
      assert accepted2 == false

      # Different request ID should be accepted
      {seen3, accepted3} = check_and_record_request("req-2", seen1, now + 100)
      assert accepted3 == true
      assert Map.has_key?(seen3, "req-2")
    end

    test "stale request IDs are cleaned up after TTL" do
      now = System.monotonic_time(:millisecond)
      old_ts = now - @seen_request_id_ttl_ms - 1000

      seen = %{
        "old-req" => old_ts,
        "recent-req" => now - 1000
      }

      cleaned = cleanup_seen_request_ids(seen, now)

      refute Map.has_key?(cleaned, "old-req")
      assert Map.has_key?(cleaned, "recent-req")
    end

    test "seen IDs are truncated when exceeding max size" do
      now = System.monotonic_time(:millisecond)

      # Create more entries than the max
      seen =
        1..(@max_seen_request_ids + 1000)
        |> Enum.reduce(%{}, fn i, acc ->
          # Older IDs have lower timestamps
          Map.put(acc, "req-#{i}", now - i)
        end)

      truncated = maybe_truncate_seen_ids(seen, now)

      # Should keep only max_seen_request_ids, preferring newer entries
      assert map_size(truncated) == @max_seen_request_ids

      # Oldest entries should be removed
      refute Map.has_key?(truncated, "req-#{@max_seen_request_ids + 500}")
      # Newest entries should be kept
      assert Map.has_key?(truncated, "req-1")
    end
  end

  describe "batch processing" do
    test "events are batched and flushed at max size" do
      # Simulate accumulating events
      pending = []
      count = 0

      # Add events up to max batch size
      {pending, count, should_flush} =
        Enum.reduce(1..@max_batch_size, {pending, count, false}, fn i, {p, c, _} ->
          event = %RoutingDecision{
            request_id: "req-#{i}",
            provider_id: "provider-1",
            chain: "ethereum",
            method: "eth_blockNumber",
            result: :success,
            duration_ms: 100,
            ts: System.system_time(:millisecond),
            source_region: "us-east"
          }

          new_pending = [event | p]
          new_count = c + 1
          flush = new_count >= @max_batch_size
          {new_pending, new_count, flush}
        end)

      assert should_flush == true
      assert count == @max_batch_size
      assert length(pending) == @max_batch_size
    end

    test "batch is processed even with fewer events on tick" do
      pending = [
        %{request_id: "req-1", ts: System.system_time(:millisecond)},
        %{request_id: "req-2", ts: System.system_time(:millisecond)}
      ]

      count = 2

      # Simulate tick processing
      {processed, new_pending, new_count} = process_batch_if_needed(pending, count)

      assert processed == true
      assert new_pending == []
      assert new_count == 0
    end

    test "empty batch is not processed" do
      pending = []
      count = 0

      {processed, new_pending, new_count} = process_batch_if_needed(pending, count)

      assert processed == false
      assert new_pending == []
      assert new_count == 0
    end
  end

  describe "stale data cleanup" do
    test "circuit states older than cutoff are removed" do
      now = System.system_time(:millisecond)
      stale_cutoff = now - 300_000

      circuit_states = %{
        {"provider-1", "us-east"} => %{
          http: :closed,
          ws: :closed,
          updated_at: stale_cutoff - 1000
        },
        {"provider-2", "us-east"} => %{http: :open, ws: :closed, updated_at: now - 1000}
      }

      cleaned = cleanup_stale_circuits(circuit_states, stale_cutoff)

      refute Map.has_key?(cleaned, {"provider-1", "us-east"})
      assert Map.has_key?(cleaned, {"provider-2", "us-east"})
    end

    test "health counters for inactive providers are removed" do
      active_provider_regions = MapSet.new([{"provider-1", "us-east"}])

      health_counters = %{
        {"provider-1", "us-east"} => %{consecutive_failures: 0, consecutive_successes: 5},
        {"provider-2", "eu-west"} => %{consecutive_failures: 2, consecutive_successes: 0}
      }

      cleaned = cleanup_inactive_health_counters(health_counters, active_provider_regions)

      assert Map.has_key?(cleaned, {"provider-1", "us-east"})
      refute Map.has_key?(cleaned, {"provider-2", "eu-west"})
    end
  end

  describe "subscriber snapshot" do
    test "snapshot contains all required state for hydration" do
      state = %{
        provider_metrics: %{"provider-1" => %{total_calls: 100}},
        circuit_states: %{{"provider-1", "us-east"} => %{http: :closed}},
        health_counters: %{{"provider-1", "us-east"} => %{consecutive_failures: 0}},
        cluster_state: %{connected: 3, responding: 3, regions: ["us-east"]},
        event_windows: %{
          {"provider-1", "ethereum", "us-east"} => [
            %{request_id: "r1", ts: System.system_time(:millisecond)}
          ]
        }
      }

      snapshot = build_snapshot(state)

      assert Map.has_key?(snapshot, :metrics)
      assert Map.has_key?(snapshot, :circuits)
      assert Map.has_key?(snapshot, :health_counters)
      assert Map.has_key?(snapshot, :cluster)
      assert Map.has_key?(snapshot, :events)

      assert snapshot.metrics == state.provider_metrics
      assert snapshot.circuits == state.circuit_states
      assert snapshot.cluster == state.cluster_state
      assert is_list(snapshot.events)
    end

    test "recent events are sorted by timestamp descending" do
      now = System.system_time(:millisecond)

      event_windows = %{
        {"p1", "eth", "us"} => [
          %{request_id: "old", ts: now - 5000},
          %{request_id: "newest", ts: now}
        ],
        {"p2", "eth", "eu"} => [
          %{request_id: "middle", ts: now - 2000}
        ]
      }

      recent = get_recent_events(event_windows, 100)

      assert length(recent) == 3
      assert List.first(recent).request_id == "newest"
      assert List.last(recent).request_id == "old"
    end
  end

  describe "metrics computation" do
    test "success rate is computed correctly" do
      events = [
        %{result: :success},
        %{result: :success},
        %{result: :success},
        %{result: :error}
      ]

      rate = compute_success_rate(events)

      # 3/4 = 75%
      assert rate == 75.0
    end

    test "empty events return 0% success rate" do
      events = []
      rate = compute_success_rate(events)
      assert rate == 0.0
    end

    test "traffic percentage is computed correctly" do
      provider_calls = 25
      chain_calls = 100

      pct = compute_traffic_pct(provider_calls, chain_calls)

      assert pct == 25.0
    end

    test "traffic percentage handles zero total gracefully" do
      pct = compute_traffic_pct(10, 0)
      assert pct == 0.0
    end

    test "percentile computation returns correct values" do
      events =
        Enum.map([10, 20, 30, 40, 50, 60, 70, 80, 90, 100], fn ms ->
          %{duration_ms: ms}
        end)

      p50 = compute_percentile(events, 50)
      p95 = compute_percentile(events, 95)

      # p50 should be around 50ms (middle value)
      assert p50 == 50
      # p95 should be around 90-100ms
      assert p95 in [90, 100]
    end

    test "percentile of empty events returns nil" do
      assert compute_percentile([], 50) == nil
    end
  end

  # Helper functions that mirror the internal logic

  defp check_and_record_request(request_id, seen, now) do
    if Map.has_key?(seen, request_id) do
      {seen, false}
    else
      {Map.put(seen, request_id, now), true}
    end
  end

  defp cleanup_seen_request_ids(seen, now) do
    cutoff = now - @seen_request_id_ttl_ms

    seen
    |> Enum.reject(fn {_id, ts} -> ts < cutoff end)
    |> Map.new()
  end

  defp maybe_truncate_seen_ids(seen, _now) when map_size(seen) <= @max_seen_request_ids, do: seen

  defp maybe_truncate_seen_ids(seen, _now) do
    seen
    |> Enum.sort_by(fn {_id, ts} -> ts end, :desc)
    |> Enum.take(@max_seen_request_ids)
    |> Map.new()
  end

  defp process_batch_if_needed(pending, count) do
    if count > 0 do
      {true, [], 0}
    else
      {false, pending, count}
    end
  end

  defp cleanup_stale_circuits(circuit_states, cutoff) do
    circuit_states
    |> Enum.reject(fn {_, %{updated_at: ts}} -> ts < cutoff end)
    |> Map.new()
  end

  defp cleanup_inactive_health_counters(health_counters, active_provider_regions) do
    health_counters
    |> Enum.filter(fn {key, _} -> MapSet.member?(active_provider_regions, key) end)
    |> Map.new()
  end

  defp build_snapshot(state) do
    recent_events =
      state.event_windows
      |> get_recent_events(100)

    %{
      metrics: state.provider_metrics,
      circuits: state.circuit_states,
      health_counters: state.health_counters,
      cluster: state.cluster_state,
      events: recent_events
    }
  end

  defp get_recent_events(windows, limit) do
    windows
    |> Enum.flat_map(fn {_key, events} -> events end)
    |> Enum.sort_by(& &1.ts, :desc)
    |> Enum.take(limit)
  end

  defp compute_success_rate([]), do: 0.0

  defp compute_success_rate(events) do
    successes = Enum.count(events, &(&1.result == :success))
    Float.round(successes / length(events) * 100, 1)
  end

  defp compute_traffic_pct(_provider_calls, 0), do: 0.0

  defp compute_traffic_pct(provider_calls, chain_calls) do
    Float.round(provider_calls / chain_calls * 100, 1)
  end

  defp compute_percentile([], _p), do: nil

  defp compute_percentile(events, p) do
    durations = events |> Enum.map(& &1.duration_ms) |> Enum.sort()
    index = max(0, round(length(durations) * p / 100) - 1)
    Enum.at(durations, index)
  end
end

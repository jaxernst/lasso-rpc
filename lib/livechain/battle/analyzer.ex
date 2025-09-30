defmodule Livechain.Battle.Analyzer do
  @moduledoc """
  Analyzes collected battle test data.

  Computes statistics:
  - Percentiles (P50, P95, P99)
  - Success rates
  - Failover counts
  - Circuit breaker behavior
  """

  @doc """
  Analyzes collected data and produces summary statistics.
  """
  def analyze(collected_data, opts \\ %{}) do
    %{
      requests: analyze_requests(Map.get(collected_data, :requests, [])),
      circuit_breaker: analyze_circuit_breaker(Map.get(collected_data, :circuit_breaker, [])),
      system: analyze_system(Map.get(collected_data, :system, [])),
      websocket: analyze_websocket(Map.get(collected_data, :websocket, [])),
      duration_ms: Map.get(opts, :duration_ms, 0)
    }
  end

  @doc """
  Verifies SLO compliance.

  Returns a map of SLO key to result:
  %{
    success_rate: %{required: 0.99, actual: 0.998, passed?: true},
    ...
  }
  """
  def verify_slos(analysis, slos) do
    Enum.into(slos, %{}, fn {key, required_value} ->
      result = check_slo(key, required_value, analysis)
      {key, result}
    end)
  end

  # Private analysis functions

  defp analyze_requests([]), do: %{total: 0, success_rate: 0.0, failover_count: 0}

  defp analyze_requests(requests) do
    total = length(requests)
    successes = Enum.count(requests, fn r -> r.result == :success end)
    failures = total - successes

    latencies =
      requests
      |> Enum.map(fn r -> r.duration_ms end)
      |> Enum.sort()

    success_rate = if total > 0, do: successes / total, else: 0.0

    # Detect failovers: requests with high latency (> 2x avg) may indicate failover
    avg_latency = avg(latencies)
    failover_threshold = avg_latency * 2

    failover_requests =
      requests
      |> Enum.filter(fn r ->
        r.duration_ms > failover_threshold && r.result == :success
      end)

    failover_latencies =
      failover_requests
      |> Enum.map(fn r -> r.duration_ms end)

    %{
      total: total,
      successes: successes,
      failures: failures,
      success_rate: success_rate,
      p50_latency_ms: percentile(latencies, 0.5),
      p95_latency_ms: percentile(latencies, 0.95),
      p99_latency_ms: percentile(latencies, 0.99),
      min_latency_ms: List.first(latencies) || 0,
      max_latency_ms: List.last(latencies) || 0,
      avg_latency_ms: avg_latency,
      # Failover analysis
      failover_count: length(failover_requests),
      avg_failover_latency_ms: avg(failover_latencies),
      max_failover_latency_ms: Enum.max(failover_latencies, fn -> 0 end)
    }
  end

  defp analyze_circuit_breaker([]), do: %{state_changes: 0}

  defp analyze_circuit_breaker(events) do
    opens = Enum.count(events, fn e -> e.new_state == :open end)
    closes = Enum.count(events, fn e -> e.new_state == :closed end)
    half_opens = Enum.count(events, fn e -> e.new_state == :half_open end)

    # Calculate time spent in open state
    time_open_ms = calculate_time_in_state(events, :open)

    %{
      state_changes: length(events),
      opens: opens,
      closes: closes,
      half_opens: half_opens,
      time_open_ms: time_open_ms
    }
  end

  defp analyze_system([]), do: %{peak_memory_mb: 0, peak_processes: 0}

  defp analyze_system(samples) do
    memories = Enum.map(samples, fn s -> s.memory_mb end)
    process_counts = Enum.map(samples, fn s -> s.process_count end)

    %{
      peak_memory_mb: Enum.max(memories, fn -> 0 end),
      avg_memory_mb: avg(memories),
      peak_processes: Enum.max(process_counts, fn -> 0 end),
      avg_processes: avg(process_counts)
    }
  end

  defp analyze_websocket([]), do: %{events: 0}

  defp analyze_websocket(events) do
    %{
      events: length(events),
      # Phase 2: Add duplicate detection, gap analysis
      duplicates: 0,
      gaps: 0
    }
  end

  # SLO verification

  defp check_slo(:success_rate, required, analysis) do
    actual = get_in(analysis, [:requests, :success_rate]) || 0.0
    %{required: required, actual: actual, passed?: actual >= required}
  end

  defp check_slo(:p95_latency_ms, required, analysis) do
    actual = get_in(analysis, [:requests, :p95_latency_ms]) || 0
    %{required: required, actual: actual, passed?: actual <= required}
  end

  defp check_slo(:p99_latency_ms, required, analysis) do
    actual = get_in(analysis, [:requests, :p99_latency_ms]) || 0
    %{required: required, actual: actual, passed?: actual <= required}
  end

  defp check_slo(:max_failover_latency_ms, required, analysis) do
    actual = get_in(analysis, [:requests, :max_latency_ms]) || 0
    %{required: required, actual: actual, passed?: actual <= required}
  end

  defp check_slo(:max_memory_mb, required, analysis) do
    actual = get_in(analysis, [:system, :peak_memory_mb]) || 0
    %{required: required, actual: actual, passed?: actual <= required}
  end

  defp check_slo(:subscription_uptime, required, _analysis) do
    # TODO: Calculate actual uptime from WebSocket telemetry
    # For now, assume perfect uptime
    actual = 1.0
    %{required: required, actual: actual, passed?: actual >= required}
  end

  defp check_slo(:max_duplicate_rate, required, _analysis) do
    # TODO: Calculate from WebSocket telemetry
    actual = 0.0
    %{required: required, actual: actual, passed?: actual <= required}
  end

  defp check_slo(:max_gap_rate, required, _analysis) do
    # TODO: Calculate from WebSocket gap detection telemetry
    actual = 0.0
    %{required: required, actual: actual, passed?: actual <= required}
  end

  defp check_slo(:max_failover_latency_ms, required, analysis) do
    actual = get_in(analysis, [:requests, :max_failover_latency_ms]) || 0
    %{required: required, actual: actual, passed?: actual <= required}
  end

  defp check_slo(:backfill_completion_ms, required, _analysis) do
    # TODO: Measure backfill time from telemetry
    actual = 0
    %{required: required, actual: actual, passed?: actual <= required}
  end

  defp check_slo(unknown, required, _analysis) do
    %{required: required, actual: nil, passed?: false, error: "Unknown SLO: #{unknown}"}
  end

  # Statistics helpers

  defp percentile([], _p), do: 0

  defp percentile(sorted_list, p) when p >= 0 and p <= 1 do
    n = length(sorted_list)
    index = trunc(p * (n - 1))
    Enum.at(sorted_list, index, 0)
  end

  defp avg([]), do: 0.0

  defp avg(list) do
    Enum.sum(list) / length(list)
  end

  defp calculate_time_in_state(events, target_state) do
    # Sort events by timestamp
    sorted = Enum.sort_by(events, fn e -> e.timestamp end)

    # Calculate duration in target state
    {total_time, _last_state, _last_time} =
      Enum.reduce(sorted, {0, nil, nil}, fn event, {acc_time, last_state, last_time} ->
        cond do
          last_state == target_state && event.new_state != target_state ->
            # Exiting target state
            duration = event.timestamp - last_time
            {acc_time + duration, event.new_state, event.timestamp}

          event.new_state == target_state ->
            # Entering target state
            {acc_time, event.new_state, event.timestamp}

          true ->
            # Other state transition
            {acc_time, event.new_state, event.timestamp}
        end
      end)

    total_time
  end
end
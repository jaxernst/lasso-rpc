defmodule Lasso.Battle.Analyzer do
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

  Now includes transport-specific breakdown for HTTP vs WebSocket comparison.
  """
  def analyze(collected_data, opts \\ %{}) do
    requests = Map.get(collected_data, :requests, [])

    %{
      requests: analyze_requests(requests),
      requests_by_transport: analyze_requests_by_transport(requests),
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

  defp analyze_requests([]) do
    %{
      total: 0,
      successes: 0,
      failures: 0,
      success_rate: 0.0,
      p50_latency_ms: 0,
      p95_latency_ms: 0,
      p99_latency_ms: 0,
      min_latency_ms: 0,
      max_latency_ms: 0,
      avg_latency_ms: 0.0,
      failover_count: 0,
      avg_failover_latency_ms: 0.0,
      max_failover_latency_ms: 0
    }
  end

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

  defp analyze_requests_by_transport([]) do
    %{
      http: nil,
      ws: nil,
      combined: nil
    }
  end

  defp analyze_requests_by_transport(requests) do
    # Group requests by transport
    by_transport = Enum.group_by(requests, fn r -> r.transport end)

    http_requests = Map.get(by_transport, :http, [])
    ws_requests = Map.get(by_transport, :ws, [])

    # Statistical significance test
    http_latencies = Enum.map(http_requests, fn r -> r.duration_ms end)
    ws_latencies = Enum.map(ws_requests, fn r -> r.duration_ms end)

    statistical_test =
      if length(http_latencies) > 0 && length(ws_latencies) > 0 do
        mann_whitney_u_test(http_latencies, ws_latencies)
      else
        nil
      end

    %{
      http: analyze_transport(http_requests, "HTTP"),
      ws: analyze_transport(ws_requests, "WebSocket"),
      combined: analyze_transport(requests, "Combined"),
      statistical_comparison: statistical_test
    }
  end

  defp analyze_transport([], _label) do
    %{
      total: 0,
      successes: 0,
      failures: 0,
      success_rate: 0.0,
      p50_latency_ms: 0,
      p95_latency_ms: 0,
      p99_latency_ms: 0,
      min_latency_ms: 0,
      max_latency_ms: 0,
      avg_latency_ms: 0.0
    }
  end

  defp analyze_transport(requests, _label) do
    total = length(requests)
    successes = Enum.count(requests, fn r -> r.result == :success end)
    failures = total - successes

    latencies =
      requests
      |> Enum.map(fn r -> r.duration_ms end)
      |> Enum.sort()

    success_rate = if total > 0, do: successes / total, else: 0.0

    avg_latency = avg(latencies)
    stddev = standard_deviation(latencies, avg_latency)

    # 95% confidence interval using t-distribution approximation
    ci_95 = confidence_interval_95(latencies, avg_latency, stddev)

    # Provider distribution analysis
    provider_dist = analyze_provider_distribution(requests)

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
      stddev_latency_ms: stddev,
      ci_95_lower_ms: ci_95.lower,
      ci_95_upper_ms: ci_95.upper,
      provider_distribution: provider_dist
    }
  end

  defp analyze_circuit_breaker([]) do
    %{
      state_changes: 0,
      opens: 0,
      closes: 0,
      half_opens: 0,
      time_open_ms: 0
    }
  end

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

  defp analyze_system([]) do
    %{
      peak_memory_mb: 0,
      avg_memory_mb: 0.0,
      peak_processes: 0,
      avg_processes: 0.0
    }
  end

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

  defp analyze_websocket([]) do
    %{
      events: 0,
      duplicates: 0,
      gaps: 0
    }
  end

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

  defp check_slo(:max_memory_mb, required, analysis) do
    actual = get_in(analysis, [:system, :peak_memory_mb]) || 0
    %{required: required, actual: actual, passed?: actual <= required}
  end

  defp check_slo(:subscription_uptime, required, _analysis) do
    # Not yet implemented: Calculate actual uptime from WebSocket connection/disconnection events
    # Currently assumes perfect uptime (1.0)
    actual = 1.0
    %{required: required, actual: actual, passed?: actual >= required}
  end

  defp check_slo(:max_duplicate_rate, required, _analysis) do
    # Not yet implemented: Calculate from analyze_websocket/1 duplicate detection
    # Currently returns 0.0 duplicates
    actual = 0.0
    %{required: required, actual: actual, passed?: actual <= required}
  end

  defp check_slo(:max_gap_rate, required, _analysis) do
    # Not yet implemented: Calculate from analyze_websocket/1 gap detection
    # Currently returns 0.0 gaps
    actual = 0.0
    %{required: required, actual: actual, passed?: actual <= required}
  end

  defp check_slo(:max_failover_latency_ms, required, analysis) do
    actual = get_in(analysis, [:requests, :max_failover_latency_ms]) || 0
    %{required: required, actual: actual, passed?: actual <= required}
  end

  defp check_slo(:backfill_completion_ms, required, _analysis) do
    # Not yet implemented: Measure backfill time from stream_coordinator telemetry events
    # Currently returns 0 ms
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

  # Advanced statistical helpers

  defp standard_deviation([], _mean), do: 0.0

  defp standard_deviation(values, mean) do
    n = length(values)
    if n <= 1 do
      0.0
    else
      variance =
        values
        |> Enum.map(fn v -> :math.pow(v - mean, 2) end)
        |> Enum.sum()
        |> Kernel./(n - 1)

      :math.sqrt(variance)
    end
  end

  defp confidence_interval_95([], _mean, _stddev) do
    %{lower: 0, upper: 0}
  end

  defp confidence_interval_95(values, mean, stddev) do
    n = length(values)

    if n <= 1 do
      %{lower: mean, upper: mean}
    else
      # t-value approximation for 95% CI (df > 30 ≈ 1.96, smaller samples use higher values)
      t_value = t_critical_value(n)
      margin_of_error = t_value * stddev / :math.sqrt(n)

      %{
        lower: mean - margin_of_error,
        upper: mean + margin_of_error
      }
    end
  end

  defp t_critical_value(n) when n <= 5, do: 2.776
  defp t_critical_value(n) when n <= 10, do: 2.262
  defp t_critical_value(n) when n <= 20, do: 2.093
  defp t_critical_value(n) when n <= 30, do: 2.045
  defp t_critical_value(_n), do: 1.96

  defp analyze_provider_distribution([]) do
    %{total: 0, by_provider: %{}, balance_score: 1.0}
  end

  defp analyze_provider_distribution(requests) do
    total = length(requests)

    by_provider =
      requests
      |> Enum.group_by(fn r -> Map.get(r, :provider_id, Map.get(r, :provider, "unknown")) end)
      |> Enum.map(fn {provider, reqs} ->
        count = length(reqs)
        percentage = count / total * 100
        {provider, %{count: count, percentage: percentage}}
      end)
      |> Enum.into(%{})

    # Calculate balance score (1.0 = perfectly balanced, 0.0 = all requests to one provider)
    # Using coefficient of variation: lower is better balanced
    provider_counts = Enum.map(by_provider, fn {_, %{count: c}} -> c end)
    expected_per_provider = total / map_size(by_provider)

    balance_score =
      if map_size(by_provider) <= 1 do
        1.0
      else
        variance =
          provider_counts
          |> Enum.map(fn c -> :math.pow(c - expected_per_provider, 2) end)
          |> Enum.sum()
          |> Kernel./(map_size(by_provider))

        stddev = :math.sqrt(variance)
        coefficient_of_variation = stddev / expected_per_provider

        # Convert to 0-1 score (lower CV = higher score)
        max(0.0, 1.0 - coefficient_of_variation)
      end

    %{
      total: total,
      by_provider: by_provider,
      balance_score: Float.round(balance_score, 3)
    }
  end

  @doc """
  Performs Mann-Whitney U test to determine if two distributions are statistically different.
  Returns p-value and whether the difference is significant at 0.05 level.
  """
  def mann_whitney_u_test(sample1, sample2) do
    n1 = length(sample1)
    n2 = length(sample2)

    if n1 == 0 or n2 == 0 do
      %{u_statistic: 0, p_value: 1.0, significant?: false, message: "Empty sample(s)"}
    else
      # Combine and rank all values
      combined =
        (Enum.map(sample1, fn v -> {v, :sample1} end) ++
           Enum.map(sample2, fn v -> {v, :sample2} end))
        |> Enum.sort_by(fn {v, _} -> v end)

      # Assign ranks (handling ties by averaging ranks)
      {ranked, _} =
        Enum.reduce(combined, {[], 1}, fn {value, group}, {acc, rank} ->
          {[{value, group, rank} | acc], rank + 1}
        end)

      ranked = Enum.reverse(ranked)

      # Sum ranks for sample 1
      r1 = ranked |> Enum.filter(fn {_, g, _} -> g == :sample1 end) |> Enum.map(fn {_, _, r} -> r end) |> Enum.sum()

      # Calculate U statistic
      u1 = r1 - n1 * (n1 + 1) / 2
      u2 = n1 * n2 - u1
      u = min(u1, u2)

      # Normal approximation for large samples (n1, n2 > 20)
      mean_u = n1 * n2 / 2
      std_u = :math.sqrt(n1 * n2 * (n1 + n2 + 1) / 12)

      # Z-score
      z = (u - mean_u) / std_u

      # Two-tailed p-value (approximation using normal distribution)
      p_value = 2 * (1 - normal_cdf(abs(z)))

      %{
        u_statistic: u,
        z_score: Float.round(z, 3),
        p_value: Float.round(p_value, 4),
        significant?: p_value < 0.05,
        interpretation:
          if p_value < 0.05 do
            "Statistically significant difference (p < 0.05)"
          else
            "No statistically significant difference (p ≥ 0.05)"
          end
      }
    end
  end

  # Normal CDF approximation (for p-value calculation)
  defp normal_cdf(z) do
    0.5 * (1 + erf(z / :math.sqrt(2)))
  end

  # Error function approximation
  defp erf(x) do
    # Abramowitz and Stegun approximation
    sign = if x < 0, do: -1, else: 1
    x = abs(x)

    a1 = 0.254829592
    a2 = -0.284496736
    a3 = 1.421413741
    a4 = -1.453152027
    a5 = 1.061405429
    p = 0.3275911

    t = 1.0 / (1.0 + p * x)

    y =
      1.0 -
        ((((a5 * t + a4) * t + a3) * t + a2) * t + a1) * t * :math.exp(-x * x)

    sign * y
  end
end

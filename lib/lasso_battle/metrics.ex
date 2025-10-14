defmodule LassoBattle.Metrics do
  @moduledoc """
  Statistical analysis for battle test results.

  Provides comprehensive metrics calculation, percentile analysis, and
  regression detection for battle tests.

  ## Usage

      # Collect battle test results
      results = run_battle_test()

      # Analyze metrics
      metrics = Metrics.analyze(results)

      # Check SLOs
      assert metrics.success_rate >= 0.99
      assert metrics.p95_latency_ms <= 500

      # Compare to baseline for regression detection
      comparison = Metrics.compare(baseline_metrics, current_metrics)
      assert length(comparison.regressions) == 0
  """

  @doc """
  Analyzes battle test results and computes comprehensive metrics.

  ## Input Format

  Expects a map with:
  - `:requests` - List of request results with `:status`, `:latency_ms`, `:provider_id`
  - `:subscription_events` - Optional list of subscription events for gap analysis
  - `:events` - Optional list of system events (CB state changes, etc.)

  ## Returns

  Map containing:
  - Basic metrics (total_requests, success_rate, etc.)
  - Latency analysis (mean, p50, p95, p99)
  - Gap analysis (for subscriptions)
  - Provider usage distribution
  - Circuit breaker activity
  - Failover analysis

  ## Example

      results = %{
        requests: [
          %{status: :success, latency_ms: 100, provider_id: "alchemy"},
          %{status: :error, latency_ms: 500, provider_id: "infura"}
        ],
        events: [
          %{type: :circuit_breaker_open, provider_id: "alchemy"}
        ]
      }

      metrics = Metrics.analyze(results)
  """
  @spec analyze(map()) :: map()
  def analyze(results) do
    requests = Map.get(results, :requests, [])
    subscription_events = Map.get(results, :subscription_events, [])
    system_events = Map.get(results, :events, [])

    latencies =
      requests
      |> Enum.filter(&(&1.status == :success))
      |> Enum.map(& &1.latency_ms)

    %{
      # Basic metrics
      total_requests: length(requests),
      successful_requests: count_successful(requests),
      failed_requests: count_failed(requests),
      success_rate: calculate_success_rate(requests),

      # Latency analysis
      mean_latency_ms: calculate_mean(latencies),
      median_latency_ms: percentile(latencies, 50),
      p50_latency_ms: percentile(latencies, 50),
      p95_latency_ms: percentile(latencies, 95),
      p99_latency_ms: percentile(latencies, 99),
      max_latency_ms: calculate_max(latencies),
      min_latency_ms: calculate_min(latencies),

      # Gap analysis (for subscriptions)
      gaps_detected: analyze_gaps(subscription_events),
      max_gap_size: max_gap_size(subscription_events),

      # Provider usage
      providers_used: unique_providers(requests),
      provider_distribution: provider_usage_distribution(requests),
      most_used_provider: most_used_provider(requests),

      # Circuit breaker activity
      circuit_breaker_opens: count_events(system_events, :circuit_breaker_open),
      circuit_breaker_half_opens: count_events(system_events, :circuit_breaker_half_open),
      circuit_breaker_closes: count_events(system_events, :circuit_breaker_close),

      # Failover analysis
      failover_count: count_failovers(requests),
      failover_success_rate: failover_success_rate(requests),
      provider_switches: count_provider_switches(requests),

      # Health state
      final_health_state: analyze_final_health(Map.get(results, :providers, []))
    }
  end

  @doc """
  Compares two battle test runs for regression detection.

  Returns a map with deltas and lists of regressions/improvements.

  ## Example

      comparison = Metrics.compare(baseline, current)

      if length(comparison.regressions) > 0 do
        IO.puts("Regressions detected:")
        Enum.each(comparison.regressions, fn {metric, baseline_val, current_val, delta} ->
          IO.puts("  \#{metric}: \#{baseline_val} -> \#{current_val} (delta: \#{delta})")
        end)
      end
  """
  @spec compare(map(), map()) :: map()
  def compare(baseline, current) do
    %{
      # Deltas
      success_rate_delta: current.success_rate - baseline.success_rate,
      p50_latency_delta: current.p50_latency_ms - baseline.p50_latency_ms,
      p95_latency_delta: current.p95_latency_ms - baseline.p95_latency_ms,
      p99_latency_delta: current.p99_latency_ms - baseline.p99_latency_ms,

      # Regression/improvement detection
      regressions: detect_regressions(baseline, current),
      improvements: detect_improvements(baseline, current)
    }
  end

  @doc """
  Verifies that metrics meet specified SLO thresholds.

  Returns `{:ok, metrics}` if all SLOs pass, or `{:error, violations}` otherwise.

  ## Example

      slos = %{
        success_rate: 0.99,
        p95_latency_ms: 500,
        max_gap_size: 0
      }

      case Metrics.verify_slos(metrics, slos) do
        {:ok, _} -> IO.puts("All SLOs met")
        {:error, violations} -> raise "SLO violations: \#{inspect(violations)}"
      end
  """
  @spec verify_slos(map(), map()) :: {:ok, map()} | {:error, [map()]}
  def verify_slos(metrics, slo_thresholds) do
    violations =
      Enum.flat_map(slo_thresholds, fn {metric, threshold} ->
        actual = Map.get(metrics, metric)

        cond do
          is_nil(actual) ->
            [%{metric: metric, reason: :metric_not_found}]

          metric_violates_slo?(metric, actual, threshold) ->
            [%{metric: metric, threshold: threshold, actual: actual}]

          true ->
            []
        end
      end)

    if violations == [] do
      {:ok, metrics}
    else
      {:error, violations}
    end
  end

  # Private functions - Basic metrics

  defp count_successful(requests) do
    Enum.count(requests, &(&1.status == :success))
  end

  defp count_failed(requests) do
    Enum.count(requests, &(&1.status != :success))
  end

  defp calculate_success_rate([]), do: 0.0

  defp calculate_success_rate(requests) do
    successful = count_successful(requests)
    total = length(requests)
    successful / total
  end

  # Private functions - Latency analysis

  defp calculate_mean([]), do: 0.0

  defp calculate_mean(values) do
    Enum.sum(values) / length(values)
  end

  defp percentile([], _p), do: 0.0

  defp percentile(values, p) when p >= 0 and p <= 100 do
    sorted = Enum.sort(values)
    index = trunc(p / 100 * length(sorted))
    index = max(0, min(index, length(sorted) - 1))
    Enum.at(sorted, index, 0.0)
  end

  defp calculate_max([]), do: 0
  defp calculate_max(values), do: Enum.max(values)

  defp calculate_min([]), do: 0
  defp calculate_min(values), do: Enum.min(values)

  # Private functions - Gap analysis

  defp analyze_gaps([]), do: 0

  defp analyze_gaps(events) do
    events
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [event1, event2] ->
      # Detect gaps in block numbers
      case {extract_block_num(event1), extract_block_num(event2)} do
        {nil, _} -> false
        {_, nil} -> false
        {num1, num2} -> num2 - num1 > 1
      end
    end)
  end

  defp max_gap_size([]), do: 0

  defp max_gap_size(events) do
    events
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [event1, event2] ->
      case {extract_block_num(event1), extract_block_num(event2)} do
        {nil, _} -> 0
        {_, nil} -> 0
        {num1, num2} -> max(0, num2 - num1 - 1)
      end
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp extract_block_num(%{block_number: num}), do: num
  defp extract_block_num(%{"number" => "0x" <> hex}), do: String.to_integer(hex, 16)
  defp extract_block_num(_), do: nil

  # Private functions - Provider analysis

  defp unique_providers(requests) do
    requests
    |> Enum.map(& &1.provider_id)
    |> Enum.uniq()
    |> length()
  end

  defp provider_usage_distribution(requests) do
    requests
    |> Enum.group_by(& &1.provider_id)
    |> Enum.map(fn {provider_id, provider_requests} ->
      {provider_id, length(provider_requests)}
    end)
    |> Enum.into(%{})
  end

  defp most_used_provider([]), do: nil

  defp most_used_provider(requests) do
    requests
    |> provider_usage_distribution()
    |> Enum.max_by(fn {_provider, count} -> count end, fn -> {nil, 0} end)
    |> elem(0)
  end

  # Private functions - Event analysis

  defp count_events(events, event_type) do
    Enum.count(events, &(&1.type == event_type))
  end

  # Private functions - Failover analysis

  defp count_failovers(requests) do
    # Count requests where latency > 2x average (heuristic for failover)
    avg_latency = calculate_mean(Enum.map(requests, & &1.latency_ms))

    Enum.count(requests, fn req ->
      req.latency_ms > avg_latency * 2
    end)
  end

  defp failover_success_rate([]), do: 0.0

  defp failover_success_rate(requests) do
    avg_latency = calculate_mean(Enum.map(requests, & &1.latency_ms))

    failover_requests =
      Enum.filter(requests, fn req ->
        req.latency_ms > avg_latency * 2
      end)

    if failover_requests == [] do
      0.0
    else
      successful = count_successful(failover_requests)
      successful / length(failover_requests)
    end
  end

  defp count_provider_switches(requests) do
    requests
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [req1, req2] ->
      req1.provider_id != req2.provider_id
    end)
  end

  defp analyze_final_health([]), do: :unknown

  defp analyze_final_health(providers) do
    all_healthy = Enum.all?(providers, &(&1.status == :healthy))

    if all_healthy do
      :all_healthy
    else
      degraded_count = Enum.count(providers, &(&1.status != :healthy))
      {:degraded, degraded_count}
    end
  end

  # Private functions - Regression detection

  defp detect_regressions(baseline, current) do
    []
    |> check_regression(:success_rate, baseline, current, -0.01)
    |> check_regression(:p50_latency_ms, baseline, current, 100)
    |> check_regression(:p95_latency_ms, baseline, current, 100)
    |> check_regression(:p99_latency_ms, baseline, current, 200)
    |> check_regression(:max_gap_size, baseline, current, 0)
  end

  defp check_regression(regressions, metric, baseline, current, threshold) do
    baseline_value = Map.get(baseline, metric)
    current_value = Map.get(current, metric)

    if is_nil(baseline_value) or is_nil(current_value) do
      regressions
    else
      delta = current_value - baseline_value

      # For success_rate, lower is worse (negative delta is bad)
      # For latencies, higher is worse (positive delta is bad)
      # For gaps, any increase is bad
      is_regression =
        case metric do
          :success_rate -> delta < threshold
          :max_gap_size -> delta > threshold
          _ -> delta > threshold
        end

      if is_regression do
        [{metric, baseline_value, current_value, delta} | regressions]
      else
        regressions
      end
    end
  end

  defp detect_improvements(baseline, current) do
    []
    |> check_improvement(:success_rate, baseline, current, 0.01)
    |> check_improvement(:p95_latency_ms, baseline, current, -50)
  end

  defp check_improvement(improvements, metric, baseline, current, threshold) do
    baseline_value = Map.get(baseline, metric)
    current_value = Map.get(current, metric)

    if is_nil(baseline_value) or is_nil(current_value) do
      improvements
    else
      delta = current_value - baseline_value

      is_improvement =
        case metric do
          :success_rate -> delta > threshold
          _ -> delta < threshold
        end

      if is_improvement do
        [{metric, baseline_value, current_value, delta} | improvements]
      else
        improvements
      end
    end
  end

  # Private functions - SLO verification

  defp metric_violates_slo?(metric, actual, threshold) do
    case metric do
      m when m in [:success_rate] ->
        # Higher is better
        actual < threshold

      m when m in [:p50_latency_ms, :p95_latency_ms, :p99_latency_ms, :max_latency_ms] ->
        # Lower is better
        actual > threshold

      m when m in [:max_gap_size, :gaps_detected] ->
        # Should be zero or less than threshold
        actual > threshold

      _ ->
        # Unknown metric, assume threshold is maximum
        actual > threshold
    end
  end
end

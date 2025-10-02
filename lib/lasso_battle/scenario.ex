defmodule Lasso.Battle.Scenario do
  @moduledoc """
  Scenario orchestration for battle testing.

  A scenario defines:
  - Setup: Initialize test environment (start mock providers, seed metrics)
  - Workload: Generate load (HTTP requests, WS subscriptions)
  - Chaos: Inject failures (kill providers, add latency)
  - Collect: Capture telemetry events (requests, circuit breaker, system)
  - SLO: Define success criteria (success rate, latency percentiles)
  """

  defstruct [
    :name,
    :setup_fn,
    :workload_fn,
    :chaos_fns,
    :collectors,
    :slos,
    :report_id
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          setup_fn: (-> {:ok, map()} | {:error, term()}),
          workload_fn: (-> :ok),
          chaos_fns: [(-> :ok)],
          collectors: [atom()],
          slos: keyword(),
          report_id: String.t() | nil
        }

  alias Lasso.Battle.{Collector, Analyzer, Reporter}

  @doc """
  Creates a new battle test scenario.

  ## Example

      Scenario.new("My Test")
      |> Scenario.setup(fn -> ... end)
      |> Scenario.workload(fn -> ... end)
      |> Scenario.run()
  """
  def new(name) when is_binary(name) do
    %__MODULE__{
      name: name,
      chaos_fns: [],
      collectors: [],
      slos: [],
      report_id: generate_report_id()
    }
  end

  @doc """
  Defines the setup phase (runs before workload).
  """
  def setup(%__MODULE__{} = scenario, setup_fn) when is_function(setup_fn, 0) do
    %{scenario | setup_fn: setup_fn}
  end

  @doc """
  Defines the workload to execute.
  """
  def workload(%__MODULE__{} = scenario, workload_fn) when is_function(workload_fn, 0) do
    %{scenario | workload_fn: workload_fn}
  end

  @doc """
  Adds a chaos injection function.

  Chaos functions run concurrently with the workload.
  """
  def chaos(%__MODULE__{chaos_fns: chaos_fns} = scenario, chaos_fn)
      when is_function(chaos_fn, 0) do
    %{scenario | chaos_fns: [chaos_fn | chaos_fns]}
  end

  def chaos(%__MODULE__{chaos_fns: chaos_fns} = scenario, chaos_fns_list)
      when is_list(chaos_fns_list) do
    %{scenario | chaos_fns: chaos_fns_list ++ chaos_fns}
  end

  @doc """
  Specifies which metrics to collect during the test.

  Available collectors: :requests, :circuit_breaker, :system, :websocket
  """
  def collect(%__MODULE__{} = scenario, collectors) when is_list(collectors) do
    %{scenario | collectors: collectors}
  end

  @doc """
  Defines Service Level Objectives (SLOs) for the test.

  ## Options

  - `:success_rate` - Minimum success rate (0.0 to 1.0)
  - `:p95_latency_ms` - Maximum P95 latency in milliseconds
  - `:p99_latency_ms` - Maximum P99 latency in milliseconds
  - `:max_failover_latency_ms` - Maximum failover latency
  - `:max_memory_mb` - Maximum memory usage in MB
  - `:subscription_uptime` - Minimum subscription uptime (0.0 to 1.0)
  - `:max_duplicate_rate` - Maximum duplicate event rate (0.0 to 1.0)
  """
  def slo(%__MODULE__{} = scenario, slos) when is_list(slos) do
    %{scenario | slos: slos}
  end

  @doc """
  Runs the battle test scenario.

  Returns a result map with:
  - `:passed?` - Boolean indicating if all SLOs passed
  - `:analysis` - Analyzed metrics
  - `:summary` - Human-readable summary
  - `:report_id` - Unique identifier for this test run
  """
  def run(%__MODULE__{} = scenario) do
    start_time = System.monotonic_time(:millisecond)

    # 1. Setup
    {:ok, context} =
      case scenario.setup_fn do
        nil -> {:ok, %{}}
        setup_fn -> setup_fn.()
      end

    # 2. Start collectors
    Collector.start_collectors(scenario.collectors)

    # 3. Start chaos tasks (run in background)
    chaos_tasks =
      Enum.map(scenario.chaos_fns, fn chaos_fn ->
        Task.async(fn -> chaos_fn.() end)
      end)

    # 4. Execute workload (blocks until complete)
    if scenario.workload_fn do
      scenario.workload_fn.()
    end

    # 5. Wait for chaos tasks to complete
    Task.await_many(chaos_tasks, :infinity)

    # 6. Stop collectors and gather data
    collected_data = Collector.stop_collectors(scenario.collectors)

    # 7. Analyze results
    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    analysis =
      Analyzer.analyze(collected_data, %{
        duration_ms: duration_ms,
        context: context
      })

    # 8. Verify SLOs
    slo_results = Analyzer.verify_slos(analysis, scenario.slos)

    # Build result
    passed? =
      if map_size(slo_results) == 0 do
        true
      else
        Enum.all?(Map.values(slo_results), fn result -> result.passed? end)
      end

    %{
      scenario: scenario,
      passed?: passed?,
      analysis: analysis,
      slo_results: slo_results,
      summary: build_summary(scenario, analysis, slo_results),
      report_id: scenario.report_id,
      duration_ms: duration_ms,
      context: context
    }
  end

  # Private helpers

  defp generate_report_id do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    random = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{timestamp}_#{random}"
  end

  defp build_summary(scenario, analysis, slo_results) do
    passed_count = Enum.count(slo_results, fn {_, r} -> r.passed? end)
    total_count = map_size(slo_results)

    """
    Battle Test: #{scenario.name}

    SLO Results: #{passed_count}/#{total_count} passed

    #{format_slo_results(slo_results)}

    Performance Summary:
    #{format_analysis(analysis)}
    """
  end

  defp format_slo_results(slo_results) do
    Enum.map_join(slo_results, "\n", fn {key, result} ->
      status = if result.passed?, do: "✅", else: "❌"
      "  #{status} #{key}: #{format_slo_value(result)}"
    end)
  end

  defp format_slo_value(%{required: req, actual: act}) do
    "required #{format_value(req)}, actual #{format_value(act)}"
  end

  defp format_value(val) when is_float(val), do: Float.round(val, 3)
  defp format_value(val), do: val

  defp format_analysis(analysis) do
    requests = Map.get(analysis, :requests, %{})

    """
      Total Requests: #{Map.get(requests, :total, 0)}
      Success Rate: #{format_percent(Map.get(requests, :success_rate, 0.0))}
      P50 Latency: #{Map.get(requests, :p50_latency_ms, 0)}ms
      P95 Latency: #{Map.get(requests, :p95_latency_ms, 0)}ms
      P99 Latency: #{Map.get(requests, :p99_latency_ms, 0)}ms
    """
  end

  defp format_percent(rate) when is_float(rate) do
    "#{Float.round(rate * 100, 2)}%"
  end

  defp format_percent(_), do: "N/A"
end

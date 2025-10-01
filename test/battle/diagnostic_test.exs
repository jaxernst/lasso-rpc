defmodule Livechain.Battle.DiagnosticTest do
  @moduledoc """
  Diagnostic tests to validate framework behavior and inspect outputs.

  These tests help us understand:
  - What data is actually being collected?
  - Are telemetry handlers firing correctly?
  - Are statistics computed accurately?
  - What does the full result structure look like?
  """

  use ExUnit.Case, async: false
  require Logger

  alias Livechain.Battle.{Scenario, Collector, Analyzer}

  @moduletag :battle
  @moduletag :diagnostic  # Framework validation tests
  @moduletag :fast        # Quick tests for CI
  @moduletag timeout: :infinity

  setup do
    Application.ensure_all_started(:livechain)
    :ok
  end

  test "DIAGNOSTIC: inspect raw telemetry collection" do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("DIAGNOSTIC TEST: Raw Telemetry Collection")
    IO.puts(String.duplicate("=", 80))

    # Start collectors manually
    Collector.start_collectors([:requests, :circuit_breaker, :system])

    IO.puts("\n📊 Emitting 10 test events...")

    # Emit exactly 10 events with known values
    for i <- 1..10 do
      latency = i * 10  # 10ms, 20ms, 30ms, ... 100ms
      result = if i <= 8, do: :success, else: {:error, :timeout}

      :telemetry.execute(
        [:livechain, :battle, :request],
        %{latency: latency},
        %{
          chain: "test",
          method: "eth_test",
          strategy: :fastest,
          result: result,
          request_id: i
        }
      )

      IO.puts("  Event #{i}: latency=#{latency}ms, result=#{inspect(result)}")
    end

    # Emit circuit breaker events
    IO.puts("\n🔌 Emitting circuit breaker events...")

    :telemetry.execute(
      [:livechain, :circuit_breaker, :state_change],
      %{},
      %{provider_id: "test_provider", old_state: :closed, new_state: :open}
    )
    IO.puts("  CB: closed -> open")

    Process.sleep(50)

    :telemetry.execute(
      [:livechain, :circuit_breaker, :state_change],
      %{},
      %{provider_id: "test_provider", old_state: :open, new_state: :closed}
    )
    IO.puts("  CB: open -> closed")

    # Stop collectors and inspect data
    collected_data = Collector.stop_collectors([:requests, :circuit_breaker, :system])

    IO.puts("\n" <> String.duplicate("-", 80))
    IO.puts("📦 RAW COLLECTED DATA:")
    IO.puts(String.duplicate("-", 80))
    IO.inspect(collected_data, pretty: true, limit: :infinity)

    # Analyze data
    analysis = Analyzer.analyze(collected_data, %{duration_ms: 1000})

    IO.puts("\n" <> String.duplicate("-", 80))
    IO.puts("📈 ANALYSIS RESULTS:")
    IO.puts(String.duplicate("-", 80))
    IO.inspect(analysis, pretty: true, limit: :infinity)

    # Verify expected values
    IO.puts("\n" <> String.duplicate("-", 80))
    IO.puts("✅ VERIFICATION:")
    IO.puts(String.duplicate("-", 80))

    assert analysis.requests.total == 10, "Expected 10 requests, got #{analysis.requests.total}"
    IO.puts("  ✓ Total requests: #{analysis.requests.total}")

    assert analysis.requests.successes == 8, "Expected 8 successes, got #{analysis.requests.successes}"
    IO.puts("  ✓ Successes: #{analysis.requests.successes}")

    assert analysis.requests.failures == 2, "Expected 2 failures, got #{analysis.requests.failures}"
    IO.puts("  ✓ Failures: #{analysis.requests.failures}")

    expected_success_rate = 0.8
    assert_in_delta analysis.requests.success_rate, expected_success_rate, 0.01
    IO.puts("  ✓ Success rate: #{Float.round(analysis.requests.success_rate * 100, 1)}%")

    # Latency checks
    IO.puts("  ✓ P50 Latency: #{analysis.requests.p50_latency_ms}ms (expected ~50ms)")
    IO.puts("  ✓ P95 Latency: #{analysis.requests.p95_latency_ms}ms (expected ~95ms)")
    IO.puts("  ✓ Min Latency: #{analysis.requests.min_latency_ms}ms (expected 10ms)")
    IO.puts("  ✓ Max Latency: #{analysis.requests.max_latency_ms}ms (expected 100ms)")

    assert analysis.requests.min_latency_ms == 10
    assert analysis.requests.max_latency_ms == 100

    # Circuit breaker checks
    IO.puts("  ✓ CB State Changes: #{analysis.circuit_breaker.state_changes}")
    assert analysis.circuit_breaker.state_changes == 2
    assert analysis.circuit_breaker.opens == 1
    assert analysis.circuit_breaker.closes == 1

    # System checks
    IO.puts("  ✓ Peak Memory: #{Float.round(analysis.system.peak_memory_mb, 2)}MB")
    IO.puts("  ✓ Peak Processes: #{analysis.system.peak_processes}")

    IO.puts("\n✅ All diagnostic checks passed!")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  test "DIAGNOSTIC: SLO verification edge cases" do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("DIAGNOSTIC TEST: SLO Verification")
    IO.puts(String.duplicate("=", 80))

    # Create test analysis data
    analysis = %{
      requests: %{
        total: 100,
        successes: 95,
        failures: 5,
        success_rate: 0.95,
        p50_latency_ms: 50,
        p95_latency_ms: 150,
        p99_latency_ms: 200,
        min_latency_ms: 10,
        max_latency_ms: 250,
        avg_latency_ms: 75.5
      },
      circuit_breaker: %{state_changes: 2, opens: 1, closes: 1, time_open_ms: 1000},
      system: %{peak_memory_mb: 100, avg_memory_mb: 80, peak_processes: 500, avg_processes: 450},
      websocket: %{events: 0, duplicates: 0, gaps: 0}
    }

    IO.puts("\n📊 Test Analysis Data:")
    IO.inspect(analysis.requests, pretty: true)

    # Test various SLO scenarios
    test_cases = [
      {[success_rate: 0.90], true, "Success rate 95% >= 90%"},
      {[success_rate: 0.96], false, "Success rate 95% < 96%"},
      {[p95_latency_ms: 200], true, "P95 latency 150ms <= 200ms"},
      {[p95_latency_ms: 100], false, "P95 latency 150ms > 100ms"},
      {[success_rate: 0.90, p95_latency_ms: 200], true, "Both pass"},
      {[success_rate: 0.96, p95_latency_ms: 200], false, "One fails"},
      {[max_memory_mb: 150], true, "Memory 100MB <= 150MB"},
      {[max_memory_mb: 50], false, "Memory 100MB > 50MB"}
    ]

    IO.puts("\n" <> String.duplicate("-", 80))
    IO.puts("Testing SLO scenarios:")
    IO.puts(String.duplicate("-", 80))

    for {slos, expected_pass, description} <- test_cases do
      slo_results = Analyzer.verify_slos(analysis, slos)

      all_passed = Enum.all?(Map.values(slo_results), fn r -> r.passed? end)

      status = if all_passed == expected_pass, do: "✅ PASS", else: "❌ FAIL"

      IO.puts("\n#{status} - #{description}")
      IO.puts("  SLOs: #{inspect(slos)}")
      IO.puts("  Results:")
      for {key, result} <- slo_results do
        pass_status = if result.passed?, do: "✅", else: "❌"
        IO.puts("    #{pass_status} #{key}: required=#{result.required}, actual=#{result.actual}")
      end

      assert all_passed == expected_pass, "Expected pass=#{expected_pass}, got #{all_passed}"
    end

    IO.puts("\n✅ All SLO verification tests passed!")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  test "DIAGNOSTIC: full scenario execution with verbose logging" do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("DIAGNOSTIC TEST: Full Scenario Execution")
    IO.puts(String.duplicate("=", 80))

    result =
      Scenario.new("Diagnostic Full Test")
      |> Scenario.setup(fn ->
        IO.puts("\n🔧 SETUP PHASE")
        IO.puts("  Setting up test environment...")
        {:ok, %{chain: "test", started_at: System.monotonic_time(:millisecond)}}
      end)
      |> Scenario.workload(fn ->
        IO.puts("\n⚡ WORKLOAD PHASE")
        IO.puts("  Generating 20 test requests...")

        for i <- 1..20 do
          latency = 40 + :rand.uniform(60)  # 40-100ms
          result = if i <= 19, do: :success, else: {:error, :timeout}

          :telemetry.execute(
            [:livechain, :battle, :request],
            %{latency: latency},
            %{
              chain: "test",
              method: "eth_blockNumber",
              strategy: nil,
              result: result,
              request_id: i
            }
          )

          if rem(i, 5) == 0 do
            IO.puts("    Progress: #{i}/20 requests")
          end

          Process.sleep(5)
        end

        IO.puts("  Workload complete!")
        :ok
      end)
      |> Scenario.collect([:requests, :system])
      |> Scenario.slo(success_rate: 0.90, p95_latency_ms: 150)
      |> Scenario.run()

    IO.puts("\n" <> String.duplicate("-", 80))
    IO.puts("📊 SCENARIO RESULT:")
    IO.puts(String.duplicate("-", 80))
    IO.puts("  Passed: #{result.passed?}")
    IO.puts("  Duration: #{result.duration_ms}ms")
    IO.puts("  Report ID: #{result.report_id}")

    IO.puts("\n📈 Analysis:")
    IO.puts("  Total Requests: #{result.analysis.requests.total}")
    IO.puts("  Success Rate: #{Float.round(result.analysis.requests.success_rate * 100, 2)}%")
    IO.puts("  P50 Latency: #{result.analysis.requests.p50_latency_ms}ms")
    IO.puts("  P95 Latency: #{result.analysis.requests.p95_latency_ms}ms")
    IO.puts("  Peak Memory: #{Float.round(result.analysis.system.peak_memory_mb, 2)}MB")

    IO.puts("\n📋 SLO Results:")
    for {key, slo_result} <- result.slo_results do
      status = if slo_result.passed?, do: "✅", else: "❌"
      IO.puts("  #{status} #{key}: #{slo_result.actual} (required: #{slo_result.required})")
    end

    IO.puts("\n📄 Summary:")
    IO.puts(result.summary)

    assert result.passed?, "Scenario should pass with 95% success rate"
    assert result.analysis.requests.total == 20

    IO.puts("\n✅ Full scenario test passed!")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  test "DIAGNOSTIC: percentile calculation accuracy" do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("DIAGNOSTIC TEST: Percentile Calculation Accuracy")
    IO.puts(String.duplicate("=", 80))

    # Test with known dataset
    Collector.start_collectors([:requests])

    # Generate requests with known latency distribution
    # 100 requests: 1ms, 2ms, 3ms, ..., 100ms
    IO.puts("\n📊 Generating 100 requests with latencies 1-100ms...")

    for i <- 1..100 do
      :telemetry.execute(
        [:livechain, :battle, :request],
        %{latency: i},
        %{
          chain: "test",
          method: "test",
          strategy: nil,
          result: :success,
          request_id: i
        }
      )
    end

    collected_data = Collector.stop_collectors([:requests])
    analysis = Analyzer.analyze(collected_data, %{duration_ms: 1000})

    IO.puts("\n📈 Percentile Results:")
    IO.puts("  P50 (expected ~50): #{analysis.requests.p50_latency_ms}ms")
    IO.puts("  P95 (expected ~95): #{analysis.requests.p95_latency_ms}ms")
    IO.puts("  P99 (expected ~99): #{analysis.requests.p99_latency_ms}ms")
    IO.puts("  Min (expected 1): #{analysis.requests.min_latency_ms}ms")
    IO.puts("  Max (expected 100): #{analysis.requests.max_latency_ms}ms")
    IO.puts("  Avg (expected ~50.5): #{Float.round(analysis.requests.avg_latency_ms, 2)}ms")

    # Verify percentiles are reasonable (within 5% tolerance)
    assert_in_delta analysis.requests.p50_latency_ms, 50, 5
    assert_in_delta analysis.requests.p95_latency_ms, 95, 5
    assert_in_delta analysis.requests.p99_latency_ms, 99, 5
    assert analysis.requests.min_latency_ms == 1
    assert analysis.requests.max_latency_ms == 100
    assert_in_delta analysis.requests.avg_latency_ms, 50.5, 2

    IO.puts("\n✅ Percentile calculations are accurate!")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  test "DIAGNOSTIC: collector data structure validation" do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("DIAGNOSTIC TEST: Collector Data Structure")
    IO.puts(String.duplicate("=", 80))

    Collector.start_collectors([:requests, :circuit_breaker, :system])

    # Emit single event
    :telemetry.execute(
      [:livechain, :battle, :request],
      %{latency: 42},
      %{
        chain: "test",
        method: "eth_test",
        strategy: :fastest,
        result: :success,
        request_id: 999
      }
    )

    collected_data = Collector.stop_collectors([:requests, :circuit_breaker, :system])

    IO.puts("\n🔍 Inspecting collector data structure:")
    IO.puts("\nKeys present: #{inspect(Map.keys(collected_data))}")

    if Map.has_key?(collected_data, :requests) do
      requests = Map.get(collected_data, :requests)
      IO.puts("\nRequests data type: #{inspect(__MODULE__.get_type(requests))}")
      IO.puts("Requests count: #{length(requests)}")

      if length(requests) > 0 do
        first_request = List.first(requests)
        IO.puts("\nFirst request structure:")
        IO.inspect(first_request, pretty: true)

        IO.puts("\nFirst request keys: #{inspect(Map.keys(first_request))}")

        # Validate structure (Collector normalizes latency to duration_ms)
        assert Map.has_key?(first_request, :duration_ms), "Missing :duration_ms key"
        assert Map.has_key?(first_request, :chain), "Missing :chain key"
        assert Map.has_key?(first_request, :method), "Missing :method key"
        assert Map.has_key?(first_request, :result), "Missing :result key"
        assert Map.has_key?(first_request, :timestamp), "Missing :timestamp key"

        IO.puts("\n✅ Request data structure is valid!")
      end
    end

    if Map.has_key?(collected_data, :system) do
      system = Map.get(collected_data, :system)
      IO.puts("\nSystem samples count: #{length(system)}")

      if length(system) > 0 do
        first_sample = List.first(system)
        IO.puts("\nFirst system sample:")
        IO.inspect(first_sample, pretty: true)

        assert Map.has_key?(first_sample, :memory_mb), "Missing :memory_mb key"
        assert Map.has_key?(first_sample, :process_count), "Missing :process_count key"
        assert Map.has_key?(first_sample, :timestamp), "Missing :timestamp key"

        IO.puts("\n✅ System data structure is valid!")
      end
    end

    IO.puts("\n" <> String.duplicate("=", 80) <> "\n")
  end

  # Helper to get type name
  def get_type(value) when is_list(value), do: "list"
  def get_type(value) when is_map(value), do: "map"
  def get_type(value), do: inspect(__MODULE__.__info__(:functions))
end
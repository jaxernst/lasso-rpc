defmodule Livechain.Battle.BasicTest do
  @moduledoc """
  Basic battle tests to validate the framework.

  These tests demonstrate the battle testing framework's capabilities:
  - HTTP load generation
  - Mock provider simulation
  - Telemetry collection
  - SLO verification
  - Report generation
  """

  use ExUnit.Case, async: false

  alias Livechain.Battle.{Scenario, Workload, MockProvider, Reporter}

  @moduletag :battle
  @moduletag timeout: :infinity

  setup do
    # Ensure application is started
    Application.ensure_all_started(:livechain)

    on_exit(fn ->
      # Cleanup: Stop any mock providers
      try do
        MockProvider.stop_providers([:provider_a, :provider_b, :provider_c])
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  test "Phase 1 Milestone: basic telemetry collection" do
    # Phase 1: Focus on testing the framework components without full integration
    # This test validates:
    # 1. Scenario orchestration
    # 2. Collector start/stop
    # 3. Analyzer statistics
    # 4. Reporter output

    result =
      Scenario.new("Phase 1 Milestone Test")
      |> Scenario.setup(fn ->
        # Simulate collected data directly for Phase 1
        {:ok, %{chain: "testchain"}}
      end)
      |> Scenario.workload(fn ->
        # Simulate some telemetry events - deterministic for test stability
        for i <- 1..100 do
          :telemetry.execute(
            [:livechain, :battle, :request],
            %{latency: 50 + :rand.uniform(50)},
            %{
              chain: "testchain",
              method: "eth_blockNumber",
              strategy: nil,
              # Only fail on specific requests to ensure we hit 95%
              result: if(i <= 95, do: :success, else: {:error, :timeout}),
              request_id: i
            }
          )

          Process.sleep(10)
        end

        :ok
      end)
      |> Scenario.collect([:requests, :system])
      |> Scenario.slo(success_rate: 0.94)
      |> Scenario.run()

    # Generate reports
    {:ok, json_path} = Reporter.save_json(result, "priv/battle_results/")
    {:ok, md_path} = Reporter.save_markdown(result, "priv/battle_results/")

    # Assertions
    assert result.passed?, """
    Test failed!

    #{result.summary}

    See reports:
    - JSON: #{json_path}
    - Markdown: #{md_path}
    """

    # Verify we collected data
    assert result.analysis.requests.total > 0
    assert result.analysis.requests.success_rate >= 0.90

    # Verify reports were created
    assert File.exists?(json_path)
    assert File.exists?(md_path)

    IO.puts("\n✅ Battle test framework validated!")
    IO.puts("📊 Reports generated:")
    IO.puts("   - #{json_path}")
    IO.puts("   - #{md_path}")
    IO.puts("\n📈 Results:")
    IO.puts("   Total Requests: #{result.analysis.requests.total}")
    IO.puts("   Success Rate: #{Float.round(result.analysis.requests.success_rate * 100, 2)}%")
    IO.puts("   P95 Latency: #{result.analysis.requests.p95_latency_ms}ms")
  end

  test "multiple SLO verification" do
    # Test with multiple SLO checks
    result =
      Scenario.new("Multi-SLO Test")
      |> Scenario.setup(fn ->
        {:ok, %{chain: "ethereum"}}
      end)
      |> Scenario.workload(fn ->
        # Simulate 200 requests with varying latencies
        for i <- 1..200 do
          latency =
            cond do
              i < 190 -> 50 + :rand.uniform(100)
              # P95 should be < 200ms
              true -> 150 + :rand.uniform(100)
              # Last 10 requests slightly higher
            end

          :telemetry.execute(
            [:livechain, :battle, :request],
            %{latency: latency},
            %{
              chain: "ethereum",
              method: "eth_blockNumber",
              strategy: nil,
              result: if(:rand.uniform() > 0.05, do: :success, else: {:error, :timeout}),
              request_id: i
            }
          )
        end

        :ok
      end)
      |> Scenario.collect([:requests, :system])
      |> Scenario.slo(
        success_rate: 0.90,
        p95_latency_ms: 300
      )
      |> Scenario.run()

    # Save reports
    Reporter.save_json(result, "priv/battle_results/")
    Reporter.save_markdown(result, "priv/battle_results/")

    # Verify SLOs
    assert result.passed?, result.summary
    assert result.analysis.requests.success_rate >= 0.90
    assert result.analysis.requests.p95_latency_ms <= 300
  end

  @tag :slow
  test "sustained load simulation" do
    # Simulate sustained load for Phase 1
    result =
      Scenario.new("Sustained Load Test")
      |> Scenario.setup(fn ->
        {:ok, %{chain: "base"}}
      end)
      |> Scenario.workload(fn ->
        # Simulate 1500 requests (50 req/s * 30s)
        for i <- 1..1500 do
          :telemetry.execute(
            [:livechain, :battle, :request],
            %{latency: 60 + :rand.uniform(40)},
            %{
              chain: "base",
              method: "eth_gasPrice",
              strategy: nil,
              result: if(:rand.uniform() > 0.01, do: :success, else: {:error, :timeout}),
              request_id: i
            }
          )

          # Simulate realistic pacing (don't overwhelm telemetry)
          if rem(i, 50) == 0, do: Process.sleep(10)
        end

        :ok
      end)
      |> Scenario.collect([:requests, :system])
      |> Scenario.slo(
        success_rate: 0.98,
        p95_latency_ms: 150,
        max_memory_mb: 1000
      )
      |> Scenario.run()

    Reporter.save_markdown(result, "priv/battle_results/")

    assert result.passed?, result.summary

    # Verify system stayed healthy
    assert result.analysis.system.peak_memory_mb < 1000

    IO.puts("\n📊 Sustained Load Results:")
    IO.puts("   Total Requests: #{result.analysis.requests.total}")
    IO.puts("   Success Rate: #{Float.round(result.analysis.requests.success_rate * 100, 2)}%")
    IO.puts("   P95 Latency: #{result.analysis.requests.p95_latency_ms}ms")
    IO.puts("   Peak Memory: #{Float.round(result.analysis.system.peak_memory_mb, 2)}MB")
  end

  @tag :mixed
  test "circuit breaker events collection" do
    # Test circuit breaker telemetry collection
    result =
      Scenario.new("Circuit Breaker Test")
      |> Scenario.setup(fn ->
        {:ok, %{chain: "optimism"}}
      end)
      |> Scenario.workload(fn ->
        # Simulate circuit breaker state changes
        :telemetry.execute(
          [:livechain, :circuit_breaker, :state_change],
          %{},
          %{
            provider_id: "provider_a",
            old_state: :closed,
            new_state: :open
          }
        )

        Process.sleep(100)

        :telemetry.execute(
          [:livechain, :circuit_breaker, :state_change],
          %{},
          %{
            provider_id: "provider_a",
            old_state: :open,
            new_state: :half_open
          }
        )

        Process.sleep(100)

        :telemetry.execute(
          [:livechain, :circuit_breaker, :state_change],
          %{},
          %{
            provider_id: "provider_a",
            old_state: :half_open,
            new_state: :closed
          }
        )

        # Also generate some requests
        for i <- 1..100 do
          :telemetry.execute(
            [:livechain, :battle, :request],
            %{latency: 60},
            %{
              chain: "optimism",
              method: "eth_blockNumber",
              strategy: nil,
              result: :success,
              request_id: i
            }
          )
        end

        :ok
      end)
      |> Scenario.collect([:requests, :circuit_breaker])
      |> Scenario.slo(success_rate: 0.95)
      |> Scenario.run()

    Reporter.save_markdown(result, "priv/battle_results/")

    assert result.passed?, result.summary

    # Verify circuit breaker events were captured
    assert result.analysis.circuit_breaker.state_changes == 3
    assert result.analysis.circuit_breaker.opens == 1
    assert result.analysis.circuit_breaker.closes == 1
  end
end
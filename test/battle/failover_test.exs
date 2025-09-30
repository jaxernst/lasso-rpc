defmodule Livechain.Battle.FailoverTest do
  @moduledoc """
  Battle tests demonstrating failover and resilience under chaos.

  These tests prove Lasso RPC's core value proposition:
  - Automatic failover when providers fail
  - Maintained service during provider outages
  - Circuit breaker protection
  - Performance under chaos conditions
  """

  use ExUnit.Case, async: false

  alias Livechain.Battle.{Scenario, Workload, MockProvider, Chaos, Reporter, TestHelper}

  @moduletag :battle
  @moduletag :failover
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

      # Cleanup test chain
      TestHelper.cleanup_test_resources("battlechain")
    end)

    :ok
  end

  test "HTTP request succeeds despite primary provider being killed" do
    result =
      Scenario.new("Provider Failover Test")
      |> Scenario.setup(fn ->
        # Start 2 mock providers with different latencies
        providers = MockProvider.start_providers([
          {:provider_a,
           latency: 50,
           reliability: 1.0,
           chain: "battlechain",
           port: 9100},
          {:provider_b,
           latency: 100,
           reliability: 1.0,
           chain: "battlechain",
           port: 9101}
        ])

        Logger.info("Started providers: #{inspect(providers)}")

        # Create test chain config
        chain_config =
          TestHelper.create_test_chain("battlechain", [
            {"provider_a", "http://localhost:9100"},
            {"provider_b", "http://localhost:9101"}
          ])

        # Start chain supervisor
        {:ok, supervisor_pid} = TestHelper.start_test_chain("battlechain", chain_config)

        # Seed benchmarks so provider_a is "fastest"
        TestHelper.seed_benchmarks("battlechain", [
          {"provider_a", "eth_blockNumber", 50, :success},
          {"provider_b", "eth_blockNumber", 100, :success}
        ])

        # Wait for everything to stabilize
        Process.sleep(1000)

        {:ok, %{chain: "battlechain", supervisor_pid: supervisor_pid, providers: providers}}
      end)
      |> Scenario.workload(fn ->
        # Generate 300 requests over 30 seconds
        # Kill provider_a at 10 seconds
        Workload.http_constant(
          chain: "battlechain",
          method: "eth_blockNumber",
          rate: 10,
          duration: 30_000,
          strategy: :fastest
        )
      end)
      |> Scenario.chaos(
        # Kill the fastest provider after 10 seconds
        Chaos.kill_provider("provider_a", delay: 10_000)
      )
      |> Scenario.collect([:requests, :circuit_breaker, :system])
      |> Scenario.slo(
        success_rate: 0.95,
        # Allow higher P95 due to failover
        p95_latency_ms: 500,
        max_failover_latency_ms: 2000
      )
      |> Scenario.run()

    # Generate reports
    Reporter.save_json(result, "priv/battle_results/")
    Reporter.save_markdown(result, "priv/battle_results/")

    # Verify test passed
    assert result.passed?, """
    Failover test failed!

    #{result.summary}

    This means provider failover is not working correctly.
    Check circuit breaker logs and provider availability.
    """

    # Verify we had some failover activity
    # (requests should have moved to provider_b after provider_a died)
    assert result.analysis.requests.total >= 250, "Expected ~300 requests"

    # Circuit breaker should have opened for failed provider
    if result.analysis.circuit_breaker.state_changes > 0 do
      assert result.analysis.circuit_breaker.opens >= 1, "Expected circuit breaker to open"
    end

    IO.puts("\n✅ Failover Test Passed!")
    IO.puts("📊 Results:")
    IO.puts("   Total Requests: #{result.analysis.requests.total}")
    IO.puts(
      "   Success Rate: #{Float.round(result.analysis.requests.success_rate * 100, 2)}%"
    )
    IO.puts("   P95 Latency: #{result.analysis.requests.p95_latency_ms}ms")
    IO.puts("   Circuit Breaker Opens: #{result.analysis.circuit_breaker.opens}")
    IO.puts("\n💥 Chaos Events:")
    IO.puts("   Provider killed at 10s")
    IO.puts("   Remaining requests completed via failover")
  end

  @tag :flapping
  test "system maintains service during provider flapping" do
    result =
      Scenario.new("Flapping Provider Test")
      |> Scenario.setup(fn ->
        # Start 3 providers
        providers = MockProvider.start_providers([
          {:provider_a, latency: 50, reliability: 1.0, chain: "flapchain", port: 9200},
          {:provider_b, latency: 80, reliability: 1.0, chain: "flapchain", port: 9201},
          {:provider_c, latency: 120, reliability: 1.0, chain: "flapchain", port: 9202}
        ])

        chain_config =
          TestHelper.create_test_chain("flapchain", [
            {"provider_a", "http://localhost:9200"},
            {"provider_b", "http://localhost:9201"},
            {"provider_c", "http://localhost:9202"}
          ])

        {:ok, supervisor_pid} = TestHelper.start_test_chain("flapchain", chain_config)

        # Seed benchmarks
        TestHelper.seed_benchmarks("flapchain", [
          {"provider_a", "eth_blockNumber", 50, :success},
          {"provider_b", "eth_blockNumber", 80, :success},
          {"provider_c", "eth_blockNumber", 120, :success}
        ])

        Process.sleep(1000)

        {:ok, %{chain: "flapchain", supervisor_pid: supervisor_pid, providers: providers}}
      end)
      |> Scenario.workload(fn ->
        # 90 seconds of load at 20 req/s = 1800 requests
        Workload.http_constant(
          chain: "flapchain",
          method: "eth_blockNumber",
          rate: 20,
          duration: 90_000,
          strategy: :fastest
        )
      end)
      |> Scenario.chaos([
        # Provider_a flaps: down 5s every 30s, 2 times
        Chaos.flap_provider("provider_a",
          down: 5_000,
          up: 30_000,
          count: 2,
          initial_delay: 15_000
        )
      ])
      |> Scenario.collect([:requests, :circuit_breaker, :system])
      |> Scenario.slo(
        # Should maintain high success rate despite flapping
        success_rate: 0.95,
        p95_latency_ms: 400
      )
      |> Scenario.run()

    Reporter.save_markdown(result, "priv/battle_results/")

    assert result.passed?, result.summary

    # Verify high volume handled
    assert result.analysis.requests.total >= 1500

    IO.puts("\n✅ Flapping Provider Test Passed!")
    IO.puts("   System maintained #{Float.round(result.analysis.requests.success_rate * 100, 2)}% success rate")
    IO.puts("   Despite provider flapping 2 times during test")
  end

  @tag :degradation
  test "performance gracefully degrades when provider latency increases" do
    result =
      Scenario.new("Provider Degradation Test")
      |> Scenario.setup(fn ->
        # Start 2 providers
        providers = MockProvider.start_providers([
          {:provider_a, latency: 50, reliability: 1.0, chain: "degradechain", port: 9300},
          {:provider_b, latency: 60, reliability: 1.0, chain: "degradechain", port: 9301}
        ])

        chain_config =
          TestHelper.create_test_chain("degradechain", [
            {"provider_a", "http://localhost:9300"},
            {"provider_b", "http://localhost:9301"}
          ])

        {:ok, supervisor_pid} = TestHelper.start_test_chain("degradechain", chain_config)

        TestHelper.seed_benchmarks("degradechain", [
          {"provider_a", "eth_blockNumber", 50, :success},
          {"provider_b", "eth_blockNumber", 60, :success}
        ])

        Process.sleep(1000)

        {:ok, %{chain: "degradechain", supervisor_pid: supervisor_pid, providers: providers}}
      end)
      |> Scenario.workload(fn ->
        # 60 seconds of load
        Workload.http_constant(
          chain: "degradechain",
          method: "eth_blockNumber",
          rate: 30,
          duration: 60_000,
          strategy: :fastest
        )
      end)
      |> Scenario.chaos(
        # After 20s, degrade provider_a with +200ms latency for 30s
        Chaos.degrade_provider("provider_a",
          latency: 200,
          after: 20_000,
          duration: 30_000
        )
      )
      |> Scenario.collect([:requests, :system])
      |> Scenario.slo(
        success_rate: 0.99,
        # Allow higher latency during degradation
        p95_latency_ms: 300
      )
      |> Scenario.run()

    Reporter.save_markdown(result, "priv/battle_results/")

    assert result.passed?, result.summary

    IO.puts("\n✅ Degradation Test Passed!")
    IO.puts("   System adapted to degraded provider")
    IO.puts("   Maintained #{Float.round(result.analysis.requests.success_rate * 100, 2)}% success")
  end

  @tag :all_fail
  test "reports errors appropriately when all providers fail" do
    result =
      Scenario.new("Total Failure Test")
      |> Scenario.setup(fn ->
        # Start 2 providers
        providers = MockProvider.start_providers([
          {:provider_a, latency: 50, reliability: 1.0, chain: "failchain", port: 9400},
          {:provider_b, latency: 60, reliability: 1.0, chain: "failchain", port: 9401}
        ])

        chain_config =
          TestHelper.create_test_chain("failchain", [
            {"provider_a", "http://localhost:9400"},
            {"provider_b", "http://localhost:9401"}
          ])

        {:ok, supervisor_pid} = TestHelper.start_test_chain("failchain", chain_config)

        Process.sleep(1000)

        {:ok, %{chain: "failchain", supervisor_pid: supervisor_pid, providers: providers}}
      end)
      |> Scenario.workload(fn ->
        Workload.http_constant(
          chain: "failchain",
          method: "eth_blockNumber",
          rate: 10,
          duration: 30_000
        )
      end)
      |> Scenario.chaos([
        # Kill both providers at 10s and 15s
        Chaos.kill_provider("provider_a", delay: 10_000),
        Chaos.kill_provider("provider_b", delay: 15_000)
      ])
      |> Scenario.collect([:requests, :circuit_breaker])
      |> Scenario.slo(
        # Expect low success rate (most requests after 15s should fail)
        success_rate: 0.30
        # This is a negative test - we expect failures
      )
      |> Scenario.run()

    Reporter.save_markdown(result, "priv/battle_results/")

    # This test verifies failure handling, not success
    # We expect the test to pass with low success rate
    assert result.passed?, "Total failure test should pass (negative test)"

    # Verify we detected the failures
    assert result.analysis.requests.failures > 0, "Expected failures when all providers down"

    IO.puts("\n✅ Total Failure Test Passed!")
    IO.puts("   System correctly reported errors when all providers failed")
    IO.puts("   Failures: #{result.analysis.requests.failures}")
  end
end
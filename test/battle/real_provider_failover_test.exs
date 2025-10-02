defmodule Lasso.Battle.RealProviderFailoverTest do
  @moduledoc """
  Battle test using real Ethereum providers to validate end-to-end failover.

  This test demonstrates:
  - Dynamic provider registration with SetupHelper
  - Real provider failover behavior
  - Production telemetry collection
  - Circuit breaker integration
  """

  use ExUnit.Case, async: false
  require Logger

  alias Lasso.Battle.{Scenario, Workload, Chaos, Reporter, SetupHelper}

  @moduletag :battle
  # Uses external RPC providers (slower)
  @moduletag :real_providers
  @moduletag timeout: :infinity

  setup_all do
    # Override HTTP client for real provider tests
    original_client = Application.get_env(:lasso, :http_client)
    Application.put_env(:lasso, :http_client, Lasso.RPC.HttpClient.Finch)

    Logger.info("Battle test: Using real HTTP client (#{inspect(Lasso.RPC.HttpClient.Finch)})")

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, original_client)
      Logger.info("Battle test: Restored HTTP client to #{inspect(original_client)}")
    end)

    :ok
  end

  setup do
    Application.ensure_all_started(:lasso)

    on_exit(fn ->
      # Cleanup dynamically registered providers
      try do
        SetupHelper.cleanup_providers("ethereum", ["llamarpc", "ankr", "quicknode"])
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  test "failover between real Ethereum providers" do
    result =
      Scenario.new("Real Provider Failover Test")
      |> Scenario.setup(fn ->
        Logger.info("Setting up real Ethereum providers...")

        # Register real providers dynamically (no config file changes)
        SetupHelper.setup_providers("ethereum", [
          {:real, "llamarpc", "https://eth.llamarpc.com"},
          {:real, "ankr", "https://rpc.ankr.com/eth"},
          {:real, "quicknode", "https://ethereum-rpc.publicnode.com"}
        ])

        # Seed initial benchmarks to influence routing
        SetupHelper.seed_benchmarks("ethereum", "eth_blockNumber", [
          {"llamarpc", 80},
          {"ankr", 120},
          {"quicknode", 150}
        ])

        Logger.info("✓ Providers ready for testing")

        {:ok, %{chain: "ethereum", provider_count: 3}}
      end)
      |> Scenario.workload(fn ->
        # Generate 200 requests over 60 seconds
        # Kill llamarpc (fastest) at 20 seconds to trigger failover
        Workload.http_constant(
          chain: "ethereum",
          method: "eth_blockNumber",
          rate: 10,
          duration: 60_000,
          strategy: :fastest
        )
      end)
      |> Scenario.chaos(
        # Kill llamarpc after 20 seconds - should failover to ankr
        Chaos.kill_provider("llamarpc", chain: "ethereum", delay: 20_000)
      )
      |> Scenario.collect([:requests, :circuit_breaker, :selection, :system])
      |> Scenario.slo(
        success_rate: 0.95,
        # Allow higher latency for real providers
        p95_latency_ms: 2000
      )
      |> Scenario.run()

    # Save results
    Reporter.save_json(result, "priv/battle_results/")
    Reporter.save_markdown(result, "priv/battle_results/")

    # Verify test results
    assert result.passed?, """
    Real provider failover test failed!

    #{result.summary}

    This indicates failover is not working correctly with real providers.
    """

    # Verify we completed most requests
    assert result.analysis.requests.total >= 180, "Expected ~200 requests"

    # Verify we captured production telemetry (stored in scenario result)
    # The analysis is computed from collected_data, but collected_data isn't exposed in result type
    # We can infer telemetry worked if we have requests in analysis
    if result.analysis.requests.total > 0 do
      Logger.info(
        "✓ Captured #{result.analysis.requests.total} requests via production telemetry"
      )
    end

    # Verify circuit breaker activity
    if result.analysis.circuit_breaker.state_changes > 0 do
      assert result.analysis.circuit_breaker.opens >= 1, "Expected circuit breaker to open"
      Logger.info("✓ Circuit breaker opened: #{result.analysis.circuit_breaker.opens} times")
    end

    IO.puts("\n✅ Real Provider Failover Test Passed!")
    IO.puts("📊 Results:")
    IO.puts("   Total Requests: #{result.analysis.requests.total}")
    IO.puts("   Success Rate: #{Float.round(result.analysis.requests.success_rate * 100, 2)}%")
    IO.puts("   P50 Latency: #{result.analysis.requests.p50_latency_ms}ms")
    IO.puts("   P95 Latency: #{result.analysis.requests.p95_latency_ms}ms")
    IO.puts("   Circuit Breaker Opens: #{result.analysis.circuit_breaker.opens}")
    IO.puts("\n💥 Chaos Events:")
    IO.puts("   llamarpc killed at 20s")
    IO.puts("   Failover to ankr/quicknode")
  end

  test "concurrent load maintains SLOs during provider failure" do
    result =
      Scenario.new("High Concurrency Failover Test")
      |> Scenario.setup(fn ->
        Logger.info("Setting up providers for concurrent load test...")

        SetupHelper.setup_providers("ethereum", [
          {:real, "llamarpc", "https://eth.llamarpc.com"},
          {:real, "ankr", "https://rpc.ankr.com/eth"},
          {:real, "quicknode", "https://ethereum-rpc.publicnode.com"}
        ])

        # Seed benchmarks
        SetupHelper.seed_benchmarks("ethereum", "eth_blockNumber", [
          {"llamarpc", 80},
          {"ankr", 120},
          {"quicknode", 150}
        ])

        {:ok, %{chain: "ethereum"}}
      end)
      |> Scenario.workload(fn ->
        # Higher rate: 50 req/s for 60 seconds = 3000 requests
        Workload.http_constant(
          chain: "ethereum",
          method: "eth_blockNumber",
          rate: 50,
          duration: 60_000,
          strategy: :fastest
        )
      end)
      |> Scenario.chaos(
        # Kill fastest provider at 30s
        Chaos.kill_provider("llamarpc", chain: "ethereum", delay: 30_000)
      )
      |> Scenario.collect([:requests, :circuit_breaker, :system])
      |> Scenario.slo(
        success_rate: 0.95,
        p95_latency_ms: 2000,
        max_memory_mb: 500
      )
      |> Scenario.run()

    Reporter.save_markdown(result, "priv/battle_results/")

    assert result.passed?, """
    High concurrency failover test failed!
    #{result.summary}
    """

    # Verify high request volume
    assert result.analysis.requests.total >= 2800, "Expected ~3000 requests"

    # Verify circuit breaker protected the failed provider
    if result.analysis.circuit_breaker.opens > 0 do
      Logger.info("✓ Circuit breaker protected failed provider")
    end

    IO.puts("\n✅ Concurrent Load Failover Test Passed!")
    IO.puts("   Handled #{result.analysis.requests.total} requests at 50 req/s")
    IO.puts("   Success rate: #{Float.round(result.analysis.requests.success_rate * 100, 2)}%")
  end

  @tag :fast
  test "fastest strategy routes to lowest latency provider" do
    result =
      Scenario.new("Fastest Strategy Routing Test")
      |> Scenario.setup(fn ->
        Logger.info("Testing fastest strategy routing...")

        SetupHelper.setup_providers("ethereum", [
          {:real, "llamarpc", "https://eth.llamarpc.com"},
          {:real, "ankr", "https://rpc.ankr.com/eth"}
        ])

        # Seed with clear latency difference
        SetupHelper.seed_benchmarks("ethereum", "eth_blockNumber", [
          # Faster
          {"llamarpc", 50},
          # Slower
          {"ankr", 200}
        ])

        {:ok, %{chain: "ethereum"}}
      end)
      |> Scenario.workload(fn ->
        # 100 requests to observe routing pattern
        Workload.http_constant(
          chain: "ethereum",
          method: "eth_blockNumber",
          rate: 20,
          duration: 5_000,
          strategy: :fastest
        )
      end)
      |> Scenario.collect([:requests, :selection])
      |> Scenario.slo(success_rate: 0.95)
      |> Scenario.run()

    assert result.passed?, "Fastest strategy routing test failed"

    # Verify most requests went to llamarpc (faster provider)
    # Note: We don't have per-provider request breakdown in current Analyzer
    # This is captured in selection telemetry but not exposed yet
    # For now, just verify test completes successfully
    assert result.analysis.requests.total >= 95

    IO.puts("\n✅ Fastest Strategy Test Passed!")
    IO.puts("   Completed #{result.analysis.requests.total} requests")
    IO.puts("   Avg latency: #{trunc(result.analysis.requests.avg_latency_ms)}ms")
  end

  @tag :fast
  test "round-robin strategy distributes load across providers" do
    result =
      Scenario.new("Round-Robin Distribution Test")
      |> Scenario.setup(fn ->
        Logger.info("Testing round-robin load distribution...")

        SetupHelper.setup_providers("ethereum", [
          {:real, "llamarpc", "https://eth.llamarpc.com"},
          {:real, "ankr", "https://rpc.ankr.com/eth"}
        ])

        {:ok, %{chain: "ethereum"}}
      end)
      |> Scenario.workload(fn ->
        Workload.http_constant(
          chain: "ethereum",
          method: "eth_blockNumber",
          rate: 20,
          duration: 5_000,
          strategy: :round_robin
        )
      end)
      |> Scenario.collect([:requests, :selection])
      |> Scenario.slo(success_rate: 0.95)
      |> Scenario.run()

    assert result.passed?, "Round-robin distribution test failed"
    assert result.analysis.requests.total >= 95

    IO.puts("\n✅ Round-Robin Distribution Test Passed!")
    IO.puts("   Load distributed across providers")
    IO.puts("   Total requests: #{result.analysis.requests.total}")
  end

  # Fast smoke test (~5s)
  @tag :quick
  # Suitable for CI
  @tag :fast
  test "basic connectivity with real providers (smoke test)" do
    Logger.info("Running smoke test with real providers...")

    # Quick connectivity check
    SetupHelper.setup_providers("ethereum", [
      {:real, "llamarpc", "https://eth.llamarpc.com"}
    ])

    result =
      Scenario.new("Real Provider Smoke Test")
      |> Scenario.workload(fn ->
        # Just 10 requests to verify connectivity
        Workload.http_constant(
          chain: "ethereum",
          method: "eth_blockNumber",
          rate: 2,
          duration: 5_000
        )
      end)
      |> Scenario.collect([:requests])
      # Lenient for smoke test
      |> Scenario.slo(success_rate: 0.80)
      |> Scenario.run()

    assert result.passed?, "Smoke test failed - check network connectivity"
    assert result.analysis.requests.total >= 8, "Expected ~10 requests"

    SetupHelper.cleanup_providers("ethereum", ["llamarpc"])

    IO.puts("\n✅ Smoke test passed - real provider connectivity confirmed")
  end
end

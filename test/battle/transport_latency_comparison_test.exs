defmodule Lasso.Battle.TransportLatencyComparisonTest do
  @moduledoc """
  Transport latency benchmarking test to compare HTTP vs WebSocket.

  ## Methodology

  This test implements rigorous statistical methodology by isolating the transport variable:

  1. **Single Provider Focus:** Tests one provider at a time with NO failover
     - Ensures HTTP and WebSocket are tested against identical infrastructure
     - Eliminates provider performance variance from comparison
     - Change @test_provider to benchmark different providers

  2. **Fair Comparison:** Uses `Workload.direct()` with `provider_override` and `failover_on_override: false`
     - Identical code paths except for transport layer
     - No fallback to other providers
     - Forces exclusive use of specified provider

  3. **Statistical Power:** 300 samples per transport per method (600 total per transport)
     - Sufficient for reliable P95/P99 and significance testing
     - Light load avoids rate limiting

  4. **Warmup Phase:** 10-second warmup eliminates cold start effects
     (connection establishment, DNS resolution, TLS handshake)

  5. **Statistical Analysis:**
     - Standard deviation and 95% confidence intervals
     - Provider distribution verification (should be 100% single provider)
     - Mann-Whitney U test for statistical significance (p < 0.05)

  ## Usage

  To test different providers, change @test_provider:
  - "llamarpc" - LlamaNodes
  - "ankr" - Ankr
  - "publicnode" - PublicNode
  - "blockpi" - BlockPI
  - Or add your own provider to @available_providers

  ## Expected Results

  - WebSocket should show significantly lower latency (p < 0.05)
  - Provider distribution: 100% to test provider (balance score = 1.0)
  - Statistical significance confirmed by Mann-Whitney U test
  """

  use ExUnit.Case, async: false
  require Logger

  alias Lasso.Battle.{Scenario, Workload, Reporter, SetupHelper}

  @moduletag :battle
  @moduletag :transport_bench
  @moduletag :real_providers
  @moduletag timeout: :infinity

  @chain "ethereum"

  # Test methods: simple queries only to minimize response size variance
  @methods ["eth_blockNumber", "eth_chainId"]

  # Available providers with both HTTP and WebSocket support
  @available_providers %{
    "llamarpc" => {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"},
    "ankr" => {:real, "ankr", "https://rpc.ankr.com/eth", "wss://rpc.ankr.com/eth/ws"},
    "publicnode" =>
      {:real, "publicnode", "https://ethereum-rpc.publicnode.com",
       "wss://ethereum-rpc.publicnode.com"},
    "blockpi" =>
      {:real, "blockpi", "https://ethereum.blockpi.network/v1/rpc/public",
       "wss://ethereum.blockpi.network/v1/ws/public"}
  }

  # CONFIGURE THIS: Provider to test (must have both HTTP and WebSocket)
  # Options: "llamarpc", "ankr", "publicnode", "blockpi"
  @test_provider "publicnode"

  # Light load configuration to avoid rate limits
  # req/s during warmup
  @warmup_rate 1
  # ms
  @warmup_duration 10_000
  # req/s during measurement
  @test_rate 5
  # ms (60s @ 5 req/s = 300 samples per transport per method)
  @test_duration 60_000

  setup_all do
    # Override HTTP client for real provider tests
    original_client = Application.get_env(:lasso, :http_client)
    Application.put_env(:lasso, :http_client, Lasso.RPC.HttpClient.Finch)

    # Use real WebSockex client (override global mock from test_helper)
    prev_ws_client = Application.get_env(:lasso, :ws_client_module)
    Application.put_env(:lasso, :ws_client_module, WebSockex)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, original_client)
      Application.put_env(:lasso, :ws_client_module, prev_ws_client)
    end)

    :ok
  end

  setup do
    Application.ensure_all_started(:lasso)

    on_exit(fn ->
      try do
        SetupHelper.cleanup_providers(@chain, [@test_provider])
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  test "transport latency comparison: HTTP vs WebSocket on single provider" do
    # Verify real WebSocket client is configured
    ws_mod = Application.get_env(:lasso, :ws_client_module)
    assert ws_mod == WebSockex, "Battle test requires real WebSockex; got #{inspect(ws_mod)}"

    provider_config = Map.fetch!(@available_providers, @test_provider)

    result =
      Scenario.new("Transport Latency: HTTP vs WebSocket [@#{@test_provider}]")
      |> Scenario.setup(fn ->
        Logger.info("Setting up single provider for isolated transport comparison...")
        Logger.info("Provider: #{@test_provider}")
        Logger.info("Configuration: #{inspect(provider_config)}")

        # Setup single provider with both HTTP and WebSocket
        SetupHelper.setup_providers(@chain, [provider_config])

        Logger.info("✓ Provider configured for transport benchmarking")
        Logger.info("✓ Failover disabled - testing single provider only")

        {:ok,
         %{
           chain: @chain,
           provider: @test_provider,
           method_count: length(@methods),
           sample_size_per_transport: @test_rate * (@test_duration / 1000) * length(@methods)
         }}
      end)
      |> Scenario.workload(fn ->
        Logger.info("Starting single-provider transport comparison...")
        Logger.info("Provider: #{@test_provider} | Methods: #{inspect(@methods)}")

        # WARMUP PHASE: Establish connections and warm caches
        Logger.info(
          "🔥 Warmup phase: #{@warmup_duration / 1000}s at #{@warmup_rate} req/s per transport..."
        )

        warmup_tasks =
          Enum.flat_map(@methods, fn method ->
            params = get_params_for_method(method)

            [
              Task.async(fn ->
                http_fn = fn ->
                  Workload.direct(@chain, method, params,
                    transport: :http,
                    provider_override: @test_provider,
                    failover_on_override: false
                  )
                end

                Workload.constant(http_fn, rate: @warmup_rate, duration: @warmup_duration)
              end),
              Task.async(fn ->
                ws_fn = fn ->
                  Workload.direct(@chain, method, params,
                    transport: :ws,
                    provider_override: @test_provider,
                    failover_on_override: false
                  )
                end

                Workload.constant(ws_fn, rate: @warmup_rate, duration: @warmup_duration)
              end)
            ]
          end)

        Task.await_many(warmup_tasks, @warmup_duration * 2)
        Logger.info("✓ Warmup complete")

        # MEASUREMENT PHASE
        # - Single provider with NO failover
        # - 60s @ 5 req/s = 300 samples per transport per method (600 total per transport)
        # - Light load avoids rate limiting
        # - Identical infrastructure, only transport differs

        Logger.info(
          "📊 Measurement phase: #{@test_duration / 1000}s at #{@test_rate} req/s per transport..."
        )

        measurement_tasks =
          Enum.flat_map(@methods, fn method ->
            params = get_params_for_method(method)

            [
              # HTTP upstream routing - LOCKED to test provider
              Task.async(fn ->
                http_fn = fn ->
                  Workload.direct(@chain, method, params,
                    transport: :http,
                    provider_override: @test_provider,
                    failover_on_override: false
                  )
                end

                Workload.constant(http_fn, rate: @test_rate, duration: @test_duration)
              end),
              # WebSocket upstream routing - LOCKED to test provider
              Task.async(fn ->
                ws_fn = fn ->
                  Workload.direct(@chain, method, params,
                    transport: :ws,
                    provider_override: @test_provider,
                    failover_on_override: false
                  )
                end

                Workload.constant(ws_fn, rate: @test_rate, duration: @test_duration)
              end)
            ]
          end)

        Task.await_many(measurement_tasks, @test_duration * 2)

        Logger.info("✓ All workloads completed")
        :ok
      end)
      |> Scenario.collect([:requests, :system])
      |> Scenario.slo(
        # Success rate: Allow 5% failures for real provider variability
        success_rate: 0.95
        # Note: No latency SLOs - we're comparing transports, not validating absolute performance
      )
      |> Scenario.run()

    # Save detailed reports
    Reporter.save_json(result, "priv/battle_results/")
    Reporter.save_markdown(result, "priv/battle_results/")

    # Assert SLOs passed
    assert result.passed?, """
    Transport latency benchmark failed SLO requirements!

    #{result.summary}
    """

    # Extract transport-specific metrics
    http_stats = result.analysis.requests_by_transport.http
    ws_stats = result.analysis.requests_by_transport.ws
    stat_test = result.analysis.requests_by_transport.statistical_comparison

    # Print detailed summary
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("✅ TRANSPORT LATENCY COMPARISON COMPLETE")
    IO.puts(String.duplicate("=", 80))
    IO.puts("\n📋 Test Configuration:")
    IO.puts("   Provider: #{@test_provider}")
    IO.puts("   Methods: #{inspect(@methods)}")
    IO.puts("   Sample Size: #{http_stats.total} HTTP, #{ws_stats.total} WebSocket")
    IO.puts("   Total Requests: #{result.analysis.requests.total}")

    IO.puts("\n🔴 HTTP Transport:")
    IO.puts("   P50: #{http_stats.p50_latency_ms}ms")
    IO.puts("   P95: #{http_stats.p95_latency_ms}ms")
    IO.puts("   P99: #{http_stats.p99_latency_ms}ms")

    IO.puts(
      "   Avg: #{Float.round(http_stats.avg_latency_ms, 2)}ms ± #{Float.round(http_stats.stddev_latency_ms, 2)}ms"
    )

    http_dist = http_stats.provider_distribution

    http_primary =
      http_dist.by_provider
      |> Enum.max_by(fn {_, %{count: c}} -> c end)
      |> then(fn {name, %{percentage: pct}} -> "#{name} (#{Float.round(pct, 1)}%)" end)

    IO.puts("   Provider: #{http_primary} | Balance: #{http_dist.balance_score}")

    IO.puts("\n🟢 WebSocket Transport:")
    IO.puts("   P50: #{ws_stats.p50_latency_ms}ms")
    IO.puts("   P95: #{ws_stats.p95_latency_ms}ms")
    IO.puts("   P99: #{ws_stats.p99_latency_ms}ms")

    IO.puts(
      "   Avg: #{Float.round(ws_stats.avg_latency_ms, 2)}ms ± #{Float.round(ws_stats.stddev_latency_ms, 2)}ms"
    )

    ws_dist = ws_stats.provider_distribution

    ws_primary =
      ws_dist.by_provider
      |> Enum.max_by(fn {_, %{count: c}} -> c end)
      |> then(fn {name, %{percentage: pct}} -> "#{name} (#{Float.round(pct, 1)}%)" end)

    IO.puts("   Provider: #{ws_primary} | Balance: #{ws_dist.balance_score}")

    IO.puts("\n⚡ Performance Difference:")
    ws_faster_p50 = http_stats.p50_latency_ms - ws_stats.p50_latency_ms
    ws_faster_p95 = http_stats.p95_latency_ms - ws_stats.p95_latency_ms

    speedup_p50 =
      if ws_stats.p50_latency_ms > 0 do
        Float.round(http_stats.p50_latency_ms / ws_stats.p50_latency_ms, 1)
      else
        "∞"
      end

    ws_faster_p50_str =
      if is_float(ws_faster_p50), do: Float.round(ws_faster_p50, 2), else: ws_faster_p50

    ws_faster_p95_str =
      if is_float(ws_faster_p95), do: Float.round(ws_faster_p95, 2), else: ws_faster_p95

    IO.puts("   P50: WebSocket #{ws_faster_p50_str}ms faster (#{speedup_p50}x speedup)")
    IO.puts("   P95: WebSocket #{ws_faster_p95_str}ms faster")

    IO.puts("\n📊 Statistical Significance:")
    IO.puts("   p-value: #{stat_test.p_value}")
    IO.puts("   Z-score: #{stat_test.z_score}")
    IO.puts("   Result: #{stat_test.interpretation}")

    IO.puts("\n📈 Full report: priv/battle_results/latest.md")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  # Helper to provide appropriate params for each method
  defp get_params_for_method("eth_getBalance"),
    do: ["0x0000000000000000000000000000000000000000", "latest"]

  defp get_params_for_method("eth_getTransactionCount"),
    do: ["0x0000000000000000000000000000000000000000", "latest"]

  defp get_params_for_method("eth_getBlockByNumber"), do: ["latest", false]

  defp get_params_for_method("eth_call") do
    [
      %{
        "to" => "0x0000000000000000000000000000000000000000",
        "data" => "0x"
      },
      "latest"
    ]
  end

  defp get_params_for_method("eth_estimateGas") do
    [
      %{
        "to" => "0x0000000000000000000000000000000000000000",
        "data" => "0x"
      }
    ]
  end

  defp get_params_for_method("eth_getLogs") do
    [
      %{
        "fromBlock" => "latest",
        "toBlock" => "latest"
      }
    ]
  end

  defp get_params_for_method(_method), do: []
end

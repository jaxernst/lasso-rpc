defmodule Lasso.Battle.TransportLatencyComparisonTest do
  @moduledoc """
  End-to-end smoke test comparing WebSocket vs HTTP latencies for common RPC methods.

  This test:
  1. Sets up real providers with both HTTP and WebSocket endpoints
  2. Executes multiple requests for each method using both transports
  3. Queries BenchmarkStore directly to compare transport-specific latencies
  4. Reports the results in a readable format
  """

  use ExUnit.Case, async: false
  require Logger

  alias Lasso.Battle.SetupHelper
  alias Lasso.RPC.RequestPipeline
  alias Lasso.RPC.Metrics
  alias Lasso.Benchmarking.BenchmarkStore

  @moduletag :battle
  @moduletag :transport_bench
  @moduletag :real_providers
  @moduletag timeout: 180_000

  @chain "ethereum"
  @methods ["eth_blockNumber", "eth_chainId", "eth_gasPrice"]
  @requests_per_method_per_transport 20

  setup_all do
    # Override HTTP client for real provider tests
    original_client = Application.get_env(:lasso, :http_client)
    Application.put_env(:lasso, :http_client, Lasso.RPC.HttpClient.Finch)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, original_client)
    end)

    :ok
  end

  setup do
    Application.ensure_all_started(:lasso)

    # Clear any existing metrics to get clean data
    BenchmarkStore.clear_chain_metrics(@chain)

    on_exit(fn ->
      try do
        SetupHelper.cleanup_providers(@chain, ["llamarpc", "ankr"])
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  test "HTTP vs WebSocket latency comparison for common RPC methods" do
    # Setup providers with both HTTP and WebSocket URLs
    SetupHelper.setup_providers(@chain, [
      {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"},
      {:real, "ankr", "https://rpc.ankr.com/eth", "wss://rpc.ankr.com/eth/ws"}
    ])

    Logger.info("\n" <> String.duplicate("=", 80))
    Logger.info("🚀 Starting Transport Latency Comparison Test")
    Logger.info(String.duplicate("=", 80))

    # Execute requests for each method and transport
    results =
      Enum.reduce(@methods, %{}, fn method, acc ->
        Logger.info("\n📊 Testing method: #{method}")

        # HTTP requests
        Logger.info("  → Running #{@requests_per_method_per_transport} HTTP requests...")
        http_start = System.monotonic_time(:millisecond)

        http_results =
          for i <- 1..@requests_per_method_per_transport do
            result =
              RequestPipeline.execute_via_channels(
                @chain,
                method,
                [],
                transport_override: :http,
                strategy: :round_robin,
                timeout: 10_000
              )

            if rem(i, 5) == 0 do
              Logger.info("    HTTP: #{i}/#{@requests_per_method_per_transport} completed")
            end

            # Small delay to avoid rate limiting
            Process.sleep(100)
            result
          end

        http_duration = System.monotonic_time(:millisecond) - http_start
        http_successes = Enum.count(http_results, fn {status, _} -> status == :ok end)

        Logger.info(
          "    ✅ HTTP: #{http_successes}/#{@requests_per_method_per_transport} succeeded in #{http_duration}ms"
        )

        # WebSocket requests
        Logger.info("  → Running #{@requests_per_method_per_transport} WebSocket requests...")
        ws_start = System.monotonic_time(:millisecond)

        ws_results =
          for i <- 1..@requests_per_method_per_transport do
            result =
              RequestPipeline.execute_via_channels(
                @chain,
                method,
                [],
                transport_override: :ws,
                strategy: :round_robin,
                timeout: 10_000
              )

            if rem(i, 5) == 0 do
              Logger.info("    WS: #{i}/#{@requests_per_method_per_transport} completed")
            end

            # Small delay to avoid overwhelming the connection
            Process.sleep(100)
            result
          end

        ws_duration = System.monotonic_time(:millisecond) - ws_start
        ws_successes = Enum.count(ws_results, fn {status, _} -> status == :ok end)

        Logger.info(
          "    ✅ WS: #{ws_successes}/#{@requests_per_method_per_transport} succeeded in #{ws_duration}ms"
        )

        Map.put(acc, method, %{
          http_results: http_results,
          http_successes: http_successes,
          ws_results: ws_results,
          ws_successes: ws_successes
        })
      end)

    # Allow a moment for async metrics to be recorded
    Process.sleep(500)

    # Query BenchmarkStore for transport-specific metrics
    Logger.info("\n" <> String.duplicate("=", 80))
    Logger.info("📈 TRANSPORT LATENCY COMPARISON RESULTS")
    Logger.info(String.duplicate("=", 80))

    comparison_results =
      Enum.flat_map(@methods, fn method ->
        Logger.info("\n🔍 Method: #{method}")
        Logger.info(String.duplicate("-", 80))

        # Get metrics for each provider and transport
        providers = ["llamarpc", "ankr"]

        Enum.flat_map(providers, fn provider_id ->
          http_perf =
            Metrics.get_provider_transport_performance(@chain, provider_id, method, :http)

          ws_perf = Metrics.get_provider_transport_performance(@chain, provider_id, method, :ws)

          Logger.info("\n  Provider: #{provider_id}")

          if http_perf do
            Logger.info("    HTTP:")
            Logger.info("      Latency: #{Float.round(http_perf.latency_ms, 2)}ms")
            Logger.info("      Success Rate: #{Float.round(http_perf.success_rate * 100, 2)}%")
            Logger.info("      Total Calls: #{http_perf.total_calls}")
          else
            Logger.info("    HTTP: No data recorded")
          end

          if ws_perf do
            Logger.info("    WebSocket:")
            Logger.info("      Latency: #{Float.round(ws_perf.latency_ms, 2)}ms")
            Logger.info("      Success Rate: #{Float.round(ws_perf.success_rate * 100, 2)}%")
            Logger.info("      Total Calls: #{ws_perf.total_calls}")
          else
            Logger.info("    WebSocket: No data recorded")
          end

          # Calculate comparison
          if http_perf && ws_perf do
            diff = ws_perf.latency_ms - http_perf.latency_ms
            diff_pct = (diff / http_perf.latency_ms * 100) |> Float.round(2)

            faster_transport = if diff < 0, do: "WebSocket", else: "HTTP"
            faster_by = abs(diff) |> Float.round(2)

            Logger.info(
              "    🏆 Winner: #{faster_transport} (faster by #{faster_by}ms / #{abs(diff_pct)}%)"
            )

            [
              %{
                method: method,
                provider: provider_id,
                http_latency: http_perf.latency_ms,
                ws_latency: ws_perf.latency_ms,
                faster: faster_transport,
                diff_ms: faster_by
              }
            ]
          else
            []
          end
        end)
      end)

    # Summary
    Logger.info("\n" <> String.duplicate("=", 80))
    Logger.info("📊 SUMMARY")
    Logger.info(String.duplicate("=", 80))

    if length(comparison_results) > 0 do
      http_wins = Enum.count(comparison_results, fn r -> r.faster == "HTTP" end)
      ws_wins = Enum.count(comparison_results, fn r -> r.faster == "WebSocket" end)
      total = length(comparison_results)

      avg_http_latency =
        comparison_results
        |> Enum.map(& &1.http_latency)
        |> Enum.sum()
        |> Kernel./(total)
        |> Float.round(2)

      avg_ws_latency =
        comparison_results
        |> Enum.map(& &1.ws_latency)
        |> Enum.sum()
        |> Kernel./(total)
        |> Float.round(2)

      Logger.info("\nTotal Comparisons: #{total}")
      Logger.info("  HTTP Wins: #{http_wins} (#{Float.round(http_wins / total * 100, 1)}%)")
      Logger.info("  WebSocket Wins: #{ws_wins} (#{Float.round(ws_wins / total * 100, 1)}%)")
      Logger.info("\nAverage Latencies:")
      Logger.info("  HTTP: #{avg_http_latency}ms")
      Logger.info("  WebSocket: #{avg_ws_latency}ms")

      overall_faster = if avg_ws_latency < avg_http_latency, do: "WebSocket", else: "HTTP"
      overall_diff = abs(avg_ws_latency - avg_http_latency) |> Float.round(2)

      Logger.info("\n🏆 Overall Winner: #{overall_faster} (faster by #{overall_diff}ms)")
    else
      Logger.warning("⚠️  No comparison data available - metrics may not have been recorded")
    end

    Logger.info("\n" <> String.duplicate("=", 80))
    Logger.info("✅ Test Complete")
    Logger.info(String.duplicate("=", 80) <> "\n")

    # Assertions
    for method <- @methods do
      method_results = Map.get(results, method)
      assert method_results.http_successes > 0, "HTTP requests for #{method} should succeed"
      assert method_results.ws_successes > 0, "WebSocket requests for #{method} should succeed"
    end

    # At least some metrics should be recorded
    assert length(comparison_results) > 0,
           "Should have recorded transport-specific metrics in BenchmarkStore"
  end
end

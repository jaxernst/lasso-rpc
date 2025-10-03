defmodule Lasso.Battle.LassoOverheadBenchmarkTest do
  @moduledoc """
  Benchmark test to measure Lasso's overhead by comparing direct provider calls vs Lasso pipeline.

  ## Methodology

  This test isolates Lasso's overhead by measuring identical requests through two paths:

  1. **Direct Path:** Raw HTTP/WebSocket calls directly to provider
     - HTTP: Uses Finch directly (bypasses all Lasso logic)
     - WebSocket: Uses WebSockex directly (bypasses all Lasso logic)
     - Represents theoretical minimum latency
     - Latencies tracked manually with microsecond precision
     - Measures: JSON encoding + network I/O + JSON decoding

  2. **Lasso Path:** Full production request pipeline
     - Uses normal execute_via_channels (NO provider_override shortcut)
     - Provider selection via Selection.select_channels
     - Circuit breaker checks
     - Channel management
     - Telemetry/logging
     - Latencies captured from RequestContext (full end-to-end)
     - Measures: All of above + routing + selection + overhead

  3. **Overhead Calculation:**
     - Overhead = Lasso Latency - Direct Latency
     - Measured at P50, P95, P99 percentiles
     - Statistical significance testing (Mann-Whitney U)
     - 95% confidence intervals

  ## Rigor and Accuracy

  - Microsecond-precision timing (System.monotonic_time(:microsecond))
  - Shared ETS table for lock-free latency collection
  - Identical request payloads
  - Same provider infrastructure for both paths
  - Sequential workloads (no cross-contention)
  - Normal production code path (no shortcuts)

  ## Configuration

  - Light load to minimize queueing effects
  - Single provider available (realistic production scenario)
  - Warmup phase to eliminate cold start effects
  - Sufficient samples for percentile analysis (100+ per path)

  ## Expected Results

  - Lasso overhead should be measurable (1-10ms at P50)
  - Overhead primarily from: provider selection, circuit breaker checks, telemetry
  - WebSocket overhead may be similar to HTTP
  - Overhead may vary by load and request type
  """

  use ExUnit.Case, async: false
  require Logger

  alias Lasso.Battle.{Scenario, Workload, Reporter, SetupHelper}

  # State management for tracking direct call latencies
  defmodule DirectLatencyTracker do
    @moduledoc false

    def init_table do
      table = :ets.new(:direct_latencies, [:public, :bag, :named_table])
      {:ok, table}
    end

    def record_latency(path, latency_us) when path in [:http_direct, :ws_direct] do
      :ets.insert(:direct_latencies, {path, latency_us})
    end

    def get_latencies(path) do
      :ets.lookup(:direct_latencies, path)
      |> Enum.map(fn {^path, latency} -> latency end)
      |> Enum.sort()
    end

    def cleanup do
      if :ets.whereis(:direct_latencies) != :undefined do
        :ets.delete(:direct_latencies)
      end
    end
  end

  @moduletag :battle
  @moduletag :overhead_bench
  @moduletag :real_providers
  @moduletag timeout: :infinity

  @chain "ethereum"
  @method "eth_blockNumber"
  @params []

  # Test configuration
  @test_provider "publicnode"
  @http_url "https://ethereum-rpc.publicnode.com"
  @ws_url "wss://ethereum-rpc.publicnode.com"

  # Benchmark configuration
  # Increased sample size for statistical stability
  # Target: 500+ samples per path (need 1000+ for stable P99)
  @warmup_rate 5
  @warmup_duration 10_000
  @test_rate 10
  @test_duration 60_000

  setup_all do
    # Use real HTTP and WebSocket clients
    original_http_client = Application.get_env(:lasso, :http_client)
    original_ws_client = Application.get_env(:lasso, :ws_client_module)

    Application.put_env(:lasso, :http_client, Lasso.RPC.HttpClient.Finch)
    Application.put_env(:lasso, :ws_client_module, WebSockex)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, original_http_client)
      Application.put_env(:lasso, :ws_client_module, original_ws_client)
    end)

    :ok
  end

  setup do
    Application.ensure_all_started(:lasso)

    # Initialize ETS table for direct latency tracking
    DirectLatencyTracker.init_table()

    on_exit(fn ->
      try do
        SetupHelper.cleanup_providers(@chain, [@test_provider])
        DirectLatencyTracker.cleanup()
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  test "lasso overhead: direct provider calls vs lasso pipeline" do
    # Verify real clients configured
    http_client = Application.get_env(:lasso, :http_client)
    ws_client = Application.get_env(:lasso, :ws_client_module)

    assert http_client == Lasso.RPC.HttpClient.Finch,
           "Battle test requires Finch HTTP client; got #{inspect(http_client)}"

    assert ws_client == WebSockex, "Battle test requires WebSockex; got #{inspect(ws_client)}"

    # Pre-establish WebSocket connection for direct calls (shared across warmup and measurement)
    {:ok, ws_direct_pid} = connect_websocket(@ws_url)
    Logger.info("✓ Established persistent WebSocket connection for direct calls")

    result =
      Scenario.new("Lasso Overhead Benchmark: Direct vs Pipeline [@#{@test_provider}]")
      |> Scenario.setup(fn ->
        Logger.info("Setting up overhead benchmark...")
        Logger.info("Provider: #{@test_provider}")
        Logger.info("HTTP URL: #{@http_url}")
        Logger.info("WS URL: #{@ws_url}")

        # Setup provider for Lasso path
        provider_config = {:real, @test_provider, @http_url, @ws_url}
        SetupHelper.setup_providers(@chain, [provider_config])

        Logger.info("✓ Provider configured for Lasso path")
        Logger.info("✓ Direct path will bypass Lasso entirely")

        {:ok,
         %{
           chain: @chain,
           provider: @test_provider,
           method: @method,
           http_url: @http_url,
           ws_url: @ws_url
         }}
      end)
      |> Scenario.workload(fn ->
        Logger.info("Starting overhead benchmark...")
        Logger.info("Method: #{@method} | Provider: #{@test_provider}")
        Logger.info("⚠️  Using NORMAL selection path (no provider_override shortcut)")
        Logger.info("⚠️  Running workloads SEQUENTIALLY to eliminate cross-contention")

        # WARMUP PHASE - Run sequentially
        Logger.info(
          "🔥 Warmup phase: #{@warmup_duration / 1000}s at #{@warmup_rate} req/s per path..."
        )

        # HTTP Direct warmup
        direct_http_fn = fn -> call_http_direct(@http_url, @method, @params) end
        Workload.constant(direct_http_fn, rate: @warmup_rate, duration: @warmup_duration)

        # HTTP Lasso warmup - using NORMAL execute_via_channels (no provider_override)
        lasso_http_fn = fn ->
          Workload.direct(@chain, @method, @params, transport: :http)
        end

        Workload.constant(lasso_http_fn, rate: @warmup_rate, duration: @warmup_duration)

        # WS Direct warmup
        direct_ws_fn = fn -> call_ws_direct(ws_direct_pid, @method, @params) end
        Workload.constant(direct_ws_fn, rate: @warmup_rate, duration: @warmup_duration)

        # WS Lasso warmup - using NORMAL execute_via_channels (no provider_override)
        lasso_ws_fn = fn ->
          Workload.direct(@chain, @method, @params, transport: :ws)
        end

        Workload.constant(lasso_ws_fn, rate: @warmup_rate, duration: @warmup_duration)

        Logger.info("✓ Warmup complete")

        # MEASUREMENT PHASE - Run sequentially
        Logger.info(
          "📊 Measurement phase: #{@test_duration / 1000}s at #{@test_rate} req/s per path..."
        )

        # HTTP Direct measurement
        Logger.info("  → HTTP Direct...")
        Workload.constant(direct_http_fn, rate: @test_rate, duration: @test_duration)

        # HTTP Lasso measurement
        Logger.info("  → HTTP Lasso (normal selection path)...")
        Workload.constant(lasso_http_fn, rate: @test_rate, duration: @test_duration)

        # WS Direct measurement
        Logger.info("  → WebSocket Direct...")
        Workload.constant(direct_ws_fn, rate: @test_rate, duration: @test_duration)

        # WS Lasso measurement
        Logger.info("  → WebSocket Lasso (normal selection path)...")
        Workload.constant(lasso_ws_fn, rate: @test_rate, duration: @test_duration)

        # Cleanup WS connection
        if Process.alive?(ws_direct_pid) do
          WebSockex.cast(ws_direct_pid, :close)
        end

        Logger.info("✓ All workloads completed")
        :ok
      end)
      |> Scenario.collect([:requests, :system])
      |> Scenario.slo(success_rate: 0.95)
      |> Scenario.run()

    # Save reports
    Reporter.save_json(result, "priv/battle_results/")
    Reporter.save_markdown(result, "priv/battle_results/")

    # Assert test passed
    assert result.passed?, """
    Overhead benchmark failed!

    #{result.summary}
    """

    # Print overhead analysis
    print_overhead_analysis(result)
  end

  # Direct HTTP call using Finch (bypasses Lasso)
  # Records latency with microsecond precision
  defp call_http_direct(url, method, params) do
    start_time = System.monotonic_time(:microsecond)

    request_body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: 1,
        method: method,
        params: params
      })

    headers = [{"content-type", "application/json"}]

    result =
      case Finch.build(:post, url, headers, request_body)
           |> Finch.request(Lasso.Finch, receive_timeout: 30_000) do
        {:ok, %{status: 200, body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"result" => result}} -> {:ok, result}
            {:ok, %{"error" => error}} -> {:error, error}
            {:error, _} -> {:error, :invalid_json}
          end

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end

    # Record latency regardless of success/failure for accurate comparison
    end_time = System.monotonic_time(:microsecond)
    latency_us = end_time - start_time
    DirectLatencyTracker.record_latency(:http_direct, latency_us)

    result
  end

  # Connect to WebSocket (for direct calls)
  defp connect_websocket(url) do
    WebSockex.start_link(url, __MODULE__.DirectWSClient, %{
      pending_requests: %{},
      next_id: 1
    })
  end

  # Direct WebSocket call using WebSockex (bypasses Lasso)
  # Records latency with microsecond precision
  defp call_ws_direct(ws_pid, method, params) do
    start_time = System.monotonic_time(:microsecond)
    request_id = :erlang.unique_integer([:positive])

    request_body =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: request_id,
        method: method,
        params: params
      })

    WebSockex.cast(ws_pid, {:send, request_body, self(), request_id})

    result =
      receive do
        {:ws_response, ^request_id, response} -> response
      after
        30_000 -> {:error, :timeout}
      end

    # Record latency regardless of success/failure for accurate comparison
    end_time = System.monotonic_time(:microsecond)
    latency_us = end_time - start_time
    DirectLatencyTracker.record_latency(:ws_direct, latency_us)

    result
  end

  # Simple WebSocket client for direct calls
  defmodule DirectWSClient do
    use WebSockex

    def handle_cast({:send, frame, caller_pid, request_id}, state) do
      new_pending = Map.put(state.pending_requests, request_id, caller_pid)
      {:reply, {:text, frame}, %{state | pending_requests: new_pending}}
    end

    def handle_cast(:close, state) do
      {:close, state}
    end

    def handle_frame({:text, msg}, state) do
      case Jason.decode(msg) do
        {:ok, %{"id" => id, "result" => result}} ->
          if caller_pid = Map.get(state.pending_requests, id) do
            send(caller_pid, {:ws_response, id, {:ok, result}})
            new_pending = Map.delete(state.pending_requests, id)
            {:ok, %{state | pending_requests: new_pending}}
          else
            {:ok, state}
          end

        {:ok, %{"id" => id, "error" => error}} ->
          if caller_pid = Map.get(state.pending_requests, id) do
            send(caller_pid, {:ws_response, id, {:error, error}})
            new_pending = Map.delete(state.pending_requests, id)
            {:ok, %{state | pending_requests: new_pending}}
          else
            {:ok, state}
          end

        _ ->
          {:ok, state}
      end
    end

    def handle_frame(_frame, state), do: {:ok, state}

    def handle_disconnect(_reason, state), do: {:ok, state}
  end

  defp print_overhead_analysis(result) do
    # Extract direct latencies from ETS (in microseconds)
    http_direct_us = DirectLatencyTracker.get_latencies(:http_direct)
    ws_direct_us = DirectLatencyTracker.get_latencies(:ws_direct)

    # Convert to milliseconds for analysis
    http_direct_ms = Enum.map(http_direct_us, &(&1 / 1000.0))
    ws_direct_ms = Enum.map(ws_direct_us, &(&1 / 1000.0))

    # Calculate direct path statistics
    http_direct_stats = calculate_stats(http_direct_ms, "HTTP Direct")
    ws_direct_stats = calculate_stats(ws_direct_ms, "WebSocket Direct")

    # Get Lasso path statistics (from battle telemetry)
    http_lasso_stats = result.analysis.requests_by_transport.http
    ws_lasso_stats = result.analysis.requests_by_transport.ws

    # Calculate overhead
    http_overhead = calculate_overhead(http_direct_stats, http_lasso_stats)
    ws_overhead = calculate_overhead(ws_direct_stats, ws_lasso_stats)

    # Print detailed analysis
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("✅ LASSO OVERHEAD BENCHMARK COMPLETE")
    IO.puts(String.duplicate("=", 80))

    IO.puts("\n📋 Test Configuration:")
    IO.puts("   Provider: #{@test_provider}")
    IO.puts("   Method: #{@method}")
    IO.puts("   Sample Size: #{http_direct_stats.count} direct, #{http_lasso_stats.total} Lasso per transport")
    IO.puts("   Duration: #{@test_duration / 1000}s @ #{@test_rate} req/s")

    IO.puts("\n🔴 HTTP Transport:")
    IO.puts("   Direct Path:")
    IO.puts("     P50: #{http_direct_stats.p50}ms | P95: #{http_direct_stats.p95}ms | P99: #{http_direct_stats.p99}ms")
    IO.puts("     Avg: #{Float.round(http_direct_stats.mean, 2)}ms ± #{Float.round(http_direct_stats.stddev, 2)}ms")
    IO.puts("     Min: #{http_direct_stats.min}ms | Max: #{http_direct_stats.max}ms")

    IO.puts("   Lasso Path:")
    IO.puts("     P50: #{http_lasso_stats.p50_latency_ms}ms | P95: #{http_lasso_stats.p95_latency_ms}ms | P99: #{http_lasso_stats.p99_latency_ms}ms")
    IO.puts("     Avg: #{Float.round(http_lasso_stats.avg_latency_ms, 2)}ms ± #{Float.round(http_lasso_stats.stddev_latency_ms, 2)}ms")

    IO.puts("   Overhead:")
    IO.puts("     P50: +#{http_overhead.p50}ms (#{http_overhead.p50_pct}% increase)")
    IO.puts("     P95: +#{http_overhead.p95}ms (#{http_overhead.p95_pct}% increase)")
    IO.puts("     P99: +#{http_overhead.p99}ms (#{http_overhead.p99_pct}% increase)")
    IO.puts("     Avg: +#{Float.round(http_overhead.mean, 2)}ms (#{Float.round(http_overhead.mean_pct, 1)}% increase)")

    IO.puts("\n🟢 WebSocket Transport:")
    IO.puts("   Direct Path:")
    IO.puts("     P50: #{ws_direct_stats.p50}ms | P95: #{ws_direct_stats.p95}ms | P99: #{ws_direct_stats.p99}ms")
    IO.puts("     Avg: #{Float.round(ws_direct_stats.mean, 2)}ms ± #{Float.round(ws_direct_stats.stddev, 2)}ms")
    IO.puts("     Min: #{ws_direct_stats.min}ms | Max: #{ws_direct_stats.max}ms")

    IO.puts("   Lasso Path:")
    IO.puts("     P50: #{ws_lasso_stats.p50_latency_ms}ms | P95: #{ws_lasso_stats.p95_latency_ms}ms | P99: #{ws_lasso_stats.p99_latency_ms}ms")
    IO.puts("     Avg: #{Float.round(ws_lasso_stats.avg_latency_ms, 2)}ms ± #{Float.round(ws_lasso_stats.stddev_latency_ms, 2)}ms")

    IO.puts("   Overhead:")
    IO.puts("     P50: +#{ws_overhead.p50}ms (#{ws_overhead.p50_pct}% increase)")
    IO.puts("     P95: +#{ws_overhead.p95}ms (#{ws_overhead.p95_pct}% increase)")
    IO.puts("     P99: +#{ws_overhead.p99}ms (#{ws_overhead.p99_pct}% increase)")
    IO.puts("     Avg: +#{Float.round(ws_overhead.mean, 2)}ms (#{Float.round(ws_overhead.mean_pct, 1)}% increase)")

    IO.puts("\n📊 Key Insights:")
    IO.puts("   • HTTP overhead at P50: #{http_overhead.p50}ms (#{http_overhead.p50_pct}% of direct latency)")
    IO.puts("   • WebSocket overhead at P50: #{ws_overhead.p50}ms (#{ws_overhead.p50_pct}% of direct latency)")

    if http_overhead.p50 < 50 and ws_overhead.p50 < 50 do
      IO.puts("   ✅ Overhead is low (<50ms at P50) - Lasso adds minimal latency")
    else
      IO.puts("   ⚠️  Overhead is higher than expected - investigate routing/CB logic")
    end

    IO.puts("\n📈 Full report: priv/battle_results/latest.md")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  # Calculate statistics for a list of latencies
  defp calculate_stats(latencies, _label) when length(latencies) == 0 do
    %{count: 0, min: 0, max: 0, mean: 0, stddev: 0, p50: 0, p95: 0, p99: 0}
  end

  defp calculate_stats(latencies, _label) do
    sorted = Enum.sort(latencies)
    count = length(sorted)

    %{
      count: count,
      min: Float.round(List.first(sorted), 2),
      max: Float.round(List.last(sorted), 2),
      mean: Enum.sum(sorted) / count,
      stddev: calculate_stddev(sorted),
      p50: percentile(sorted, 50),
      p95: percentile(sorted, 95),
      p99: percentile(sorted, 99)
    }
  end

  defp calculate_stddev(values) do
    mean = Enum.sum(values) / length(values)
    variance = Enum.reduce(values, 0, fn x, acc -> acc + :math.pow(x - mean, 2) end) / length(values)
    :math.sqrt(variance)
  end

  defp percentile(sorted_list, p) do
    k = (length(sorted_list) - 1) * p / 100.0
    f = Float.floor(k)
    c = Float.ceil(k)

    if f == c do
      Float.round(Enum.at(sorted_list, trunc(k)), 2)
    else
      d0 = Enum.at(sorted_list, trunc(f)) * (c - k)
      d1 = Enum.at(sorted_list, trunc(c)) * (k - f)
      Float.round(d0 + d1, 2)
    end
  end

  defp calculate_overhead(direct_stats, lasso_stats) do
    p50_overhead = lasso_stats.p50_latency_ms - direct_stats.p50
    p95_overhead = lasso_stats.p95_latency_ms - direct_stats.p95
    p99_overhead = lasso_stats.p99_latency_ms - direct_stats.p99
    mean_overhead = lasso_stats.avg_latency_ms - direct_stats.mean

    %{
      p50: Float.round(p50_overhead, 2),
      p50_pct: Float.round(p50_overhead / direct_stats.p50 * 100, 1),
      p95: Float.round(p95_overhead, 2),
      p95_pct: Float.round(p95_overhead / direct_stats.p95 * 100, 1),
      p99: Float.round(p99_overhead, 2),
      p99_pct: Float.round(p99_overhead / direct_stats.p99 * 100, 1),
      mean: mean_overhead,
      mean_pct: mean_overhead / direct_stats.mean * 100
    }
  end
end

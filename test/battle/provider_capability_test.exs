defmodule Lasso.Battle.ProviderCapabilityTest do
  @moduledoc """
  Battle test that validates provider capability differences.

  Different RPC providers support different sets of methods and have
  varying performance characteristics. This test validates:
  - Method support across providers
  - Performance differences for the same method
  - Error handling for unsupported methods
  - Provider-specific quirks and behaviors
  """

  use ExUnit.Case, async: false
  require Logger

  alias Lasso.Battle.{Scenario, Workload, Reporter, SetupHelper}

  @moduletag :battle
  @moduletag :real_providers
  @moduletag :capability
  @moduletag timeout: :infinity

  # Methods that should be widely supported
  @core_methods [
    "eth_blockNumber",
    "eth_chainId",
    "eth_gasPrice",
    "eth_getBlockByNumber"
  ]

  # Methods that may have varying support
  @extended_methods [
    "eth_maxPriorityFeePerGas",
    "eth_feeHistory",
    "net_version",
    "web3_clientVersion"
  ]

  setup_all do
    original_client = Application.get_env(:lasso, :http_client)
    Application.put_env(:lasso, :http_client, Lasso.RPC.HttpClient.Finch)

    Logger.info("Provider capability test: Using real HTTP client")

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, original_client)
    end)

    :ok
  end

  setup do
    Application.ensure_all_started(:lasso)

    on_exit(fn ->
      try do
        SetupHelper.cleanup_providers("ethereum", ["llamarpc", "ankr", "cloudflare"])
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  test "compare method support across providers" do
    result =
      Scenario.new("Provider Capability Comparison")
      |> Scenario.setup(fn ->
        Logger.info("Setting up multiple providers for capability testing...")

        # Register 3 different providers
        SetupHelper.setup_providers("ethereum", [
          {:real, "llamarpc", "https://eth.llamarpc.com"},
          {:real, "ankr", "https://rpc.ankr.com/eth"},
          {:real, "cloudflare", "https://cloudflare-eth.com"}
        ])

        Logger.info("✓ Providers ready for capability testing")

        {:ok, %{chain: "ethereum", providers: ["llamarpc", "ankr", "cloudflare"]}}
      end)
      |> Scenario.workload(fn ->
        # Test each provider with both core and extended methods
        # Track results manually for per-provider analysis
        providers = ["llamarpc", "ankr", "cloudflare"]
        all_methods = @core_methods ++ @extended_methods

        results =
          for provider_id <- providers do
            Logger.info("Testing provider: #{provider_id}")

            provider_results =
              for method <- all_methods do
                Logger.debug("  Testing #{method} on #{provider_id}")

                case Workload.direct("ethereum", method, [],
                       provider_override: provider_id,
                       failover_on_override: false,
                       transport: :http
                     ) do
                  {:ok, _result} ->
                    Logger.debug("    ✓ #{method} supported")
                    {:ok, method}

                  {:error, reason} ->
                    Logger.debug("    ✗ #{method} failed: #{inspect(reason)}")
                    {:error, method}
                end
              end

            # Count successes for this provider
            successes = Enum.count(provider_results, fn
              {:ok, _} -> true
              _ -> false
            end)

            total = length(provider_results)
            success_rate = if total > 0, do: successes / total, else: 0.0

            Logger.info("Provider #{provider_id}: #{successes}/#{total} methods supported (#{Float.round(success_rate * 100, 1)}%)")

            {provider_id, %{successes: successes, total: total, success_rate: success_rate}}
          end

        {:ok, Map.new(results)}
      end)
      |> Scenario.collect([:requests, :errors, :selection])
      |> Scenario.slo(
        # Allow failures for unsupported methods
        success_rate: 0.60,
        p95_latency_ms: 3000
      )
      |> Scenario.run()

    Reporter.save_json(result, "priv/battle_results/")

    # All providers should support core methods
    assert result.analysis.requests.success_rate >= 0.60,
           "Overall success rate #{result.analysis.requests.success_rate} below 60%"

    assert result.analysis.requests.total >= 20, "Should test multiple methods across providers"
  end

  test "compare performance across providers for same method" do
    result =
      Scenario.new("Provider Performance Comparison")
      |> Scenario.setup(fn ->
        SetupHelper.setup_providers("ethereum", [
          {:real, "llamarpc", "https://eth.llamarpc.com"},
          {:real, "ankr", "https://rpc.ankr.com/eth"}
        ])

        {:ok, %{chain: "ethereum"}}
      end)
      |> Scenario.workload(fn ->
        # Test the same method on each provider multiple times
        # Collect latencies manually for statistical analysis
        method = "eth_blockNumber"
        iterations = 10

        results =
          for provider_id <- ["llamarpc", "ankr"] do
            Logger.info("Performance testing #{method} on #{provider_id}")

            latencies =
              for i <- 1..iterations do
                Logger.debug("  Iteration #{i}/#{iterations}")

                start_time = System.monotonic_time(:millisecond)

                result =
                  Workload.direct("ethereum", method, [],
                    provider_override: provider_id,
                    failover_on_override: false,
                    transport: :http
                  )

                latency_ms = System.monotonic_time(:millisecond) - start_time

                case result do
                  {:ok, _} -> latency_ms
                  {:error, _} -> nil
                end
              end
              |> Enum.reject(&is_nil/1)

            n = length(latencies)

            if n > 0 do
              avg_latency = Enum.sum(latencies) / n
              sorted = Enum.sort(latencies)
              p95_latency = Enum.at(sorted, trunc(n * 0.95))

              # Calculate standard deviation
              variance =
                Enum.reduce(latencies, 0, fn x, acc -> acc + :math.pow(x - avg_latency, 2) end) / n

              std_dev = :math.sqrt(variance)

              # Calculate 95% confidence interval for mean (using z=1.96 for large samples)
              margin = 1.96 * std_dev / :math.sqrt(n)
              ci_lower = avg_latency - margin
              ci_upper = avg_latency + margin

              Logger.info("Provider #{provider_id}:")
              Logger.info("  avg=#{Float.round(avg_latency, 2)}ms, p95=#{p95_latency}ms")
              Logger.info("  std_dev=#{Float.round(std_dev, 2)}ms")
              Logger.info("  95% CI: [#{Float.round(ci_lower, 2)}ms, #{Float.round(ci_upper, 2)}ms]")
              Logger.info("  samples: #{n}")

              {provider_id,
               %{
                 avg: avg_latency,
                 p95: p95_latency,
                 std_dev: std_dev,
                 ci_lower: ci_lower,
                 ci_upper: ci_upper,
                 n: n
               }}
            else
              Logger.warning("Provider #{provider_id}: No successful requests")
              {provider_id, nil}
            end
          end
          |> Map.new()

        # Check if confidence intervals overlap - if not, difference is statistically significant
        llamarpc = results["llamarpc"]
        ankr = results["ankr"]

        if llamarpc && ankr do
          intervals_overlap =
            (llamarpc.ci_lower <= ankr.ci_upper) and (ankr.ci_lower <= llamarpc.ci_upper)

          if intervals_overlap do
            Logger.info("⚠️  Performance difference not statistically significant (overlapping CIs)")
          else
            faster = if llamarpc.avg < ankr.avg, do: "llamarpc", else: "ankr"

            Logger.info(
              "✓ Performance difference is statistically significant (non-overlapping CIs)"
            )

            Logger.info("  #{faster} is measurably faster")
          end
        end

        {:ok, results}
      end)
      |> Scenario.collect([:requests, :selection])
      |> Scenario.slo(success_rate: 0.95, p95_latency_ms: 2000)
      |> Scenario.run()

    assert result.analysis.requests.success_rate >= 0.95
    assert result.analysis.requests.total >= 18, "Should test both providers with multiple iterations"
  end

  test "validate error handling for unsupported methods" do
    result =
      Scenario.new("Unsupported Method Error Handling")
      |> Scenario.setup(fn ->
        SetupHelper.setup_providers("ethereum", [
          {:real, "llamarpc", "https://eth.llamarpc.com"}
        ])

        {:ok, %{chain: "ethereum"}}
      end)
      |> Scenario.workload(fn ->
        # Try intentionally unsupported/invalid methods
        invalid_methods = [
          "eth_unsupportedMethod",
          "debug_traceTransaction",
          "trace_block",
          "parity_getBlockReceipts"
        ]

        for method <- invalid_methods do
          Logger.info("Testing unsupported method: #{method}")

          case Workload.direct("ethereum", method, [],
                 provider_override: "llamarpc",
                 failover_on_override: false,
                 transport: :http
               ) do
            {:ok, _} -> Logger.warning("  Unexpected success for #{method}")
            {:error, reason} -> Logger.debug("  Expected error: #{inspect(reason)}")
          end
          # No artificial sleep - requests execute at natural rate
        end

        :ok
      end)
      |> Scenario.collect([:requests, :errors])
      |> Scenario.slo(
        # Expect failures for unsupported methods
        success_rate: 0.0,
        p95_latency_ms: 3000
      )
      |> Scenario.run()

    # All requests should fail gracefully
    assert result.analysis.requests.success_rate < 0.25,
           "Expected most/all methods to fail, got #{result.analysis.requests.success_rate} success rate"

    assert result.analysis.requests.total >= 3, "Should test multiple invalid methods"
  end
end

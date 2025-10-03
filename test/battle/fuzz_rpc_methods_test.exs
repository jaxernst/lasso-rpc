defmodule Lasso.Battle.FuzzRPCMethodsTest do
  @moduledoc """
  Fuzz battle test that exercises a wide variety of RPC methods with real providers.

  This test validates:
  - Multiple RPC method support across providers
  - Method-specific error handling
  - Provider capability differences
  - Realistic parameter generation
  - System stability under diverse workloads
  """

  use ExUnit.Case, async: false
  require Logger

  alias Lasso.Battle.{Scenario, Workload, Reporter, SetupHelper}

  @moduletag :battle
  @moduletag :real_providers
  @moduletag :fuzz
  @moduletag timeout: :infinity

  # Common RPC methods to test
  @rpc_methods [
    # Block methods
    {"eth_blockNumber", []},
    {"eth_getBlockByNumber", ["latest", false]},

    # Chain info
    {"eth_chainId", []},
    {"eth_gasPrice", []},
    {"net_version", []},

    # Account queries (using zero address for safety)
    {"eth_getBalance", ["0x0000000000000000000000000000000000000000", "latest"]},
    {"eth_getTransactionCount", ["0x0000000000000000000000000000000000000000", "latest"]},
    {"eth_getCode", ["0x0000000000000000000000000000000000000000", "latest"]},

    # Gas and fee queries
    {"eth_maxPriorityFeePerGas", []},
    {"eth_feeHistory", [4, "latest", [25, 75]]},

    # Contract calls (USDC balanceOf for zero address)
    {"eth_call", [
      %{
        to: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        data: "0x70a082310000000000000000000000000000000000000000000000000000000000000000"
      },
      "latest"
    ]}
  ]

  setup_all do
    # Use real HTTP client for fuzz testing
    original_client = Application.get_env(:lasso, :http_client)
    Application.put_env(:lasso, :http_client, Lasso.RPC.HttpClient.Finch)

    Logger.info("Fuzz test: Using real HTTP client")

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

  test "fuzz test various RPC methods with real providers" do
    result =
      Scenario.new("Fuzz RPC Methods Test")
      |> Scenario.setup(fn ->
        Logger.info("Setting up Ethereum providers for fuzz testing...")

        # Register multiple real providers
        SetupHelper.setup_providers("ethereum", [
          {:real, "llamarpc", "https://eth.llamarpc.com"},
          {:real, "ankr", "https://rpc.ankr.com/eth"},
          {:real, "cloudflare", "https://cloudflare-eth.com"}
        ])

        Logger.info("✓ Providers ready - starting fuzz test with #{length(@rpc_methods)} methods")

        {:ok, %{chain: "ethereum", provider_count: 3, method_count: length(@rpc_methods)}}
      end)
      |> Scenario.workload(fn ->
        # Execute each method sequentially (3 requests per method)
        Logger.info("Executing #{length(@rpc_methods)} different RPC methods...")

        for {method, params} <- @rpc_methods do
          for i <- 1..3 do
            Logger.debug("Executing #{method} (attempt #{i}/3)")

            case Workload.http("ethereum", method, params, strategy: :round_robin) do
              {:ok, _result} -> :ok
              {:error, reason} -> Logger.warning("Method #{method} failed: #{inspect(reason)}")
            end
            # No artificial sleep - requests execute at natural rate
          end
        end

        :ok
      end)
      |> Scenario.collect([:requests, :errors, :selection, :system])
      |> Scenario.slo(
        # Allow some failures for unsupported methods
        success_rate: 0.70,
        # Real providers are slower
        p95_latency_ms: 3000
      )
      |> Scenario.run()

    # Save detailed results
    Reporter.save_json(result, "priv/battle_results/")

    # Assertions
    assert result.analysis.requests.success_rate >= 0.70,
           "Success rate #{result.analysis.requests.success_rate} below 70% threshold"

    # Verify we tested multiple methods and requests completed
    assert result.analysis.requests.total >= 20,
           "Should execute multiple methods across providers (got #{result.analysis.requests.total})"
  end

  test "fuzz test with sequential workload pattern" do
    result =
      Scenario.new("Sequential Fuzz Test")
      |> Scenario.setup(fn ->
        SetupHelper.setup_providers("ethereum", [
          {:real, "llamarpc", "https://eth.llamarpc.com"}
        ])

        {:ok, %{chain: "ethereum"}}
      end)
      |> Scenario.workload(fn ->
        # Execute methods sequentially to test ordering and state
        methods = [
          {"eth_blockNumber", []},
          {"eth_chainId", []},
          {"eth_gasPrice", []},
          {"eth_getBlockByNumber", ["latest", false]},
          {"eth_maxPriorityFeePerGas", []}
        ]

        for {method, params} <- methods do
          Workload.http("ethereum", method, params, strategy: :priority)
          # No artificial sleep - requests execute at natural rate
        end

        :ok
      end)
      |> Scenario.collect([:requests, :system])
      |> Scenario.slo(success_rate: 0.90, p95_latency_ms: 2000)
      |> Scenario.run()

    assert result.analysis.requests.success_rate >= 0.90
    assert result.analysis.requests.total >= 5
  end

  test "stress test with high concurrency mixed methods" do
    result =
      Scenario.new("High Concurrency Fuzz Test")
      |> Scenario.setup(fn ->
        SetupHelper.setup_providers("ethereum", [
          {:real, "llamarpc", "https://eth.llamarpc.com"},
          {:real, "ankr", "https://rpc.ankr.com/eth"}
        ])

        {:ok, %{chain: "ethereum"}}
      end)
      |> Scenario.workload(fn ->
        # Generate heavy concurrent load with mixed methods
        # Spawn multiple concurrent tasks, each calling different methods
        parent = self()

        tasks =
          for method_group <- [
                ["eth_blockNumber", "eth_chainId"],
                ["eth_gasPrice", "net_version"],
                ["eth_getBlockByNumber", "eth_maxPriorityFeePerGas"]
              ] do
            Task.async(fn ->
              # Each task alternates between its assigned methods
              end_time = System.monotonic_time(:millisecond) + 30_000

              stats =
                Stream.cycle(method_group)
                |> Enum.reduce_while(%{requests: 0}, fn method, acc ->
                  if System.monotonic_time(:millisecond) < end_time do
                    params =
                      case method do
                        "eth_getBlockByNumber" -> ["latest", false]
                        _ -> []
                      end

                    Workload.http("ethereum", method, params, strategy: :fastest)
                    Process.sleep(150)
                    {:cont, %{acc | requests: acc.requests + 1}}
                  else
                    {:halt, acc}
                  end
                end)

              send(parent, {:task_done, stats})
              stats
            end)
          end

        # Wait for all tasks to complete
        for task <- tasks do
          Task.await(task, 35_000)
        end

        :ok
      end)
      |> Scenario.collect([:requests, :selection, :system])
      |> Scenario.slo(
        success_rate: 0.85,
        p95_latency_ms: 3000
      )
      |> Scenario.run()

    Reporter.save_json(result, "priv/battle_results/")

    assert result.analysis.requests.success_rate >= 0.85

    # Verify high request volume (3 concurrent tasks, each ~200 requests = ~600 total)
    assert result.analysis.requests.total >= 500,
           "Should generate at least 500 requests across 3 concurrent tasks (got #{result.analysis.requests.total})"
  end
end

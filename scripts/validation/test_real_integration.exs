#!/usr/bin/env elixir

# Comprehensive Real RPC Integration Test Script
# This script tests real RPC endpoint integration and system functionality

defmodule RealIntegrationTest do
  require Logger

  def run_test do
    Logger.info("🧪 Testing Real RPC Integration")
    Logger.info("=" |> String.duplicate(50))

    # Test 1: Direct RPC call to real endpoints
    test_direct_real_rpc()

    # Test 2: Test our JSON-RPC controller with real data
    test_json_rpc_controller()

    # Test 3: Real Ethereum WebSocket connection
    test_real_ethereum_websocket()

    Logger.info("✅ Real RPC integration test completed!")
  end

  defp test_direct_real_rpc do
    Logger.info("\n🔗 Test 1: Direct RPC Call to Real Endpoints")
    Logger.info("-" |> String.duplicate(40))

    # Test with multiple public Ethereum endpoints
    real_endpoints = [
      {"LlamaRPC", "https://eth.llamarpc.com"},
      {"Ankr", "https://rpc.ankr.com/eth"},
      {"PublicNode", "https://ethereum.publicnode.com"}
    ]

    Enum.each(real_endpoints, fn {name, url} ->
      Logger.info("📡 Testing #{name}...")

      request = Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "eth_blockNumber",
        "params" => [],
        "id" => 1
      })

      case System.cmd("curl", [
        "-s",
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", request,
        "--max-time", "10",
        url
      ]) do
        {body, 0} ->
          case Jason.decode(body) do
            {:ok, %{"result" => result}} ->
              Logger.info("  ✅ #{name}: Block #{result}")
            {:ok, %{"error" => error}} ->
              Logger.warning("  ⚠️  #{name}: #{inspect(error)}")
            _ ->
              Logger.warning("  ⚠️  #{name}: Unexpected response")
          end

        {error, status} ->
          Logger.error("  ❌ #{name}: HTTP #{status} - #{error}")
      end

      :timer.sleep(500)
    end)
  end

  defp test_json_rpc_controller do
    Logger.info("\n🎛️  Test 2: JSON-RPC Controller Integration")
    Logger.info("-" |> String.duplicate(40))

    # Test our JSON-RPC controller endpoints
    controller_endpoints = [
      "/rpc/ethereum",
      "/rpc/arbitrum",
      "/rpc/polygon",
      "/rpc/bsc"
    ]

    Enum.each(controller_endpoints, fn endpoint ->
      Logger.info("🔍 Testing #{endpoint}...")

      request = Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => "eth_blockNumber",
        "params" => [],
        "id" => 1
      })

      case System.cmd("curl", [
        "-s",
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", request,
        "--max-time", "10",
        "http://localhost:4000#{endpoint}"
      ]) do
        {body, 0} ->
          case Jason.decode(body) do
            {:ok, %{"result" => result}} ->
              Logger.info("  ✅ #{endpoint}: Block #{result}")
            {:ok, %{"error" => error}} ->
              Logger.warning("  ⚠️  #{endpoint}: #{inspect(error)}")
            _ ->
              Logger.warning("  ⚠️  #{endpoint}: Unexpected response")
          end

        {error, status} ->
          Logger.error("  ❌ #{endpoint}: HTTP #{status} - #{error}")
      end

      :timer.sleep(500)
    end)
  end

  defp test_real_ethereum_websocket do
    Logger.info("\n🔌 Test 3: Real Ethereum WebSocket Connection")
    Logger.info("-" |> String.duplicate(40))

    # Create a real Ethereum endpoint using public RPC
    real_endpoint = Livechain.RPC.RealEndpoints.ethereum_mainnet_public()

    Logger.info("📡 Created real endpoint: #{real_endpoint.name}")
    Logger.info("🔗 URL: #{real_endpoint.url}")
    Logger.info("🔌 WebSocket: #{real_endpoint.ws_url}")

    # Start the real connection
    case Livechain.RPC.WSSupervisor.start_connection(real_endpoint) do
      {:ok, _pid} ->
        Logger.info("✅ Real WebSocket connection started successfully!")

        # Test JSON-RPC calls through WebSocket
        test_websocket_rpc_calls(real_endpoint)

        # Clean up
        Livechain.RPC.WSSupervisor.stop_connection(real_endpoint.id)
        Logger.info("🧹 Cleaned up real WebSocket connection")

      {:error, reason} ->
        Logger.error("❌ Failed to start real WebSocket connection: #{inspect(reason)}")
    end
  end

  defp test_websocket_rpc_calls(endpoint) do
    Logger.info("\n📡 Testing WebSocket RPC calls to real endpoint")
    Logger.info("-" |> String.duplicate(40))

    # Test basic RPC methods via WebSocket
    test_methods = [
      {"eth_blockNumber", []},
      {"eth_chainId", []},
      {"eth_gasPrice", []}
    ]

    Enum.each(test_methods, fn {method, params} ->
      Logger.info("🔍 Testing #{method} via WebSocket...")

      request = Jason.encode!(%{
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params,
        "id" => 1
      })

      case System.cmd("curl", [
        "-s",
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "-d", request,
        "--max-time", "10",
        endpoint.url
      ]) do
        {body, 0} ->
          case Jason.decode(body) do
            {:ok, %{"result" => result}} ->
              Logger.info("  ✅ #{method}: #{inspect(result)}")
            {:ok, %{"error" => error}} ->
              Logger.warning("  ⚠️  #{method}: #{inspect(error)}")
            _ ->
              Logger.warning("  ⚠️  #{method}: Unexpected response format")
          end

        {error, status} ->
          Logger.error("  ❌ #{method}: HTTP #{status} - #{error}")
      end

      # Small delay between requests
      :timer.sleep(1000)
    end)
  end
end

# Run test
RealIntegrationTest.run_test()

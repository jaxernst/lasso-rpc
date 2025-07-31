#!/usr/bin/env elixir

# Test script to verify real RPC endpoint integration
# This script tests how the system would work with real RPC endpoints

defmodule RealIntegrationTest do
  require Logger

  def run_test do
    Logger.info("🧪 Testing Real RPC Integration")
    Logger.info("=" |> String.duplicate(50))

    # Test 1: Direct RPC call to real endpoint
    test_direct_real_rpc()

    # Test 2: Test our JSON-RPC controller with real data
    test_json_rpc_controller()

    Logger.info("✅ Real RPC integration test completed!")
  end

  defp test_direct_real_rpc do
    Logger.info("\n🔗 Test 1: Direct RPC Call to Real Endpoint")
    Logger.info("-" |> String.duplicate(40))

    # Test with LlamaRPC (public Ethereum endpoint)
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

    # Test our JSON-RPC controller (which currently uses mock data)
    # This shows how the system would work with real endpoints
    Logger.info("📡 Testing our JSON-RPC controller...")

    # Test our controller endpoints
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
end

# Run test
RealIntegrationTest.run_test()

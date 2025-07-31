#!/usr/bin/env elixir

# Test script to verify real RPC endpoint integration
# This script replaces a mock endpoint with a real public RPC endpoint

defmodule RealRPCTest do
  require Logger

  def run_test do
    Logger.info("🧪 Testing Real RPC Endpoint Integration")
    Logger.info("=" |> String.duplicate(50))

    # Test with a real public Ethereum endpoint
    test_real_ethereum_endpoint()

    Logger.info("✅ Real RPC test completed!")
  end

  defp test_real_ethereum_endpoint do
    Logger.info("\n🔗 Testing Real Ethereum Public Endpoint")
    Logger.info("-" |> String.duplicate(40))

    # Create a real Ethereum endpoint using public RPC
    real_endpoint = Livechain.RPC.RealEndpoints.ethereum_mainnet_public()

    Logger.info("📡 Created real endpoint: #{real_endpoint.name}")
    Logger.info("🔗 URL: #{real_endpoint.url}")
    Logger.info("🔌 WebSocket: #{real_endpoint.ws_url}")

    # Start the real connection
    case Livechain.RPC.WSSupervisor.start_connection(real_endpoint) do
      {:ok, _pid} ->
        Logger.info("✅ Real connection started successfully!")

        # Test JSON-RPC calls
        test_json_rpc_calls(real_endpoint)

        # Clean up
        Livechain.RPC.WSSupervisor.stop_connection(real_endpoint.id)
        Logger.info("🧹 Cleaned up real connection")

      {:error, reason} ->
        Logger.error("❌ Failed to start real connection: #{inspect(reason)}")
    end
  end

    defp test_json_rpc_calls(endpoint) do
    Logger.info("\n📡 Testing JSON-RPC calls to real endpoint")
    Logger.info("-" |> String.duplicate(40))

    # Test basic RPC methods
    test_methods = [
      {"eth_blockNumber", []},
      {"eth_chainId", []},
      {"eth_gasPrice", []}
    ]

    Enum.each(test_methods, fn {method, params} ->
      Logger.info("🔍 Testing #{method}...")

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
RealRPCTest.run_test()

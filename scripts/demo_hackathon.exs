#!/usr/bin/env elixir

# ChainPulse Hackathon Demo Script
# This script demonstrates the key features of the RPC orchestration service

defmodule ChainPulseDemo do
  require Logger

  @doc """
  Run the complete hackathon demo showcasing all features.
  """
  def run_demo do
    Logger.info("🚀 Starting ChainPulse Hackathon Demo")
    Logger.info("=" |> String.duplicate(50))

    # Wait for server to be ready
    wait_for_server()

    # Demo sections
    test_health_endpoints()
    test_json_rpc_endpoints()
    test_multi_chain_support()
    test_websocket_subscriptions()
    test_orchestration_dashboard()

    Logger.info("✅ Demo completed successfully!")
    Logger.info("🌐 Dashboard available at: http://localhost:4000")
    Logger.info("📊 Orchestration view: http://localhost:4000/orchestration")
  end

  defp wait_for_server do
    Logger.info("⏳ Waiting for server to be ready...")

    case System.cmd("curl", ["-s", "http://localhost:4000/api/health"]) do
      {body, 0} ->
        Logger.info("✅ Server is ready!")
        Logger.info("Health response: #{String.slice(body, 0, 100)}...")
      {error, _} ->
        Logger.error("❌ Server not ready. Please start with: mix phx.server")
        Logger.error("Error: #{error}")
        System.halt(1)
    end
  end

  defp test_health_endpoints do
    Logger.info("\n🏥 Testing Health Endpoints")
    Logger.info("-" |> String.duplicate(30))

    endpoints = [
      "/api/health",
      "/api/status",
      "/api/metrics"
    ]

    Enum.each(endpoints, fn endpoint ->
      case System.cmd("curl", ["-s", "http://localhost:4000#{endpoint}"]) do
        {body, 0} ->
          Logger.info("✅ #{endpoint}: #{String.slice(body, 0, 100)}...")
        {error, status} ->
          Logger.warning("⚠️  #{endpoint}: Status #{status} - #{error}")
      end
    end)
  end

  defp test_json_rpc_endpoints do
    Logger.info("\n🔗 Testing JSON-RPC Endpoints")
    Logger.info("-" |> String.duplicate(30))

    chains = ["ethereum", "arbitrum", "polygon", "bsc"]
    methods = [
      {"eth_blockNumber", []},
      {"eth_chainId", []},
      {"eth_getLogs", [%{"fromBlock" => "0x0", "toBlock" => "latest"}]}
    ]

    Enum.each(chains, fn chain ->
      Logger.info("📡 Testing #{chain}...")

      Enum.each(methods, fn {method, params} ->
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
          "http://localhost:4000/rpc/#{chain}"
        ]) do
          {body, 0} ->
            Logger.info("  ✅ #{method}: #{String.slice(body, 0, 80)}...")
          {error, status} ->
            Logger.warning("  ⚠️  #{method}: Status #{status} - #{error}")
        end
      end)
    end)
  end

  defp test_multi_chain_support do
    Logger.info("\n⛓️  Testing Multi-Chain Support")
    Logger.info("-" |> String.duplicate(30))

    # Test chain status via API
    case System.cmd("curl", ["-s", "http://localhost:4000/api/status"]) do
      {body, 0} ->
        case Jason.decode(body) do
          {:ok, %{"chains" => chains}} ->
            Logger.info("📊 Active chains: #{length(chains)}")
            Enum.each(chains, fn {chain_name, status} ->
              Logger.info("  🔗 #{chain_name}: #{status["status"]} (#{length(status["providers"])} providers)")
            end)
          _ ->
            Logger.warning("⚠️  Could not parse chain status")
        end
      {error, _} ->
        Logger.error("❌ Could not fetch chain status: #{error}")
    end
  end

  defp test_websocket_subscriptions do
    Logger.info("\n🔌 Testing WebSocket Subscriptions")
    Logger.info("-" |> String.duplicate(30))

    # This would require a WebSocket client to test properly
    # For demo purposes, we'll just show the subscription endpoints
    Logger.info("📡 WebSocket endpoints available:")
    Logger.info("  ws://localhost:4000/socket/websocket")
    Logger.info("  Channels: blockchain, rpc")
    Logger.info("  Example subscription: {\"event\": \"phx_join\", \"topic\": \"blockchain:ethereum\"}")
  end

  defp test_orchestration_dashboard do
    Logger.info("\n🎛️  Testing Orchestration Dashboard")
    Logger.info("-" |> String.duplicate(30))

    # Test dashboard endpoints
    dashboard_endpoints = [
      "/orchestration",
      "/network",
      "/table"
    ]

    Enum.each(dashboard_endpoints, fn endpoint ->
      case System.cmd("curl", ["-s", "-I", "http://localhost:4000#{endpoint}"]) do
        {body, 0} ->
          Logger.info("✅ Dashboard #{endpoint}: Available")
        {error, status} ->
          Logger.warning("⚠️  Dashboard #{endpoint}: Status #{status} - #{error}")
      end
    end)
  end
end

# Run demo
ChainPulseDemo.run_demo()

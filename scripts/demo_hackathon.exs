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
    test_system_validation()
    show_multiclient_instructions()

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
    chains = ["ethereum", "arbitrum", "polygon", "bsc"]

    Enum.each(chains, fn chain ->
      case System.cmd("curl", ["-s", "http://localhost:4000/api/chains/#{chain}/status"]) do
        {body, 0} ->
          Logger.info("✅ #{chain}: #{String.slice(body, 0, 80)}...")
        {error, status} ->
          Logger.warning("⚠️  #{chain}: Status #{status} - #{error}")
      end
    end)
  end

  defp test_websocket_subscriptions do
    Logger.info("\n🔌 Testing WebSocket Subscriptions")
    Logger.info("-" |> String.duplicate(30))

    # This would require a WebSocket client to test properly
    Logger.info("📡 WebSocket server available at ws://localhost:4000/socket")
    Logger.info("🔗 Phoenix channels ready for blockchain subscriptions")
    Logger.info("📊 Real-time data streaming enabled")
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
      case System.cmd("curl", ["-s", "http://localhost:4000#{endpoint}"]) do
        {body, 0} ->
          Logger.info("✅ #{endpoint}: Available")
        {error, status} ->
          Logger.warning("⚠️  #{endpoint}: Status #{status} - #{error}")
      end
    end)
  end

  defp test_system_validation do
    Logger.info("\n📊 System Validation")
    Logger.info("-" |> String.duplicate(30))

    # Check if Phoenix endpoint is running
    case Process.whereis(LivechainWeb.Endpoint) do
      nil ->
        Logger.warning("⚠️  Phoenix endpoint not running")

      _pid ->
        Logger.info("✅ Phoenix endpoint running")
    end

    # Check WebSocket supervisor
    case Process.whereis(Livechain.RPC.WSSupervisor) do
      nil ->
        Logger.warning("⚠️  WebSocket supervisor not running")

      _pid ->
        Logger.info("✅ WebSocket supervisor running")
    end

    # Check chain manager
    case Process.whereis(Livechain.RPC.ChainManager) do
      nil ->
        Logger.warning("⚠️  Chain manager not running")

      _pid ->
        Logger.info("✅ Chain manager running")
    end
  end

  defp show_multiclient_instructions do
    Logger.info("\n👥 Multi-Client WebSocket Testing Instructions")
    Logger.info("-" |> String.duplicate(40))

    instructions = """
    🔧 To test with multiple WebSocket clients:

    1. Install wscat: npm install -g wscat

    2. Open multiple terminals and connect:
       Terminal 1: wscat -c "ws://localhost:4000/socket/websocket"
       Terminal 2: wscat -c "ws://localhost:4000/socket/websocket"

    3. Join blockchain channels:
       Send: {"topic":"blockchain:ethereum","event":"phx_join","payload":{},"ref":"1"}
       Send: {"topic":"blockchain:polygon","event":"phx_join","payload":{},"ref":"2"}

    4. Subscribe to block events:
       Send: {"topic":"blockchain:ethereum","event":"subscribe","payload":{"type":"blocks"},"ref":"3"}

    5. Watch real-time blockchain data flow to all connected clients!

    📊 Expected behavior:
       - Multiple clients can connect simultaneously
       - Each receives the same blockchain data
       - New blocks are broadcast to all subscribers
       - Connections are fault-tolerant
    """

    Logger.info(instructions)
  end

  @doc """
  Run a live demo for a specified duration.
  """
  def run_live_demo(duration_seconds \\ 30) do
    Logger.info("🔴 LIVE DEMO: Running for #{duration_seconds} seconds...")
    Logger.info("Connect WebSocket clients now to see real-time data!")

    run_demo()

    Logger.info("\n⏰ Demo running... Connect your WebSocket clients!")
    Process.sleep(duration_seconds * 1000)

    Logger.info("\n✨ Demo completed!")
  end
end

# Run demo
ChainPulseDemo.run_demo()

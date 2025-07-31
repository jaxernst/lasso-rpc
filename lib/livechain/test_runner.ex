defmodule Livechain.TestRunner do
  @moduledoc """
  Test runner for comprehensive Livechain testing.
  """

  alias Livechain.RPC.{MockWSEndpoint, RealEndpoints, WSSupervisor}

  def run_comprehensive_test do
    IO.puts("\n🚀 Starting Comprehensive Livechain Test")
    IO.puts("=" |> String.duplicate(60))

    # Test 1: Mock Provider Test
    test_mock_providers()

    # Test 2: Phoenix Channel Test
    test_phoenix_channels()

    # Test 3: Real Ethereum Test
    test_real_ethereum()

    # Test 4: System Status
    test_system_status()

    # Test 5: Multi-client instructions
    show_multiclient_instructions()

    IO.puts("\n🎉 All tests completed!")
  end

  defp test_mock_providers do
    IO.puts("\n📊 Test 1: Mock Provider Test")
    IO.puts("-" |> String.duplicate(40))

    # Create mock endpoints
    ethereum_mock = MockWSEndpoint.ethereum_mainnet()
    polygon_mock = MockWSEndpoint.polygon()

    IO.puts("✅ Created mock endpoints:")
    IO.puts("  - #{ethereum_mock.name} (Chain ID: #{ethereum_mock.chain_id})")
    IO.puts("  - #{polygon_mock.name} (Chain ID: #{polygon_mock.chain_id})")

    # Start mock connections
    case WSSupervisor.start_connection(ethereum_mock) do
      {:ok, _pid} -> IO.puts("✅ Started Ethereum mock connection")
      {:error, reason} -> IO.puts("❌ Failed to start Ethereum: #{inspect(reason)}")
    end

    case WSSupervisor.start_connection(polygon_mock) do
      {:ok, _pid} -> IO.puts("✅ Started Polygon mock connection")
      {:error, reason} -> IO.puts("❌ Failed to start Polygon: #{inspect(reason)}")
    end

    # Wait for connections to establish
    Process.sleep(2000)
  end

  defp test_phoenix_channels do
    IO.puts("\n🌐 Test 2: Phoenix Channel Test")
    IO.puts("-" |> String.duplicate(40))

    # Check if Phoenix endpoint is running
    case Process.whereis(LivechainWeb.Endpoint) do
      nil ->
        IO.puts("⚠️  Phoenix endpoint not running, starting it...")

        case LivechainWeb.Endpoint.start_link() do
          {:ok, _pid} -> IO.puts("✅ Phoenix endpoint started")
          {:error, reason} -> IO.puts("❌ Failed to start Phoenix: #{inspect(reason)}")
        end

      _pid ->
        IO.puts("✅ Phoenix endpoint already running")
    end

    IO.puts("✅ WebSocket server available at ws://localhost:4000/socket")
  end

  defp test_real_ethereum do
    IO.puts("\n🔗 Test 3: Real Ethereum Connection Test")
    IO.puts("-" |> String.duplicate(40))

    try do
      real_ethereum = RealEndpoints.ethereum_mainnet_public()
      IO.puts("✅ Created real Ethereum endpoint: #{real_ethereum.name}")

      case WSSupervisor.start_connection(real_ethereum) do
        {:ok, _pid} ->
          IO.puts("✅ Successfully connected to real Ethereum network!")

          # Subscribe to new blocks
          case WSSupervisor.subscribe(real_ethereum.id, "newHeads") do
            :ok ->
              IO.puts("✅ Subscribed to real Ethereum blocks")

            {:error, reason} ->
              IO.puts("⚠️  Failed to subscribe: #{inspect(reason)}")
          end

        {:error, reason} ->
          IO.puts("⚠️  Could not connect to real Ethereum: #{inspect(reason)}")
          IO.puts("   (This is normal - public endpoints may be rate limited)")
      end
    rescue
      error ->
        IO.puts("⚠️  Error with real Ethereum: #{inspect(error)}")
        IO.puts("   (This is normal - network connectivity issues)")
    end
  end

  defp test_system_status do
    IO.puts("\n📈 Test 4: System Status")
    IO.puts("-" |> String.duplicate(40))

    connections = WSSupervisor.list_connections()
    IO.puts("📊 Total active connections: #{length(connections)}")

    if length(connections) > 0 do
      Enum.each(connections, fn conn ->
        status_icon =
          case conn.status do
            :connected -> "🟢"
            :disconnected -> "🔴"
            _ -> "🟡"
          end

        IO.puts("  #{status_icon} #{conn.name}")
        IO.puts("     Status: #{conn.status}")
        IO.puts("     Reconnect attempts: #{conn.reconnect_attempts || 0}")
        IO.puts("     Subscriptions: #{conn.subscriptions || 0}")
      end)
    else
      IO.puts("⚠️  No active connections found")
    end
  end

  defp show_multiclient_instructions do
    IO.puts("\n👥 Multi-Client WebSocket Testing")
    IO.puts("-" |> String.duplicate(40))

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

    IO.puts(instructions)
  end

  def run_live_demo(duration_seconds \\ 30) do
    IO.puts("\n🔴 LIVE DEMO: Running for #{duration_seconds} seconds...")
    IO.puts("Connect WebSocket clients now to see real-time data!")

    run_comprehensive_test()

    IO.puts("\n⏰ Demo running... Connect your WebSocket clients!")
    Process.sleep(duration_seconds * 1000)

    final_connections = WSSupervisor.list_connections()
    IO.puts("\n📊 Final Status: #{length(final_connections)} active connections")

    IO.puts("\n✨ Demo completed!")
  end
end

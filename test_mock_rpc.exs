#!/usr/bin/env elixir

# Test script for the mock RPC system
# Run with: elixir test_mock_rpc.exs

# Start the application
Application.ensure_all_started(:livechain)

# Import required modules
alias Livechain.RPC.{MockWSEndpoint, WSSupervisor, MockProvider}

IO.puts("🚀 Starting Mock RPC Test")
IO.puts("=" |> String.duplicate(50))

# Create mock endpoints for different networks
ethereum = MockWSEndpoint.ethereum_mainnet()
polygon = MockWSEndpoint.polygon()
arbitrum = MockWSEndpoint.arbitrum()

IO.puts("📡 Created mock endpoints:")
IO.puts("  - #{ethereum.name} (Chain ID: #{ethereum.chain_id})")
IO.puts("  - #{polygon.name} (Chain ID: #{polygon.chain_id})")
IO.puts("  - #{arbitrum.name} (Chain ID: #{arbitrum.chain_id})")

# Start connections
{:ok, _ethereum_pid} = WSSupervisor.start_connection(ethereum)
{:ok, _polygon_pid} = WSSupervisor.start_connection(polygon)
{:ok, _arbitrum_pid} = WSSupervisor.start_connection(arbitrum)

IO.puts("\n✅ Started all mock connections")

# List connections
connections = WSSupervisor.list_connections()
IO.puts("\n📊 Active connections:")
Enum.each(connections, fn conn ->
  IO.puts("  - #{conn.name} (#{conn.id}): #{conn.status}")
end)

# Test RPC calls
IO.puts("\n🔍 Testing RPC calls...")

# Get block numbers
{:ok, ethereum_block} = MockProvider.call(ethereum.mock_provider, "eth_blockNumber")
{:ok, polygon_block} = MockProvider.call(polygon.mock_provider, "eth_blockNumber")
{:ok, arbitrum_block} = MockProvider.call(arbitrum.mock_provider, "eth_blockNumber")

IO.puts("  Ethereum block: #{ethereum_block}")
IO.puts("  Polygon block: #{polygon_block}")
IO.puts("  Arbitrum block: #{arbitrum_block}")

# Test getting blocks
{:ok, ethereum_latest} = MockProvider.call(ethereum.mock_provider, "eth_getBlockByNumber", ["latest", false])
IO.puts("\n📦 Latest Ethereum block:")
IO.puts("  Number: #{ethereum_latest["number"]}")
IO.puts("  Hash: #{ethereum_latest["hash"]}")
IO.puts("  Transactions: #{length(ethereum_latest["transactions"])}")

# Test subscriptions
IO.puts("\n📡 Testing subscriptions...")

# Subscribe to new blocks
MockProvider.subscribe(ethereum.mock_provider, "newHeads")
MockProvider.subscribe(polygon.mock_provider, "newHeads")

IO.puts("  Subscribed to newHeads on Ethereum and Polygon")

# Get provider status
{:ok, ethereum_status} = MockProvider.status(ethereum.mock_provider)
{:ok, polygon_status} = MockProvider.status(polygon.mock_provider)

IO.puts("\n📈 Provider statistics:")
IO.puts("  Ethereum - Requests: #{ethereum_status.stats.total_requests}, Events: #{ethereum_status.stats.events_sent}")
IO.puts("  Polygon - Requests: #{polygon_status.stats.total_requests}, Events: #{polygon_status.stats.events_sent}")

# Wait for some events
IO.puts("\n⏳ Waiting for events (10 seconds)...")
Process.sleep(10_000)

# Get updated status
{:ok, ethereum_status_updated} = MockProvider.status(ethereum.mock_provider)
{:ok, polygon_status_updated} = MockProvider.status(polygon.mock_provider)

IO.puts("\n📈 Updated statistics:")
IO.puts("  Ethereum - Requests: #{ethereum_status_updated.stats.total_requests}, Events: #{ethereum_status_updated.stats.events_sent}")
IO.puts("  Polygon - Requests: #{polygon_status_updated.stats.total_requests}, Events: #{polygon_status_updated.stats.events_sent}")

# Test failure simulation
IO.puts("\n🔥 Testing failure simulation...")

# Create a provider with high failure rate
failure_provider = MockWSEndpoint.new(
  id: "mock_failure_test",
  name: "Mock Failure Test",
  chain_id: 999,
  failure_rate: 0.5,  # 50% failure rate
  block_time: 5_000
)

{:ok, _failure_pid} = WSSupervisor.start_connection(failure_provider)

# Test multiple calls to see failures
IO.puts("  Making 10 calls to failure provider...")
results = for i <- 1..10 do
  result = MockProvider.call(failure_provider.mock_provider, "eth_blockNumber")
  IO.puts("    Call #{i}: #{if elem(result, 0) == :ok, do: "✅ Success", else: "❌ Failed"}")
  result
end

success_count = Enum.count(results, fn {status, _} -> status == :ok end)
IO.puts("  Success rate: #{success_count}/10 (#{Float.round(success_count / 10 * 100, 1)}%)")

IO.puts("\n🎉 Mock RPC test completed!")
IO.puts("=" |> String.duplicate(50))

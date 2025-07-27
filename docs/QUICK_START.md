# Livechain Quick Start Guide

## Overview

This guide will help you get started with Livechain's mock RPC system for testing and development. The mock system provides realistic blockchain data simulation without requiring actual network connections.

## Prerequisites

- Elixir 1.18+ installed
- Mix (comes with Elixir)
- Basic understanding of Elixir/Erlang

## Installation

1. **Clone the repository** (if not already done):

   ```bash
   git clone <repository-url>
   cd livechain
   ```

2. **Install dependencies**:

   ```bash
   mix deps.get
   ```

3. **Compile the project**:
   ```bash
   mix compile
   ```

## Quick Start

### 1. Start the Application

```bash
# Start the application in the console
iex -S mix
```

### 2. Create Mock Endpoints

```elixir
# Import the required modules
alias Livechain.RPC.{MockWSEndpoint, WSSupervisor, MockProvider}

# Create mock endpoints for different networks
ethereum = MockWSEndpoint.ethereum_mainnet()
polygon = MockWSEndpoint.polygon()
arbitrum = MockWSEndpoint.arbitrum()

# Or create custom endpoints
custom = MockWSEndpoint.new(
  id: "my_custom_chain",
  name: "My Custom Chain",
  chain_id: 12345,
  block_time: 5_000,      # 5 seconds between blocks
  failure_rate: 0.01,     # 1% failure rate
  latency_range: {100, 500}  # 100-500ms latency
)
```

### 3. Start Connections

```elixir
# Start connections to the mock providers
{:ok, _ethereum_pid} = WSSupervisor.start_connection(ethereum)
{:ok, _polygon_pid} = WSSupervisor.start_connection(polygon)
{:ok, _arbitrum_pid} = WSSupervisor.start_connection(arbitrum)
```

### 4. Make RPC Calls

```elixir
# Get the latest block number
{:ok, block_number} = MockProvider.call(ethereum.mock_provider, "eth_blockNumber")
IO.puts("Latest block: #{block_number}")

# Get a specific block
{:ok, block} = MockProvider.call(ethereum.mock_provider, "eth_getBlockByNumber", ["latest", false])
IO.puts("Block hash: #{block["hash"]}")

# Get account balance
address = "0x742d35Cc6634C0532925a3b8D4C9db96C4b4d8b6"
{:ok, balance} = MockProvider.call(ethereum.mock_provider, "eth_getBalance", [address, "latest"])
IO.puts("Balance: #{balance}")
```

### 5. Subscribe to Events

```elixir
# Subscribe to new blocks
MockProvider.subscribe(ethereum.mock_provider, "newHeads")

# The mock provider will automatically generate new blocks
# and broadcast them to subscribers
```

### 6. Monitor Status

```elixir
# List all active connections
connections = WSSupervisor.list_connections()
Enum.each(connections, fn conn ->
  IO.puts("#{conn.name}: #{conn.status}")
end)

# Get detailed provider statistics
{:ok, stats} = MockProvider.status(ethereum.mock_provider)
IO.puts("Total requests: #{stats.stats.total_requests}")
IO.puts("Success rate: #{stats.stats.successful_requests / max(stats.stats.total_requests, 1) * 100}%")
```

## Running the Test Script

For a comprehensive demonstration, run the included test script:

```bash
elixir test_mock_rpc.exs
```

This script will:

- Create multiple mock endpoints
- Start connections
- Make various RPC calls
- Test subscriptions
- Demonstrate failure simulation
- Show statistics

## Configuration Options

### Mock Provider Configuration

```elixir
# Basic configuration
provider = MockWSEndpoint.new(
  id: "my_provider",
  name: "My Provider",
  chain_id: 1,
  block_time: 12_000,        # 12 seconds between blocks
  failure_rate: 0.01,        # 1% failure rate
  latency_range: {50, 200},  # 50-200ms latency
  enable_events: true        # Enable event streaming
)
```

### Advanced Configuration

```elixir
# High-performance configuration
fast_provider = MockWSEndpoint.new(
  id: "fast_provider",
  name: "Fast Provider",
  chain_id: 137,
  block_time: 2_000,         # 2 seconds between blocks
  failure_rate: 0.001,       # 0.1% failure rate
  latency_range: {10, 50},   # 10-50ms latency
  enable_events: true
)

# High-failure configuration for testing
failure_provider = MockWSEndpoint.new(
  id: "failure_test",
  name: "Failure Test",
  chain_id: 999,
  block_time: 5_000,
  failure_rate: 0.5,         # 50% failure rate
  latency_range: {100, 1000}, # 100-1000ms latency
  enable_events: true
)
```

## Supported RPC Methods

The mock provider supports the following Ethereum RPC methods:

### Block Methods

- `eth_blockNumber` - Get latest block number
- `eth_getBlockByNumber` - Get block by number
- `eth_getBlockByHash` - Get block by hash

### Account Methods

- `eth_getBalance` - Get account balance
- `eth_getTransactionCount` - Get transaction count
- `eth_getCode` - Get contract code

### Transaction Methods

- `eth_getTransactionByHash` - Get transaction by hash
- `eth_getTransactionReceipt` - Get transaction receipt

### Subscription Methods

- `eth_subscribe` - Subscribe to events
- `eth_unsubscribe` - Unsubscribe from events

## Event Types

The mock provider generates the following events:

- `newHeads` - New block headers
- `logs` - Contract event logs
- `pendingTransactions` - Pending transactions

## Troubleshooting

### Common Issues

1. **Connection not starting**:

   ```elixir
   # Check if the supervisor is running
   Process.whereis(Livechain.RPC.WSSupervisor)

   # Check for errors in the logs
   # Look for error messages in the console
   ```

2. **RPC calls failing**:

   ```elixir
   # Check provider status
   {:ok, status} = MockProvider.status(provider.mock_provider)
   IO.inspect(status)

   # Verify the provider is running
   Process.alive?(provider.mock_provider)
   ```

3. **No events received**:

   ```elixir
   # Check if events are enabled
   IO.inspect(provider.enable_events)

   # Verify subscription
   MockProvider.subscribe(provider.mock_provider, "newHeads")
   ```

### Debug Mode

Enable debug logging to see more detailed information:

```elixir
# In your IEx session
Logger.configure(level: :debug)
```

## Next Steps

1. **Explore the API**: Try different RPC methods and parameters
2. **Test Failure Scenarios**: Create providers with high failure rates
3. **Build Your Application**: Integrate the mock system into your development workflow
4. **Read the Documentation**: Check out the full vision document for architectural details
5. **Contribute**: Help improve the mock system or add new features

## Support

- **Documentation**: Check the `docs/` directory for detailed guides
- **Issues**: Report bugs or request features through the issue tracker
- **Discussions**: Join the community discussions for help and ideas

## Example Applications

### Simple Block Monitor

```elixir
defmodule BlockMonitor do
  def start_monitoring do
    # Create and start a mock provider
    provider = Livechain.RPC.MockWSEndpoint.ethereum_mainnet()
    {:ok, _pid} = Livechain.RPC.WSSupervisor.start_connection(provider)

    # Subscribe to new blocks
    Livechain.RPC.MockProvider.subscribe(provider.mock_provider, "newHeads")

    # Monitor blocks
    monitor_blocks(provider.mock_provider)
  end

  defp monitor_blocks(provider) do
    receive do
      {:websocket_message, message} ->
        case Jason.decode(message) do
          {:ok, %{"method" => "eth_subscription", "params" => %{"result" => block}}} ->
            IO.puts("New block: #{block["number"]} (#{block["hash"]})")
          _ ->
            :ok
        end
        monitor_blocks(provider)
    end
  end
end

# Start monitoring
BlockMonitor.start_monitoring()
```

This example shows how to create a simple block monitoring application using the mock RPC system.

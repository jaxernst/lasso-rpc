# Livechain Quick Start Guide

## Overview

This guide will help you get started with Livechain's real-time blockchain data streaming system. Livechain combines mock providers for development with Phoenix Channels for scalable WebSocket connections to client applications.

## Prerequisites

- Elixir 1.18+ installed
- Mix (comes with Elixir)
- Node.js (for WebSocket testing with wscat)

## Installation

1. **Clone the repository**:

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

### Option 1: Automated Demo

The fastest way to see Livechain in action:

```bash
# Run the comprehensive demo
mix run -e "Livechain.TestRunner.run_live_demo(60)"
```

This starts:
- Mock blockchain providers (Ethereum, Polygon)
- Phoenix WebSocket server on port 4000
- HTTP API endpoints
- Real-time block generation and broadcasting

### Option 2: Manual Setup

For hands-on exploration:

#### 1. Start Interactive Session

```bash
iex -S mix
```

#### 2. Create Mock Blockchain Endpoints

```elixir
# Import the required modules
alias Livechain.RPC.{MockWSEndpoint, WSSupervisor}

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

#### 3. Start Blockchain Connections

```elixir
# Start connections to the mock providers
{:ok, _ethereum_pid} = WSSupervisor.start_connection(ethereum)
{:ok, _polygon_pid} = WSSupervisor.start_connection(polygon)
{:ok, _arbitrum_pid} = WSSupervisor.start_connection(arbitrum)

# Check connection status
WSSupervisor.list_connections()
```

#### 4. Start Phoenix WebSocket Server

```elixir
# Start the Phoenix endpoint for WebSocket connections
{:ok, _endpoint_pid} = LivechainWeb.Endpoint.start_link()
```

## WebSocket Client Testing

### Install WebSocket Client

```bash
npm install -g wscat
```

### Connect Multiple Clients

Open multiple terminals and run:

```bash
# Terminal 1 - Ethereum client
wscat -c "ws://localhost:4000/socket/websocket"

# Terminal 2 - Polygon client  
wscat -c "ws://localhost:4000/socket/websocket"

# Terminal 3 - Multi-chain client
wscat -c "ws://localhost:4000/socket/websocket"
```

### Join Blockchain Channels

In each WebSocket client, send:

```json
# Join Ethereum channel
{"topic":"blockchain:ethereum","event":"phx_join","payload":{},"ref":"1"}

# Join Polygon channel
{"topic":"blockchain:polygon","event":"phx_join","payload":{},"ref":"2"}
```

### Subscribe to Real-Time Events

```json
# Subscribe to Ethereum blocks
{"topic":"blockchain:ethereum","event":"subscribe","payload":{"type":"blocks"},"ref":"3"}

# Subscribe to Polygon blocks
{"topic":"blockchain:polygon","event":"subscribe","payload":{"type":"blocks"},"ref":"4"}
```

### Watch Real-Time Data! 🎉

You should now see live blockchain data streaming to all connected clients:

```json
{
  "event": "new_block",
  "payload": {
    "chain_id": "ethereum",
    "block": {
      "number": "0x123",
      "hash": "0xabc...",
      "timestamp": "0x...",
      "transactions": [...]
    }
  }
}
```

## HTTP API Testing

Test the REST endpoints:

```bash
# System health
curl http://localhost:4000/api/health

# Detailed system status
curl http://localhost:4000/api/status

# List supported chains
curl http://localhost:4000/api/chains

# Specific chain status
curl http://localhost:4000/api/chains/1/status  # Ethereum
curl http://localhost:4000/api/chains/137/status  # Polygon
```

## Advanced Usage

### Direct RPC Calls to Mock Providers

```elixir
# Get the latest block number
{:ok, block_number} = Livechain.RPC.MockProvider.call(
  ethereum.mock_provider, 
  "eth_blockNumber"
)

# Get a specific block
{:ok, block} = Livechain.RPC.MockProvider.call(
  ethereum.mock_provider,
  "eth_getBlockByNumber", 
  ["latest", false]
)

# Get account balance
{:ok, balance} = Livechain.RPC.MockProvider.call(
  ethereum.mock_provider,
  "eth_getBalance", 
  ["0x742d35Cc6634C0532925a3b8D4C9db96C4b4d8b6", "latest"]
)
```

### Real Blockchain Connections

For production use with real RPC providers:

```elixir
alias Livechain.RPC.RealEndpoints

# Using Infura (requires API key)
ethereum_real = RealEndpoints.ethereum_mainnet_infura("your_infura_api_key")

# Using public endpoints
ethereum_public = RealEndpoints.ethereum_mainnet_public()

# Start real connection
{:ok, _pid} = WSSupervisor.start_connection(ethereum_real)
```

### Monitor System Status

```elixir
# List all active connections
connections = WSSupervisor.list_connections()

# Get detailed connection info
Enum.each(connections, fn conn ->
  IO.puts("#{conn.name}: #{conn.status}")
  IO.puts("  Reconnect attempts: #{conn.reconnect_attempts}")
  IO.puts("  Subscriptions: #{conn.subscriptions}")
end)
```

## Phoenix Channels Architecture

### How It Works

Livechain uses a two-tier architecture:

1. **GenServers** connect to blockchain RPC nodes and handle data ingestion
2. **Phoenix Channels** handle WebSocket connections from client applications  
3. **Phoenix PubSub** broadcasts data from GenServers to all connected clients

```
[Blockchain RPC] ←→ [GenServer] → [PubSub] → [Phoenix Channel] ←→ [Your App]
```

### Multi-Client Broadcasting

When a new block arrives:
1. GenServer receives it from the blockchain
2. Broadcasts to PubSub topic `"blockchain:ethereum"`
3. All subscribed Phoenix Channels receive the event
4. Channels push the data to their WebSocket clients
5. **All connected clients get the same data simultaneously**

### Supported Channels

- `blockchain:ethereum` - Ethereum mainnet data
- `blockchain:polygon` - Polygon network data
- `blockchain:arbitrum` - Arbitrum network data
- `blockchain:bsc` - Binance Smart Chain data

### Channel Events

- `new_block` - New blockchain blocks
- `new_transaction` - New transactions
- `chain_status` - Connection status updates

## Configuration Options

### Mock Provider Configuration

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

### Real Provider Configuration

```elixir
# Production configuration with Infura
config :livechain,
  infura_api_key: System.get_env("INFURA_API_KEY"),
  alchemy_api_key: System.get_env("ALCHEMY_API_KEY")
```

## Supported RPC Methods

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

## Troubleshooting

### WebSocket Connection Issues

```bash
# Test WebSocket connectivity
wscat -c "ws://localhost:4000/socket/websocket"
```

### Phoenix Channel Issues

```elixir
# Check if Phoenix endpoint is running
Process.whereis(LivechainWeb.Endpoint)

# Restart if needed
LivechainWeb.Endpoint.start_link()
```

### Blockchain Connection Issues

```elixir
# Check blockchain connections
Livechain.RPC.WSSupervisor.list_connections()

# Check specific connection status
Livechain.RPC.WSSupervisor.connection_status("ethereum_mainnet_public")
```

### Debug Mode

```elixir
# Enable debug logging
Logger.configure(level: :debug)

# Monitor PubSub messages
Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:ethereum")
```

## Example Applications

### JavaScript WebSocket Client

```javascript
// Connect to Livechain
const socket = new WebSocket('ws://localhost:4000/socket/websocket');

socket.onopen = function() {
  // Join Ethereum channel
  const joinMessage = {
    topic: "blockchain:ethereum",
    event: "phx_join", 
    payload: {},
    ref: "1"
  };
  socket.send(JSON.stringify(joinMessage));
};

socket.onmessage = function(event) {
  const data = JSON.parse(event.data);
  
  if (data.event === "new_block") {
    console.log("New Ethereum block:", data.payload.block);
    // Update your UI with new block data
  }
};
```

### Elixir GenServer Client

```elixir
defmodule MyBlockchainClient do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    # Subscribe to Ethereum blocks via PubSub
    Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:ethereum")
    {:ok, state}
  end

  def handle_info(%{event: "new_block", payload: block_data}, state) do
    IO.puts("Received new block: #{block_data["number"]}")
    # Process block data here
    {:noreply, state}
  end
end
```

## Production Deployment

### Docker Compose

```yaml
version: '3.8'
services:
  livechain:
    build: .
    ports:
      - "4000:4000"
    environment:
      - INFURA_API_KEY=${INFURA_API_KEY}
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
    restart: unless-stopped
```

### Environment Variables

```bash
export INFURA_API_KEY="your_infura_api_key"
export ALCHEMY_API_KEY="your_alchemy_api_key"
export SECRET_KEY_BASE="your_secret_key_base"
```

## Next Steps

1. **Multi-Client Testing**: Connect multiple WebSocket clients simultaneously
2. **Build Your Frontend**: Integrate with React, Vue, or any WebSocket-capable framework
3. **Scale Horizontally**: Deploy multiple Livechain instances with load balancing
4. **Add Custom Chains**: Extend support for additional blockchain networks
5. **Monitoring**: Set up metrics and alerting for production use

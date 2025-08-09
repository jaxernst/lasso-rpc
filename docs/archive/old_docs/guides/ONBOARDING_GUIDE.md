# 🚀 Livechain Onboarding Guide

## Your Journey Through Real-Time Blockchain Orchestration

Welcome to **Livechain** - a live-first blockchain event streaming system built with Elixir and Phoenix. This guide will take you on a journey through the codebase, explaining the architecture, patterns, and design decisions that make this system powerful and reliable.

---

## 🎯 What You're Building

Livechain is a **real-time blockchain event streaming middleware** that solves a critical problem: unreliable RPC providers causing app downtime and the complexity of building custom event listeners for each consumer app.

### The Problem We're Solving

```
┌─────────────────────────────────────────────────────────────┐
│                    The Current Reality                      │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │   App 1     │  │   App 2     │  │   App 3     │      │
│  │ (Farcaster) │  │ (DeFi App)  │  │ (NFT App)   │      │
│  └─────────────┘  └─────────────┘  └─────────────┘      │
│         │                │                │              │
│         ▼                ▼                ▼              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │  Custom     │  │  Custom     │  │  Custom     │      │
│  │ Event List. │  │ Event List. │  │ Event List. │      │
│  └─────────────┘  └─────────────┘  └─────────────┘      │
│         │                │                │              │
│         ▼                ▼                ▼              │
│  ┌─────────────────────────────────────────────────────┐  │
│  │           Fragile RPC Provider Chain               │  │
│  │  Infura → Alchemy → Public RPC → App Crashes       │  │
│  └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### The Livechain Solution

```
┌─────────────────────────────────────────────────────────────┐
│                    Livechain Reality                       │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │   App 1     │  │   App 2     │  │   App 3     │      │
│  │ (Farcaster) │  │ (DeFi App)  │  │ (NFT App)   │      │
│  └─────────────┘  └─────────────┘  └─────────────┘      │
│         │                │                │              │
│         └────────────────┼────────────────┘              │
│                          │                               │
│                          ▼                               │
│  ┌─────────────────────────────────────────────────────┐  │
│  │              Livechain Service                      │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │   Unified   │  │   Real-time │  │   Fault     │  │  │
│  │  │   Event     │  │   Streaming │  │  Tolerant   │  │  │
│  │  │   Feed      │  │   <1s Lat.  │  │   RPC Pool  │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  └─────────────────────────────────────────────────────┘  │
│                          │                               │
│                          ▼                               │
│  ┌─────────────────────────────────────────────────────┐  │
│  │           Robust Multi-Provider Pool               │  │
│  │  Infura + Alchemy + Public RPC + Auto-Failover     │  │
│  └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 🏗️ Architecture Overview

Livechain follows a **layered architecture** with clear separation of concerns. Let's explore each layer:

### The Architecture Stack

```
┌─────────────────────────────────────────────────────────────┐
│                    Client Applications                     │
│  (Viem/Wagmi dApps, Farcaster, DeFi Protocols)            │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────┐  │
│  │              Web Interface Layer                    │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │   HTTP      │  │ WebSocket   │  │   Phoenix   │  │  │
│  │  │  Controllers│  │  Channels   │  │   PubSub    │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  └─────────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────┐  │
│  │              Orchestration Layer                    │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │   Chain     │  │   Provider  │  │   Message   │  │  │
│  │  │  Manager    │  │    Pool     │  │ Aggregator  │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  └─────────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────┐  │
│  │              Connection Layer                       │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │  │
│  │  │ WebSocket   │  │   Circuit   │  │   Process   │  │  │
│  │  │ Connections │  │  Breakers   │  │  Registry   │  │  │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  │  │
│  └─────────────────────────────────────────────────────┘  │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────┐  │
│  │              Blockchain Networks                    │  │
│  │  Ethereum, Base, Polygon, Arbitrum, Solana         │  │
│  └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 🚀 Your First Steps: Understanding the Codebase

### 1. Start with the Application Entry Point

The journey begins in `lib/livechain/application.ex`:

```elixir
defmodule Livechain.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start PubSub for real-time messaging
      {Phoenix.PubSub, name: Livechain.PubSub},

      # Start process registry for centralized process management
      {Livechain.RPC.ProcessRegistry, name: Livechain.RPC.ProcessRegistry},

      # Start dynamic supervisor for chain supervisors
      {DynamicSupervisor, strategy: :one_for_one, name: Livechain.RPC.Supervisor},

      # Start the chain manager for orchestrating all blockchain connections
      Livechain.RPC.ChainManager,

      # Start the WebSocket supervisor
      Livechain.RPC.WSSupervisor,

      # Start Phoenix endpoint
      LivechainWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Livechain.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

**What's happening here?**

- We're building a **supervision tree** - Elixir's way of ensuring fault tolerance
- Each component is a **GenServer** or **Supervisor** that can be monitored and restarted
- The system starts from the bottom up: infrastructure → orchestration → web interface

### 2. The Chain Manager: Your Orchestration Hub

The `ChainManager` is the brain of the system. It coordinates multiple blockchain connections:

```elixir
defmodule Livechain.RPC.ChainManager do
  use GenServer

  defstruct [
    :config,           # Chain configurations
    :chain_supervisors, # Active chain supervisors
    :global_stats      # System-wide statistics
  ]
end
```

**Key Responsibilities:**

- **Load chain configurations** from YAML files
- **Start/stop chain supervisors** dynamically
- **Monitor health** across all chains
- **Provide unified interface** for client applications

### 3. Understanding the Chain Supervisor Pattern

Each blockchain gets its own supervisor that manages multiple RPC providers:

```
┌─────────────────────────────────────────────────────────────┐
│                 ChainSupervisor (Ethereum)                 │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │ Provider 1  │  │ Provider 2  │  │ Provider 3  │      │
│  │ (Infura)    │  │ (Alchemy)   │  │ (Public)    │      │
│  │ Priority 1  │  │ Priority 2  │  │ Priority 3  │      │
│  └─────────────┘  └─────────────┘  └─────────────┘      │
│         │                │                │              │
│         └────────────────┼────────────────┘              │
│                          │                               │
│  ┌─────────────────────────────────────────────────────┐  │
│  │              Message Aggregator                     │  │
│  │  • Deduplicates messages from multiple providers   │  │
│  │  • Always forwards the fastest response            │  │
│  │  • Handles provider failures gracefully            │  │
│  └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 4. The Provider Pool: Health and Failover

The `ProviderPool` manages the health and failover logic:

```elixir
defmodule Livechain.RPC.ProviderPool do
  # Manages provider health, failover, and load balancing

  def get_best_provider(chain_name) do
    # Returns the healthiest provider with highest priority
  end

  def mark_unhealthy(chain_name, provider_id) do
    # Marks provider as unhealthy, triggers failover
  end
end
```

**Failover Flow:**

```
Provider 1 (Infura) Fails
         ↓
Circuit Breaker Opens
         ↓
Provider 2 (Alchemy) Takes Over
         ↓
Health Check Monitors Recovery
         ↓
Provider 1 Returns When Healthy
```

---

## 🔧 Core Patterns You'll Encounter

### 1. The GenServer Pattern

Most components in Livechain are GenServers. Here's the pattern:

```elixir
defmodule Livechain.RPC.ExampleGenServer do
  use GenServer

  # Client API
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def some_operation(data) do
    GenServer.call(__MODULE__, {:some_operation, data})
  end

  # Server Callbacks
  @impl true
  def init(opts) do
    {:ok, initial_state}
  end

  @impl true
  def handle_call({:some_operation, data}, _from, state) do
    # Process the operation
    new_state = process_data(data, state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:some_message, state) do
    # Handle async messages
    {:noreply, state}
  end
end
```

### 2. The Supervisor Pattern

Supervisors ensure fault tolerance:

```elixir
defmodule Livechain.RPC.ExampleSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Worker1, []},
      {Worker2, []},
      {Worker3, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

**Supervision Strategies:**

- `:one_for_one`: Restart only the failed child
- `:one_for_all`: Restart all children when one fails
- `:rest_for_one`: Restart the failed child and all children started after it

### 3. The PubSub Pattern

Phoenix PubSub enables real-time communication:

```elixir
# Broadcasting events
Phoenix.PubSub.broadcast(Livechain.PubSub, "blockchain:ethereum", {:new_block, block_data})

# Subscribing to events
Phoenix.PubSub.subscribe(Livechain.PubSub, "blockchain:ethereum")
```

---

## 🌐 Web Interface Layer

### HTTP Controllers

The web interface provides both HTTP and WebSocket endpoints:

```elixir
# Health check endpoint
defmodule LivechainWeb.HealthController do
  use LivechainWeb, :controller

  def health(conn, _params) do
    health_status = %{
      status: "healthy",
      timestamp: DateTime.utc_now(),
      uptime: System.monotonic_time(:second),
      version: Application.spec(:livechain, :vsn)
    }

    json(conn, health_status)
  end
end
```

### WebSocket Channels

Real-time event streaming happens through Phoenix Channels:

```elixir
defmodule LivechainWeb.BlockchainChannel do
  use LivechainWeb, :channel

  def join("blockchain:" <> chain_name, _params, socket) do
    # Join a specific blockchain channel
    {:ok, socket}
  end

  def handle_in("subscribe", %{"type" => event_type}, socket) do
    # Subscribe to specific event types
    {:reply, :ok, socket}
  end
end
```

---

## 🔄 Data Flow: From Blockchain to Client

Let's trace how data flows through the system:

```
┌─────────────────────────────────────────────────────────────┐
│                    Data Flow Journey                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. Blockchain Event Occurs                                │
│     ┌─────────────┐                                        │
│     │  Ethereum   │  New block mined                       │
│     │  Network    │  USDC transfer executed                 │
│     └─────────────┘                                        │
│             │                                               │
│             ▼                                               │
│  2. RPC Provider Receives Event                            │
│     ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│     │   Infura    │  │   Alchemy   │  │   Public    │      │
│     │  WebSocket  │  │  WebSocket  │  │  WebSocket  │      │
│     └─────────────┘  └─────────────┘  └─────────────┘      │
│             │               │               │              │
│             └───────────────┼───────────────┘              │
│                             │                               │
│                             ▼                               │
│  3. Message Aggregator Processes                            │
│     ┌─────────────────────────────────────────────────────┐ │
│     │              Message Aggregator                     │ │
│     │  • Deduplicates identical events                   │ │
│     │  • Selects fastest response                         │ │
│     │  • Transforms raw data to structured events        │ │
│     └─────────────────────────────────────────────────────┘ │
│                             │                               │
│                             ▼                               │
│  4. Phoenix PubSub Broadcasts                              │
│     ┌─────────────────────────────────────────────────────┐ │
│     │              Phoenix PubSub                         │ │
│     │  • Broadcasts to all subscribed channels           │ │
│     │  • Handles thousands of concurrent subscribers     │ │
│     │  • Ensures reliable message delivery               │ │
│     └─────────────────────────────────────────────────────┘ │
│                             │                               │
│                             ▼                               │
│  5. WebSocket Channels Deliver to Clients                 │
│     ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│     │   Client 1  │  │   Client 2  │  │   Client N  │      │
│     │ (Farcaster) │  │ (DeFi App)  │  │ (NFT App)   │      │
│     └─────────────┘  └─────────────┘  └─────────────┘      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Key Performance Characteristics:**

- **Sub-second latency**: Events delivered in <1 second
- **Automatic failover**: Provider failures handled seamlessly
- **Scalable**: Thousands of concurrent WebSocket connections
- **Fault-tolerant**: Individual failures don't cascade

---

## 🧪 Testing and Development

### Mock Provider System

For development and testing, Livechain includes a comprehensive mock system:

```elixir
# Create mock endpoints
ethereum = Livechain.RPC.MockWSEndpoint.ethereum_mainnet()
polygon = Livechain.RPC.MockWSEndpoint.polygon()

# Start connections
{:ok, _pid} = Livechain.RPC.WSSupervisor.start_connection(ethereum)
{:ok, _pid} = Livechain.RPC.WSSupervisor.start_connection(polygon)
```

**Mock Features:**

- **Realistic data generation**: Authentic blockchain data structures
- **Configurable latency**: Simulate network delays (50-200ms)
- **Failure simulation**: Configurable failure rates
- **Event streaming**: WebSocket-like subscription events

### Running Tests

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test files
mix test test/livechain/architecture_test.exs

# Run live integration tests (requires network)
mix test --only live
```

---

## 🚀 Getting Started: Your First Steps

### 1. Start the Application

```bash
# Clone and setup
git clone <repository>
cd livechain
mix deps.get

# Start the application
mix run --no-halt
```

### 2. Test the Health Endpoint

```bash
# Check if the service is running
curl http://localhost:4000/api/health

# Expected response:
{
  "status": "healthy",
  "timestamp": "2024-01-15T12:00:00Z",
  "uptime": 12345,
  "version": "0.1.0"
}
```

### 3. Connect to WebSocket

```bash
# Install wscat for WebSocket testing
npm install -g wscat

# Connect to the blockchain channel
wscat -c "ws://localhost:4000/socket/websocket"

# Join Ethereum channel
{"topic":"blockchain:ethereum","event":"phx_join","payload":{},"ref":"1"}

# Subscribe to new blocks
{"topic":"blockchain:ethereum","event":"subscribe","payload":{"type":"blocks"},"ref":"2"}
```

### 4. Explore the Codebase

**Start with these files:**

1. `lib/livechain/application.ex` - Application startup
2. `lib/livechain/rpc/chain_manager.ex` - Main orchestration
3. `lib/livechain/rpc/chain_supervisor.ex` - Per-chain management
4. `lib/livechain_web/channels/blockchain_channel.ex` - Real-time events
5. `config/chains.yml` - Chain configurations

---

## 🎯 Key Concepts to Master

### 1. OTP and Supervision

- **GenServers**: Stateful processes with message handling
- **Supervisors**: Fault tolerance and process management
- **DynamicSupervisor**: Runtime process creation

### 2. Phoenix Channels

- **Real-time communication**: WebSocket-based event streaming
- **PubSub**: Broadcasting events to multiple subscribers
- **Channel lifecycle**: Join, subscribe, leave patterns

### 3. Configuration Management

- **YAML-based configs**: Chain and provider definitions
- **Environment variables**: API keys and secrets
- **Runtime configuration**: Dynamic provider management

### 4. Error Handling

- **Circuit breakers**: Prevent cascade failures
- **Automatic failover**: Seamless provider switching
- **Graceful degradation**: Partial failures don't break the system

---

## 🔍 Debugging and Monitoring

### Logging

Livechain uses structured logging throughout:

```elixir
require Logger

Logger.info("Starting ChainSupervisor for #{chain_name}")
Logger.error("Provider #{provider_id} failed: #{reason}")
```

### Telemetry

The system includes comprehensive telemetry:

```elixir
# Custom telemetry events
:telemetry.execute([:livechain, :provider, :request], %{
  provider: provider_id,
  method: "eth_getBlockByNumber",
  duration: 150
})
```

### Health Monitoring

```bash
# Check system status
curl http://localhost:4000/api/status

# Monitor specific chain
curl http://localhost:4000/api/chains/ethereum/status
```

---

## 🎉 Congratulations!

You've completed your journey through the Livechain codebase! You now understand:

- ✅ **The architecture**: Layered design with clear separation of concerns
- ✅ **The patterns**: GenServer, Supervisor, PubSub, and more
- ✅ **The data flow**: From blockchain events to client applications
- ✅ **The testing approach**: Mock providers and comprehensive test coverage
- ✅ **The deployment**: How to start and monitor the system

### Next Steps

1. **Explore the test files**: Understand how each component is tested
2. **Try the mock providers**: Experiment with different failure scenarios
3. **Connect a real client**: Build a simple WebSocket client
4. **Add a new chain**: Configure and test a new blockchain network
5. **Contribute**: Fix bugs, add features, improve documentation

### Resources

- **Elixir Documentation**: https://elixir-lang.org/docs.html
- **Phoenix Framework**: https://hexdocs.pm/phoenix/
- **OTP Design Principles**: https://elixir-lang.org/getting-started/mix-otp/supervisor-and-application.html
- **Livechain Architecture**: See `docs/RPC_ORCHESTRATION_VISION.md`

Welcome to the team! 🚀

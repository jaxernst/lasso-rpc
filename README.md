# Livechain

**An intelligent blockchain RPC orchestrator and smart router for bulletproof onchain application development.**

Building reliable blockchain applications is challenging, largely due to the complexity of choosing and managing RPC providers. With dozens of providers offering different performance, pricing models, and reliability guarantees, developers face an opaque decision that directly impacts their application's user experience.

Livechain solves this by acting as an intelligent proxy that sits between your application and multiple RPC providers. While it provides the same JSON-RPC endpoints for WebSocket and HTTP that you'd expect from any provider, Livechain orchestrates **all** your providers across **all** your chains. It automatically routes requests to the best-performing provider, handles failures gracefully, and gives you the reliability and performance to build consumer-grade onchain applications.

Want to bypass rate limits? Configure Livechain to target multiple free providers and load balance between them:

```
POST /rpc/base # Automatically load balances across available providers
```

Want the fastest possible responses? Livechain routes to your best-performing provider using real-world benchmarks:

```
POST /rpc/ethereum # Automatic routing based on passive performance measurement
```

Want much better reliability? Livechain will quietly retry your failed request with circuit breakers and intelligent failover—your application stays resilient when providers don't.

Want to build your own blockchain node infrastructure? Start with Livechain as your orchestration layer.

## Built on Elixir/OTP: Fault-Tolerance by Design

Livechain runs on the Erlang BEAM VM, a battle-tested platform that powers highly scalable platforms like WhatsApp, Discord, Supabase, and telecom infrastructure serving billions of users. This gives us superpowers:

- **Massive concurrency**: Handle thousands of concurrent connections with minimal overhead
- **Fault isolation**: Provider failures don't cascade—each connection runs in its own lightweight process
- **Self-healing**: Crashed processes automatically restart without affecting others
- **Hot code updates**: Deploy fixes without downtime
- **Distributed by default**: Simple and high level primitives to coordinate across multiple nodes and regions

## Global Distribution Potential

BEAM's distributed capabilities unlock powerful possibilities for smart routing:

- **Regional nodes**: Deploy Livechain instances globally, each maintaining region-local performance benchmarks
- **Latency-aware routing**: Clients connect to the nearest Livechain node, which routes to the fastest upstream provider for that region
- **Cross-region coordination**: Nodes can share performance data to optimize routing decisions globally
- **Edge deployment**: Run Livechain close to your users for minimal added latency

This architecture scales from a single self-hosted instance to a global network of coordinated nodes.

## Core Features

- **Multi-provider orchestration** with pluggable routing strategies (fastest, cheapest, priority, round-robin)
- **Full JSON-RPC compatibility** via HTTP and WebSocket proxies for all standard read-only methods
- **RPC Method failover** with per-provider circuit breakers and health monitoring
- **Passive benchmarking** using real traffic to measure provider performance per-chain and per-method
- **Performance tracking** - measures real RPC call latencies to optimize provider selection
- **Live dashboard** with real-time insights, provider leaderboards, and performance metrics
- **Global distribution ready** with BEAM's built-in clustering and fault-tolerance

## Usage

### HTTP vs WebSocket

- WebSocket (WS): Subscriptions (e.g., `eth_subscribe`, `eth_unsubscribe`) and read-only methods.
- HTTP (POST /rpc/:chain): Read-only methods proxied to upstream providers.
  - WS-only methods over HTTP return a JSON-RPC error with a hint to use WS.

### Provider Selection Strategy

The orchestrator uses a pluggable strategy to pick providers when forwarding HTTP calls.

- Default: `:cheapest` (prefers free providers)
- Alternatives: `:fastest` (performance-based), `:priority` (static config), `:round_robin` (load balanced)

Try all 4 strategies with these endpoints:

```bash
# 💰 CHEAPEST - Prefers free providers to save costs
curl -X POST http://localhost:4000/rpc/cheapest/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# ⚡ FASTEST - Routes to best-performing provider based on real latency data
curl -X POST http://localhost:4000/rpc/fastest/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 📊 PRIORITY - Uses static configuration priorities
curl -X POST http://localhost:4000/rpc/priority/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 🔄 ROUND_ROBIN - Load balances across all available providers
curl -X POST http://localhost:4000/rpc/round-robin/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

## Quick Start

### Prerequisites

- **Elixir/OTP 26+** - [Install Elixir](https://elixir-lang.org/install.html)
- **Node.js 18+** - [Install Node.js](https://nodejs.org/) (for Phoenix LiveView assets)

### 🚀 Running Locally (For Judges & Reviewers)

```bash
# 1. Clone the repository
git clone https://github.com/your-org/livechain
cd livechain

# 2. Install Elixir dependencies
mix deps.get

# 3. Install Node.js assets (for the dashboard)
cd assets && npm install && cd ..

# 4. Start the Phoenix server
mix phx.server

# 5. Open your browser
open http://localhost:4000
```

**🎯 The app will be running at:** http://localhost:4000

**⚡ Test the routing strategies immediately:**

```bash
# Test cheapest strategy (uses free providers first)
curl -X POST http://localhost:4000/rpc/cheapest/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Test fastest strategy (performance-based routing)
curl -X POST http://localhost:4000/rpc/fastest/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

**📊 View the live dashboard:** http://localhost:4000 for real-time provider metrics

### 🎬 Automated Demo

Run the interactive demo script:

```bash
# Demonstrates all 4 routing strategies with live examples
./scripts/demo_routing_strategies.exs
```

### Configure Providers

Edit `config/chains.yml` to add your RPC providers:

```yaml
chains:
  ethereum:
    chain_id: 1
    name: "Ethereum Mainnet"
    providers:
      - id: "ankr_eth"
        name: "Ankr Public"
        url: "https://rpc.ankr.com/eth"
        ws_url: "wss://rpc.ankr.com/eth/ws"
        type: "public"
      - id: "alchemy_eth"
        name: "Alchemy"
        url: "https://eth-mainnet.g.alchemy.com/v2/YOUR-API-KEY"
        ws_url: "wss://eth-mainnet.g.alchemy.com/v2/YOUR-API-KEY"
        type: "premium"
```

### Basic Usage

```bash
# Get latest block
curl -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# WebSocket subscriptions
wscat -c ws://localhost:4000/rpc/ethereum
{"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}
```

## API Reference

### Supported Chains & Endpoints

```bash
# Ethereum Mainnet
POST /rpc/ethereum
WebSocket: ws://localhost:4000/rpc/ethereum

# Base
POST /rpc/base
WebSocket: ws://localhost:4000/rpc/base

# Polygon, Arbitrum, etc. (configurable)
```

### Supported Methods

- **Block queries**: `eth_blockNumber`, `eth_getBlockByNumber`, `eth_getBlockByHash`
- **Account queries**: `eth_getBalance`, `eth_getTransactionCount`, `eth_getCode`
- **Transaction queries**: `eth_getTransactionByHash`, `eth_getTransactionReceipt`
- **Log queries**: `eth_getLogs` with full filter support
- **Subscriptions** (WebSocket only): `eth_subscribe`, `eth_unsubscribe` for `newHeads`, `logs`

### System Health & Metrics

```bash
# Health check
GET /api/health

# Detailed system status
GET /api/status

# Provider performance metrics
GET /api/metrics/:chain
```

## Key Innovation: Real Performance Tracking

Unlike traditional load balancers, Livechain uses **real RPC call measurements** for intelligent routing:

1. **Track actual RPC latencies** from your production traffic
2. **Build provider leaderboards** based on real performance data
3. **Route requests intelligently** using the `:fastest` strategy
4. **Automatic failover** when providers fail or slow down

This gives you production-grounded performance data without synthetic benchmarks or artificial load.

## Live Dashboard

Access the real-time dashboard at `http://localhost:4000`:

- **Provider leaderboards** with win rates and average latency
- **Performance matrix** showing RPC call latencies by provider and method
- **Circuit breaker status** and provider health monitoring
- **Chain selection** to switch between networks
- **System simulator** for load testing

## Architecture

Built on **Elixir/OTP** for fault-tolerance and massive concurrency:

- **Process isolation**: Each provider connection runs in its own lightweight process
- **Circuit breakers**: Automatic failover when providers fail
- **Self-healing**: Crashed processes restart automatically without affecting others
- **Hot updates**: Deploy fixes without downtime
- **Distributed ready**: Simple clustering across multiple nodes/regions

## Configuration

### Provider Selection Strategy

```elixir
# config/config.exs
config :livechain, :provider_selection_strategy, :fastest
# Options: :fastest, :cheapest, :priority, :round_robin
```

### Circuit Breaker Settings

```elixir
config :livechain, :circuit_breaker,
  failure_threshold: 5,      # failures before opening
  recovery_timeout: 60_000,  # ms before retry
  success_threshold: 2       # successes before closing
```

## Development & Testing

```bash
# Run tests
mix test

# Start with simulation mode
mix phx.server
# Visit http://localhost:4000/simulator

# Load testing
mix run scripts/load_test.exs
```

## Links

- [Full Documentation](docs/)
- [API Reference](docs/API_REFERENCE.md)
- [Architecture Deep Dive](docs/ARCHITECTURE.md)
- [Getting Started Guide](docs/GETTING_STARTED.md)

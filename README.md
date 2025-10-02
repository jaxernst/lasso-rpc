# Lasso RPC

**A smart blockchain RPC aggregator for building bulletproof onchain applications.**

<img width="1466" height="1034" alt="Screenshot 2025-09-02 at 5 13 21 PM" src="https://github.com/user-attachments/assets/0fdd37bb-e4c2-4ae0-b3c8-3cb3f4ba04d6" />

#### [watch the demo](https://www.youtube.com/watch?v=ZhCqh001zNE)

---

Building reliable blockchain applications is challenging, largely due to the complexity of choosing and managing RPC providers. With dozens of providers offering different performance, pricing models, and reliability guarantees, developers face an opaque decision that directly impacts their application's user experience.

Lasso solves this by acting as an intelligent proxy that sits between your application and multiple RPC providers. While it provides the same JSON-RPC endpoints for WebSocket and HTTP that you'd expect from any provider, Lasso orchestrates **all** your providers across **all** your chains. It automatically routes requests to the best-performing provider, handles failures gracefully, and gives you the reliability and performance to build consumer-grade onchain applications.

Want to bypass rate limits? Configure Lasso to target multiple free providers and load balance between them:

```
POST /rpc/base # Automatically load balances across available providers
```

Want the fastest possible responses? Lasso routes to your best-performing provider using real-world RPC latency benchmarks:

```
POST /rpc/fastest/ethereum # Automatic routing based on passive performance measurement
```

Want much better reliability? Lasso will quietly retry your failed request with circuit breakers and intelligent failover—your application stays resilient when providers don't.

Want to build your own blockchain node infrastructure? Start with Lasso as your orchestration layer.

## Built on Elixir/OTP: Fault-Tolerance by Design

Lasso runs on the Erlang BEAM VM, a battle-tested platform that powers highly scalable platforms like WhatsApp, Discord, Supabase, and telecom infrastructure serving billions of users. This gives us superpowers:

- **Massive concurrency**: Handle thousands of concurrent connections with minimal overhead
- **Fault isolation**: Provider failures don't cascade—each connection runs in its own lightweight process
- **Self-healing**: Crashed processes automatically restart without affecting others
- **Hot code updates**: Deploy fixes without downtime
- **Distributed by default**: Simple and high level primitives to coordinate across multiple nodes and regions

## Core Features

- **Multi-provider orchestration** with pluggable routing strategies (fastest, cheapest, priority, round-robin)
- **Transport-agnostic routing** - single requests automatically route across both HTTP and WebSocket providers based on performance
- **Full JSON-RPC compatibility** via HTTP and WebSocket proxies for all standard read-only methods
- **WebSocket subscription management** - intelligent multiplexing, automatic failover with gap-filling during provider switches
- **RPC Method failover** with per-provider circuit breakers and health monitoring
- **Method-specific benchmarking** using real RPC call latencies to measure provider performance per-chain and per-method
- **Intelligent routing** - automatically selects providers based on actual latency measurements for each RPC method
- **Request observability** - structured logs and optional client-visible metadata for routing decisions, latencies, and retries
- **Battle testing framework** - sophisticated load testing with chaos engineering capabilities for validating reliability
- **Live dashboard** with real-time insights, provider leaderboards, and performance metrics
- **Globally distributable** with BEAM's built-in clustering and fault-tolerance

## Global Distribution Potential

BEAM's distributed capabilities unlock powerful possibilities for smart routing:

- **Regional nodes**: Deploy Lasso instances globally, each maintaining region-local performance benchmarks
- **Latency-aware routing**: Clients connect to the nearest Lasso node, which routes to the fastest upstream provider for that region
- **Cross-region coordination**: Nodes can share performance data to optimize routing decisions globally
- **Edge deployment**: Run Lasso close to your users for minimal added latency

This architecture scales from a single self-hosted instance to a global network of coordinated nodes.

## Usage

### HTTP vs WebSocket

- WebSocket (WS): Subscriptions (e.g., `eth_subscribe`, `eth_unsubscribe`) and read-only methods.
- HTTP (POST /rpc/:chain): Read-only methods proxied to upstream providers.

## Quick Start

**🎯 For Hackathon Judges:** See [HACKATHON_SETUP.md](HACKATHON_SETUP.md) for the fastest setup guide

Choose your preferred setup method:

### 🚀 Option 1: Docker (Production Optimized Build)

**Fastest way to get started - no Elixir installation required:**

```bash
git clone <repository-url>
cd lasso-rpc
./run-docker.sh

# Windows Command Prompt
git clone <repository-url>
cd lasso-rpc
run-docker.bat
```

**Or manually:**

```bash
docker build -t lasso-rpc .
docker run --rm -p 4000:4000 lasso-rpc
```

**🎯 Access at:** http://localhost:4000

### 🚀 Option 2: Local Development

**Prerequisites:** [Elixir/OTP 26+](https://elixir-lang.org/install.html)

```bash
# Development mode (hot reloading, faster builds)
mix deps.get
mix phx.server
```

**🎯 Access at:** http://localhost:4000

## ⚡ Test the RPC Endpoints

Once running, test all 4 routing strategies:

```bash
# 💰 CHEAPEST - Prefers free providers
curl -X POST http://localhost:4000/rpc/cheapest/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# ⚡ FASTEST - Performance-based routing
curl -X POST http://localhost:4000/rpc/fastest/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 🎯 PRIORITY - Static configuration priorities
curl -X POST http://localhost:4000/rpc/priority/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# 🔄 ROUND_ROBIN - Load balances across providers
curl -X POST http://localhost:4000/rpc/round-robin/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

**📊 Live Dashboard:** http://localhost:4000

### 🎬 Automated Demo

Run the interactive demo script:

```bash
# Demonstrates all 4 routing strategies with live examples
./scripts/demo_routing_strategies.exs
```

## Configuration

### Provider Setup

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

### Provider Selection Strategy

Routing strategies are determined by the endpoint you use:

- `/rpc/fastest/:chain` - Routes to the fastest provider based on performance metrics
- `/rpc/cheapest/:chain` - Prefers free/public providers
- `/rpc/priority/:chain` - Uses static priority order from configuration
- `/rpc/round-robin/:chain` - Load balances across all available providers
- `/rpc/:chain` - Uses the default strategy (configured below)

**Default strategy for base `/rpc/:chain` endpoint:**

```elixir
# config/config.exs
config :lasso, :provider_selection_strategy, :cheapest
# Options: :fastest, :cheapest, :priority, :round_robin
```

### Circuit Breaker Settings

```elixir
config :lasso, :circuit_breaker,
  failure_threshold: 5,      # failures before opening
  recovery_timeout: 60_000,  # ms before retry
  success_threshold: 2       # successes before closing
```

## Observability & Request Metadata

Lasso provides comprehensive request observability with optional client-visible metadata to help you understand routing decisions and performance characteristics.

### Structured Server Logs

Every RPC request emits a structured `rpc.request.completed` event to server logs (`:info` level by default):

```json
{
  "event": "rpc.request.completed",
  "request_id": "21027f767548a9b6ddff97c860e7e58c",
  "strategy": "cheapest",
  "chain": "ethereum",
  "transport": "http",
  "jsonrpc_method": "eth_blockNumber",
  "params_present": false,
  "routing": {
    "candidate_providers": [
      "ethereum_cloudflare:http",
      "ethereum_llamarpc:http"
    ],
    "selected_provider": { "id": "ethereum_llamarpc", "protocol": "http" },
    "selection_latency_ms": 0,
    "retries": 2,
    "circuit_breaker_state": "unknown"
  },
  "timing": {
    "upstream_latency_ms": 592,
    "end_to_end_latency_ms": 592
  },
  "response": {
    "status": "success",
    "result_type": "string"
  }
}
```

### Client-Visible Metadata (Opt-in)

Clients can request routing and performance metadata by adding `include_meta` to requests:

**Via HTTP Headers:**

```bash
# Request metadata in response headers
curl -X POST "http://localhost:4000/rpc/ethereum?include_meta=headers" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'

# Response includes:
# X-Lasso-Request-ID: d12fd341cc14fc97ce9f09876fffa7a3
# X-Lasso-Meta: <base64url-encoded JSON with routing details>
```

**Via JSON-RPC Response Body:**

```bash
# Request metadata inline in response
curl -X POST "http://localhost:4000/rpc/ethereum?include_meta=body" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_gasPrice","params":[],"id":1}'

# Response includes lasso_meta field:
{
  "id": 1,
  "result": "0x8471c9a",
  "jsonrpc": "2.0",
  "lasso_meta": {
    "version": "1.0",
    "request_id": "2306632247e756bfbf451c23c9041644",
    "strategy": "cheapest",
    "chain": "ethereum",
    "transport": "http",
    "selected_provider": {"id": "ethereum_llamarpc", "protocol": "http"},
    "candidate_providers": ["ethereum_cloudflare:http", "ethereum_llamarpc:http"],
    "upstream_latency_ms": 525,
    "retries": 1,
    "circuit_breaker_state": "unknown",
    "selection_latency_ms": 0,
    "end_to_end_latency_ms": 525
  }
}
```

**Alternative: Use request header instead of query param**

```bash
curl -X POST "http://localhost:4000/rpc/ethereum" \
  -H 'Content-Type: application/json' \
  -H 'X-Lasso-Include-Meta: body' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

### Observability Configuration

```elixir
# config/config.exs
config :lasso, :observability,
  log_level: :info,                    # Log level for request completed events
  include_params_digest: true,         # Include SHA-256 digest of params in logs
  max_error_message_chars: 256,        # Truncate error messages for logs
  max_meta_header_bytes: 4096,         # Max size for X-Lasso-Meta header
  sampling: [rate: 1.0]                # Sample rate (0.0-1.0) for high-volume scenarios
```

## Integration

### Using with Web3 Libraries

**Viem/Wagmi:**

```typescript
import { createPublicClient, http } from "viem";

const client = createPublicClient({
  transport: http("http://localhost:4000/rpc/fastest/ethereum"),
});
```

**WebSocket subscriptions:**

```bash
wscat -c ws://localhost:4000/rpc/ethereum
{"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}
```

## Live Dashboard

Access the real-time dashboard at http://localhost:4000:

- **Provider leaderboards** with success rates and RPC method latencies
- **Performance matrix** showing RPC call latencies by provider and method
- **Circuit breaker status** and provider health monitoring
- **Chain selection** to switch between networks
- **System simulator** for load testing

## API Reference

### System Health & Metrics

```bash
# Health check
GET /api/health

# Detailed system status
GET /api/status

# Provider performance metrics
GET /api/metrics/:chain
```

## Development & Testing

### Running Tests

Lasso has three types of tests organized for different purposes:

```bash
# Unit tests (fast, run on every PR)
# 165 tests covering core RPC functionality, transport abstraction, and observability
mix test --exclude battle --exclude real_providers

# Start the dev server
mix phx.server
```

**For local development:** Run unit tests frequently. Run integration tests before pushing.

### Test Tags

- `:battle` - Battle testing framework (integration & e2e tests)
- `:fast` - Fast tests suitable for CI (<30s)
- `:slow` - Slow tests requiring real blockchain events (5+ min)
- `:real_providers` - Uses external RPC providers (network-dependent)
- `:diagnostic` - Framework validation tests

### Development Mode

```bash
# Start with hot reloading
mix phx.server

# Visit dashboard
open http://localhost:4000

# Visit simulator
open http://localhost:4000/simulator
```

### Battle Testing & Load Testing

Lasso includes a sophisticated battle testing framework for validating reliability under load and chaos conditions:

```bash
# Run battle testing scenarios with the DSL
mix test test/battle/

# Example: HTTP failover with provider chaos
mix test test/battle/chaos_test.exs

# Example: WebSocket subscription continuity
mix test test/battle/websocket_subscription_test.exs
```

**Framework capabilities:**

- Fluent scenario DSL for orchestrating complex test flows
- Workload generation with configurable concurrency and duration
- Chaos engineering: kill providers, inject latency, flap connections
- Telemetry collection and percentile analysis (P50, P95, P99)
- Automatic SLO verification and detailed reporting

For quick manual load testing:

```bash
# Basic RPC method load test (curl)
for i in {1..20}; do for method in eth_blockNumber eth_gasPrice eth_getBlockByNumber eth_chainId; do curl -s -X POST http://localhost:4000/rpc/round-robin/ethereum -H 'Content-Type: application/json' -d "{\"jsonrpc\":\"2.0\",\"method\":\"$method\",\"params\":$(if [ \"$method\" = "eth_getBlockByNumber" ]; then echo '[\"latest\", false]'; else echo '[]'; fi),\"id\":$i}" & done; wait; done
```

See [project/battle-testing/BATTLE_TESTING_GUIDE.md](project/battle-testing/BATTLE_TESTING_GUIDE.md) for detailed documentation.

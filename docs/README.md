# Livechain

**A Blockchain RPC orchestrator and smart router for bulletproof onchain application development.**

Building reliable blockchain applications is challenging, largely due to the complexity of choosing and managing RPC providers. With dozens of providers offering different performance characteristics, pricing models, and reliability guarantees, developers face an opaque decision that directly impacts their application's user experience.

Lasso solves this by acting as an intelligent proxy that sits between your application and multiple RPC providers. While it provides the same JSON-RPC endpoints for WebSocket and HTTP that you'd expect from any provider, Livechain orchestrates **all** your providers across **all** your chains. It automatically routes requests to the best-performing provider, handles failures gracefully, and gives you the reliability and performance your applications deserve.

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

## Why Livechain Exists

**Stop accepting RPC failures.** Providers go down, hit rate limits, and suffer network issues that break your app. Livechain routes around these failures with circuit breakers and intelligent failover—your dApp stays online when others don't.

**Stop guessing which provider is best.** Livechain passively benchmarks providers using your actual traffic. When network conditions change, routing adapts automatically. No synthetic benchmarks, no guesswork—just real performance data driving intelligent decisions.

## Built on Elixir/OTP: Fault-Tolerance by Design

Livechain runs on the Erlang BEAM VM, the same battle-tested platform that powers WhatsApp, Discord, and telecom infrastructure serving billions of users. This gives us superpowers:

- **Massive concurrency**: Handle thousands of concurrent connections with minimal overhead
- **Fault isolation**: Provider failures don't cascade—each connection runs in its own lightweight process
- **Self-healing**: Crashed processes automatically restart without affecting others
- **Hot code updates**: Deploy fixes without downtime
- **Distributed by default**: Built to coordinate across multiple nodes and regions

## Global Distribution Potential

BEAM's distributed capabilities unlock powerful possibilities for smart routing:

- **Regional nodes**: Deploy Livechain instances globally, each maintaining region-local performance benchmarks
- **Latency-aware routing**: Clients connect to the nearest Livechain node, which routes to the fastest upstream provider for that region
- **Cross-region coordination**: Nodes can share performance data to optimize routing decisions globally
- **Edge deployment**: Run Livechain close to your users for minimal added latency

This architecture scales from a single self-hosted instance to a global network of coordinated nodes.

## Core Features

- **Multi-provider orchestration** with pluggable routing strategies (cheapest, fastest, priority, round-robin)
- **Full JSON-RPC compatibility** via HTTP and WebSocket proxies for all standard read-only methods
- **Bulletproof failover** with per-provider circuit breakers and health monitoring
- **Passive benchmarking** using real traffic to measure provider performance per-chain and per-method
- **Live dashboard** with real-time insights and provider performance metrics

## Usage

### HTTP vs WebSocket

- WebSocket (WS): Subscriptions (e.g., `eth_subscribe`, `eth_unsubscribe`) and read-only methods.
- HTTP (POST /rpc/:chain): Read-only methods proxied to upstream providers.
  - WS-only methods over HTTP return a JSON-RPC error with a hint to use WS.

### Provider Selection Strategy

The orchestrator uses a pluggable strategy to pick providers when forwarding HTTP calls.

- Default: `:fastest` (leaderboard-based on passive benchmarking)
- Alternatives: `:priority`, `:round_robin`, `:cheapest`

Configure via:

```elixir
# config/config.exs
config :livechain, :provider_selection_strategy, :fastest
# :priority, :round_robin, or :cheapest also supported
```

### Examples

```bash
# Latest block number via HTTP proxy
curl -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

```javascript
// Subscribe to new block headers over WS
const ws = new WebSocket("ws://localhost:4000/ws/rpc/ethereum");
ws.onopen = () =>
  ws.send(
    JSON.stringify({
      jsonrpc: "2.0",
      method: "eth_subscribe",
      params: ["newHeads"],
      id: 1,
    })
  );
```

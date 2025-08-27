# Livechain

**Self-hostable and infinitely scalable RPC orchestrator for bulletproof onchain onchain application development.**

Blockchain applications are hard to build, and at the core of this development space are Node RPC providers. Node RPC providers drive the onchain application ecosystem, and the pletora of existing providers make for a tough, opaque decision. Lasso RPC makes the decision easy.

On the surface, Lasso RPC looks like any RPC provider (Alchemy, Infura, QuickNode)—giving you JSON-RPC endpoints for WebSocket and HTTP. But dig deeper and you'll see Livechain is a different beast: it's **ALL** your providers across **ALL** your chains, intelligently orchestrated so you can focus on building great apps while Lasso gives you the best RPC performance on the market.

Want to bypass rate limits? Declare your Lasso endpoint to target multiple free providers and load balance between them:

```
POST /rpc/base/free/load-balance     # A RPC endpoint that target free providers only and load balances requests between them
```

Want the fastest possible responses? Let Livechain route to your best-performing provider using real-world benchmarks:

```
POST /rpc/ethereum/fastest # Automatic routing to fastest provider
```

Want much better reliability? Lasso will quietly retry your failed request in the event of a transient error or node provider issue, and you'll never know it happened.

Want to build out you own blockchain node infrastructure and compete with the big boy providers? Start with Lasso RPC.

## Why Lasso RPC Exists

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

- **Multi-provider orchestration** with pluggable routing strategies (fastest, cheapest, round-robin)
- **Full JSON-RPC compatibility** via HTTP and WebSocket proxies for all standard read-only methods
- **Bulletproof failover** with per-provider circuit breakers and health monitoring
- **Passive benchmarking** using real traffic to measure provider performance per-chain and per-method
- **Event racing** for maximum speed—multiple providers compete to deliver blockchain events first
- **Live dashboard** with real-time insights, provider performance metrics, and interactive load testing

## Usage

### HTTP vs WebSocket

- WebSocket (WS): Subscriptions only (e.g., `eth_subscribe`, `eth_unsubscribe`). Also supports generic forwarding of read-only methods using the same selection/failover logic as HTTP.
- HTTP (POST /rpc/:chain): Read-only methods proxied to upstream providers.
  - WS-only methods over HTTP return a JSON-RPC error with a hint to use WS.

### Provider Selection Strategy

The orchestrator uses a pluggable strategy to pick providers when forwarding HTTP calls.

- Default: `:leaderboard` (highest score from BenchmarkStore)
- Alternatives: `:priority`, `:round_robin`

Configure via:

```elixir
# config/config.exs
config :livechain, :provider_selection_strategy, :leaderboard
# :priority or :round_robin also supported
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
const ws = new WebSocket("ws://localhost:4000/rpc/ethereum");
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

# Livechain

High-performance, scalable, and fault tolerant RPC orchestration service for EVM chains.

## Core Features + Selling points

- Multi-provider orchestration with smart routing based on pluggable provider routing strategies (fastest, cheapest, round_robin)
- Scalable + reliable real-time RPC support with websockets feeds
- Strong failover properties for provider connection issues across http and ws
- WS + HTTP JSON-RPC proxy to support all standard readonly rpc methods supported by providers
- Passive provider benchmarking on a per-chain, per JSON rpc method basis
- Support for provider 'racing' to for maximally low latency modes ('fastest response possible' mode)
- Live dashboard with deep system insights, live chain info + status, provider performance metrics, and system load simulation hub

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

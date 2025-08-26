# Lasso RPC

A smart blockchain RPC router for building bulletproof onchain applications.

On the surface Lasso RPC is just like a standard node provider (i.e. Alchemy, Infura, QuickNode), providing ethereum json rpc endpoints for both websocket and http connections, but was you look deeper, it becomes clear that Lasso is a different beast. As a matter of fact, Lasso is ALL the RPC providers across ALL the EVM chains ALL at once. It provides ALL the best properties of your high performing RPC service, but with the flexability to pick and choose what properties you want in an RPC services:

Want to use free provider without the resitrictions of aggressive rate limits? Simply configure Lasso RPC with a bunch of free providers and take advantage of Lasso's round robin routing strategy to load balance between them:

`https://lasso-rpc/base/round-robin`

Want the fast possible response to your RPC call? Have your RPC requests routed to the fastest proivder using real-world provider benchmarking data:

`https://lasso-rpc/optimism/fastest`

### Don't accept RPC failures

Lasso implements deep orchestration with built in fault tolerance, enabling deep failover behavior resulting in hightly reliable RPC behavior. Providers go down, see intermittant failures, and or network errors that can distrupt critical services, but Lasso routes around failures and provides stronger reliablity guarantees

### Don't guess on the best RPC provider

Lasso uses passive benchmarking to make informed decisions about request routing. As real network conditions change, Lasso's smart routing will too. Degraded provider performance will be identified, and under severe circumstances will trigger a circuit breaker fault to auto redirect to the next best provider.

## Core Features

- Multi-provider orchestration with smart routing based on pluggable provider routing strategies (fastest, cheapest, round_robin)
- WS + HTTP JSON-RPC proxy to support all standard readonly rpc methods supported by providers
- Strong failover properties for provider connection issues across http and ws
- Passive provider benchmarking on a per-chain, per JSON rpc method basis
- Support for provider 'racing' to for maximally low latency modes ('fastest response possible' mode)
- Live dashboard with deep system insights, live chain info + status, live RPC actvity streams, provider performance metrics, and an interactive client load test/simulation

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

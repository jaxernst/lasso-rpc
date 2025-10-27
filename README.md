# Lasso RPC

A smart blockchain RPC aggregator for building reliable and performant onchain apps.

- Multi-provider orchestration across HTTP and WebSocket
- Intelligent routing (latency + health based routing strategies)
- Per-method benchmarking and circuit-breaking failover
- WebSocket subscriptions with multiplexing and failover gap-filling
- Structured observability with optional client-visible metadata

Production demo: http://lasso-rpc.fly.dev

---

## Why Lasso

Choosing a single RPC provider has real UX and reliability consequences, yet the tradeoffs (latency, uptime, quotas, features, cost) are often opaque and shift over time. Performance varies by region, method, and hour; free tiers and API inconsistencies make a “one URL” setup brittle.

Lasso makes the RPC layer programmable and resilient. Its a distributed proxy that sits in front of a configurable set of RPC providers, continuously measures real latencies and health, and routes each call to the best option for that chain, method, and transport. You get redundancy without rewrites, and you can scale throughput by adding providers instead of replatforming.

Designed for production workloads: from hot reads to archival queries and subscriptions, different providers excel at different tasks. Lasso lets you express those preferences and enforces them automatically.

Key benefits:

- Faster responses: method-aware, real-latency routing
- Higher reliability: circuit breakers, retries, graceful failover
- Horizontal scale: add providers to raise throughput and headroom
- Transport-agnostic: HTTP and WebSocket with route parity
- Clear visibility: structured logs and opt-in client metadata
- Transparent benchmarking: per-provider method/transport metrics

---

## Built on Elixir/OTP (BEAM)

Lasso is built with Elixir on the Erlang VM (BEAM). This runtime was designed for fault-tolerant, real-time systems and powers telecom and web-scale platforms (Discord, WhatsApp, Supabase). It is a strong fit for an RPC aggregator with several key unlocks:

- Massive concurrency with lightweight processes
- Fault isolation via OTP supervision trees
- Self-healing restarts; components can crash without taking the system down
- Low-latency networking and long-lived WebSocket handling with minimal overhead
- Simple distribution primitives for multi-region deployments
- First-class telemetry and observability

This foundation lets Lasso handle thousands of concurrent HTTP/WS requests with predictable latency and strong resilience.

---

## JSON-RPC Compatibility

Lasso follows the standard Ethereum JSON-RPC API for read-only methods. It works as a drop-in replacement for existing RPC URLs in client libraries and apps (e.g., Viem, Ethers, Wagmi) for non-mutating calls and subscriptions. Write methods (e.g., eth_sendRawTransaction) are not supported yet. See Limitations below for details on future write and batching support

Drop-in usage:

```ts
// Viem
import { createPublicClient, http, webSocket } from "viem";

const client = createPublicClient({
  transport: http(`${HOST}/rpc/ethereum`),
});

// Optional WS client (route parity)
const wsClient = createPublicClient({
  transport: webSocket(`${WS_HOST}/ws/rpc/ethereum`),
});
```

```ts
// Ethers v6
import { JsonRpcProvider } from "ethers";

const provider = new JsonRpcProvider(`${HOST}/rpc/ethereum`);
```

---

## RPC Endpoints

HTTP (POST):

- `/rpc/:chain` (default round-robin)
- `/rpc/fastest/:chain`
- `/rpc/round-robin/:chain`
- `/rpc/latency-weighted/:chain`
- `/rpc/provider/:provider_id/:chain`

WebSocket (route parity):

- `ws://host/ws/rpc/:chain`
- `ws://host/ws/rpc/fastest/:chain`
- `ws://host/ws/rpc/round-robin/:chain`
- `ws://host/ws/rpc/latency-weighted/:chain`
- `ws://host/ws/rpc/provider/:provider_id/:chain`

Metrics API:

- `GET /api/metrics/:chain`

---

## Try It (Live or Local)

Set convenience variables first:

```bash
export HOST=https://lasso-rpc.fly.dev
export WS_HOST=wss://lasso-rpc.fly.dev
# or for local
# export HOST=http://localhost:4000
# export WS_HOST=ws://localhost:4000
```

HTTP examples:

```bash
# Round-robin
curl -s -X POST "$HOST/rpc/ethereum" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq -r '.result'

# Fastest per current metrics
curl -s -X POST "$HOST/rpc/fastest/ethereum" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_gasPrice","params":[],"id":1}' | jq

# Provider override (example id)
curl -s -X POST "$HOST/rpc/provider/ethereum_llamarpc/ethereum" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq

# Include routing metadata in response body
curl -s -X POST "$HOST/rpc/ethereum?include_meta=body" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq

# HTTP batching (array of requests)
curl -s -X POST "$HOST/rpc/ethereum" \
  -H 'Content-Type: application/json' \
  -d '[
    {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1},
    {"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":2}
  ]' | jq .
```

WebSocket examples (wscat or websocat):

```bash
# Default strategy
wscat -c "$WS_HOST/ws/rpc/ethereum"
> {"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}

# Strategy-specific
wscat -c "$WS_HOST/ws/rpc/fastest/ethereum"
```

Subscriptions:

```bash
wscat -c "$WS_HOST/ws/rpc/ethereum"
> {"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}
< {"jsonrpc":"2.0","id":1,"result":"0x..."}
< {"jsonrpc":"2.0","method":"eth_subscription","params":{...}}
```

---

## Quick Start

Docker:

```bash
git clone <repo-url>
cd lasso-rpc
./run-docker.sh
# or
docker build -t lasso-rpc . && docker run --rm -p 4000:4000 lasso-rpc
```

Local (Elixir 1.15+/OTP 26+):

```bash
mix deps.get
mix phx.server
```

Access: http://localhost:4000

Configuration lives in `config/chains.yml`. Minimal example:

```yaml
chains:
  ethereum:
    chain_id: 1
    providers:
      - id: "ethereum_llamarpc"
        name: "LlamaRPC"
        url: "https://eth.llamarpc.com"
        ws_url: "wss://eth.llamarpc.com"
        type: "public"
```

Default strategy can be changed:

```elixir
# config/config.exs
config :lasso, :provider_selection_strategy, :round_robin
# options: :fastest | :round_robin | :latency_weighted
```

WebSocket subscriptions use a stable, priority-based provider chosen from `chains.yml` to maintain continuity; unary WS calls still follow the selected strategy.

---

## Metrics and Reporting

Fetch runtime performance metrics and export a report:

```bash
# CSV (default)
node scripts/export_metrics_csv.mjs --url "$HOST/api/metrics" --chain ethereum --output ethereum_rpc_performance.csv

# JSON
node scripts/export_metrics_csv.mjs -u "$HOST/api/metrics" -c base -f json -o base_metrics.json
```

From the live demo:

```bash
HOST=http://lasso-rpc.fly.dev node scripts/export_metrics_csv.mjs -u "$HOST/api/metrics" -c ethereum
```

You can also generate load locally to populate metrics:

```bash
node scripts/rpc_load_test.mjs --url "$HOST/rpc/round-robin/ethereum" --concurrency 24 --duration 45
```

---

## Observability (Optional Client Metadata)

Add `include_meta=headers|body` to get routing details back:

```bash
curl -s -X POST "$HOST/rpc/ethereum?include_meta=headers" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' -i | sed -n '1,10p'
```

This returns `X-Lasso-Request-ID` and a base64url `X-Lasso-Meta` header. Use `include_meta=body` to embed metadata in the JSON-RPC response instead.

---

## Limitations

- Read-only only: write methods (for example, `eth_sendRawTransaction`) are not supported.
- HTTP batching: JSON-RPC batch requests are supported via HTTP (default maximum 50 items per batch, configurable).
- WebSocket: individual messages only; do not send batch arrays over WebSocket (will crash the connection). Send each request as a separate JSON object.
- Compatibility: provider-specific api inconsistencies are normalized, but method availability and proivder-specific adapters and error parsing likely have coverage gaps that will improve over time

---

## Architecture

Core components (see full document for details):

- Provider pool and per-transport circuit breakers
- Unified request pipeline selecting across HTTP and WS channels
- Per-method benchmarking feeding the fastest strategy
- Subscription multiplexing with gap-filling on failover

Read more:

- `project/ARCHITECTURE.md`
- `project/OBSERVABILITY.md`

---

## Development

Tests and basic dev workflow:

```bash
mix test --exclude battle --exclude real_providers
mix phx.server
```

Load testing and metrics export are in `scripts/`.

---

## Future Work

Lasso’s roadmap and ideas for where this can go next (advanced routing strategies, hedged requests, caching, geo-aware routing, multi-tenancy, and more) are tracked here:

- `project/FUTURE_FEATURES.md`

---

## Status

- Multi-region capable via BEAM clustering and regional deployments
- Provider adapters with per-chain capabilities and validation
- Focus: read-only JSON-RPC and subscription reliability; writes are out of scope for now

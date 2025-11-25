# Lasso RPC

A smart blockchain node RPC aggregator for building reliable and performant onchain apps.

- Multi-provider and multi-chain orchestration across HTTP and WebSocket
- Intelligent and expressive request routing
- Per-method request benchmarking and circuit-breaking failover
- WebSocket subscriptions with multiplexing and failover gap-filling
- Structured observability with optional client-visible metadata
- Realtime live dashboard

Multi-region production RPC endpoints (base, ethereum currently supported):

```
https://lasso-rpc.fly.dev/rpc/ethereum
https://lasso-rpc.fly.dev/rpc/base

wss://lasso-rpc.fly.dev/ws/rpc/ethereum
wss://lasso-rpc.fly.dev/ws/rpc/base

(additional strategy-specific endpoints below)
```

Provider Metrics dashboard (wip): https://lasso-rpc.fly.dev/metrics/ethereum  
Full dashboard: https://lasso-rpc.fly.dev

---

## Why Lasso

Choosing a single RPC provider has real UX and reliability consequences, yet the tradeoffs (latency, uptime, quotas, features, cost) are often opaque and shift over time. Performance varies by region, method, and hour; free tiers and API inconsistencies make a “one URL” setup brittle.

Lasso makes the RPC layer programmable and resilient. Its a distributed proxy that sits in front of a configurable set of RPC providers, continuously measures real latencies and health, and routes each call to the best option for that chain, method, and transport. You get redundancy without rewrites, and you can scale throughput by adding providers instead of replatforming.

Designed for production workloads: from hot reads to archival queries and subscriptions, different providers excel at different tasks. Lasso lets you express those preferences and enforce them automatically.

Key benefits:

- Faster responses: method-aware, real-latency routing
- Higher reliability: circuit breakers, retries, graceful failover
- Horizontal scale: add nodes/providers to raise throughput and headroom
- Transport-agnostic: HTTP and WebSocket channels support, extendable for other protocols (i.e. grpc)
- Clear visibility: real-time Lasso node dashboards, deep telemetry + observability, opt-in client metadata
- Transparent benchmarking: per-provider method/transport metrics

---

## Built w/ Elixir/OTP (BEAM)

Lasso is built with Elixir on the Erlang VM (BEAM). This runtime was designed for fault-tolerant, real-time systems and powers major telecom systems + web-scale platforms (Discord, WhatsApp, Supabase). It’s a strong fit for an RPC aggregator/proxy/routing layer, with some key unlocks:

- Massive concurrency via lightweight processes (100k+ processes per VM)
- Fault isolation via OTP supervision trees
- Low-latency networking with efficient websocket and http transport perf
- Shared, concurrent in‑memory tables (ETS) for fast lookups, lock‑free reads, and cross‑process caching; optional snapshot/restore for warm starts
- Simple distribution primitives and VM clustering + orchestration for easy distribution + decentralization
- First‑class telemetry and observability (OpenTelemetry)

This foundation lets Lasso handle thousands of concurrent HTTP/WS requests with predictable latency and strong resilience.

Elixir is also very fun + nice to work with.

---

## JSON-RPC Compatibility

Lasso follows the standard Ethereum JSON-RPC API for read-only methods. It works as a drop-in replacement for existing RPC URLs in client libraries and apps (e.g., Viem, Ethers, Wagmi) for non-mutating calls and subscriptions. Write methods (e.g., eth_sendRawTransaction) are not supported yet. See Limitations below for details on future write and batching support

Drop-in usage:

```ts
// Viem
import { createPublicClient, http, webSocket } from "viem";

// Default strategy: load balanced requests
const loadBalancedClient = createPublicClient({
  transport: http(`${HOST}/rpc/ethereum/round-robin`),
});

const fastClient = createPublicClient({
  transport: http(`${HOST}/rpc/fastest/ethereum`),
});

// Optional WS client (route parity)
const wsClient = createPublicClient({
  transport: webSocket(`${WS_HOST}/ws/rpc/ethereum`),
});
```

---

## RPC Endpoints

Routing strategies are defined with url slug parameters

HTTP (POST):

- `/rpc/:chain` (configurable default strategy with round-robin as the preset default)
- `/rpc/fastest/:chain`
- `/rpc/round-robin/:chain`
- `/rpc/latency-weighted/:chain`
- `/rpc/provider/:provider_id/:chain`

WebSocket (same routes with /ws/ prefix):

- `ws://host/ws/rpc/:chain`
- `ws://host/ws/rpc/fastest/:chain`
- `ws://host/ws/rpc/round-robin/:chain`
- `ws://host/ws/rpc/latency-weighted/:chain`
- `ws://host/ws/rpc/provider/:provider_id/:chain`

Metrics API (provider performance):

- `GET /api/metrics/:chain` (JSON)
- `GET /metrics/:chain` (HTML page)

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

Architecture brief (see full document for details):

- Provider pool and per-transport circuit breakers
- Unified request pipeline selecting across HTTP and WS channels
- Per-method benchmarking feeding the fastest strategy
- Subscription multiplexing with gap-filling on failover
- Transport-agnostic architecture - HTTP and WebSocket treated as first-class routing options
- Per-transport circuit breakers - {chain, provider_id, :http} and {chain, provider_id, :ws} independently managed
- Per-method, per-transport metrics - Selection strategies can make transport-aware decisions
- Sophisticated error classification - Message-pattern-first classification handles provider inconsistencies
- Adapter-based capability validation - Method-level (supports_method?/3) and parameter-level (validate_params/4)
- Two-phase validation - Fast method filtering, then lazy param validation on finalists
- Category-specific circuit breaker thresholds - Rate limits, capability violations, server errors have different thresholds
- Adaptive capability discovery - Learns provider constraints in real-time and prevents requests that would fail
- Intelligent provider filtering - Avoids archival queries on non-archive providers, respects block range limits, and tracks per-proivder RPC method support

Read more:

- `project/ARCHITECTURE.md`
- `project/OBSERVABILITY.md`

---

## Development

Tests and basic dev workflow:

```bash
mix test --exclude battle --include integration
mix phx.server
```

Load testing and metrics export are in `scripts/`.

**Provider Discovery and Probing:**

Probe RPC providers to discover supported methods, limits, and WebSocket capabilities:

```bash
# Full probe (methods + limits + websocket)
mix lasso.probe https://eth.llamarpc.com

# Probe specific capabilities only
mix lasso.probe https://eth.llamarpc.com --probes methods,limits

# WebSocket-only probe
mix lasso.probe wss://eth.llamarpc.com --probes websocket

# Full method probe with JSON output
mix lasso.probe https://eth.llamarpc.com --level full --output json
```

**Probe Options:**

- `--probes <list>` - Comma-separated: methods, limits, websocket (default: all)
- `--level <level>` - Method probe depth: critical, standard, full (default: standard)
- `--timeout <ms>` - Request timeout (default: 10000)
- `--output <format>` - Output: table, json (default: table)
- `--chain <name>` - Chain context for test contracts (default: ethereum)
- `--subscription-wait <ms>` - WebSocket event wait time (default: 15000)

**What it discovers:**

- **Methods**: Which JSON-RPC methods the provider supports
- **Limits**: Block range limits, address count limits, batch request support, archive node support, rate limiting
- **WebSocket**: Connection capability, subscription support (newHeads, logs, newPendingTransactions)

Use the probe task when adding new providers or debugging provider issues

---

## Development Automation (Claude Code)

Lasso includes comprehensive Claude Code automation to accelerate development workflows:

**Slash Commands** (use immediately):

- `/health-check` - Run compile + test + credo + dialyzer in one command
- `/smoke-test [target]` - Validate local/staging/prod endpoints with performance regression detection
- `/test-audit` - test quality review with improvement and coverage expansion recommendations
- `/code-cleanup` - Fix compilation warnings, remove dead code, update deprecations
- `/add-provider` - Complete guided workflow for integrating new RPC providers
- `/review-changes` - Pre-commit review with automated quality checks
- `/docs-sync` - Quick check for documentation drift (provider lists, broken refs, TODOs)

**Agent Skills** (auto-invoke):

- `elixir-quality` - Automatically detects and fixes compilation warnings and code quality issues
- `smoke-test-runner` - Automated endpoint validation with baseline comparison
- `provider-integration` - End-to-end provider addition with templates and testing

**Quick examples:**

```bash
# Check codebase health before committing
/health-check

# Validate production endpoint after deployment
/smoke-test prod

# Auto-fix compilation warnings
"Fix the compilation warnings"  # elixir-quality skill auto-invokes
```

---

## Future Features

- Caching strategies
- Request racing strategies
- Provider method support superset (partial implementation done with adapters - need method support tracking)
- Integrate block height/sync state into provider selection

Additional roadmap items and ideas tracked here:

- `project/FUTURE_FEATURES.md`

---

### Additional docs and project tracking available in `/project`

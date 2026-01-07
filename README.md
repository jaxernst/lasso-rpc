# Lasso RPC

**Smart RPC aggregation for consumer-grade blockchain apps.**

Lasso is a smart proxy/router that turns a set of upstream RPCs (hosted providers + self-hosted nodes) into a **fast, observable, configurable, and resilient** multi-chain JSON-RPC layer.

It proxies Ethereum JSON-RPC over **HTTP + WebSocket** and gives you a single, stable RPC surface area with explicit routing control (strategies, provider overrides, and profiles).

Route every request to the best available provider to handle that request, while configuring providers to match your application's needs. Leverage deep redundancy, expressive routing, and built-in observability to improve end-user UX without changing client code.

---

## Why Lasso

Choosing a single RPC provider has real UX and reliability consequences, yet the tradeoffs (latency, uptime, quotas, features, cost, rate limits) are often opaque and shift over time. Performance varies by region, method, and hour; free tiers and API inconsistencies make a “one URL” setup brittle.

Lasso makes the RPC layer programmable and resilient. It's a distributed proxy that sits in front of a configurable set of RPC providers, continuously measures real latencies and health, and routes each call to the best option for that chain, method, and transport. You get redundancy without brittle application code, and you can scale throughput by adding providers instead of replatforming.

Designed for production workloads: from hot reads to archival queries and subscriptions, different providers excel at different tasks. Lasso lets you express those preferences and enforce them automatically.

---

What you get:

- Multi-provider, multi-chain, Ethereum JSON-RPC spec proxy for **HTTP + WebSocket**
- Strategy routes (`fastest`, `round-robin`, `latency-weighted`) + provider override routes
- Per-method latency benchmarking (w/ latency feedback for routing decisions)
- Circuit breakers + retries + transport-aware failover
- WebSocket subscriptions with multiplexing + subscription gap-filling
- Profile isolation (dev/staging/prod, multi-tenant, experiments) with independent state/metrics/breakers
- LiveView dashboard: aggregate provider status, routing decision breakdowns, issue logs, per-method latency metrics, provider health, RPC load testing, and more

Live hosted public-provider dashboard: [lasso-rpc.fly.dev/dashboard](https://lasso-rpc.fly.dev/dashboard)

---

## Endpoints

HTTP (POST):

- `/rpc/:chain_id` (default strategy)
- `/rpc/fastest/:chain_id`
- `/rpc/round-robin/:chain_id`
- `/rpc/latency-weighted/:chain_id`
- `/rpc/provider/:provider_id/:chain_id` (provider override)

WebSocket:

- `/ws/rpc/:chain_id`
- `/ws/rpc/:strategy/:chain_id`
- `/ws/rpc/provider/:provider_id/:chain_id`

Profiles (namespaced routing configs):

- HTTP: `/rpc/profile/:profile/...`
- WS: `/ws/rpc/profile/:profile/...`

---

## Key Features

### Profiles: isolated configs, isolated state

Profiles are complete, isolated routing universes: providers, chains, rate limits, circuit breakers, metrics, and WS state do not bleed across profiles.

Use them for:

- dev/staging/prod
- per-tenant configs
- “try the new routing policy without wrecking prod”

### Method-aware routing + real benchmarking

- Benchmarks are recorded per **provider × method × transport**
- Strategies can route differently for `eth_call` vs `eth_getLogs` vs `debug_*`

### Failure handling that doesn’t lie

- Per-provider, per-transport circuit breakers
- Retries + failover across a ranked candidate list
- Transport-aware routing (HTTP/WS are first-class, not an afterthought)

### WebSocket subscriptions: multiplexing + continuity

- Multiplex many client subscriptions onto fewer upstream subscriptions
- On upstream failure, Lasso can switch providers and **gap-fill** missed blocks/events via HTTP

### Observability built-in

- LiveView dashboard: routing events, decision breakdowns, provider status, realtime method performance
- Deep telemetry handlers with OpenTelemetry
- Structured logs with request context
- Optional client-visible metadata (`include_meta=headers|body`)

---

## Quick Start

### Local (recommended)

```bash
git clone https://github.com/jaxernst/lasso-rpc
cd lasso-rpc
mix deps.get
mix phx.server
```

Dashboard: `http://localhost:4000/dashboard`

### Docker

```bash
./run-docker.sh
```

---

## Try It

```bash
curl -sS -X POST http://localhost:4000/rpc/ethereum \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

WebSocket subscription:

```bash
wscat -c ws://localhost:4000/ws/rpc/ethereum
> {"jsonrpc":"2.0","method":"eth_subscribe","params":["newHeads"],"id":1}
```

Want routing metadata back:

```bash
curl -sS -X POST 'http://localhost:4000/rpc/ethereum?include_meta=headers' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' -i | sed -n '1,15p'
```

---

## Configuration (profiles)

Profiles live in `config/profiles/*.yml`. Each profile defines chains, providers, routing policy, and limits. `${ENV_VAR}` substitution is supported.

### Ready to Use: Default Profile

The included `default.yml` profile is configured free public providers (LlamaRPC, PublicNode, DRPC, 0xRPC, Merkle) and provides premium-provider performance and throughput. No API keys required—just `mix phx.server` and you have a working multi-provider RPC proxy for Ethereum and Base.

Perfect for:

- **Getting started** without setting up API keys
- **Local development** with instant redundancy
- **Production fallback** when combined with your own nodes
- **Testing Lasso's routing** before configuring custom providers

Minimal example:

```yaml
# config/profiles/default.yml
name: "Default"
slug: "default"
type: "standard"

chains:
  ethereum:
    chain_id: 1
    providers:
      - id: "llamarpc"
        url: "https://eth.llamarpc.com"
        ws_url: "wss://eth.llamarpc.com"

      - id: "alchemy"
        url: "https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
        ws_url: "wss://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
```

Multiple profiles:

```yaml
# config/profiles/production.yml
name: "Production"
slug: "production"
default_rps_limit: 1000
default_burst_limit: 5000

chains:
  ethereum:
    providers:
      - id: "your_erigon"
        url: "http://your-erigon-node:8545"
        priority: 1
      - id: "alchemy_fallback"
        url: "https://..."
        priority: 2
```

Access it via:

- `POST /rpc/profile/production/ethereum`
- `ws://localhost:4000/ws/rpc/profile/production/ethereum`

---

## Use Cases (real ones)

- Run your own node, keep a paid provider as a fallback (and stop waking up to “provider outage” incidents).
- Route `eth_getLogs` differently from “hot reads” so your indexer stops melting your cheapest endpoint.
- Multiplex subscriptions so 10k clients don’t mean 10k upstream WebSockets.
- Give every env/tenant a profile so you can debug + experiment without cross-contamination.

---

## How it works (short version)

Request pipeline:

1. Build candidates (method + transport aware)
2. Filter unhealthy channels (breakers / health)
3. Execute request
4. On failure: retry/failover
5. Record benchmarking + telemetry

If you want the details (supervision tree, BenchmarkStore, adapters, streaming internals), start here:

- `docs/ARCHITECTURE.md`

---

## Why Elixir/OTP?

Because this problem is basically “a million tiny concurrent state machines with strict fault isolation”.

- OTP supervision trees keep failures local
- BEAM processes are cheap enough to model everything as a process
- ETS makes hot-path lookups fast without hand-rolled lock-free C++ nightmares

---

---

## Docs

- `docs/ARCHITECTURE.md` - System design + components
- `docs/OBSERVABILITY.md` - Logging/metrics
- `docs/TESTING.md` - Dev workflow
- `docs/FUTURE_FEATURES.md` - Roadmap

---

## Community

Built by [@jaxernst](https://github.com/jaxernst).

[Follow me on Farcaster for updates](https://farcaster.xyz/jaxer.eth)

- Issues and PRs welcome
- For questions, open a GitHub issue

---

## License

Lasso is licensed under **AGPL-3.0**.

- You can self-host it freely
- You can modify it
- If you run a modified version as a service, you must publish those modifications

See `LICENSE.md` for full terms.

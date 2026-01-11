<h1 align="left">
  <img src="priv/static/images/lasso-logo.png" alt="Lasso RPC Logo" width="45" style="margin-right: 10px; margin-top: 5px;">
  Lasso RPC
</h1>

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Version](https://img.shields.io/badge/version-0.1.0-blue.svg)](https://github.com/jaxernst/lasso-rpc/releases)

### Smart RPC aggregation for consumer-grade blockchain apps.

Lasso is a smart proxy/router that turns your node infrastructure and RPC providers into a **fast, observable, configurable, and resilient** multi-chain JSON-RPC layer.

It proxies Ethereum JSON-RPC over **HTTP + WebSocket** and gives you a single RPC API with expressive routing control (strategies, provider overrides, and profiles).

Route every request to the best available provider to handle that request, while configuring providers to match your application's needs. Leverage deep redundancy, expressive routing, and built-in observability to improve UX while keeping your application code simple.

**📊 [Live Dashboard](https://lasso-rpc.fly.dev/dashboard)** &nbsp;&nbsp;|&nbsp;&nbsp; **📖 [Architecture](docs/ARCHITECTURE.md)** &nbsp;&nbsp;|&nbsp;&nbsp; **🐛 [Report Bug](https://github.com/jaxernst/lasso-rpc/issues)** &nbsp;&nbsp;|&nbsp;&nbsp; **💡 [Request Feature](https://github.com/jaxernst/lasso-rpc/issues)**

---

## Table of Contents

- [Why Lasso](#why-lasso)
- [Features](#features)
- [Endpoints](#endpoints)
- [Quick Start](#quick-start)
  - [Prerequisites](#prerequisites)
  - [Local (recommended)](#local-recommended)
  - [Docker](#docker)
- [Try It](#try-it)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Built with Elixir/OTP](#built-with-elixirotp)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Why Lasso

Choosing a single RPC provider has real UX and reliability consequences, but the tradeoffs (latency, uptime, quotas, features, cost, rate limits) are opaque and shift over time. Performance varies by region, method, and hour, and API inconsistencies make a “one URL” setup brittle.

Lasso makes the RPC layer programmable and resilient. It's designed to run as a distributed proxy that sits in front of a configurable set of RPC providers, continuously measures real latencies and health, and routes each call to the best option for that chain, method, and transport. You get redundancy without brittle application code, and you can scale throughput by adding providers instead of replatforming.

Different providers excel at different workloads (hot reads vs archival queries vs subscriptions). Lasso lets you express those preferences and enforce them automatically.

---

## Features

- **Multi-provider, multi-chain** Ethereum JSON-RPC proxy for **HTTP + WebSocket**
- **Routing strategies**: `fastest`, `round-robin`, `latency-weighted`, plus provider override routes
- **Method-aware benchmarking**: latency tracked per **provider × method × transport**
- **Resilience**: circuit breakers, retries, and transport-aware failover
- **WebSocket subscriptions**: multiplexing with optional gap-filling via HTTP on upstream failure
- **Profiles**: isolated configs/state/metrics (dev/staging/prod, multi-tenant, experiments)
- **LiveView dashboard**: provider status, routing decisions, logs, latency metrics, and load testing

---

## Endpoints

HTTP (POST):

- `/rpc/:chain` (default strategy)
- `/rpc/fastest/:chain`
- `/rpc/round-robin/:chain`
- `/rpc/latency-weighted/:chain`
- `/rpc/provider/:provider_id/:chain` (provider override)

WebSocket:

- `/ws/rpc/:chain`
- `/ws/rpc/:strategy/:chain`
- `/ws/rpc/provider/:provider_id/:chain`

Profiles (namespaced routing configs):

- HTTP: `/rpc/profile/:profile/...`
- WS: `/ws/rpc/profile/:profile/...`

---

## Quick Start

### Prerequisites

- **Elixir**: 1.17+ (check with `elixir --version`)
- **Erlang/OTP**: 26+ (check with `erl -version`)
- **Node.js**: 18+ (for asset compilation)

### Local (recommended)

```bash
# Clone the repository
git clone https://github.com/jaxernst/lasso-rpc
cd lasso-rpc

# Install dependencies
mix deps.get

# Start the Phoenix server
mix phx.server
```

The application will be available at `http://localhost:4000` and the dashboard at `http://localhost:4000/dashboard`.

**Note**: The default profile includes free public providers (no API keys required), so you can start using it immediately.

### Docker

```bash
# Run with Docker
./run-docker.sh
```

The application will be available at `http://localhost:4000`.

For production deployments, see the [Dockerfile](Dockerfile) for customization options.

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

Return routing metadata with your request:

```bash
curl -sS -X POST 'http://localhost:4000/rpc/ethereum?include_meta=headers' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' -i | sed -n '1,15p'
```

---

## Configuration

Profiles live in `config/profiles/*.yml`. Each profile defines chains, providers, routing policy, and limits. `${ENV_VAR}` substitution is supported.

For detailed configuration documentation, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Ready to Use: Default Profile

The included `default.yml` profile is configured with free public providers (no API keys required). Start `mix phx.server` and you have a working multi-provider RPC proxy.

Good for:

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

## How it works

Request pipeline:

1. Build candidates (method + transport aware)
2. Filter unhealthy channels (breakers / health)
3. Execute request
4. On failure: retry/failover
5. Record benchmarking + telemetry

For deeper implementation details (supervision tree, BenchmarkStore, adapters, streaming internals), start with:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

---

## Built with Elixir/OTP

Lasso runs on the BEAM (Erlang VM) to take advantage of its strengths for high-concurrency, failure-prone networking systems.

- **Massive concurrency**: lightweight processes and message passing make it natural to model per-request, per-provider, and per-connection workflows without shared-memory complexity.
- **Fault isolation + self-healing**: OTP supervision trees keep failures contained and allow fast restarts, which is ideal when upstream providers are flaky or rate-limited.
- **Distributed by design**: the runtime supports clustering and remote messaging, making it straightforward to scale Lasso horizontally and keep components decoupled.
- **Fast in-memory state**: ETS provides efficient shared state for hot-path lookups (routing decisions, benchmarks, breaker state) without turning every read into a bottleneck.

---

## Documentation

- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** - System design + components
- **[OBSERVABILITY.md](docs/OBSERVABILITY.md)** - Logging/metrics
- **[TESTING.md](docs/TESTING.md)** - Dev workflow
- **[FUTURE_FEATURES.md](docs/FUTURE_FEATURES.md)** - Roadmap
- **[RPC_STANDARDS.md](docs/RPC_STANDARDS.md)** - RPC compliance details
- **[CHANGELOG.md](CHANGELOG.md)** - Version history

---

## Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details on:

- Development setup
- Code style and quality standards
- Testing requirements
- Pull request process

**Before contributing**, please:

1. Read [CONTRIBUTING.md](CONTRIBUTING.md)
2. Check existing [issues](https://github.com/jaxernst/lasso-rpc/issues) and [pull requests](https://github.com/jaxernst/lasso-rpc/pulls)
3. For major changes, open an issue first to discuss your approach

---

## Security

For security concerns, please review our [Security Policy](SECURITY.md).

**To report a security vulnerability**, please email: **jaxernst@gmail.com** (do not open a public issue).

---

Built by [jaxer.eth](https://farcaster.xyz/jaxer.eth)

---

## License

Lasso RPC is licensed under **AGPL-3.0**.

- ✅ You can self-host it freely
- ✅ You can modify it
- ⚠️ If you run a modified version as a service, you must publish those modifications

See [LICENSE.md](LICENSE.md) for full terms.

# Configuration Reference

Lasso is configured via YAML profile files in `config/profiles/`. Each profile defines chains, providers, routing policy, and rate limits. Multiple profiles enable isolated configurations for different environments or tenants.

## Profile File Structure

```yaml
# config/profiles/<slug>.yml

# --- Frontmatter (YAML document separator) ---
---
name: "My Profile"           # Display name
slug: "my-profile"           # URL identifier (used in /rpc/profile/:slug/...)
rps_limit: 100               # Requests per second limit
burst_limit: 500             # Burst token bucket capacity
---

# --- Body: Chain configurations ---
chains:
  ethereum:
    chain_id: 1
    providers:
      - id: "my_provider"
        url: "https://..."
```

**Frontmatter fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Human-readable profile name |
| `slug` | string | Yes | URL-safe identifier. Must be unique across profiles |
| `rps_limit` | integer | No | Per-key requests/second limit (default: 100) |
| `burst_limit` | integer | No | Token bucket burst capacity (default: 500) |

## Chain Configuration

Each chain is a key under `chains:` with the following structure:

```yaml
chains:
  ethereum:
    chain_id: 1
    name: "Ethereum Mainnet"
    block_time_ms: 12000

    monitoring:
      probe_interval_ms: 12000
      lag_alert_threshold_blocks: 5

    selection:
      max_lag_blocks: 1
      archival_threshold: 128

    websocket:
      subscribe_new_heads: true
      new_heads_timeout_ms: 35000
      failover:
        max_backfill_blocks: 100
        backfill_timeout_ms: 30000

    ui-topology:
      color: "#627EEA"
      size: xl

    providers:
      - id: "ethereum_llamarpc"
        # ...
```

### Chain Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `chain_id` | integer | Yes | EIP-155 chain ID |
| `name` | string | No | Display name (defaults to chain key) |
| `block_time_ms` | integer | No | Average block time in milliseconds. Used for optimistic lag calculation |

### Monitoring

Controls health probe frequency and lag alerting.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `probe_interval_ms` | integer | 12000 | Health check polling interval. Set to ~1x block time for L1, ~2.5x for L2 |
| `lag_alert_threshold_blocks` | integer | 5 | Log warning when a provider lags this many blocks behind consensus |

### Selection

Controls provider eligibility filtering during request routing.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_lag_blocks` | integer | 1 | Exclude providers lagging more than N blocks. L1: 1-2, L2: 3-10 |
| `archival_threshold` | integer | 128 | Blocks before data is considered "archival". Requests for blocks older than `head - threshold` are only routed to archival providers |

### WebSocket

Controls upstream WebSocket subscription behavior.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `subscribe_new_heads` | boolean | true | Subscribe to `newHeads` for real-time block tracking |
| `new_heads_timeout_ms` | integer | 35000 | Timeout before marking subscription stale (~3x block time) |
| `failover.max_backfill_blocks` | integer | 100 | Max blocks to fetch via HTTP during subscription failover |
| `failover.backfill_timeout_ms` | integer | 30000 | Timeout for backfill HTTP requests |

### UI Topology

Dashboard visualization settings.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `color` | string | - | Hex color for the chain node in the dashboard topology |
| `size` | string | `md` | Node size: `sm`, `md`, `lg`, `xl` |

## Provider Configuration

Each provider is an entry in a chain's `providers` list.

```yaml
providers:
  - id: "ethereum_llamarpc"
    name: "LlamaRPC Ethereum"
    priority: 2
    url: "https://eth.llamarpc.com"
    ws_url: "wss://eth.llamarpc.com"
    archival: true
    subscribe_new_heads: true
    capabilities:
      limits:
        max_block_range: 1000
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | Yes | Unique provider identifier within the chain |
| `name` | string | No | Display name (defaults to `id`) |
| `priority` | integer | No | Lower = higher priority. Used by `:priority` strategy and as tiebreaker |
| `url` | string | Yes* | HTTP RPC endpoint URL |
| `ws_url` | string | No | WebSocket RPC endpoint URL. Required for subscriptions |
| `archival` | boolean | No | Whether this provider serves historical data (default: true) |
| `subscribe_new_heads` | boolean | No | Override chain-level `subscribe_new_heads` for this provider |
| `capabilities` | map | No | Provider capabilities (see Capabilities below) |

*At least one of `url` or `ws_url` is required.

## Environment Variable Substitution

Provider URLs support `${ENV_VAR}` substitution. Unresolved variables crash at startup to prevent silent misconfiguration.

```yaml
providers:
  - id: "alchemy_ethereum"
    url: "https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
    ws_url: "wss://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
```

## Routing Strategies

Strategies control how providers are selected for each request. Set via URL path segment.

| Strategy | URL Slug | Description |
|----------|----------|-------------|
| **Priority** | `/rpc/:chain` | Select by `priority` field (lowest first). Default strategy |
| **Fastest** | `/rpc/fastest/:chain` | Lowest latency provider for the method (passive benchmarking) |
| **Load Balanced** | `/rpc/load-balanced/:chain` | Distribute requests across healthy providers with health-aware tiering |
| **Latency Weighted** | `/rpc/latency-weighted/:chain` | Weighted random selection by latency scores |

### When to Use Each Strategy

**Priority** — Predictable routing order. Use when you have a preferred provider (e.g., your own node) with public providers as fallback.

**Fastest** — Optimal latency. Benchmarks are tracked per provider, per method, per transport. Best for latency-sensitive reads. May concentrate load on one provider.

**Load Balanced** — Even distribution with health-aware tiering. Spreads load across all healthy providers, deprioritizing those with tripped circuit breakers or rate limits. Good for throughput maximization and avoiding rate limits.

**Latency Weighted** — Balanced approach. Routes more traffic to faster providers while still using slower ones. Prevents single-provider concentration while favoring performance.

### Health-Based Tiering

All strategies are subject to health-based tiering after initial ranking. The pipeline reorders providers into 4 tiers based on circuit breaker state and rate limit status:

1. **Tier 1**: Closed circuit + not rate-limited (preferred)
2. **Tier 2**: Closed circuit + rate-limited
3. **Tier 3**: Half-open circuit + not rate-limited
4. **Tier 4**: Half-open circuit + rate-limited

Open-circuit providers are excluded entirely. Within each tier, the strategy's original ranking is preserved.

This ensures healthy providers receive traffic first while allowing recovering providers to gradually reintegrate. See [ROUTING.md](ROUTING.md#health-based-tiering) for detailed behavior and examples.

### Provider Override

Route directly to a specific provider, bypassing strategy selection:

```
POST /rpc/provider/:provider_id/:chain
```

## Provider Capabilities

Capabilities declare what a provider supports and its limits. Validated at boot time.

```yaml
capabilities:
  unsupported_categories: [debug, trace]
  unsupported_methods: [eth_getLogs]
  limits:
    max_block_range: 10000
    max_block_age: 1000
    block_age_methods: [eth_call, eth_getBalance]
  error_rules:
    - code: 35
      category: capability_violation
    - message_contains: "timeout on the free tier"
      category: rate_limit
```

| Field | Type | Description |
|-------|------|-------------|
| `unsupported_categories` | list | Method categories this provider doesn't support (e.g., `debug`, `trace`) |
| `unsupported_methods` | list | Specific methods this provider doesn't support |
| `limits.max_block_range` | integer | Max block range for `eth_getLogs` |
| `limits.max_block_age` | integer | Max block age for state methods (pruned provider) |
| `limits.block_age_methods` | list | Methods subject to `max_block_age` limit |
| `error_rules` | list | Provider-specific error classification overrides (first match wins) |

When `capabilities` is omitted, defaults to permissive (only `local_only` methods blocked, no limits).

## BYOK (Bring Your Own Keys)

Use your own provider API keys alongside public providers:

```yaml
chains:
  ethereum:
    chain_id: 1
    providers:
      # Your own node (highest priority)
      - id: "my_erigon"
        url: "http://my-erigon:8545"
        priority: 1

      # Paid provider with your API key
      - id: "alchemy"
        url: "https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_API_KEY}"
        priority: 2

      # Free public fallback
      - id: "publicnode"
        url: "https://ethereum-rpc.publicnode.com"
        priority: 10
```

## Multiple Profiles

Create separate profiles for different environments or use cases:

```
config/profiles/
├── default.yml      # Free public providers
├── production.yml   # BYOK + own nodes
└── staging.yml      # Subset for testing
```

Access via URL: `/rpc/profile/:slug/:chain`

```bash
# Default profile
curl -X POST http://localhost:4000/rpc/ethereum ...

# Production profile
curl -X POST http://localhost:4000/rpc/profile/production/ethereum ...
```

## Application-Level Configuration

Set in `config/runtime.exs` or via environment variables:

| Environment Variable | Description | Default |
|---------------------|-------------|---------|
| `LASSO_NODE_ID` | Unique node identifier (typically region name) | Generated |
| `CLUSTER_DNS_QUERY` | DNS name for cluster node discovery | (disabled) |
| `PHX_HOST` | Hostname for the Phoenix endpoint | `localhost` |
| `PORT` | HTTP port | `4000` |
| `SECRET_KEY_BASE` | Phoenix secret key (required in production) | - |
| `DATABASE_URL` | PostgreSQL connection URL (cloud only) | - |

### Circuit Breaker Defaults

```elixir
config :lasso, :circuit_breaker,
  failure_threshold: 5,     # Consecutive failures to open
  success_threshold: 2,     # Consecutive successes to close
  recovery_timeout: 30_000  # ms before half-open attempt
```

### Default Strategy

```elixir
config :lasso, :provider_selection_strategy, :load_balanced
```

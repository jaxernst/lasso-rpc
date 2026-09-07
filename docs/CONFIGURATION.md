# Configuration Reference

Lasso is configured via YAML profile files in `config/profiles/`. Each profile defines chains, providers, routing policy, and dashboard tester settings. Multiple profiles provide separate routing configurations for different environments. Identical upstreams can share connections, health, and observations; profiles are not authentication boundaries.

## Profile File Structure

```yaml
# config/profiles/<slug>.yml

# --- Frontmatter (YAML document separator) ---
---
name: "My Profile"           # Display name
slug: "my-profile"           # URL identifier (used in /rpc/profile/:slug/...)
rps_limit: 100               # Dashboard tester maximum RPS
burst_limit: 500             # Metadata; not enforced by OSS
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
| `rps_limit` | integer | No | Maximum RPS offered by dashboard tester controls (default: 100) |
| `burst_limit` | integer | No | Profile metadata (default: 500); no OSS ingress enforcement |

OSS does not authenticate clients or enforce per-client request quotas. Configure authentication and inbound rate limiting at your reverse proxy. Provider quota and circuit-breaker backoff are separate routing controls.

Unknown YAML fields and invalid types are rejected. Use booleans (`false`), not quoted strings (`"false"`). A failed reload keeps the previous active configuration. Errors identify the field without printing credential values.

Profile slugs must match their `.yml` filenames. Files beginning with `_` or `.` are skipped. Keep a `public.yml` profile: routes without a profile use `public`, and it is required at startup. `unlisted: true` hides a profile from the selector; its endpoints remain accessible.

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

Controls probe frequency and the dashboard lag status threshold. Shared upstreams use the shortest configured probe interval across profiles; HTTP polling slows while WebSocket block updates are active.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `probe_interval_ms` | integer | 12000 | Health check polling interval. Set to ~1x block time for L1, ~2.5x for L2 |
| `lag_alert_threshold_blocks` | integer | 3 | Dashboard lag status threshold; this setting does not emit lag warning logs |

### Selection

Controls provider eligibility filtering during request routing.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `max_lag_blocks` | integer | unset | Exclude providers lagging more than N blocks. L1: 1-2, L2: 3-10 |
| `archival_threshold` | integer | 128 | Blocks before data is considered "archival". Requests for blocks older than `head - threshold` are only routed to archival providers |

### WebSocket

Controls upstream WebSocket subscription behavior.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `subscribe_new_heads` | boolean | true | Enable `newHeads` block tracking and eligibility for client `newHeads` subscriptions |
| `new_heads_timeout_ms` | integer | 42000 | Timeout before marking subscription stale (~3x block time) |
| `failover.max_backfill_blocks` | integer | 100 | Max blocks to fetch via HTTP during subscription failover |
| `failover.backfill_timeout_ms` | integer | 30000 | Timeout for backfill HTTP requests |

Failover limits are captured from the active profile at the beginning of each recovery, including after YAML reload. An in-progress recovery keeps its captured limits. The backfill timeout is also bounded by the overall 30-second recovery deadline. Gaps beyond `max_backfill_blocks` terminate continuity rather than silently skipping missing blocks.

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
| `sharing_mode` | string | No | `auto` shares identical upstream runtime; `isolated` separates it by profile |
| `api_key` | string | No | Sends `Authorization: Bearer <value>` |
| `headers` | map | No | HTTP request and WebSocket handshake headers, overriding defaults |
| `auth_headers` | map | No | Headers with precedence over `headers` and `api_key` |

*At least one of `url` or `ws_url` is required.

## Environment Variable Substitution

Provider URLs support `${ENV_VAR}` substitution. Unresolved variables reject a profile at startup or reload. Substitution also applies to `api_key`, `headers`, and `auth_headers`.

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
| **Priority** | `/rpc/:chain` with application default set to `:priority` | Select by `priority` field (lowest first) |
| **Fastest** | `/rpc/fastest/:chain` | Lowest recent mean latency among reliability-qualified upstreams |
| **Load Balanced** | `/rpc/load-balanced/:chain` | Distribute requests across healthy providers with health-aware tiering |
| **Latency Weighted** | `/rpc/latency-weighted/:chain` | Weighted permutation using relative successful-attempt latency |

### When to Use Each Strategy

**Priority** — Predictable routing order. Use when you have a preferred provider (e.g., your own node) with public providers as fallback.

**Fastest** — Optimal latency among upstreams with qualified recent evidence. It never ranks from lifetime averages. If none qualifies, all live candidates remain available and the engine emits an explicit degradation.

**Load Balanced** — Even distribution with health-aware tiering. Spreads load across all healthy providers, deprioritizing those with tripped circuit breakers or rate limits. Good for throughput maximization and avoiding rate limits.

**Latency Weighted** — Weighted random ordering of qualified upstreams using scale-free latency ratios. Reliability qualification, capacity policy, and exploration remain separate concerns.

### Health-Based Tiering

All strategies are subject to health-based tiering after initial ranking. The pipeline reorders providers into 4 tiers based on circuit breaker state and rate limit status:

1. **Tier 1**: Closed circuit + not rate-limited (preferred)
2. **Tier 2**: Half-open circuit + not rate-limited
3. **Tier 3**: Closed circuit + rate-limited
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

## Provider Credentials

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
├── public.yml       # Included free public providers
├── production.yml   # Credentialed providers + own nodes
└── staging.yml      # Subset for testing
```

The dashboard lists configured profiles and links to this guide. To add a profile, create its YAML file in the profiles directory on each node and restart Lasso. For containers, follow the [deployment instructions](DEPLOYMENT.md#custom-profiles-and-credentials). In v0.3.4, reload alone can leave a newly added profile's WebSocket subscriptions unavailable.

For YAML edits to existing profiles, reload the running release:

```bash
_build/prod/rel/lasso/bin/lasso rpc 'Lasso.Config.ConfigStore.reload()'
```

Confirm the reload returns `:ok`, then refresh the dashboard. Each node reads its own files; distribute the same configuration to every node.

Access via URL: `/rpc/profile/:slug/:chain`

```bash
# Included public profile
curl -X POST http://localhost:4000/rpc/ethereum ...

# Production profile
curl -X POST http://localhost:4000/rpc/profile/production/ethereum ...
```

## Application-Level Configuration

Set in `config/runtime.exs` or via environment variables. Application configuration changes require a restart; edits to existing profile YAML use the reload command above:

| Environment Variable | Description | Default |
|---------------------|-------------|---------|
| `LASSO_NODE_ID` | Stable unique node identifier, required in production | `local` in development |
| `CLUSTER_DNS_QUERY` | DNS name for cluster node discovery | (disabled) |
| `PHX_HOST` | Hostname for the Phoenix endpoint | `localhost` |
| `PORT` | HTTP port | `4000` |
| `SECRET_KEY_BASE` | Phoenix secret key (required in production) | - |
| `LASSO_COWBOY_TELEMETRY_ENABLED` | Enable Cowboy per-request telemetry (`true`, `false`, `1`, or `0`); disabling it does not disable Lasso application or dashboard events | `true` |
| `LASSO_HTTP_RESPONSE_HEAP_TUNING_ENABLED` | Use a larger short-lived heap while validating completed HTTP upstream responses; useful for CPU-bound, high-concurrency deployments | `false` |
| `LASSO_HTTP_POOL_SIZE` | Maximum HTTP/1 connections per upstream host and pool | `256` |
| `LASSO_HTTP_POOL_COUNT` | Independent Finch pools per upstream host | `1` |

### Circuit Breaker Defaults

```elixir
config :lasso, :circuit_breaker,
  failure_threshold: 5,     # Aggregate failure threshold; category thresholds also apply
  success_threshold: 2,     # Consecutive successes to close
  recovery_timeout: 60_000  # Base ms before half-open; category/backoff rules also apply
```

Circuit settings take effect when provider instances start; restart Lasso after changing application configuration. YAML reload does not restart existing circuit breakers.

### Default Strategy

```elixir
config :lasso, :provider_selection_strategy, :load_balanced
```

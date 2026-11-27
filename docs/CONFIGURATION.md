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
| `head_policy` | string | No | `off` (default), `local` (one running instance), or `global` ([durable fleet setup](BLOCK_CONTINUITY_OPERATIONS.md)). Covers block choice, not automatic pinning of state reads. |
| `block_time_ms` | integer | No | Average block time in milliseconds. Sets the bounded profile-head reference window and supports legacy chain-wide time alignment. |

### HTTP chain identity

The configured `chain_id` is the expected identity of every provider on that
chain. A background HTTP `eth_chainId` probe that returns a readable, different
chain ID rejects the provider. An empty, null or malformed answer is an ordinary
probe failure and leaves identity as it was. Once observed, a rejection blocks HTTP dispatch even while the
provider's circuit is closed; requests can fail over to another eligible route.
A later matching probe clears the identity rejection without resetting circuit
state. Transport errors, rate limits, and JSON-RPC errors cannot clear it.

Identity observations are local to the physical endpoint (chain, URLs, and
authentication). Rejection survives unrelated configuration changes; stale probe
completions cannot clear it. A changed or newly configured endpoint has no identity
verdict and keeps normal admission behavior until observed. This is protection
against observed misconfiguration, not mandatory verification before first use.
HTTP observations do not establish the identity of a separate WebSocket URL.

### Monitoring

Controls probe frequency and the dashboard lag status threshold. Shared upstreams use the shortest configured probe interval across profiles; HTTP polling slows while WebSocket block updates are active.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `probe_interval_ms` | integer | `max(2 * block_time_ms, 5000)`, or 12000 without `block_time_ms` | Legacy fallback for the HTTP head-poll interval. |
| `lag_alert_threshold_blocks` | integer | 3 | Dashboard lag status threshold for qualified profile-scoped transport evidence; this setting does not emit lag warning logs. |
| `background_observations` | boolean | true | Enable periodic head polling, chain-identity probes, and configured `newHeads` observation. Client requests remain separate, and a routed request that times out still schedules one probe of that upstream. |
| `http_heads_interval_ms` | integer | `probe_interval_ms` | Normal HTTP head-poll interval; `0` disables periodic head polling. A chain polls its upstreams together in one round at the shortest interval its upstreams request, and each upstream polls in the rounds where its own interval is due. An upstream fed by `newHeads` answers each round with its latest head instead of polling. |
| `http_backup_interval_ms` | integer | 3 × normal interval | HTTP head-poll interval while WebSocket head evidence is fresh; `0` disables backup polling. |
| `chain_identity_interval_ms` | integer | 1800000 (30 min) | Interval for `eth_chainId` probes; `0` disables periodic identity probes. A routed request that times out still schedules one probe of its upstream, so liveness does not wait for this interval. |
| `evidence_freshness_ms` | integer | 30000–60000 from block time | Freshness window for retained head evidence. |
| `subscribe_new_heads` | boolean | WebSocket setting | Override automatic `newHeads` observation for the chain. |

Routed client `eth_blockNumber` and `eth_getBlockByNumber("latest")` responses
are head observations for the transport that served them. An `eth_blockNumber`
answer counts whenever it is higher than that transport's last observation; a
`latest` block response is sampled at most every 250 ms per transport. A provider
with background observations off keeps head evidence while it serves those reads.

The new intervals accept `0` to disable that activity, or at least 1000 ms. When profiles share a physical upstream, Core uses the shortest positive interval requested by an enabled reference. A disabled reference does not turn off another profile's observations. After a YAML reload, the worker applies the new demand without restarting client requests.

### Selection

Controls archival routing.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `archival_threshold` | integer | 128 | Blocks before data is considered "archival". Requests for blocks older than `head - threshold` are only routed to archival providers |

Requests that need the latest block prefer providers with a current head; see
[Head freshness](ROUTING.md#head-freshness). The retired `max_lag_blocks` field
still loads, has no effect and logs a warning naming the profile and chains.
Remove it.

### WebSocket

Controls upstream WebSocket subscription behavior.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `subscribe_new_heads` | boolean | true | Enable `newHeads` block tracking and eligibility for client `newHeads` subscriptions |
| `new_heads_timeout_ms` | integer | 42000 | Timeout before marking subscription stale (~3x block time) |
| `failover.max_backfill_blocks` | integer | 100 | Minimum block allowance during subscription failover; fast chains may expand to cover the recovery horizon |
| `failover.backfill_timeout_ms` | integer | 30000 | Timeout for backfill HTTP requests |

Failover limits are captured from the active profile at the beginning of each recovery, including after YAML reload. An in-progress recovery keeps its captured limits. The effective block allowance is the greater of `max_backfill_blocks` and the blocks expected during one backfill-timeout horizon, with time-derived expansion capped at 2048 blocks. The backfill timeout is also bounded by the overall 30-second recovery deadline. Gaps beyond the effective allowance terminate continuity rather than silently skipping missing blocks. A replacement upstream behind the last head or log the client received is not spliced in early: Lasso drops its older heads and logs, waits for it to reach that height, and resumes once the block it serves there has the hash the client already received. A different hash at that height is replayed as a reorg. The wait ends at the backfill timeout or the recovery deadline, whichever comes first, and a replacement that never catches up closes the subscription with code `1011`.

RPC socket notifications also have a node-local
delivery bound: 16 MiB and 32 queued notifications per client, within 128 MiB
across the node. A client that cannot keep up loses its subscription and its
WebSocket closes with code `1013`; the `[:lasso, :stream, :slow_consumer]`
telemetry event names the reason. Reservations are reclaimed when a socket
dies. These are runtime defaults, not profile YAML settings. Connected-reorg
repair remains tracked under [issue #186](https://github.com/jaxernst/lasso-rpc/issues/186).

Lasso also admits incoming upstream frames and instance fanout
before they enter recipient mailboxes. The node-local ingress envelope is
128 MiB, with 32 MiB and 128 queued messages per recipient. Exhaustion
invalidates only the affected subscriptions, which recover through the continuity
path or close with code `1011` on continuity failure. Unrelated RPC requests
and subscriptions retain their shared upstream connection. RPC responses apply
backpressure while the connection owner drains its mailbox. The pool-to-coordinator
mailbox uses the same envelope. If
its reservation fails, the affected pool key stops delivering and its clients
receive a continuity failure. Coordinator-to-client fanout uses the same
envelope; exhaustion terminates continuity without advancing the stream marker.
Backfill events use the same ingress envelope. The backfill owner waits for
each coordinator acknowledgement within the recovery deadline, and admission
failure or a missed acknowledgement terminates recovery rather than reporting
success for an undelivered event. Live events buffered during recovery have a
100-event count limit and also reserve from the 16 MiB per-stream and 128 MiB
node continuity envelope, with a 4 MiB per-event limit. Exhaustion terminates
continuity and releases the reservation. Recent heads and logs are retained
within the effective replay horizon and charged to the same per-stream and node
continuity envelope. History exhaustion terminates downstream continuity and
releases its reservation. Connected-reorg repair remains under issue #186, so
these defaults do not establish full streaming continuity qualification.

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
| `request_budget` | map | No | Per-node outbound JSON-RPC token bucket: positive integer `requests_per_second`, optional positive integer `burst` (defaults to the rate). Shared by HTTP, WebSocket, client attempts and background work; omitted means unlimited unless another reference to the same upstream declares a budget |
| `background_observations` | boolean | No | `false` removes this provider reference's periodic identity checks, block-height polls, and `newHeads` demand (default: true). Shared upstreams may still observe for another enabled reference; client requests and subscriptions remain available, and a routed request that times out still schedules one probe of that upstream |
| `observation_overrides` | map | No | Sparse per-provider overrides for `background_observations`, `subscribe_new_heads`, and the HTTP head, backup, and chain-identity intervals |
| `capabilities` | map | No | Provider capabilities (see Capabilities below) |
| `sharing_mode` | string | No | `auto` shares identical upstream runtime; `isolated` separates it by profile |
| `api_key` | string | No | Sends `Authorization: Bearer <value>` |
| `headers` | map | No | HTTP request and WebSocket handshake headers, overriding defaults |
| `auth_headers` | map | No | Headers with precedence over `headers` and `api_key` |

*At least one of `url` or `ws_url` is required. WebSocket-only providers are supported; omit `url` rather than setting it to null in YAML.

`observation_overrides` is sparse: an omitted field keeps the provider's legacy preference, then the chain setting. An explicit override wins. The chain-wide `background_observations: false` switch still disables periodic work for that chain reference.

### Outbound request budget

```yaml
providers:
  - id: metered
    url: https://rpc.example.com/${RPC_KEY}
    request_budget:
      requests_per_second: 3
      burst: 20
```

A bucket starts full, refills continuously, and admits at most `burst +
requests_per_second * elapsed_seconds` requests over an interval. This is a
sustained-rate/burst allowance, not a fixed or rolling one-second window.
One outbound JSON-RPC item costs one token: every HTTP attempt (including
retry/fallback), WebSocket request, subscribe/resubscribe/unsubscribe, head
poll and identity observation. Incoming subscription notifications, WebSocket
upgrades, and protocol ping/pong/close frames cost nothing. An admitted attempt
keeps its charge if cancelled or failed before sending; tokens are not refunded.

The bucket is shared across profiles and transports with the same canonical
upstream identity (chain, normalized HTTP and WS URLs, authentication), even
with `sharing_mode: isolated`. An omitted declaration inherits another
reference's explicit budget. Conflicting explicit budgets reject startup or
reload without replacing the active configuration. Different endpoint identities
and different nodes have separate buckets; this is not an account-wide quota.
Unchanged reloads reuse the bucket; a changed budget or node restart starts a
fresh bucket. Removing all declarations disables enforcement.

A spent budget skips dispatch and tries another eligible provider within the
ordinary routing and transaction-provider boundaries. Background work skips
that tick. Refusals do not open circuits, create learned cooldowns, or count as
provider failures. If every eligible route is budget-refused, JSON-RPC returns
`-32005` with `data.reason: "upstream_request_budget_exhausted"` and
`data.retry_after_ms` for the earliest refill. Mixed failures retain the ordinary
error rules, including log-range advice. Opt-in `lasso_meta.budget_refusals`
identifies refused provider/transport routes separately from dispatched attempts.
Provider details show this node's rate/burst and admitted/refused totals per
upstream. Counts reset with a fresh bucket.

## Environment Variable Substitution

Provider URLs also accept percent-encoded Basic credentials (`https://user:password@host/rpc` or `wss://user:password@host/ws`); a username alone sends an empty password. Credentials apply only to that URL and cannot be combined with an explicit Authorization header (including `auth_headers`) or `api_key`.

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
| **Priority** | `/rpc/priority/:chain` | Select by `priority` field (lowest first) |
| **Fastest** | `/rpc/fastest/:chain` | Lowest recent mean latency among reliability-qualified upstreams |
| **Load Balanced** | `/rpc/load-balanced/:chain` | Randomized order with a bounded distinct-instance first pass for replay-safe fallback |
| **Balanced Fast** | `/rpc/balanced-fast/:chain` | Weighted permutation over each reliable provider's best latency evidence |

### When to Use Each Strategy

**Priority** — Predictable routing order. Use when you have a preferred provider (e.g., your own node) with public providers as fallback.

**Fastest** — Optimal latency among upstreams with qualified recent evidence. It never ranks from lifetime averages. If none qualifies, all live candidates remain available and the engine emits an explicit degradation.

**Load Balanced** — Randomized ordering with health-aware tiering, deferring routes
whose recent failure rate is clearly worse than their peers' until they recover. For replay-safe
fallback, distinct physical instances receive a bounded first pass before sibling
transports within a tier. It does not guarantee exact shares, capacity-aware
balancing, or independent operators. See [Routing](ROUTING.md#load-balanced)
for the dispatch-budget and recovered-head-preference boundaries.

For upgrades from v0.5.1, rename `LW_BETA` to `BALANCED_FAST_BETA` (application key `:balanced_fast_beta`); the old variable is no longer read, and startup logs a warning when it is set. Existing `latency-weighted` URLs and `strategy` values remain permanent aliases.

**Balanced Fast** — Weighted random ordering of reliable upstreams by their best latency evidence: client samples in the method family, else the same family's system prior. One reliable upstream with no latency evidence yet competes in each ranking at 1/8 of the quickest's weight, so it earns samples instead of being starved; upstreams with recent failures follow the reliable ones. It sits between load-balanced and fastest: load stays spread while the quickest providers receive more of it. See [balanced fast](ROUTING.md#balanced-fast). `latency-weighted` is an alias.

### Health-Based Tiering

All strategies are subject to health-based tiering after initial ranking. The pipeline reorders providers into 4 tiers based on circuit breaker state and rate limit status:

1. **Tier 1**: Closed circuit + not rate-limited (preferred)
2. **Tier 2**: Half-open circuit + not rate-limited
3. **Tier 3**: Closed circuit + rate-limited
4. **Tier 4**: Half-open circuit + rate-limited

Open-circuit providers are excluded entirely. Within each tier, the strategy's ranking is preserved; load-balanced replay-safe fallback gives distinct physical instances a first pass before alternate transports, subject to the cursor's candidate bound and explicit recovered-head preference. See [load-balanced semantics](ROUTING.md#load-balanced) for limits and tradeoffs.

Exception: a connection-class HTTP circuit in half-open with a free probation lease and no rate limit keeps its ordinary strategy ranking instead of being deferred behind closed circuits.

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
| `limits.block_age_methods` | list | Methods subject to `max_block_age` limit; only methods with a block number parameter (such as `eth_call`, `eth_getBalance`, `eth_getStorageAt`, `eth_getBlockByNumber`) |
| `error_rules` | list | Provider-specific error classification overrides (first match wins) |

When `capabilities` is omitted, defaults to permissive (only `local_only` methods blocked, no limits).

Unsupported methods and categories keep a provider out of a request while
another provider supports the method. When none does, Lasso tries the
unsupported providers as a last resort instead of refusing the request. `max_block_age` reads the request's block number parameter, so
it has no effect on `eth_getLogs`; use `max_block_range` for log queries. Startup and reload now reject `block_age_methods` entries without a readable block number parameter, including previously accepted `eth_getLogs` entries.

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

### Provider templates

`config/examples/` holds provider-specific profiles. Each keeps the provider at `priority: 1` with keyless public fallbacks at lower priority, copied from `config/profiles/public.yml` with their capabilities and error rules, so rate limits, outages, range limits, and archive reads still have somewhere to fail over. The default `balanced_fast` strategy orders by measured latency and ignores `priority`, so keep the provider primary with the priority strategy. A template copied as its own profile is addressed by its slug: route through `/rpc/profile/<slug>/priority/:chain`, or through `/rpc/profile/<slug>/:chain` after setting the node-wide default `config :lasso, :provider_selection_strategy, :priority`. Unscoped routes such as `/rpc/priority/:chain` use the `public` profile, so they apply only when you merge the template's providers into `public.yml`. See [Priority routing](ROUTING.md#priority).

#### Chainstack

[`config/examples/chainstack.yml`](../config/examples/chainstack.yml) is a profile template for Chainstack Global Nodes on Ethereum, Base, and Arbitrum, with dRPC, PublicNode, Pocket, and thirdweb fallbacks. It uses one [multichain auth token](https://docs.chainstack.com/docs/multichain-api) for every chain, so a single credential covers the whole profile:

1. In the Chainstack console, create a multichain endpoint and attach a Global Node for each chain you keep. Nodes that are not attached answer `401`.
2. Set `CHAINSTACK_MULTICHAIN_TOKEN` to the endpoint's `mt_` token.
3. Copy the template into your profiles directory, or merge its provider entries into an existing profile, and reload.
4. Send requests to `/rpc/profile/chainstack/priority/:chain`. For merged entries, use `/rpc/profile/<slug>/priority/:chain` with the receiving profile's slug, or `/rpc/priority/:chain` for `public`.

```yaml
- id: "ethereum_chainstack"
  priority: 1
  url: "https://ethereum-mainnet.core.chainstack.com/${CHAINSTACK_MULTICHAIN_TOKEN}"
  ws_url: "wss://ethereum-mainnet.core.chainstack.com/${CHAINSTACK_MULTICHAIN_TOKEN}"
```

Other chains use the same token with their `<protocol>-<network>` host, for example `polygon-mainnet` or `ethereum-sepolia`, and need their own fallback providers. Adjust these Chainstack defaults to your plan and nodes:

| Setting | Template value | When to change |
|---------|----------------|----------------|
| `limits.max_block_range` | `100` (Developer plan `eth_getLogs` cap) | Set `10000` on Growth and higher plans |
| `archival` | `false` | Set `true` when the attached node runs in Archive mode |
| `error_rules` | `-32612` → `capability_violation` | Keep: Chainstack returns it for disabled tracers, so the request fails over to another provider when one supports it |

For a Dedicated Node, use the node's own HTTPS and WSS URLs from its connection details; the multichain token works in the same URL position when the node is attached.

## Multiple Profiles

Create separate profiles for different environments or use cases:

```
config/profiles/
├── public.yml       # Included free public providers
├── production.yml   # Credentialed providers + own nodes
└── staging.yml      # Subset for testing
```

The dashboard lists configured profiles and links to this guide. To add a profile, create its YAML file in the profiles directory on each node and reload Lasso. For containers, follow the [deployment instructions](DEPLOYMENT.md#custom-profiles-and-credentials). v0.3.5 supports new profiles reusing connected WebSocket upstreams after reload. On v0.3.4, restart after adding a profile to avoid unavailable subscriptions.

For Core v0.5 and later, validate edited files before applying them to the
running release:

```bash
_build/prod/rel/lasso/bin/lasso check-config
_build/prod/rel/lasso/bin/lasso reload
```

`reload` reaches the running node over Erlang distribution, so start the release
with `RELEASE_COOKIE` set and run `reload` with the same value. `check-config`
needs neither.

From source, run the same commands in the IEx session started with
`iex -S mix phx.server`:

```elixir
Lasso.Operator.Commands.check_config!()
Lasso.Operator.Commands.reload!()
```

`check-config` reads the existing file profiles without changing disk or the
active routes. Both commands exit nonzero on invalid configuration. A rejected
reload keeps the active configuration, but a later cold start cannot recover it
from invalid files. On v0.4.x, use `bin/lasso rpc 'IO.inspect(Lasso.Config.ConfigStore.reload())'`
for reload. After a successful reload, refresh the dashboard. Each node reads
its own files; distribute the same configuration to every node.

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
| `LASSO_NODE_ID` | Stable unique node identifier, required in production when Erlang distribution is on | `local` |
| `CLUSTER_DNS_QUERY` | DNS name for cluster node discovery | (disabled) |
| `PHX_HOST` | Hostname for the Phoenix endpoint | `localhost` |
| `PORT` | HTTP port | `4000` |
| `SECRET_KEY_BASE` | Phoenix secret key, required in production when Erlang distribution is on | Generated per boot without distribution |
| `LASSO_OTEL_ENABLED` | Enable optional tracing (`true`, `false`, `1`, or `0`); invalid values fail startup. See [Tracing](TRACING.md). | `false` |
| `LASSO_HTTP_RESPONSE_HEAP_TUNING_ENABLED` | Use a larger short-lived heap while validating completed HTTP upstream responses; useful for CPU-bound, high-concurrency deployments | `false` |
| `LASSO_HTTP_POOL_SIZE` | Maximum HTTP/1 connections per upstream host and pool | `256` |
| `LASSO_HTTP_POOL_COUNT` | Independent Finch pools per upstream host | `1` |
| `LASSO_UPSTREAM_ADMISSION_SHARDS` | Shards for the upstream admission ledger | `32` |
| `LASSO_UPSTREAM_INFLIGHT_NODE_LIMIT` | Maximum concurrent upstream HTTP requests on this node | `512` |
| `LASSO_UPSTREAM_INFLIGHT_ORIGIN_LIMIT` | Maximum concurrent requests to one physical upstream origin | `192` |
| `LASSO_UPSTREAM_INFLIGHT_RESPONSE_BYTE_LIMIT` | Aggregate retained upstream HTTP response budget, in bytes | `134217728` (128 MiB) |
| `LASSO_UPSTREAM_RESPONSE_BYTE_LIMIT` | Maximum upstream HTTP response size, in bytes | `16777216` (16 MiB) |

Upstream HTTP responses are streamed under these limits. The byte budget initially charges twice the received body size to cover a conservative in-memory copy during validation and delivery. Retained JSON-RPC errors also reserve decoded heap and restored response bytes until serialization or discard; a small wire response can therefore exhaust retention capacity if its decoded representation is large. An oversized or compressed response is rejected locally; it does not penalize upstream reliability. The origin limit must be divisible by the shard count, no greater than the node limit or Finch pool capacity. The aggregate byte budget must cover twice the maximum response size. Invalid combinations fail application startup.

### Circuit Breaker Defaults

```elixir
config :lasso, :circuit_breaker,
  failure_threshold: 5,     # Aggregate failure threshold; category thresholds also apply
  success_threshold: 2,     # Consecutive successes to close
  recovery_timeout: 60_000  # Base ms before half-open; category/backoff rules also apply
```

Circuit settings take effect when provider instances start; restart Lasso after changing application configuration. YAML reload does not restart existing circuit breakers.

### Default Strategy

Routes that name no strategy, such as `/rpc/:chain` and `/ws/rpc/:chain`, use `:balanced_fast`. To change the node-wide default:

```elixir
config :lasso, :provider_selection_strategy, :load_balanced
```

## Learned routing

Four routing effects learned from traffic are enabled by default:

| Environment variable | Default | Accepted values |
| --- | --- | --- |
| `LASSO_PROVIDER_KNOWLEDGE_METHOD_REFUSAL_MODE` | `on` | `on`/`off`, `true`/`false`, `1`/`0`, any case |
| `LASSO_PROVIDER_KNOWLEDGE_HISTORICAL_DEPTH_MODE` | `on` | `on`/`off`, `true`/`false`, `1`/`0`, any case |
| `LASSO_PROVIDER_KNOWLEDGE_SPAN_LIMIT_MODE` | `on` | `on`/`off`, `true`/`false`, `1`/`0`, any case |
| `LASSO_PROVIDER_KNOWLEDGE_FAILURE_RATE_DEFERRAL_MODE` | `on` | `on`/`off`, `true`/`false`, `1`/`0`, any case |

Set a variable to `off` and restart to keep that effect from reordering routes.
Other values fail startup. Disabling an effect does not erase its observations;
inspection remains available. Application configuration uses
`:provider_knowledge_effect_modes`, a map with `:method_refusal`,
`:historical_depth`, `:span_limit` and `:failure_rate_deferral` keys.
Failure-rate deferral is the `load-balanced` weighting described in
[routing](ROUTING.md#load-balanced); off, that strategy shares load equally. Runtime environment values populate
that map at boot. No profile schema or database migration is required.

The quota-exhaustion effect remains off. Claim auditing also
remains off. The four settled effects accept no `shadow` mode. Knowledge uses
node-local memory, no durable knowledge store, and no background model service.
See [routing](ROUTING.md#learned-provider-limits) for evidence and safety rules.

## Transaction providers

A chain may declare `transactions: {providers: [provider_id], fallback: none}`.
Each listed ID must name a send-capable provider on that chain, without
duplicates, and at least one other provider must remain to serve reads.
`fallback` is `none` (the default) or `read_providers`. Omit the block for
ordinary routing; the stock public profile leaves it unset. See
[the private-send example](../config/examples/private-sends.yml), and
[routing](ROUTING.md#transaction-providers) for how requests use the two sides.

Transaction providers and their downstream builders still see every transaction
sent to them, and a wallet that rebroadcasts through another endpoint bypasses
the boundary. `fallback: read_providers` hands the signed transaction to read
providers, which normally broadcast it to the public mempool.

Reads stay outside the boundary. `eth_call` and `eth_estimateGas` send their
calldata to a read provider, so simulating through Lasso shows that provider your
intent before you sign; simulate locally when that matters. Polling a private
transaction's hash through a read provider ties the hash to your connection and
timing.

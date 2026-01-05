# Routing Profiles System Design v4.3

**Status**: Ready for Implementation
**Last Updated**: December 2024
**Supersedes**: ROUTING_PROFILES_DESIGN_V4.2.md

---

## Changes from V4.2

This revision resolves implementation blockers identified in design review:

| Issue                         | V4.2 Approach                            | V4.3 Fix                                                                                                                      |
| ----------------------------- | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Startup circular dependency   | ConfigStore.init loads profiles          | Two-phase: init creates ETS only, `load_all_profiles()` called by Application after supervision tree is up                    |
| Event filtering unclear       | String parsing in hot path               | Profile-scoped PubSub topics eliminate filtering                                                                              |
| Rollback logic broken         | Read chains from ETS (not yet written)   | Track started chains in local variable                                                                                        |
| Hot reload transaction safety | Undefined                                | Best-effort hot reload: immediate changes, in-flight may fail, circuit breaker resets                                         |
| ETS table confusion           | Single table mentioned                   | Three tables: `:lasso_config_store` (config) + `:lasso_provider_state` (runtime) + `:lasso_chain_refcount` (cleanup tracking) |
| Invalid file handling         | Skip and continue                        | Fail-fast on first invalid profile                                                                                            |
| Global worker cleanup         | Not addressed                            | Inline refcounting for BYOK long-tail chain cleanup                                                                           |
| Registry key migration        | Not documented                           | Full migration table added (Appendix D)                                                                                       |
| Global provider keys          | Composite string `"profile:provider_id"` | Tuple keys `{profile, provider_id}` - no parsing needed                                                                       |

---

## Design Philosophy

1. **Clean OSS/SaaS Split** - Dashboard and profiles are OSS core; billing/auth are SaaS extensions
2. **Explicit Profile URLs** - Profile always required in path, no defaults or fallbacks
3. **ETS-Only Hot Path** - All request-path checks use ETS (<1ms), no DB reads
4. **Full Profile Isolation** - Each profile has completely independent circuit breakers, metrics, and routing state
5. **Explicit Tuple Keys** - All Registry and ETS keys use tuples with consistent ordering
6. **No Conditional Sharing** - Simplicity over optimization; no infrastructure-type detection or heuristics
7. **BYOK First** - Architecture designed for full isolation that BYOK users expect

---

## 1. OSS/SaaS Architecture Split

### 1.1 Component Distribution

| OSS (Self-Hosted)                     | SaaS Adds                             |
| ------------------------------------- | ------------------------------------- |
| Dashboard (LiveView UI)               | DB Config Backend (PostgreSQL)        |
| Profiles (YAML files)                 | Accounts & Authentication             |
| File-based config backend             | API Keys (account-scoped)             |
| Request pipeline with profile routing | Subscriptions (account→profile links) |
| Telemetry (Prometheus export)         | CU Metering (bytes-based)             |
| WebSocket (eth_subscribe)             |                                       |
| Rate Limiting (Hammer + ETS)          |                                       |

### 1.2 Extension Architecture

```elixir
# config/config.exs (OSS defaults)
config :lasso,
  config_backend: Lasso.Config.Backend.File,
  config_backend_config: [profiles_dir: "config/profiles"],
  auth_enabled: false,
  metering_enabled: false

# config/config.exs (SaaS/lasso-cloud)
config :lasso,
  config_backend: LassoCloud.Config.Backend.Database,
  auth_enabled: true,
  metering_enabled: true
```

**Critical Rule**: SaaS depends on OSS, never the reverse. OSS must be fully functional standalone.

---

## 2. URL Structure

Profile is always required. No defaults, no fallbacks.

```
# OSS (no auth)
/rpc/:profile/:chain
/rpc/:profile/:strategy/:chain

# SaaS (API key required)
/rpc/:profile/:chain?key=lasso_abc123

# WebSocket
/ws/rpc/:profile/:chain
```

---

## 3. Data Model

### 3.1 Entity Relationships

```
Account (SaaS only)
├── has_many API Keys (account-scoped, work for all subscribed profiles)
└── has_many Subscriptions
    └── belongs_to Profile (links account to profile with CU limits)

Profile (OSS + SaaS)
├── slug: unique identifier
├── name: display name
├── type: free|standard|premium|byok (for telemetry)
├── config: YAML text (chains, providers)
└── default_rps_limit, default_burst_limit
```

**Key Decisions:**

- Profiles are just configuration (no ownership/tier fields)
- Subscriptions define access and limits (SaaS only)
- Rate limit defaults live on profile, subscriptions can override

### 3.2 Database Schema (SaaS)

```sql
CREATE TABLE profiles (
  id UUID PRIMARY KEY,
  slug VARCHAR(50) UNIQUE NOT NULL,
  name VARCHAR(100) NOT NULL,
  config TEXT NOT NULL,
  default_rps_limit INTEGER NOT NULL DEFAULT 100,
  default_burst_limit INTEGER NOT NULL DEFAULT 500
);

CREATE TABLE subscriptions (
  id UUID PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts(id),
  profile_id UUID NOT NULL REFERENCES profiles(id),
  status VARCHAR(20) NOT NULL DEFAULT 'active',
  cu_limit BIGINT NOT NULL,
  cu_used_this_period BIGINT NOT NULL DEFAULT 0,
  rps_limit_override INTEGER,
  burst_limit_override INTEGER,
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  CONSTRAINT unique_account_profile UNIQUE (account_id, profile_id)
);

CREATE TABLE api_keys (
  id UUID PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts(id),
  key_hash VARCHAR(64) NOT NULL UNIQUE,
  key_prefix VARCHAR(12) NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT true,
  expires_at TIMESTAMPTZ
);
```

---

## 4. API Key Design (SaaS)

Keys belong to accounts, not profiles. One key accesses all profiles the account is subscribed to.

**Format:** `lasso_abc123def456xyz789qrs` (32 chars, base62)

**Validation (<0.1ms via ETS):**

```elixir
def validate(provided_key) do
  hash = :crypto.hash(:sha256, provided_key) |> Base.encode16(case: :lower)
  case :ets.lookup(:api_keys_cache, hash) do
    [{^hash, key_meta}] -> validate_key_meta(key_meta)
    [] -> {:error, :invalid_key}
  end
end
```

**Extraction Priority:** `x-lasso-api-key` header → Bearer token → `?key=` query param

---

## 5. Request Resolution Flow

### 5.1 Hot Path Requirements

All hot path operations use ETS only (<1ms):

- Profile lookup: ETS
- API key validation: ETS
- Rate limit check: Hammer (ETS backend)
- Subscription lookup: ETS cache

**No DB reads on hot path.** CU limit enforcement is eventual (checked periodically).

### 5.2 Resolution Logic

```elixir
def resolve(conn) do
  profile_slug = conn.path_params["profile"]

  with {:ok, profile} <- get_profile_from_ets(profile_slug) do
    case extract_api_key(conn) do
      {:error, :no_key} -> {:ok, profile, nil, nil}  # OSS/anonymous
      {:ok, api_key, _} ->
        with {:ok, key_meta} <- validate_key(api_key),
             {:ok, subscription} <- get_subscription(key_meta.account_id, profile.id) do
          {:ok, profile, subscription, key_meta}
        end
    end
  end
end
```

### 5.3 Router Configuration

```elixir
scope "/rpc", LassoWeb do
  pipe_through [:rpc]  # ProfileResolver, RateLimiter plugs

  post "/:profile/:chain", RPCController, :rpc
  post "/:profile/:strategy/:chain", RPCController, :rpc
end
```

---

## 6. Config Backend

### 6.1 Behaviour Definition

```elixir
defmodule Lasso.Config.Backend do
  @callback init(config :: keyword()) :: {:ok, state :: term()}
  @callback load_all(state :: term()) :: {:ok, [profile_spec()]}
  @callback load(state :: term(), slug :: String.t()) :: {:ok, profile_spec()} | {:error, :not_found}
  @callback save(state :: term(), slug :: String.t(), yaml :: String.t()) :: :ok | {:error, term()}
  @optional_callbacks [save: 3]
end
```

### 6.2 ConfigStore ETS Structure

**Table:** `:lasso_config_store`

| Key                          | Value                           | Description                                  |
| ---------------------------- | ------------------------------- | -------------------------------------------- |
| `{:profile, slug, :meta}`    | `profile_meta()`                | Profile metadata                             |
| `{:profile, slug, :chains}`  | `%{chain => ChainConfig.t()}`   | Parsed chain configs                         |
| `{:profile_list}`            | `[slug, ...]`                   | All loaded profile slugs                     |
| `{:chain_profiles, chain}`   | `[profile_slug, ...]`           | Profiles containing this chain               |
| `{:all_chains}`              | `[chain, ...]`                  | Union of all chains across all profiles      |
| `{:global_providers, chain}` | `[{profile, provider_id}, ...]` | All provider instances for global components |

### 6.3 Provider ID Handling

Provider IDs remain unchanged within profile-scoped components. For **global components** (BlockSync, HealthProbe), a tuple key `{profile, provider_id}` is used to prevent collisions when multiple profiles use the same provider ID.

```elixir
defmodule Lasso.Config.ConfigStore do
  @doc """
  Returns all global provider keys for a chain (across all profiles).
  Used by GlobalChainSupervisor to start BlockSync/HealthProbe workers.
  Returns list of {profile, provider_id} tuples.
  """
  def list_global_providers(chain) do
    case :ets.lookup(@table, {:global_providers, chain}) do
      [{{:global_providers, ^chain}, providers}] -> providers
      [] -> []
    end
  end
end
```

**Example:**

```elixir
# Profile "free" has provider "alchemy" for ethereum
# Profile "premium" has provider "alchemy" for ethereum (different API key)

# Profile-scoped keys (no collision - different profiles):
{:circuit_breaker, "free", "ethereum", "alchemy", :http}
{:circuit_breaker, "premium", "ethereum", "alchemy", :http}

# Global keys (use tuple to avoid collision - no string parsing):
{:block_sync_worker, "ethereum", {"free", "alchemy"}}
{:block_sync_worker, "ethereum", {"premium", "alchemy"}}
```

**Rationale:** Profile-scoped components already include profile in the key tuple. Global components use a tuple `{profile, provider_id}` as the provider key dimension. This avoids string parsing/encoding and leverages Erlang's native tuple handling in Registry and ETS.

### 6.4 Profile YAML Format

```yaml
---
name: Production
slug: production
type: standard
default_rps_limit: 500
default_burst_limit: 1000
---
chains:
  ethereum:
    chain_id: 1
    providers:
      - id: "alchemy"
        url: "https://eth-mainnet.g.alchemy.com/v2/..."
        ws_url: "wss://eth-mainnet.g.alchemy.com/v2/..."
        priority: 1
```

**Profile Types:** `free` | `standard` | `premium` | `byok`

### 6.5 BYOK Profile Format

BYOK users bring their own provider endpoints:

```yaml
---
name: Acme Corp
slug: byok-acme
type: byok
default_rps_limit: 1000
default_burst_limit: 2000
---
chains:
  ethereum:
    chain_id: 1
    providers:
      - id: "acme-alchemy"
        url: "https://eth-mainnet.g.alchemy.com/v2/ACME_API_KEY"
        ws_url: "wss://eth-mainnet.g.alchemy.com/v2/ACME_API_KEY"
        priority: 1
      - id: "acme-infura"
        url: "https://mainnet.infura.io/v3/ACME_INFURA_KEY"
        priority: 2
```

**Credential Storage:** API keys are embedded in URLs. For SaaS deployments, profile YAML may be stored encrypted in database or fetched from secure vault.

### 6.6 Chain Name Validation

Chain names must use canonical identifiers to ensure consistent global component sharing. BYOK profiles are validated at load time.

**Canonical Chain Names:**

```elixir
@canonical_chains %{
  "ethereum" => 1,
  "sepolia" => 11155111,
  "holesky" => 17000,
  "polygon" => 137,
  "polygon-amoy" => 80002,
  "arbitrum" => 42161,
  "arbitrum-sepolia" => 421614,
  "optimism" => 10,
  "optimism-sepolia" => 11155420,
  "base" => 8453,
  "base-sepolia" => 84532,
  "avalanche" => 43114,
  "avalanche-fuji" => 43113,
  "bsc" => 56,
  "bsc-testnet" => 97
}

def valid_chain_name?(name), do: Map.has_key?(@canonical_chains, name)
def expected_chain_id(name), do: Map.get(@canonical_chains, name)
```

**Validation Rules:**

1. Chain name must be in the canonical list
2. `chain_id` in config must match the expected value for that chain name
3. Validation fails the entire profile load (no partial loads)

```elixir
defp validate_chain_names(chains) do
  Enum.reduce_while(chains, :ok, fn {chain_name, config}, :ok ->
    cond do
      not valid_chain_name?(chain_name) ->
        {:halt, {:error, {:invalid_chain_name, chain_name, Map.keys(@canonical_chains)}}}

      config.chain_id != expected_chain_id(chain_name) ->
        {:halt, {:error, {:chain_id_mismatch, chain_name, config.chain_id, expected_chain_id(chain_name)}}}

      true ->
        {:cont, :ok}
    end
  end)
end
```

**Error Messages:**

```
Invalid chain name "eth". Use canonical name "ethereum".
Chain ID mismatch for "ethereum": got 5, expected 1.
```

**Extending the Chain List:**

New chains are added to `@canonical_chains` in code. This is intentional - chain names are part of the system's namespace, not user-configurable. For truly custom chains (private networks), use a naming convention like `"custom-{chain_id}"`.

---

## 7. Rate Limiting

### 7.1 Profile-Scoped Rate Limiting

Dual-window rate limiting with Hammer (ETS backend), scoped by profile.

**Bucket keys use tuples** to prevent injection attacks:

```elixir
def call(conn, _opts) do
  {rps, burst} = get_limits(conn.assigns.profile, conn.assigns[:subscription])
  bucket = rate_limit_bucket(conn)

  with {:allow, _} <- Hammer.check_rate(bucket_key(bucket, :burst), 1_000, burst),
       {:allow, _} <- Hammer.check_rate(bucket_key(bucket, :sustained), 60_000, rps * 60) do
    conn
  else
    {:deny, retry_after} -> rate_limit_response(conn, retry_after)
  end
end

# Tuple-based bucket keys prevent injection attacks
defp rate_limit_bucket(conn) do
  profile_slug = conn.assigns.profile.slug

  case conn.assigns[:key_meta] do
    # Anonymous: rate limit by profile + IP
    nil -> {:profile, profile_slug, :ip, client_ip(conn)}
    # Authenticated: rate limit by account + profile
    key -> {:account, key.account_id, :profile, profile_slug}
  end
end

defp bucket_key(bucket_tuple, window) do
  # Hammer requires string keys, so we serialize the tuple safely
  :erlang.term_to_binary({bucket_tuple, window}) |> Base.encode64()
end
```

### 7.2 Rate Limit State Isolation

Each profile maintains independent rate limit state. If the same IP hits both `free` and `premium` profiles, they have separate buckets:

```elixir
{:profile, "free", :ip, "1.2.3.4"}     # separate counter
{:profile, "premium", :ip, "1.2.3.4"} # separate counter
```

**Rationale:** BYOK profiles should not be affected by traffic to shared profiles.

---

## 8. Batch Request Handling

Global batch size limit (not per-profile):

```elixir
@max_batch_size Application.compile_env(:lasso, :max_batch_size, 100)

defp handle_batch(conn, requests) when length(requests) > @max_batch_size do
  error_response(conn, -32005, "Batch too large (max: #{@max_batch_size})")
end
```

Batches are metered by total bytes, not per-request CU.

---

## 9. CU Metering (SaaS)

### 9.1 Calculation

Bytes-based with method multipliers:

```elixir
@bytes_per_cu 1024
@category_multipliers %{
  core: 1.0,      # eth_blockNumber, eth_chainId
  state: 1.5,    # eth_call, eth_estimateGas
  filters: 2.0,  # eth_getLogs
  debug: 5.0,    # debug_traceTransaction
  trace: 5.0     # trace_block
}

def calculate(method, bytes_in, bytes_out) do
  base_cu = div(bytes_in + bytes_out, @bytes_per_cu)
  multiplier = get_multiplier(method)
  max(1, trunc(base_cu * multiplier))
end
```

### 9.2 Async Metering

- Writes to ETS buffer, flushes periodically to DB
- CU limits checked every 60s, not per-request
- Over-limit subscriptions marked in ETS cache for rate limiting

### 9.3 Subscription Cache

All subscription lookups hit ETS, never DB on hot path. Cache invalidation via PubSub broadcast.

---

## 10. Profile-Scoped Isolation

### 10.1 Isolation Principle

**Every component is fully isolated by profile.** There is no conditional sharing based on infrastructure type, URL patterns, or other heuristics. This provides:

- Predictable behavior for BYOK users
- Simple mental model (profile = isolation boundary)
- No hidden dependencies between profiles
- Easy debugging (profile is always explicit in keys)

**Trade-off acknowledged:** If two profiles use the same upstream endpoint and that endpoint is down, each profile discovers this independently. This is acceptable because:

1. Simplicity outweighs shared-failure-detection optimization
2. BYOK users expect full isolation
3. No heuristics to maintain or debug
4. Circuit breaker recovery is fast (30-60s)

### 10.2 Canonical Registry Key Format

**All keys follow this ordering:** `{:type, profile, chain, ...additional_dimensions}`

The type tag comes first to enable efficient pattern matching by component type. Profile is always the second element for profile-scoped components.

**Profile-Scoped Components:**

| Component                    | Registry Key                                                 | Notes                           |
| ---------------------------- | ------------------------------------------------------------ | ------------------------------- |
| **ChainSupervisor**          | `{:chain_supervisor, profile, chain}`                        | Supervision tree root           |
| **ProviderPool**             | `{:provider_pool, profile, chain}`                           | Health tracking                 |
| **TransportRegistry**        | `{:transport_registry, profile, chain}`                      | Channel management              |
| **Circuit Breaker**          | `{:circuit_breaker, profile, chain, provider_id, transport}` | Failure protection              |
| **WSConnection**             | `{:ws_conn, profile, chain, provider_id}`                    | WebSocket state                 |
| **ProviderSupervisor**       | `{:provider_supervisor, profile, chain, provider_id}`        | Per-provider tree               |
| **ProviderSupervisors (DS)** | `{:provider_supervisors, profile, chain}`                    | DynamicSupervisor for providers |
| **Metrics** (BenchmarkStore) | `{:benchmark, profile, chain, provider_id, method}`          | Latency tracking                |
| **UpstreamSubManager**       | `{:upstream_sub_manager, profile, chain}`                    | WS subscription mgmt            |
| **UpstreamSubPool**          | `{:upstream_sub_pool, profile, chain}`                       | Subscription pooling            |
| **ClientSubRegistry**        | `{:client_registry, profile, chain}`                         | Client subscriptions            |
| **StreamSupervisor**         | `{:stream_supervisor, profile, chain}`                       | Stream coordination             |
| **StreamCoordinator**        | `{:stream_coordinator, profile, chain, key}`                 | Per-subscription                |

**Global Components (no profile dimension):**

| Component              | Registry Key                                            | Notes                         |
| ---------------------- | ------------------------------------------------------- | ----------------------------- |
| BlockSync.Supervisor   | `{:block_sync_supervisor, chain}`                       | Per-chain supervisor          |
| BlockSync.Worker       | `{:block_sync_worker, chain, {profile, provider_id}}`   | Tuple key - no parsing needed |
| HealthProbe.Supervisor | `{:health_probe_supervisor, chain}`                     | Per-chain supervisor          |
| HealthProbe.Worker     | `{:health_probe_worker, chain, {profile, provider_id}}` | Tuple key - no parsing needed |
| BlockCache             | `{:block_cache, chain}`                                 | Immutable block data          |

**BlockSync.Registry ETS keys:**

| Key                                        | Value                                   |
| ------------------------------------------ | --------------------------------------- |
| `{:height, chain, {profile, provider_id}}` | `{height, timestamp, source, metadata}` |

### 10.3 Circuit Breaker Isolation

Circuit breakers use the canonical key format:

```elixir
defmodule Lasso.RPC.CircuitBreaker do
  @doc """
  Circuit breaker identity uses canonical tuple format.
  Full isolation - no shared state between profiles.
  """
  def breaker_id(profile, chain, provider_id, transport) do
    {:circuit_breaker, profile, chain, provider_id, transport}
  end

  def via_name(profile, chain, provider_id, transport) do
    {:via, Registry, {Lasso.Registry, breaker_id(profile, chain, provider_id, transport)}}
  end
end
```

**Example keys:**

```elixir
# These are completely independent circuit breakers:
{:circuit_breaker, "free", "ethereum", "alchemy", :http}
{:circuit_breaker, "premium", "ethereum", "alchemy", :http}
{:circuit_breaker, "byok-acme", "ethereum", "alchemy", :http}
```

### 10.4 What's Profile-Scoped vs Global

**Profile-scoped components (isolated per profile):**

- Circuit breakers (failure state)
- Rate limiters (quota tracking)
- Metrics/benchmarks (latency, CU tracking)
- Provider health in ProviderPool (availability state)
- WebSocket connections (one per profile-provider)
- Streaming subscriptions (client and upstream)
- Selection state (weights, preferences)

**Global components (shared across profiles):**

- Block heights (canonical chain state) - via BlockSync.Registry
- Block cache (immutable historical data)
- HTTP connection pools (Finch, by URL host)

**Why BlockSync and HealthProbe are global:**

- Block heights are objective blockchain state, not profile-specific
- If provider X reports block 1000 for chain Y, that's true for all profiles
- Duplicating sync workers per profile wastes connections and bandwidth
- HealthProbe detects provider recovery - also objective, not profile-specific

**Why global components use composite provider keys:**

- Multiple profiles can have the same provider ID (e.g., both "free" and "premium" have "alchemy")
- Each profile's "alchemy" may point to different API keys/endpoints
- Composite key `"free:alchemy"` vs `"premium:alchemy"` prevents collision

### 10.5 Supervision Architecture

```
Application
├── Lasso.PubSub (shared)
├── Lasso.Registry (shared, partitioned)
├── Lasso.Finch (shared, pools by URL host)
├── Lasso.GlobalChainSupervisor (empty at startup)
├── Lasso.ProfileChainSupervisor (empty at startup)
├── Lasso.Config.ConfigStore (loads profiles, starts supervisors)
│
├── [After ConfigStore.init completes]
│
├── Lasso.GlobalChainSupervisor (DynamicSupervisor)
│   └── Per unique chain (across all profiles):
│       ├── BlockSync.Supervisor {:block_sync_supervisor, chain}
│       │   └── BlockSync.Worker {:block_sync_worker, chain, "profile:provider_id"}
│       └── HealthProbe.Supervisor {:health_probe_supervisor, chain}
│           └── HealthProbe.Worker {:health_probe_worker, chain, "profile:provider_id"}
│
└── Lasso.ProfileChainSupervisor (DynamicSupervisor)
    └── Per (profile, chain) pair:
        └── ChainSupervisor {:chain_supervisor, profile, chain}
            ├── ProviderPool {:provider_pool, profile, chain}
            ├── TransportRegistry {:transport_registry, profile, chain}
            ├── ProviderSupervisors {:provider_supervisors, profile, chain}
            │   └── Per provider:
            │       ├── CircuitBreaker[:http] {:circuit_breaker, profile, chain, provider_id, :http}
            │       ├── CircuitBreaker[:ws] {:circuit_breaker, profile, chain, provider_id, :ws}
            │       └── WSConnection {:ws_conn, profile, chain, provider_id}
            ├── ClientSubscriptionRegistry {:client_registry, profile, chain}
            ├── UpstreamSubscriptionManager {:upstream_sub_manager, profile, chain}
            ├── UpstreamSubscriptionPool {:upstream_sub_pool, profile, chain}
            └── StreamSupervisor {:stream_supervisor, profile, chain}
                └── StreamCoordinator {:stream_coordinator, profile, chain, key}
```

### 10.6 Application Startup Order

**Two-Phase Initialization:** ConfigStore.init creates ETS tables only. Profile loading happens AFTER the supervision tree is fully started, avoiding circular dependencies.

```elixir
defmodule Lasso.Application do
  def start(_type, _args) do
    # Phase 1: Create ETS tables (owned by Application, never dies)
    :ets.new(:lasso_config_store, [:set, :protected, :named_table, read_concurrency: true])
    :ets.new(:lasso_provider_state, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(:lasso_chain_refcount, [:set, :public, :named_table, read_concurrency: true])

    children = [
      # Core infrastructure
      {Phoenix.PubSub, name: Lasso.PubSub},
      {Registry, keys: :unique, name: Lasso.Registry, partitions: System.schedulers_online()},
      {Finch, name: Lasso.Finch, pools: %{default: [size: 200, count: 5]}},

      # Empty supervisors (populated after supervision tree is up)
      Lasso.GlobalChainSupervisor,
      Lasso.ProfileChainSupervisor,

      # ConfigStore GenServer (does NOT load profiles in init)
      {Lasso.Config.ConfigStore, backend_opts()},

      # Phoenix endpoint
      LassoWeb.Endpoint
    ]

    with {:ok, supervisor} <- Supervisor.start_link(children, strategy: :one_for_one),
         {:ok, profiles} <- Lasso.Config.ConfigStore.load_all_profiles() do
      # Phase 2 complete: profiles loaded after supervision tree is up
      Logger.info("Loaded #{length(profiles)} profiles")
      {:ok, supervisor}
    else
      {:error, reason} ->
        # Fail-fast: if profiles can't load, app shouldn't start
        Logger.error("Application startup failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```

**Why two-phase?**

- ConfigStore.init cannot call GlobalChainSupervisor because it may not be started yet
- Profile load failures fail app startup (fail-fast principle)
- ETS tables are owned by Application process (never dies), not ConfigStore

**Why no mutex?**

- `DynamicSupervisor.start_child` is idempotent - returns `{:error, {:already_started, pid}}` for duplicates
- `ensure_chain_processes` is idempotent - safe to call from multiple concurrent profile loads
- Concurrent profile loads naturally serialize at the supervisor level

### 10.7 GlobalChainSupervisor

Manages global per-chain processes (BlockSync, HealthProbe):

```elixir
defmodule Lasso.GlobalChainSupervisor do
  use DynamicSupervisor
  require Logger

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Ensure global processes are running for a chain.
  Called by ConfigStore after loading profiles.
  Idempotent - safe to call multiple times.
  """
  def ensure_chain_processes(chain_name) do
    with :ok <- ensure_block_sync(chain_name),
         :ok <- ensure_health_probe(chain_name) do
      :ok
    end
  end

  @doc """
  Stop global processes for a chain.
  Called when the last profile using a chain is removed.
  """
  def stop_chain_processes(chain_name) do
    stop_block_sync(chain_name)
    stop_health_probe(chain_name)
    :ok
  end

  defp ensure_block_sync(chain_name) do
    spec = {Lasso.BlockSync.Supervisor, chain_name}
    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_health_probe(chain_name) do
    spec = {Lasso.HealthProbe.Supervisor, chain_name}
    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_block_sync(chain_name) do
    case Registry.lookup(Lasso.Registry, {:block_sync_supervisor, chain_name}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end

  defp stop_health_probe(chain_name) do
    case Registry.lookup(Lasso.Registry, {:health_probe_supervisor, chain_name}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end

  @doc """
  Start BlockSync/HealthProbe workers for all global providers on a chain.
  Called after chain supervisors are ready.
  """
  def start_workers_for_chain(chain_name) do
    global_providers = Lasso.Config.ConfigStore.list_global_providers(chain_name)

    Enum.each(global_providers, fn {profile, provider_id} ->
      # Use tuple key directly - no string encoding
      Lasso.BlockSync.Supervisor.start_worker(chain_name, {profile, provider_id})
      Lasso.HealthProbe.Supervisor.start_worker(chain_name, {profile, provider_id})
    end)
  end
end
```

**Global worker config lookup:** BlockSync and HealthProbe workers receive `{profile, provider_id}` tuples. On init or restart, they look up provider configuration via `ConfigStore.get_provider(profile, chain, provider_id)`. This ensures workers always have current config even after supervisor restarts.

### 10.8 ProfileChainSupervisor

```elixir
defmodule Lasso.ProfileChainSupervisor do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start supervision tree for a (profile, chain) pair"
  def start_profile_chain(profile, chain_name, chain_config) do
    DynamicSupervisor.start_child(__MODULE__,
      {Lasso.RPC.ChainSupervisor, {profile, chain_name, chain_config}})
  end

  @doc "Stop supervision tree for a (profile, chain) pair"
  def stop_profile_chain(profile, chain_name) do
    case Registry.lookup(Lasso.Registry, {:chain_supervisor, profile, chain_name}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "List all running (profile, chain) pairs"
  def list_profile_chains do
    Registry.select(Lasso.Registry, [
      {{{:chain_supervisor, :"$1", :"$2"}, :_, :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end
end
```

### 10.9 ChainSupervisor Changes

```elixir
defmodule Lasso.RPC.ChainSupervisor do
  use Supervisor

  def start_link({profile, chain_name, chain_config}) do
    Supervisor.start_link(__MODULE__, {profile, chain_name, chain_config},
      name: via_name(profile, chain_name))
  end

  defp via_name(profile, chain_name) do
    {:via, Registry, {Lasso.Registry, {:chain_supervisor, profile, chain_name}}}
  end

  def init({profile, chain_name, chain_config}) do
    children = [
      {ProviderPool, {profile, chain_name, chain_config}},
      {TransportRegistry, {profile, chain_name, chain_config}},
      {DynamicSupervisor, strategy: :one_for_one,
        name: {:via, Registry, {Lasso.Registry, {:provider_supervisors, profile, chain_name}}}},
      {ClientSubscriptionRegistry, {profile, chain_name}},
      {Lasso.Core.Streaming.UpstreamSubscriptionManager, {profile, chain_name}},
      {UpstreamSubscriptionPool, {profile, chain_name}},
      {Lasso.Core.Streaming.StreamSupervisor, {profile, chain_name}},
      # Provider connection starter (runs once, fail-fast)
      %{
        id: :provider_connection_starter,
        start: {Task, :start_link,
          [fn -> start_provider_connections!(profile, chain_name, chain_config) end]},
        restart: :transient
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp start_provider_connections!(profile, chain_name, chain_config) do
    Enum.each(chain_config.providers, fn provider ->
      case start_provider_supervisor(profile, chain_name, chain_config, provider) do
        :ok -> :ok
        {:error, reason} ->
          # Log but don't crash - provider will be marked unhealthy
          Logger.error("Failed to start provider #{provider.id}: #{inspect(reason)}")
      end
    end)
  end
end
```

### 10.10 PubSub Topic Format

All chain-scoped topics include profile:

| Topic Pattern                                | Example                                | Subscribers                         |
| -------------------------------------------- | -------------------------------------- | ----------------------------------- |
| `"ws:conn:#{profile}:#{chain}"`              | `"ws:conn:free:ethereum"`              | ProviderPool, TransportRegistry     |
| `"ws:subs:#{profile}:#{chain}"`              | `"ws:subs:free:ethereum"`              | UpstreamSubscriptionManager         |
| `"provider_pool:events:#{profile}:#{chain}"` | `"provider_pool:events:free:ethereum"` | Dashboard, UpstreamSubscriptionPool |
| `"circuit:events:#{profile}:#{chain}"`       | `"circuit:events:free:ethereum"`       | ProviderPool, Dashboard             |
| `"upstream_sub_manager:#{profile}:#{chain}"` | `"upstream_sub_manager:free:ethereum"` | UpstreamSubscriptionPool            |
| `"block_sync:#{profile}:#{chain}"`           | `"block_sync:free:ethereum"`           | ProviderPool (profile-scoped)       |
| `"health_probe:#{profile}:#{chain}"`         | `"health_probe:free:ethereum"`         | ProviderPool (profile-scoped)       |

**Global topics (for cross-profile consumers like Dashboard):**

| Topic                     | Purpose                                   |
| ------------------------- | ----------------------------------------- |
| `"block_sync:#{chain}"`   | BlockSync updates (Dashboard aggregation) |
| `"health_probe:#{chain}"` | HealthProbe recovery events (Dashboard)   |
| `"block_cache:updates"`   | Block cache updates                       |

**Dual-broadcast pattern for global workers:**

BlockSync and HealthProbe workers broadcast to BOTH global and profile-scoped topics. This eliminates filtering in the hot path.

```elixir
# BlockSync.Worker broadcasts to both topics:
defp broadcast_height(state, height, source) do
  # provider_key is a tuple {profile, provider_id}
  msg = {:block_height_update, state.provider_key, height, source}

  # Global topic (Dashboard, cross-profile consumers)
  Phoenix.PubSub.broadcast(Lasso.PubSub, "block_sync:#{state.chain}", msg)

  # Profile-scoped topic (ProviderPool receives only its profile's updates)
  {profile, _provider_id} = state.provider_key
  Phoenix.PubSub.broadcast(Lasso.PubSub, "block_sync:#{profile}:#{state.chain}", msg)
end
```

```elixir
# ProviderPool subscribes ONLY to its profile's topic - no filtering needed:
def init({profile, chain, config}) do
  Phoenix.PubSub.subscribe(Lasso.PubSub, "block_sync:#{profile}:#{chain}")
  Phoenix.PubSub.subscribe(Lasso.PubSub, "health_probe:#{profile}:#{chain}")
  {:ok, %{profile: profile, chain: chain, ...}}
end

# All received messages are guaranteed to be for this profile
# provider_key is already a tuple - no parsing needed
def handle_info({:block_height_update, {_profile, provider_id}, height, _source}, state) do
  {:noreply, update_provider_height(state, provider_id, height)}
end
```

**Rationale:** Dual-broadcast adds negligible overhead (PubSub is ETS-based) but eliminates all filtering from the hot path. Tuple keys avoid string parsing entirely.

### 10.11 Finch Pool Safety

Finch pools are shared by URL host. This is safe because:

1. **Headers are per-request, not per-connection:** API keys in `Authorization` headers are attached to individual requests, not HTTP/2 connections
2. **Connection reuse doesn't leak credentials:** Each request carries its own headers regardless of which profile initiated it
3. **Performance benefit:** Sharing HTTP/2 connections reduces handshake overhead

```elixir
# Both profiles use the same Finch pool for alchemy.com
# but each request carries profile-specific Authorization headers
Finch.build(:post, "https://eth-mainnet.g.alchemy.com/v2/KEY_A", headers_a, body)
Finch.build(:post, "https://eth-mainnet.g.alchemy.com/v2/KEY_B", headers_b, body)
```

### 10.12 ETS Table Strategy

**Three tables** with distinct ownership and access patterns:

| Table                   | Owner       | Access                                 | Purpose                                  |
| ----------------------- | ----------- | -------------------------------------- | ---------------------------------------- |
| `:lasso_config_store`   | Application | `:protected` (only ConfigStore writes) | Profile metadata, chain configs          |
| `:lasso_provider_state` | Application | `:public` (many writers)               | Runtime provider state (heights, health) |
| `:lasso_chain_refcount` | Application | `:public` (atomic counters)            | Track profiles per chain for cleanup     |

```elixir
# Created in Application.start (owned by Application process, never dies)
:ets.new(:lasso_config_store, [:set, :protected, :named_table, read_concurrency: true])
:ets.new(:lasso_provider_state, [:set, :public, :named_table, read_concurrency: true])
:ets.new(:lasso_chain_refcount, [:set, :public, :named_table, read_concurrency: true])

# Config table (read-heavy, written by ConfigStore only)
:ets.insert(:lasso_config_store, {{:profile, slug, :meta}, profile_meta})
:ets.insert(:lasso_config_store, {{:profile, slug, :chains}, chains_map})

# State table (write-heavy, written by ProviderPool, BlockSync, etc.)
:ets.insert(:lasso_provider_state, {{:provider_sync, profile, chain, provider_id}, state})
:ets.insert(:lasso_provider_state, {{:block_height, chain, {profile, provider_id}}, height_info})

# Refcount table (atomic increment/decrement for chain usage tracking)
# Key: chain_name, Value: count of profiles using this chain
:ets.update_counter(:lasso_chain_refcount, chain_name, {2, 1}, {chain_name, 0})
```

**Rationale for three tables:**

- **Separation of concerns:** Config is static, state is hot-path mutable, refcount is lifecycle-only
- **Different access patterns:** Config is read-heavy, state is write-heavy, refcount uses atomic counters
- **Ownership clarity:** ConfigStore owns config writes, multiple processes write state
- **No atom table growth:** Tuple keys avoid `:"provider_pool_#{profile}_#{chain}"` patterns
- **BYOK cleanup:** Refcount enables cleanup of long-tail chains when last profile is removed

### 10.13 Request Context

```elixir
defmodule Lasso.RPC.RequestOptions do
  defstruct [
    :strategy,
    :provider_override,
    :transport,
    :failover_on_override,
    :timeout_ms,
    :request_id,
    :request_context,
    :plug_start_time,
    # Profile context (required)
    :profile,       # Profile slug
    :profile_meta   # Profile metadata from ETS
  ]
end
```

### 10.14 Selection API

```elixir
defmodule Lasso.RPC.Selection do
  @doc """
  Select channels for a request. Profile is required.

  The profile determines which ProviderPool to query and which
  providers are available for selection.
  """
  @spec select_channels(String.t(), String.t(), String.t(), keyword()) :: [Channel.t()]
  def select_channels(profile, chain, method, opts \\ []) do
    # Query profile-scoped ProviderPool
    candidates = ProviderPool.list_candidates(profile, chain, build_filters(opts))

    # Build channels from candidates (provider_id is original, not composite)
    build_channels(profile, candidates, chain, method, opts)
  end
end
```

### 10.15 Dashboard Aggregation

Dashboard subscribes to events from all profiles:

```elixir
defmodule LassoWeb.Dashboard do
  def mount(_params, _session, socket) do
    # Subscribe to global topics
    Phoenix.PubSub.subscribe(Lasso.PubSub, "block_sync:updates")

    # Subscribe to profile-scoped topics for all profile×chain combinations
    for profile <- ConfigStore.list_profiles(),
        chain <- ConfigStore.list_chains_for_profile(profile) do
      Phoenix.PubSub.subscribe(Lasso.PubSub, "provider_pool:events:#{profile}:#{chain}")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "circuit:events:#{profile}:#{chain}")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{profile}:#{chain}")
    end

    {:ok, socket}
  end
end
```

**Scale note:** At 100 profiles × 10 chains × 3 topics = 3,000 subscriptions per LiveView. This is acceptable for initial deployment. For larger scale, consider an aggregator process pattern (deferred to future optimization).

### 10.16 Telemetry Cardinality

| Field          | Cardinality      | Use in Prometheus Labels? |
| -------------- | ---------------- | ------------------------- |
| `profile_type` | Low (4 values)   | Yes                       |
| `profile_slug` | High (unbounded) | No - logs only            |
| `chain`        | Low (~20)        | Yes                       |

---

## 11. WebSocket Support

### 11.1 Connection Handling

```elixir
def connect(%{path_params: path_params} = info) do
  profile_slug = path_params["profile"]
  chain = path_params["chain"]

  with {:ok, profile} <- ConfigStore.get_profile(profile_slug),
       {:ok, chain_config} <- ConfigStore.get_chain(profile_slug, chain),
       {:ok, auth} <- resolve_auth(info.params) do
    {:ok, %{profile_slug: profile_slug, profile: profile, chain: chain, ...}}
  end
end
```

### 11.2 Block Height Integration

Profile-scoped components receive block height updates from global BlockSync via PubSub. With dual-broadcast, ProviderPool subscribes only to its profile's topic:

```elixir
defmodule Lasso.RPC.ProviderPool do
  def init({profile, chain, config}) do
    # Subscribe to profile-scoped topic only - no filtering needed
    Phoenix.PubSub.subscribe(Lasso.PubSub, "block_sync:#{profile}:#{chain}")

    {:ok, %{profile: profile, chain: chain, ...}}
  end

  # All messages on this topic are for our profile
  # provider_key is a tuple - no parsing needed
  def handle_info({:block_height_update, {_profile, provider_id}, height, _source}, state) do
    {:noreply, update_provider_height(state, provider_id, height)}
  end
end
```

### 11.3 Failover Boundaries

StreamCoordinator failover stays within profile's configured providers:

```elixir
defp select_next_provider(state) do
  ConfigStore.get_chain(state.profile, state.chain)
  |> Map.get(:providers, [])
  |> Enum.filter(&(&1.id != state.failed_provider_id))
  |> Enum.filter(&supports_websocket?/1)
end
```

### 11.4 Connection Limits (SaaS)

Limits enforced at subscription level:

| Limit               | Default |
| ------------------- | ------- |
| `max_connections`   | 10      |
| `max_subscriptions` | 500     |

### 11.5 Subscription Metering (SaaS)

| Event                | CU Cost        |
| -------------------- | -------------- |
| Subscription created | 1 CU           |
| newHeads event       | 0.1 CU         |
| logs event           | 0.5 CU per log |

CU exhaustion: Warning at 80%, 5-minute grace at 100%, then disconnect.

### 11.6 JSON Passthrough

Minimize parsing in hot path - extract method via regex, forward raw bytes:

```elixir
defp extract_method_fast(text) do
  case Regex.run(~r/"method"\s*:\s*"([^"]+)"/, text) do
    [_, method] -> {:ok, method}
    nil -> {:error, :no_method}
  end
end
```

---

## 12. Security

### 12.1 SSRF Prevention (BYOK URLs)

Validate at profile creation time:

- Block private IP ranges (RFC1918, link-local, loopback)
- Resolve hostnames and validate resolved IPs
- Block dangerous ports (22, 23, 25, 3306, 5432, 6379)
- Support IPv4 and IPv6

**Trade-off:** DNS resolution at validation time only (not per-request). Document that BYOK URLs should use static IPs or trusted DNS.

### 12.2 Brute Force Protection

Rate limit auth failures per IP: 10 failures/minute max.

---

## 13. Distributed Deployment

### 13.1 State Classification

| State Type           | Examples                                       | Clustering Impact           |
| -------------------- | ---------------------------------------------- | --------------------------- |
| **Instance-Local**   | Metrics, circuit breakers, Finch pools         | None - correct per-instance |
| **Logically-Global** | Subscription cache, API key cache, rate limits | Requires coordination       |

### 13.2 OSS Single-Instance

All features work correctly with single instance. Multi-instance without clustering:

- Rate limits: Nx effective limit with N instances
- Cache staleness: 60s max window
- Config changes: Require redeployment

### 13.3 Clustering (SaaS)

Add `libcluster` for Erlang distribution. PubSub broadcasts automatically reach clustered nodes. Optional: Redis backend for Hammer for accurate distributed rate limiting.

---

## 14. Profile Lifecycle

### 14.1 Profile Creation (Two-Phase Commit)

When a new profile is loaded, **start supervisors first, then commit to ETS**. Track started chains in a local variable for rollback (cannot read from ETS since it hasn't been written yet).

```elixir
defmodule Lasso.Config.ConfigStore do
  def load_profile(profile_spec) do
    with {:ok, meta} <- parse_frontmatter(profile_spec),
         {:ok, chains} <- parse_chains(profile_spec),
         :ok <- validate_chain_names(chains),
         :ok <- validate_all_providers(chains),
         # Phase 1: Start supervision trees, track what started for rollback
         {:ok, started_chains} <- start_profile_processes(meta.slug, chains) do

      # Phase 2: Commit to ETS only after all supervisors are running
      store_profile_meta(meta)
      store_profile_chains(meta.slug, chains)
      update_profile_list(meta.slug)
      update_indices_atomic(meta.slug, chains)

      # Phase 3: Start global workers
      start_global_workers(meta.slug, chains)

      {:ok, meta.slug}
    else
      {:error, reason, started_chains} ->
        # Rollback using local list (NOT ETS - it hasn't been written yet)
        rollback_started_chains(meta.slug, started_chains)
        {:error, reason}

      {:error, reason} ->
        # Validation failed before any chains started
        {:error, reason}
    end
  end

  # Returns {:ok, started_chains} or {:error, reason, started_chains}
  defp start_profile_processes(profile_slug, chains) do
    Enum.reduce_while(chains, {:ok, []}, fn {chain_name, chain_config}, {:ok, started} ->
      # Increment refcount for cleanup tracking
      increment_chain_ref(chain_name)

      # Always call ensure_chain_processes - it's idempotent
      # This avoids race conditions when multiple profiles load concurrently
      :ok = Lasso.GlobalChainSupervisor.ensure_chain_processes(chain_name)

      case Lasso.ProfileChainSupervisor.start_profile_chain(profile_slug, chain_name, chain_config) do
        {:ok, _pid} ->
          {:cont, {:ok, [chain_name | started]}}
        {:error, reason} ->
          # Decrement refcount since we failed
          decrement_chain_ref(chain_name)
          # Return accumulated chains for rollback
          {:halt, {:error, {chain_name, reason}, started}}
      end
    end)
  end

  defp rollback_started_chains(profile_slug, started_chains) do
    Enum.each(started_chains, fn chain_name ->
      Lasso.ProfileChainSupervisor.stop_profile_chain(profile_slug, chain_name)
      # Decrement refcount - if 0, we were the only profile, stop global supervisors
      case decrement_chain_ref(chain_name) do
        0 -> Lasso.GlobalChainSupervisor.stop_chain_processes(chain_name)
        _ -> :ok
      end
    end)
  end

  defp update_indices_atomic(profile_slug, chains) do
    chain_names = Map.keys(chains)

    # Update chain_profiles index
    Enum.each(chain_names, fn chain_name ->
      current = list_profiles_for_chain(chain_name)
      :ets.insert(@config_table, {{:chain_profiles, chain_name}, [profile_slug | current] |> Enum.uniq()})
    end)

    # Update all_chains index
    current_chains = list_all_chains()
    :ets.insert(@config_table, {{:all_chains}, (current_chains ++ chain_names) |> Enum.uniq()})

    # Update global_providers index
    Enum.each(chains, fn {chain_name, chain_config} ->
      providers = Enum.map(chain_config.providers, fn p -> {profile_slug, p.id} end)
      current = list_global_providers(chain_name)
      :ets.insert(@config_table, {{:global_providers, chain_name}, current ++ providers})
    end)
  end

  defp start_global_workers(profile_slug, chains) do
    Enum.each(chains, fn {chain_name, chain_config} ->
      Enum.each(chain_config.providers, fn provider ->
        # Use tuple key directly
        Lasso.BlockSync.Supervisor.start_worker(chain_name, {profile_slug, provider.id})
        Lasso.HealthProbe.Supervisor.start_worker(chain_name, {profile_slug, provider.id})
      end)
    end)
  end

  # Inline refcounting for chain cleanup (BYOK long-tail chains)
  defp increment_chain_ref(chain_name) do
    :ets.update_counter(:lasso_chain_refcount, chain_name, {2, 1}, {chain_name, 0})
  end

  defp decrement_chain_ref(chain_name) do
    case :ets.update_counter(:lasso_chain_refcount, chain_name, {2, -1, 0, 0}, {chain_name, 0}) do
      0 ->
        :ets.delete(:lasso_chain_refcount, chain_name)
        0
      count ->
        count
    end
  end
end
```

### 14.1.1 File Backend Behavior

```elixir
defmodule Lasso.Config.Backend.File do
  @behaviour Lasso.Config.Backend

  @doc "Load all profiles from directory. Fail-fast on first invalid file."
  def load_all(%{profiles_dir: dir}) do
    dir
    |> list_profile_files()
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case load_profile_file(file) do
        {:ok, spec} -> {:cont, {:ok, [spec | acc]}}
        {:error, reason} ->
          Logger.error("Failed to load profile #{file}: #{inspect(reason)}")
          {:halt, {:error, {file, reason}}}
      end
    end)
  end

  defp list_profile_files(dir) do
    Path.wildcard(Path.join(dir, "*.yml"))
    |> Enum.reject(fn path ->
      filename = Path.basename(path)
      String.starts_with?(filename, ".") or String.starts_with?(filename, "_")
    end)
    |> Enum.sort()
  end

  defp load_profile_file(path) do
    with {:ok, content} <- File.read(path),
         {:ok, spec} <- parse_yaml(content),
         :ok <- validate_slug_matches_filename(spec, path) do
      {:ok, spec}
    end
  end

  defp validate_slug_matches_filename(%{slug: slug}, path) do
    expected_slug = path |> Path.basename(".yml")
    if slug == expected_slug do
      :ok
    else
      {:error, {:slug_mismatch, slug, expected_slug}}
    end
  end
end
```

**File discovery rules:**

- Load all `*.yml` files in `profiles_dir` (no subdirectory scanning)
- Skip files starting with `.` or `_` (backups, templates)
- Profile slug must match filename (`premium.yml` must have `slug: premium`)
- **Fail-fast:** First invalid file fails entire load (caught at deploy time)

### 14.2 Profile Deletion

**Deferred for initial release.** See Appendix B.3.

### 14.3 Best-Effort Hot Reload

Profile changes take effect immediately with "best-effort" semantics. This is designed for BYOK users who control their own traffic patterns.

**Supported Operations:**

| Operation             | Effect    | In-Flight Requests |
| --------------------- | --------- | ------------------ |
| Add new profile       | Immediate | N/A                |
| Add chain to profile  | Immediate | N/A                |
| Add provider to chain | Immediate | N/A                |
| Remove provider       | Immediate | May fail           |
| Remove chain          | Immediate | May fail           |
| Update provider URL   | Immediate | May fail           |

**Semantics:**

- Changes take effect immediately (no drain period)
- In-flight requests to removed resources may fail with 503
- Circuit breaker state is NOT preserved (starts fresh)
- WebSocket clients are disconnected and must reconnect
- This is acceptable for BYOK users who control their own traffic

**What's NOT supported (deferred):**

- Graceful request draining
- Circuit breaker state preservation across reload
- Zero-downtime provider URL changes

### 14.3.1 Adding a New Profile

```elixir
def load_new_profile(profile_spec) do
  # Same as startup loading - no existing state to worry about
  load_profile(profile_spec)
end
```

### 14.3.2 Adding/Removing Chains

```elixir
def add_chain(profile_slug, chain_name, chain_config) do
  with :ok <- validate_chain_names(%{chain_name => chain_config}),
       :ok <- validate_all_providers(%{chain_name => chain_config}) do

    # Increment refcount for cleanup tracking
    increment_chain_ref(chain_name)

    # Always call ensure_chain_processes - it's idempotent
    :ok = GlobalChainSupervisor.ensure_chain_processes(chain_name)

    case ProfileChainSupervisor.start_profile_chain(profile_slug, chain_name, chain_config) do
      {:ok, _pid} ->
        # Update ETS
        update_profile_chain(profile_slug, chain_name, chain_config)
        update_indices_for_chain(profile_slug, chain_name)

        # Start global workers
        start_global_workers_for_chain(profile_slug, chain_name, chain_config)

        {:ok, chain_name}

      {:error, reason} ->
        # Rollback refcount
        decrement_chain_ref(chain_name)
        {:error, reason}
    end
  end
end

def remove_chain(profile_slug, chain_name) do
  # Stop profile-scoped supervisor (in-flight requests will fail)
  :ok = ProfileChainSupervisor.stop_profile_chain(profile_slug, chain_name)

  # Stop global workers for this profile's providers
  stop_global_workers_for_chain(profile_slug, chain_name)

  # Decrement refcount - if 0, we were the last profile, stop global supervisors
  case decrement_chain_ref(chain_name) do
    0 -> GlobalChainSupervisor.stop_chain_processes(chain_name)
    _ -> :ok
  end

  # Update ETS
  remove_profile_chain(profile_slug, chain_name)
  rebuild_indices()

  :ok
end
```

### 14.3.3 Adding/Removing Providers

```elixir
def add_provider(profile_slug, chain_name, provider_config) do
  with :ok <- validate_provider(provider_config),
       :ok <- ChainSupervisor.ensure_provider(profile_slug, chain_name, provider_config) do

    # Start global workers with tuple key
    provider_key = {profile_slug, provider_config.id}
    BlockSync.Supervisor.start_worker(chain_name, provider_key)
    HealthProbe.Supervisor.start_worker(chain_name, provider_key)

    # Update ETS
    add_provider_to_chain(profile_slug, chain_name, provider_config)
    update_global_providers_index(profile_slug, chain_name, provider_config.id)

    {:ok, provider_config.id}
  end
end

def remove_provider(profile_slug, chain_name, provider_id) do
  # Stop provider supervisor (closes connections, in-flight may fail)
  :ok = ChainSupervisor.remove_provider(profile_slug, chain_name, provider_id)

  # Stop global workers with tuple key
  provider_key = {profile_slug, provider_id}
  BlockSync.Supervisor.stop_worker(chain_name, provider_key)
  HealthProbe.Supervisor.stop_worker(chain_name, provider_key)

  # Update ETS
  remove_provider_from_chain(profile_slug, chain_name, provider_id)
  rebuild_global_providers_index(chain_name)

  :ok
end
```

### 14.3.4 Updating Provider Config

```elixir
def update_provider(profile_slug, chain_name, provider_config) do
  # Remove old, add new (simple approach - circuit breaker resets)
  :ok = remove_provider(profile_slug, chain_name, provider_config.id)
  add_provider(profile_slug, chain_name, provider_config)
end
```

**Note:** This resets circuit breaker state. For URL-only changes where you want to preserve state, a more sophisticated approach would be needed (deferred).

### 14.3.5 Full Profile Reload

For convenience, reload entire profile from backend:

```elixir
def reload_profile(profile_slug) do
  with {:ok, old_chains} <- get_profile_chains(profile_slug),
       {:ok, new_spec} <- backend_load(profile_slug),
       {:ok, new_meta} <- parse_frontmatter(new_spec),
       {:ok, new_chains} <- parse_chains(new_spec),
       :ok <- validate_chain_names(new_chains),
       :ok <- validate_all_providers(new_chains) do

    old_chain_names = MapSet.new(Map.keys(old_chains))
    new_chain_names = MapSet.new(Map.keys(new_chains))

    removed = MapSet.difference(old_chain_names, new_chain_names)
    added = MapSet.difference(new_chain_names, old_chain_names)
    updated = MapSet.intersection(old_chain_names, new_chain_names)

    # Remove old chains
    Enum.each(removed, &remove_chain(profile_slug, &1))

    # Add new chains
    Enum.each(added, fn chain ->
      add_chain(profile_slug, chain, Map.get(new_chains, chain))
    end)

    # Update existing chains (diff providers)
    Enum.each(updated, fn chain ->
      reload_chain_providers(profile_slug, chain,
        Map.get(old_chains, chain),
        Map.get(new_chains, chain))
    end)

    # Update profile metadata
    store_profile_meta(new_meta)

    :ok
  end
end

defp reload_chain_providers(profile, chain, old_config, new_config) do
  old_ids = MapSet.new(Enum.map(old_config.providers, & &1.id))
  new_ids = MapSet.new(Enum.map(new_config.providers, & &1.id))

  # Remove old providers
  Enum.each(MapSet.difference(old_ids, new_ids), fn id ->
    remove_provider(profile, chain, id)
  end)

  # Add new providers
  Enum.each(MapSet.difference(new_ids, old_ids), fn id ->
    provider = Enum.find(new_config.providers, &(&1.id == id))
    add_provider(profile, chain, provider)
  end)

  # Update changed providers (URL, priority, etc.)
  Enum.each(MapSet.intersection(old_ids, new_ids), fn id ->
    old_provider = Enum.find(old_config.providers, &(&1.id == id))
    new_provider = Enum.find(new_config.providers, &(&1.id == id))
    if old_provider != new_provider do
      update_provider(profile, chain, new_provider)
    end
  end)
end
```

### 14.4 Profile Lifecycle Error Handling

**Invalid provider URL:** Operation fails, no changes made.

**Provider connection failure:** Provider marked unhealthy in ProviderPool. Other providers continue. Circuit breaker opens after threshold.

**Invalid YAML:** Operation fails with parse error. Existing config unchanged.

**Partial chain start failure:** Rollback stops chains started for that operation.

### 14.5 ConfigStore API Summary

```elixir
defmodule Lasso.Config.ConfigStore do
  # Profile queries
  @spec get_profile(String.t()) :: {:ok, profile_meta()} | {:error, :not_found}
  @spec list_profiles() :: [String.t()]

  # Chain queries
  @spec get_chain(String.t(), String.t()) :: {:ok, ChainConfig.t()} | {:error, :not_found}
  @spec get_profile_chains(String.t()) :: {:ok, %{String.t() => ChainConfig.t()}} | {:error, :not_found}
  @spec list_chains_for_profile(String.t()) :: [String.t()]
  @spec list_all_chains() :: [String.t()]
  @spec list_profiles_for_chain(String.t()) :: [String.t()]

  # Provider queries
  @spec get_provider(String.t(), String.t(), String.t()) :: {:ok, provider_config()} | {:error, :not_found}
  @spec get_provider_ids(String.t(), String.t()) :: [String.t()]
  @spec list_global_providers(String.t()) :: [{String.t(), String.t()}]  # Returns [{profile, provider_id}]

  # Lifecycle - startup
  @spec load_all_profiles() :: {:ok, [String.t()]} | {:error, term()}

  # Lifecycle - hot reload (best-effort)
  @spec load_new_profile(String.t()) :: {:ok, String.t()} | {:error, term()}
  @spec reload_profile(String.t()) :: :ok | {:error, term()}
  @spec add_chain(String.t(), String.t(), ChainConfig.t()) :: {:ok, String.t()} | {:error, term()}
  @spec remove_chain(String.t(), String.t()) :: :ok | {:error, term()}
  @spec add_provider(String.t(), String.t(), provider_config()) :: {:ok, String.t()} | {:error, term()}
  @spec remove_provider(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  @spec update_provider(String.t(), String.t(), provider_config()) :: {:ok, String.t()} | {:error, term()}
end
```

---

## 15. File Inventory

| File                                                        | Action | Description                                                                       |
| ----------------------------------------------------------- | ------ | --------------------------------------------------------------------------------- |
| `lib/lasso/config/backend.ex`                               | CREATE | Backend behaviour                                                                 |
| `lib/lasso/config/backend/file.ex`                          | CREATE | File-based backend                                                                |
| `lib/lasso/config/profile_validator.ex`                     | CREATE | YAML + SSRF validation                                                            |
| `lib/lasso/config/config_store.ex`                          | MODIFY | Profile-scoped storage, chain indices, lifecycle, two-phase commit                |
| `lib/lasso/global_chain_supervisor.ex`                      | CREATE | DynamicSupervisor for global per-chain processes                                  |
| `lib/lasso/profile_chain_supervisor.ex`                     | CREATE | DynamicSupervisor for (profile, chain) trees                                      |
| `lib/lasso_web/plugs/profile_resolver.ex`                   | CREATE | Extract profile from path                                                         |
| `lib/lasso_web/plugs/rate_limiter.ex`                       | CREATE | Hammer-based rate limiting with tuple keys                                        |
| `lib/lasso_web/router.ex`                                   | MODIFY | Profile routes                                                                    |
| `lib/lasso_web/endpoint.ex`                                 | MODIFY | WebSocket routes                                                                  |
| `lib/lasso_web/sockets/rpc_socket.ex`                       | MODIFY | Profile resolution, limits                                                        |
| `lib/lasso_web/live/dashboard.ex`                           | MODIFY | Multi-profile subscription                                                        |
| `lib/lasso/application.ex`                                  | MODIFY | Start GlobalChainSupervisor, ProfileChainSupervisor before ConfigStore            |
| `lib/lasso/core/request/request_options.ex`                 | MODIFY | Add profile, profile_meta fields                                                  |
| `lib/lasso/core/selection/selection.ex`                     | MODIFY | Profile as first parameter                                                        |
| `lib/lasso/core/support/circuit_breaker.ex`                 | MODIFY | Canonical key format `{:circuit_breaker, profile, chain, provider_id, transport}` |
| `lib/lasso/core/providers/provider_pool.ex`                 | MODIFY | Tuple via_name, profile in state, subscribe to block_sync, add `update_config/3`  |
| `lib/lasso/core/transport/registry.ex`                      | MODIFY | Profile-scoped topics                                                             |
| `lib/lasso/core/transport/websocket/connection.ex`          | MODIFY | Profile-scoped topics                                                             |
| `lib/lasso/chain_supervisor.ex`                             | MODIFY | Receive {profile, chain} tuple, remove BlockSync/HealthProbe children             |
| `lib/lasso/core/streaming/upstream_subscription_manager.ex` | MODIFY | Profile param, scoped topics                                                      |
| `lib/lasso/core/streaming/upstream_subscription_pool.ex`    | MODIFY | Profile param, scoped topics                                                      |
| `lib/lasso/core/streaming/client_subscription_registry.ex`  | MODIFY | Profile param                                                                     |
| `lib/lasso/core/streaming/stream_coordinator.ex`            | MODIFY | Profile-bounded failover                                                          |
| `lib/lasso/core/streaming/stream_supervisor.ex`             | MODIFY | Profile param                                                                     |
| `lib/lasso/core/block_sync/supervisor.ex`                   | MODIFY | Move to GlobalChainSupervisor, use global_provider_key                            |
| `lib/lasso/core/block_sync/worker.ex`                       | MODIFY | Accept global_provider_key, publish to global topic                               |
| `lib/lasso/core/block_sync/registry.ex`                     | MODIFY | Use global_provider_key in ETS keys                                               |
| `lib/lasso/core/health_probe/supervisor.ex`                 | MODIFY | Move to GlobalChainSupervisor, use global_provider_key                            |
| `lib/lasso/core/health_probe/worker.ex`                     | MODIFY | Accept global_provider_key, publish to global topic                               |

**Total: ~8 new files, ~24 modified files**

---

## 16. Configuration Reference

```elixir
# config/config.exs
config :lasso,
  config_backend: Lasso.Config.Backend.File,
  config_backend_config: [profiles_dir: "config/profiles"],
  max_batch_size: 100,
  rate_limit_enabled: true
```

**Directory Structure:**

```
config/profiles/
├── default.yml
├── production.yml
├── staging.yml
└── byok-acme.yml
```

---

## 17. Migration Path

### 17.1 Single-Profile to Multi-Profile

For existing deployments:

1. **Create default profile:** Move existing `chains.yml` to `config/profiles/default.yml`
2. **Add frontmatter:** Add profile metadata to YAML
3. **Deploy:** Application starts with single "default" profile
4. **Add profiles:** Create additional profile YAML files, restart or hot-reload

### 17.2 Breaking Changes

This is **not a hot upgrade** - requires restart:

- Registry keys change from `{:type, chain}` to `{:type, profile, chain}`
- ETS table structure changes
- PubSub topics change
- BlockSync/HealthProbe workers use composite keys

**Deployment strategy:** Rolling restart with brief downtime, or blue-green deployment.

### 17.3 Backward Compatibility (Optional)

For gradual migration, support legacy URLs temporarily:

```elixir
# Router
get "/rpc/:chain", RPCController, :rpc_legacy

# Controller
def rpc_legacy(conn, %{"chain" => chain}) do
  # Redirect to default profile
  redirect(conn, to: "/rpc/default/#{chain}")
end
```

Remove after migration period.

---

## Appendix A: Key Decisions Summary

| Decision                 | Choice                                                       | Rationale                                                          |
| ------------------------ | ------------------------------------------------------------ | ------------------------------------------------------------------ |
| Provider ID format       | Original in profile-scoped, tuple in global                  | Avoids collision in global components                              |
| Isolation strategy       | Full profile isolation                                       | Simplicity over shared-failure optimization; BYOK expectation      |
| Key format               | `{:type, profile, chain, ...}`                               | Type first for component queries, profile second for consistency   |
| Circuit breaker key      | `{:circuit_breaker, profile, chain, provider_id, transport}` | Full 5-tuple with canonical ordering                               |
| Global component keys    | `{:block_sync_worker, chain, {profile, provider_id}}`        | Tuple key - no string parsing needed                               |
| Infrastructure detection | None                                                         | No heuristics; treat all providers uniformly                       |
| Conditional sharing      | None                                                         | No shared circuit breakers; simplicity over efficiency             |
| BlockSync/HealthProbe    | Global per-chain with tuple keys                             | Objective blockchain state; avoid redundant connections            |
| BlockCache               | Global per-chain                                             | Immutable block data                                               |
| ETS tables               | Three tables (config + state + refcount)                     | Separation of concerns; different access patterns                  |
| PubSub topics            | Dual-broadcast (global + profile-scoped)                     | Eliminates filtering in hot path                                   |
| Finch pools              | Shared by URL host                                           | Safe (headers per-request); reduces connection overhead            |
| Rate limiter keys        | Tuple-based                                                  | Prevents injection attacks                                         |
| Profile load             | Two-phase commit                                             | Prevents partial load states                                       |
| Profile deletion         | Deferred                                                     | Out of scope for initial release                                   |
| Chain naming             | Canonical allowlist                                          | Simplicity; prevents "eth" vs "ethereum" conflicts                 |
| Hot reload               | Best-effort (immediate, no drain)                            | BYOK users control their traffic; circuit breaker reset acceptable |
| File backend errors      | Fail-fast                                                    | Catch errors at deploy time                                        |
| Concurrent loads         | Supervisor idempotency                                       | DynamicSupervisor handles race conditions; no mutex needed         |
| Startup sequence         | Two-phase (ETS then supervisors then load)                   | Avoids circular dependency                                         |
| Chain cleanup            | Inline refcounting                                           | Cleans up BYOK long-tail chains when last profile removed          |

---

## Appendix B: Known Issues (Deferred)

### B.1 Circuit Breaker 429 Handling

**Status:** Documented for future improvement.

**Issue:** Current implementation opens circuit breakers on HTTP 429 (rate limit) responses. Rate limits are backpressure, not failures.

**Future work:** Separate rate limit tracking from circuit breaker state.

### B.2 Dashboard Subscription Scale

**Status:** Acceptable for initial deployment.

**Issue:** At 100+ profiles, dashboard has 3000+ PubSub subscriptions per LiveView.

**Future work:** Implement aggregator process pattern if scale requires.

### B.3 Profile Deletion

**Status:** Deferred to post-MVP.

**Issue:** No graceful profile deletion with drain phase.

**Future work:** Implement drain phase, synchronous shutdown, and cleanup.

### B.4 Graceful Hot Reload

**Status:** Best-effort reload implemented; graceful features deferred.

**What's implemented:**

- Immediate profile/chain/provider add/remove/update
- Circuit breaker resets on provider changes

**What's deferred:**

- Request draining before removing resources
- Circuit breaker state preservation across provider URL changes
- Zero-downtime provider updates

**Rationale:** Best-effort is acceptable for BYOK users who control their own traffic. Graceful reload adds significant complexity for marginal benefit.

---

## Appendix C: Implementation Checklist

Phase 1 - Foundation:

- [ ] Create ConfigStore with two-phase commit and inline refcounting
- [ ] Add chain name validation (canonical allowlist)
- [ ] Create GlobalChainSupervisor with start/stop_chain_processes
- [ ] Create ProfileChainSupervisor
- [ ] Create Backend behaviour and File implementation
- [ ] Add third ETS table `:lasso_chain_refcount` in Application.start

Phase 2 - Global Components:

- [ ] Modify BlockSync to use tuple provider keys `{profile, provider_id}`
- [ ] Modify HealthProbe to use tuple provider keys
- [ ] Wire GlobalChainSupervisor startup with refcount-based cleanup

Phase 3 - Profile-Scoped Components:

- [ ] Modify ProviderPool for profile parameter and profile-scoped PubSub
- [ ] Modify CircuitBreaker for canonical keys
- [ ] Modify TransportRegistry for profile
- [ ] Modify ChainSupervisor for profile

Phase 4 - Streaming:

- [ ] Modify UpstreamSubscriptionManager
- [ ] Modify StreamCoordinator
- [ ] Modify ClientSubscriptionRegistry

Phase 5 - Request Pipeline:

- [ ] Create ProfileResolver plug
- [ ] Create RateLimiter plug with tuple keys
- [ ] Update Router
- [ ] Update Selection API

Phase 6 - Hot Reload:

- [ ] Implement ConfigStore.load_new_profile
- [ ] Implement ConfigStore.add_chain / remove_chain with refcounting
- [ ] Implement ConfigStore.add_provider / remove_provider / update_provider
- [ ] Implement ConfigStore.reload_profile

Phase 7 - Integration:

- [ ] Update Dashboard for multi-profile
- [ ] Integration tests for hot reload
- [ ] Migration testing

---

## Appendix D: Registry Key Migration Table

**Clean break required** - no backward compatibility wrappers. All call sites must be updated.

### Profile-Scoped Components

| Component                | Old Key                                      | New Key                                                      |
| ------------------------ | -------------------------------------------- | ------------------------------------------------------------ |
| ChainSupervisor          | `{:chain_supervisor, chain}`                 | `{:chain_supervisor, profile, chain}`                        |
| ProviderPool             | `{:provider_pool, chain}`                    | `{:provider_pool, profile, chain}`                           |
| TransportRegistry        | `{:transport_registry, chain}`               | `{:transport_registry, profile, chain}`                      |
| CircuitBreaker           | `{chain, provider_id, transport}`            | `{:circuit_breaker, profile, chain, provider_id, transport}` |
| WSConnection             | `{:ws_conn, chain, provider_id}`             | `{:ws_conn, profile, chain, provider_id}`                    |
| ProviderSupervisor       | `{:provider_supervisor, chain, provider_id}` | `{:provider_supervisor, profile, chain, provider_id}`        |
| ProviderSupervisors (DS) | `:"#{chain}_provider_supervisors"`           | `{:provider_supervisors, profile, chain}`                    |
| UpstreamSubManager       | `{:upstream_sub_manager, chain}`             | `{:upstream_sub_manager, profile, chain}`                    |
| UpstreamSubPool          | `{:upstream_sub_pool, chain}`                | `{:upstream_sub_pool, profile, chain}`                       |
| ClientSubRegistry        | `{:client_registry, chain}`                  | `{:client_registry, profile, chain}`                         |
| StreamSupervisor         | `{:stream_supervisor, chain}`                | `{:stream_supervisor, profile, chain}`                       |
| StreamCoordinator        | `{:stream_coordinator, chain, key}`          | `{:stream_coordinator, profile, chain, key}`                 |

### Global Components (unchanged structure, tuple provider key)

| Component              | Old Key                                      | New Key                                                 |
| ---------------------- | -------------------------------------------- | ------------------------------------------------------- |
| BlockSync.Supervisor   | `{:block_sync_supervisor, chain}`            | `{:block_sync_supervisor, chain}` (unchanged)           |
| BlockSync.Worker       | `{:block_sync_worker, chain, provider_id}`   | `{:block_sync_worker, chain, {profile, provider_id}}`   |
| HealthProbe.Supervisor | `{:health_probe_supervisor, chain}`          | `{:health_probe_supervisor, chain}` (unchanged)         |
| HealthProbe.Worker     | `{:health_probe_worker, chain, provider_id}` | `{:health_probe_worker, chain, {profile, provider_id}}` |

### ETS Keys

| Table    | Old Key                                  | New Key                                          |
| -------- | ---------------------------------------- | ------------------------------------------------ |
| Config   | `{:chain, chain_name}`                   | `{:profile, slug, :chains}`                      |
| Config   | N/A                                      | `{:profile, slug, :meta}`                        |
| Config   | N/A                                      | `{:profile_list}`                                |
| Config   | N/A                                      | `{:chain_profiles, chain}`                       |
| Config   | N/A                                      | `{:all_chains}`                                  |
| Config   | N/A                                      | `{:global_providers, chain}`                     |
| State    | `{:provider_height, chain, provider_id}` | `{:block_height, chain, {profile, provider_id}}` |
| Refcount | N/A                                      | `{chain_name, count}`                            |

### PubSub Topics

| Old Topic                 | New Topic(s)                                                     |
| ------------------------- | ---------------------------------------------------------------- |
| `"block_sync:#{chain}"`   | `"block_sync:#{chain}"` + `"block_sync:#{profile}:#{chain}"`     |
| `"health_probe:#{chain}"` | `"health_probe:#{chain}"` + `"health_probe:#{profile}:#{chain}"` |
| `"circuit:events"`        | `"circuit:events:#{profile}:#{chain}"`                           |
| `"ws:conn:#{chain}"`      | `"ws:conn:#{profile}:#{chain}"`                                  |
| `"provider_pool:events"`  | `"provider_pool:events:#{profile}:#{chain}"`                     |

### Function Signature Changes

```elixir
# Old
ChainSupervisor.get_chain_status(chain)
ProviderPool.get_status(chain)
Selection.select_channels(chain, method, opts)
CircuitBreaker.record_success({chain, provider, transport})

# New
ChainSupervisor.get_chain_status(profile, chain)
ProviderPool.get_status(profile, chain)
Selection.select_channels(profile, chain, method, opts)
CircuitBreaker.record_success({:circuit_breaker, profile, chain, provider, transport})
```

### Migration Steps

1. Update all Registry key definitions (via_name helpers)
2. Update all GenServer.call/cast call sites
3. Update all ETS key patterns
4. Update all PubSub subscribe/broadcast calls
5. Update all function signatures
6. Run full test suite
7. Deploy with fresh start (no rolling update)

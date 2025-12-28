# Routing Profiles System Design v4

**Status**: Draft
**Last Updated**: December 2024
**Supersedes**: ROUTING_PROFILES_DESIGN_V3.md

---

## Design Philosophy

v4 simplifies the design with these principles:

1. **Clean OSS/SaaS Split** - Dashboard and profiles are OSS core; billing/auth are SaaS extensions
2. **Explicit Profile URLs** - Profile always required in path, no defaults or fallbacks
3. **ETS-Only Hot Path** - All request-path checks use ETS (<1ms), no DB reads
4. **Billing Agnostic** - No payment provider lock-in, flexible metering
5. **Simple Metering** - Bytes-based or per-request CU, not method-specific
6. **Minimal Complexity** - Global limits where per-profile granularity isn't needed

---

## 1. OSS/SaaS Architecture Split

### 1.1 What's in OSS (Self-Hosted)

| Component            | Description                                              |
| -------------------- | -------------------------------------------------------- |
| **Dashboard**        | LiveView UI for monitoring and config management         |
| **Profiles**         | Multiple chain configs, stored as YAML files             |
| **Config Backend**   | File-based profile loading (directory of YAML files)     |
| **Request Pipeline** | Profile-aware routing, provider failover                 |
| **Telemetry**        | Comprehensive metrics for monitoring (Prometheus export) |
| **WebSocket**        | Full eth_subscribe support with per-profile config       |
| **Rate Limiting**    | Configurable per-profile limits (Hammer + ETS)           |

### 1.2 What SaaS Adds

| Component             | Description                                      |
| --------------------- | ------------------------------------------------ |
| **DB Config Backend** | PostgreSQL storage for profiles (replaces files) |
| **Accounts**          | User registration, authentication, sessions      |
| **API Keys**          | Account-scoped access tokens                     |
| **Subscriptions**     | Links accounts to profiles with usage limits     |
| **Metering**          | CU tracking (bytes-based or per-request)         |

### 1.3 Extension Architecture

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

### 1.4 Dependency Direction

```
lasso (OSS)                          lasso_cloud (SaaS)
├── lib/lasso/config/                ├── lib/lasso_cloud/accounts/
│   ├── config_store.ex              │   ├── account.ex
│   ├── backend.ex (behaviour)       │   ├── auth.ex
│   └── backend/file.ex              │   └── session.ex
├── lib/lasso/core/                  ├── lib/lasso_cloud/billing/
│   ├── request_pipeline.ex          │   ├── subscription.ex
│   └── request_context.ex           │   └── metering_handler.ex
├── lib/lasso_web/                   ├── lib/lasso_cloud/config/
│   ├── live/dashboard/              │   └── backend/database.ex
│   └── controllers/                 │
└── No DB, no auth, no billing       └── Depends on :lasso as dep
```

**Critical Rule**: SaaS depends on OSS, never the reverse. OSS must be fully functional standalone.

---

## 2. URL Structure

### 2.1 URL Pattern

Profile is always required in the URL path. No defaults, no fallbacks.

```
# OSS (no auth)
/rpc/:profile/:chain                 → explicit profile
/rpc/:profile/:strategy/:chain       → with routing strategy

# SaaS (API key required)
/rpc/:profile/:chain?key=lasso_abc123
/rpc/:profile/:strategy/:chain?key=lasso_abc123

# WebSocket (same pattern)
/ws/rpc/:profile/:chain
/ws/rpc/:profile/:chain?key=lasso_abc123
```

**No Legacy Routes**: Clients must always specify the profile. This keeps routing simple and explicit.

---

## 3. Data Model

### 3.1 Entity Relationships

```
┌─────────────────────────────────────────────────────────────────────┐
│                            Account                                   │
│  - Identity (email, auth)                                            │
│  - Has many API keys (account-scoped)                                │
│  - Has many subscriptions                                            │
└─────────────────────────────────────────────────────────────────────┘
        │                                    │
        │ has_many                           │ has_many
        ▼                                    ▼
┌─────────────────────────────┐   ┌─────────────────────────────────────┐
│         API Key             │   │            Subscription              │
│  - Account-scoped access    │   │  - Links account to profile          │
│  - Works for all subscribed │   │  - CU limits (what they paid for)    │
│    profiles                 │   │  - Status, usage tracking            │
└─────────────────────────────┘   └─────────────────────────────────────┘
                                            │
                                            │ belongs_to
                                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                            Profile                                   │
│  - slug: unique identifier                                           │
│  - name: display name                                                │
│  - config: YAML text (chains, providers)                             │
│  - default_rps_limit, default_burst_limit: rate limit defaults       │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.2 Key Design Decisions

**Profiles are just configuration**:
- No `ownership` or `tier` fields on profile
- Profile doesn't know about billing - it's just chains/providers config
- Rate limit defaults live on profile (used by OSS, can be overridden by subscription)

**Subscriptions define access and limits**:
- Links account to profile with specific limits
- CU allocation based on what they paid for
- No subscription = no access (for SaaS gated profiles)
- System profiles (like a public free tier) can be accessed without subscription via config flag

**No "free tier" concept in subscriptions**:
- All subscriptions represent paid access with CU limits
- Free/anonymous access is a separate concern (rate limiting only, no metering)

### 3.3 Database Schema

```sql
-- Accounts (identity)
CREATE TABLE accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Profiles (configuration only)
CREATE TABLE profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  slug VARCHAR(50) UNIQUE NOT NULL,
  name VARCHAR(100) NOT NULL,

  -- Config stored as YAML text (same format as chains.yml)
  config TEXT NOT NULL,

  -- Rate limiting defaults (OSS uses these, SaaS can override via subscription)
  default_rps_limit INTEGER NOT NULL DEFAULT 100,
  default_burst_limit INTEGER NOT NULL DEFAULT 500,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Subscriptions (billing entity, links account to profile)
CREATE TABLE subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  profile_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,

  status VARCHAR(20) NOT NULL DEFAULT 'active',

  -- CU allocation (what they paid for)
  cu_limit BIGINT NOT NULL,              -- monthly limit (NULL not allowed - all subs have limits)
  cu_used_this_period BIGINT NOT NULL DEFAULT 0,

  -- Optional rate limit overrides (NULL = use profile defaults)
  rps_limit_override INTEGER,
  burst_limit_override INTEGER,

  -- Billing period
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,

  -- External billing reference (Stripe, Paddle, custom, etc.)
  external_subscription_id VARCHAR(100),

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- One subscription per account per profile
  CONSTRAINT unique_account_profile UNIQUE (account_id, profile_id),
  CONSTRAINT valid_status CHECK (status IN ('active', 'past_due', 'cancelled', 'trialing'))
);

CREATE INDEX idx_subscriptions_account ON subscriptions(account_id);
CREATE INDEX idx_subscriptions_status ON subscriptions(status) WHERE status = 'active';

-- API Keys (account-scoped, not profile-scoped)
CREATE TABLE api_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,

  -- SHA256 hash for fast ETS lookup
  key_hash VARCHAR(64) NOT NULL UNIQUE,
  key_prefix VARCHAR(12) NOT NULL,

  name VARCHAR(100),

  enabled BOOLEAN NOT NULL DEFAULT true,
  expires_at TIMESTAMPTZ,
  last_used_at TIMESTAMPTZ,

  -- Deprecation for graceful rotation
  deprecated_at TIMESTAMPTZ,
  grace_period_ends TIMESTAMPTZ,

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_api_keys_hash ON api_keys(key_hash);
CREATE INDEX idx_api_keys_account ON api_keys(account_id);

-- Usage records (async metering, partitioned by month)
CREATE TABLE usage_records (
  id BIGSERIAL,
  subscription_id UUID NOT NULL,

  -- Simple metering: bytes or request count
  bytes_in BIGINT NOT NULL DEFAULT 0,
  bytes_out BIGINT NOT NULL DEFAULT 0,
  request_count INTEGER NOT NULL DEFAULT 1,

  -- Optional metadata
  chain VARCHAR(50),

  recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  PRIMARY KEY (id, recorded_at)
) PARTITION BY RANGE (recorded_at);
```

### 3.4 Rate Limit Tiers (Reference)

Rate limits are configured per-profile. Example configurations:

| Profile Type | RPS Limit | Burst Limit | Use Case            |
| ------------ | --------- | ----------- | ------------------- |
| Public/Free  | 10        | 20          | Anonymous access    |
| Standard     | 100       | 200         | Paid individual     |
| Professional | 500       | 1000        | Paid team           |
| BYOK         | 1000      | 2000        | Self-hosted nodes   |

These are profile defaults. SaaS subscriptions can override with `rps_limit_override`.

---

## 4. API Key Design

### 4.1 Account-Scoped Keys

Keys belong to accounts, not profiles. One key accesses all profiles the account is subscribed to.

### 4.2 Key Format

```
lasso_abc123def456xyz789qrs  (32 chars total)
└────┘└──────────────────────┘
prefix    random (26 chars, base62)
```

### 4.3 Key Validation (< 0.1ms via ETS)

```elixir
defmodule Lasso.Auth.KeyValidator do
  @doc "Validate API key - O(1) ETS lookup"
  def validate(provided_key) do
    lookup_hash = :crypto.hash(:sha256, provided_key) |> Base.encode16(case: :lower)

    case :ets.lookup(:api_keys_cache, lookup_hash) do
      [{^lookup_hash, key_meta}] ->
        cond do
          not key_meta.enabled -> {:error, :key_disabled}
          expired?(key_meta) -> {:error, :key_expired}
          key_meta.deprecated_at -> {:ok, key_meta, :deprecated}
          true -> {:ok, key_meta}
        end
      [] ->
        {:error, :invalid_key}
    end
  end

  defp expired?(%{expires_at: nil}), do: false
  defp expired?(%{expires_at: exp}), do: DateTime.compare(DateTime.utc_now(), exp) == :gt
end
```

### 4.4 Key Extraction

Support multiple auth methods:

```elixir
defmodule Lasso.Auth.KeyExtractor do
  @doc "Extract API key from request (header preferred, query param fallback)"
  def extract(conn) do
    cond do
      key = get_header(conn, "x-lasso-api-key") -> {:ok, key, :header}
      key = get_bearer_token(conn) -> {:ok, key, :bearer}
      key = conn.query_params["key"] -> {:ok, key, :query_param}
      true -> {:error, :no_key}
    end
  end
end
```

---

## 5. Request Resolution Flow

### 5.1 Hot Path Requirements

**All hot path operations must use ETS only (<1ms)**:
- Profile lookup: ETS
- API key validation: ETS
- Rate limit check: Hammer (ETS backend)
- Subscription lookup: ETS cache

**No DB reads on hot path**. CU limit enforcement is eventual (checked periodically, not per-request).

### 5.2 Resolution Logic

```elixir
defmodule Lasso.Auth.RequestResolver do
  @doc """
  Resolve profile from request. All lookups are ETS-based.

  Returns: {:ok, profile} | {:ok, profile, subscription, key_meta} | {:error, reason}
  """
  def resolve(conn) do
    profile_slug = conn.path_params["profile"]

    with {:ok, profile} <- get_profile_from_ets(profile_slug) do
      case Lasso.Auth.KeyExtractor.extract(conn) do
        {:error, :no_key} ->
          # OSS mode or anonymous access
          {:ok, profile, nil, nil}

        {:ok, api_key, _source} ->
          with {:ok, key_meta} <- Lasso.Auth.KeyValidator.validate(api_key),
               {:ok, subscription} <- get_subscription_from_ets(key_meta.account_id, profile.id) do
            {:ok, profile, subscription, key_meta}
          end
      end
    end
  end

  defp get_profile_from_ets(slug) do
    case :ets.lookup(:lasso_config_store, {:profile, slug, :meta}) do
      [{{:profile, ^slug, :meta}, profile}] -> {:ok, profile}
      [] -> {:error, :profile_not_found}
    end
  end

  defp get_subscription_from_ets(account_id, profile_id) do
    case :ets.lookup(:subscriptions_cache, {account_id, profile_id}) do
      [{{^account_id, ^profile_id}, sub}] -> {:ok, sub}
      [] -> {:error, :not_subscribed}
    end
  end
end
```

### 5.3 Router Configuration

```elixir
# lib/lasso_web/router.ex

pipeline :rpc do
  plug :accepts, ["json"]
  plug LassoWeb.Plugs.ProfileResolver
  plug LassoWeb.Plugs.RateLimiter
  # Note: NO CU limit check plug - CU enforcement is async
end

scope "/rpc", LassoWeb do
  pipe_through :rpc

  # All routes require explicit :profile parameter
  post "/:profile/:chain", RPCController, :rpc
  post "/:profile/fastest/:chain", RPCController, :rpc_fastest
  post "/:profile/round-robin/:chain", RPCController, :rpc_round_robin
  post "/:profile/latency-weighted/:chain", RPCController, :rpc_latency_weighted
  post "/:profile/provider/:provider_id/:chain", RPCController, :rpc_provider_override
end
```

---

## 6. Config Backend Behaviour

### 6.1 Behaviour Definition

```elixir
defmodule Lasso.Config.Backend do
  @moduledoc """
  Behaviour for loading profile configurations.

  OSS: Backend.File (YAML files in directory)
  SaaS: Backend.Database (PostgreSQL)
  """

  @type profile_meta :: %{
    id: String.t(),
    name: String.t(),
    slug: String.t(),
    default_rps_limit: pos_integer(),
    default_burst_limit: pos_integer()
  }

  @type profile_spec :: %{
    meta: profile_meta(),
    config_yaml: String.t()
  }

  @callback init(config :: keyword()) :: {:ok, state :: term()} | {:error, term()}
  @callback load_all(state :: term()) :: {:ok, [profile_spec()]} | {:error, term()}
  @callback load(state :: term(), slug :: String.t()) :: {:ok, profile_spec()} | {:error, :not_found}
  @callback save(state :: term(), slug :: String.t(), yaml :: String.t()) :: :ok | {:error, term()}

  @optional_callbacks [save: 3]
end
```

### 6.2 File Backend (OSS)

```elixir
defmodule Lasso.Config.Backend.File do
  @behaviour Lasso.Config.Backend

  @impl true
  def init(config) do
    profiles_dir = Keyword.get(config, :profiles_dir, "config/profiles")
    {:ok, %{profiles_dir: profiles_dir}}
  end

  @impl true
  def load_all(%{profiles_dir: dir}) do
    profiles = dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".yml"))
    |> Enum.map(&load_file(dir, &1))
    |> Enum.reject(&is_nil/1)

    {:ok, profiles}
  end

  @impl true
  def load(%{profiles_dir: dir}, slug) do
    path = Path.join(dir, "#{slug}.yml")

    if File.exists?(path) do
      {:ok, load_file(dir, "#{slug}.yml")}
    else
      {:error, :not_found}
    end
  end

  @impl true
  def save(%{profiles_dir: dir}, slug, yaml) do
    path = Path.join(dir, "#{slug}.yml")
    File.write(path, yaml)
  end

  defp load_file(dir, filename) do
    slug = String.replace_suffix(filename, ".yml", "")
    path = Path.join(dir, filename)
    yaml = File.read!(path)

    {meta, config_yaml} = parse_frontmatter(yaml)

    %{
      meta: Map.merge(default_meta(slug), meta),
      config_yaml: config_yaml
    }
  end

  defp default_meta(slug) do
    %{
      id: slug,
      name: slug,
      slug: slug,
      default_rps_limit: 100,
      default_burst_limit: 500
    }
  end

  defp parse_frontmatter(yaml) do
    case String.split(yaml, ~r/^---\n/m, parts: 3) do
      ["", frontmatter, rest] ->
        meta = YamlElixir.read_from_string!(frontmatter)
        {atomize_keys(meta), rest}
      _ ->
        {%{}, yaml}
    end
  end
end
```

---

## 7. Rate Limiting

### 7.1 Dual-Window Rate Limiting (ETS-based)

```elixir
defmodule LassoWeb.Plugs.RateLimiter do
  import Plug.Conn
  alias Lasso.JSONRPC.Error, as: JError

  def init(opts), do: opts

  def call(conn, _opts) do
    profile = conn.assigns[:profile]
    subscription = conn.assigns[:subscription]

    # Use subscription overrides if present, otherwise profile defaults
    {rps, burst} = get_limits(profile, subscription)
    bucket = rate_limit_bucket(conn)

    with {:allow, _} <- Hammer.check_rate("#{bucket}:burst", 1_000, burst),
         {:allow, _} <- Hammer.check_rate("#{bucket}:sustained", 60_000, rps * 60) do
      conn
    else
      {:deny, retry_after} ->
        error = JError.new(-32005, "Rate limit exceeded")

        conn
        |> put_resp_header("retry-after", to_string(div(retry_after, 1000)))
        |> put_status(429)
        |> json(JError.to_response(error, nil))
        |> halt()
    end
  end

  defp get_limits(profile, nil) do
    {profile.default_rps_limit, profile.default_burst_limit}
  end

  defp get_limits(profile, subscription) do
    rps = subscription.rps_limit_override || profile.default_rps_limit
    burst = subscription.burst_limit_override || profile.default_burst_limit
    {rps, burst}
  end

  defp rate_limit_bucket(conn) do
    profile_slug = conn.assigns.profile.slug
    client_ip = get_client_ip(conn)

    case conn.assigns[:key_meta] do
      nil -> "profile:#{profile_slug}:ip:#{client_ip}"
      key_meta -> "account:#{key_meta.account_id}:profile:#{profile_slug}"
    end
  end
end
```

---

## 8. Batch Request Handling

### 8.1 Global Batch Limits

Batch size is a global limit, not per-profile. Simple and predictable.

```elixir
defmodule LassoWeb.RPCController do
  # Global max batch size - configurable via app config
  @max_batch_size Application.compile_env(:lasso, :max_batch_size, 100)

  def handle(conn, _params) do
    body = conn.assigns[:raw_body]

    case Jason.decode(body) do
      {:ok, requests} when is_list(requests) ->
        handle_batch(conn, requests)
      {:ok, request} when is_map(request) ->
        handle_single(conn, request)
      {:error, _} ->
        error_response(conn, -32700, "Parse error")
    end
  end

  defp handle_batch(conn, requests) do
    cond do
      length(requests) == 0 ->
        error_response(conn, -32600, "Empty batch")

      length(requests) > @max_batch_size ->
        error_response(conn, -32005, "Batch too large (max: #{@max_batch_size})")

      true ->
        # Process all requests
        results = Enum.map(requests, &process_request(&1, conn))
        json(conn, results)
    end
  end
end
```

### 8.2 Batch Metering

Batches are metered by total bytes, not per-request CU. Simple and efficient.

```elixir
defp emit_metering(conn, bytes_in, bytes_out) do
  if subscription = conn.assigns[:subscription] do
    :telemetry.execute(
      [:lasso, :rpc, :request, :metered],
      %{bytes_in: bytes_in, bytes_out: bytes_out, request_count: 1},
      %{subscription_id: subscription.id, profile_slug: conn.assigns.profile.slug}
    )
  end
end
```

---

## 9. CU Metering

### 9.1 Bytes-Based Metering with Method Multipliers

CU calculation uses bytes as the base metric, with multipliers for expensive methods. This balances simplicity with fairness:

- **Base calculation**: `(bytes_in + bytes_out) / 1024 = base_cu`
- **Method multiplier**: Applied based on computational cost
- **Minimum**: 1 CU per request

```elixir
defmodule Lasso.Metering.CUCalculator do
  @moduledoc """
  CU calculation based on bytes with method-aware multipliers.

  Multipliers reflect computational cost that isn't captured by response size:
  - eth_call: Executes EVM code, can be expensive
  - eth_getLogs: Archive queries, can scan many blocks
  - debug_*/trace_*: Heavy computational methods

  Uses Lasso.RPC.MethodRegistry for method categorization.
  """

  @bytes_per_cu 1024  # 1 KB = 1 CU

  # Method category multipliers
  @category_multipliers %{
    core: 1.0,           # eth_blockNumber, eth_chainId, etc.
    state: 1.5,          # eth_call, eth_estimateGas
    network: 1.0,        # net_version, web3_clientVersion
    filters: 2.0,        # eth_getLogs - archive queries
    mempool: 1.0,        # eth_sendRawTransaction
    debug: 5.0,          # debug_traceTransaction, etc.
    trace: 5.0,          # trace_block, trace_transaction, etc.
    subscriptions: 1.0,  # eth_subscribe (metered per message)
    unknown: 1.0         # Conservative default
  }

  @doc """
  Calculate CUs for a request based on bytes and method.

  ## Examples

      iex> calculate("eth_blockNumber", 50, 100)
      1  # Minimum 1 CU

      iex> calculate("eth_call", 500, 2048)
      4  # (2548 / 1024) * 1.5 = 3.7, rounded up

      iex> calculate("debug_traceTransaction", 200, 50_000)
      245  # (50200 / 1024) * 5.0 = 245.1
  """
  @spec calculate(String.t(), non_neg_integer(), non_neg_integer()) :: pos_integer()
  def calculate(method, bytes_in, bytes_out) do
    base_cu = div(bytes_in + bytes_out, @bytes_per_cu)
    multiplier = get_multiplier(method)

    max(1, trunc(base_cu * multiplier))
  end

  @doc "Get multiplier for a method"
  def get_multiplier(method) do
    category = Lasso.RPC.MethodRegistry.method_category(method)
    Map.get(@category_multipliers, category, @category_multipliers.unknown)
  end

  @doc """
  Batch CU calculation - sum of individual method CUs.
  Used for metering, not rate limiting (batches count as 1 request for rate limits).
  """
  def calculate_batch(requests, bytes_in, bytes_out) when is_list(requests) do
    # Proportionally allocate bytes across requests based on method weights
    total_weight = requests
    |> Enum.map(&get_multiplier(&1["method"]))
    |> Enum.sum()

    if total_weight == 0 do
      max(1, div(bytes_in + bytes_out, @bytes_per_cu))
    else
      avg_bytes = div(bytes_in + bytes_out, length(requests))

      requests
      |> Enum.map(fn req ->
        calculate(req["method"], div(avg_bytes, 2), div(avg_bytes, 2))
      end)
      |> Enum.sum()
    end
  end
end
```

**Integration with MethodRegistry:**

The CU calculator leverages the existing `Lasso.RPC.MethodRegistry` for method categorization. This keeps method knowledge centralized and makes it easy to adjust costs as we learn from production usage.

### 9.2 Async Metering Handler

CU metering is async - writes to ETS buffer, flushes periodically to DB.

```elixir
defmodule Lasso.Metering.TelemetryHandler do
  use GenServer

  @buffer_table :metering_buffer
  @flush_interval 5_000
  @max_buffer_size 1000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    :ets.new(@buffer_table, [:set, :public, :named_table, write_concurrency: true])

    :telemetry.attach(
      "lasso-metering",
      [:lasso, :rpc, :request, :metered],
      &__MODULE__.handle_metering/4,
      nil
    )

    schedule_flush()
    {:ok, %{}}
  end

  def handle_metering(_event, measurements, metadata, _config) do
    record = %{
      id: System.unique_integer([:positive]),
      subscription_id: metadata.subscription_id,
      bytes_in: measurements.bytes_in,
      bytes_out: measurements.bytes_out,
      request_count: measurements.request_count,
      recorded_at: DateTime.utc_now()
    }

    :ets.insert(@buffer_table, {record.id, record})
    maybe_flush()
  end

  defp maybe_flush do
    if :ets.info(@buffer_table, :size) >= @max_buffer_size do
      GenServer.cast(__MODULE__, :flush)
    end
  end

  def handle_info(:flush, state) do
    do_flush()
    schedule_flush()
    {:noreply, state}
  end

  defp do_flush do
    records = :ets.tab2list(@buffer_table)
    :ets.delete_all_objects(@buffer_table)

    unless Enum.empty?(records) do
      Task.start(fn ->
        Lasso.Metering.UsageWriter.write_batch(Enum.map(records, &elem(&1, 1)))
      end)
    end
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end
end
```

### 9.3 CU Limit Enforcement (Async)

CU limits are checked periodically, not per-request. This keeps the hot path fast.

```elixir
defmodule Lasso.Metering.LimitEnforcer do
  @moduledoc """
  Periodically checks subscription CU usage and updates ETS cache.
  Subscriptions over limit are marked in cache for rate limiting.
  """

  use GenServer

  @check_interval 60_000  # Check every minute

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_check()
    {:ok, %{}}
  end

  def handle_info(:check_limits, state) do
    check_all_subscriptions()
    schedule_check()
    {:noreply, state}
  end

  defp check_all_subscriptions do
    # Query subscriptions over limit
    over_limit = Repo.all(
      from s in Subscription,
      where: s.status == "active" and s.cu_used_this_period >= s.cu_limit
    )

    # Update ETS cache to mark these as over limit
    Enum.each(over_limit, fn sub ->
      :ets.insert(:subscriptions_cache, {{sub.account_id, sub.profile_id},
        Map.put(sub, :over_limit, true)})
    end)
  end

  defp schedule_check do
    Process.send_after(self(), :check_limits, @check_interval)
  end
end
```

### 9.4 Subscription Cache Management (SaaS)

The subscription cache is critical for hot path performance. All subscription lookups must hit ETS, never the database.

```elixir
defmodule Lasso.Billing.SubscriptionCache do
  @moduledoc """
  ETS cache for subscription lookups. Keeps hot path at <1ms.

  Cache invalidation triggers:
  - Subscription created/updated/cancelled
  - Account suspended
  - Billing period reset

  Cache warming:
  - On application startup
  - Background refresh every 60s
  """

  @cache_table :subscriptions_cache
  @refresh_interval 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    :ets.new(@cache_table, [:set, :public, :named_table, read_concurrency: true])

    # Subscribe to invalidation events
    Phoenix.PubSub.subscribe(Lasso.PubSub, "subscriptions:cache")

    # Initial cache warm
    warm_all()

    # Schedule periodic refresh
    schedule_refresh()

    {:ok, %{}}
  end

  @doc "Get subscription from cache - O(1) ETS lookup"
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(account_id, profile_id) do
    case :ets.lookup(@cache_table, {account_id, profile_id}) do
      [{{^account_id, ^profile_id}, sub}] -> {:ok, sub}
      [] -> {:error, :not_found}
    end
  end

  @doc "Invalidate a specific subscription"
  def invalidate(account_id, profile_id) do
    :ets.delete(@cache_table, {account_id, profile_id})

    # Broadcast to cluster for multi-node invalidation
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "subscriptions:cache",
      {:invalidate, account_id, profile_id}
    )
  end

  @doc "Invalidate all subscriptions for an account"
  def invalidate_account(account_id) do
    # Scan and delete all entries for this account
    :ets.match_delete(@cache_table, {{account_id, :_}, :_})

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "subscriptions:cache",
      {:invalidate_account, account_id}
    )
  end

  @doc "Warm cache with a specific subscription"
  def put(subscription) do
    cache_entry = build_cache_entry(subscription)
    :ets.insert(@cache_table, {{subscription.account_id, subscription.profile_id}, cache_entry})
  end

  # Handle PubSub messages for multi-node cache invalidation
  def handle_info({:invalidate, account_id, profile_id}, state) do
    :ets.delete(@cache_table, {account_id, profile_id})
    {:noreply, state}
  end

  def handle_info({:invalidate_account, account_id}, state) do
    :ets.match_delete(@cache_table, {{account_id, :_}, :_})
    {:noreply, state}
  end

  def handle_info(:refresh, state) do
    warm_all()
    schedule_refresh()
    {:noreply, state}
  end

  defp warm_all do
    # Load all active subscriptions from DB
    subscriptions = Repo.all(
      from s in Subscription,
      where: s.status == "active",
      preload: [:profile]
    )

    Enum.each(subscriptions, &put/1)

    :telemetry.execute(
      [:lasso, :subscription, :cache, :warmed],
      %{count: length(subscriptions)},
      %{}
    )
  end

  defp build_cache_entry(subscription) do
    %{
      id: subscription.id,
      account_id: subscription.account_id,
      profile_id: subscription.profile_id,
      cu_limit: subscription.cu_limit,
      cu_used_this_period: subscription.cu_used_this_period,
      rps_limit_override: subscription.rps_limit_override,
      burst_limit_override: subscription.burst_limit_override,
      status: subscription.status,
      over_limit: subscription.cu_used_this_period >= subscription.cu_limit
    }
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end
end
```

**Cache Invalidation Integration:**

```elixir
# In subscription context/service module
defmodule Lasso.Billing.Subscriptions do
  alias Lasso.Billing.SubscriptionCache

  def create(attrs) do
    with {:ok, subscription} <- do_create(attrs) do
      SubscriptionCache.put(subscription)
      {:ok, subscription}
    end
  end

  def update(subscription, attrs) do
    with {:ok, updated} <- do_update(subscription, attrs) do
      SubscriptionCache.invalidate(subscription.account_id, subscription.profile_id)
      SubscriptionCache.put(updated)
      {:ok, updated}
    end
  end

  def cancel(subscription) do
    with {:ok, cancelled} <- do_cancel(subscription) do
      SubscriptionCache.invalidate(subscription.account_id, subscription.profile_id)
      {:ok, cancelled}
    end
  end
end
```

---

## 10. WebSocket Support

### 10.1 Connection Handling

WebSocket connections follow the same profile-required pattern.

```elixir
defmodule LassoWeb.RPCSocket do
  @behaviour Phoenix.Socket.Transport

  # Global subscription limits
  @max_subscriptions 500
  @max_connections_per_profile 200

  def connect(%{params: params} = info) do
    profile_slug = info.path_params["profile"]

    with {:ok, profile} <- get_profile(profile_slug),
         {:ok, auth} <- resolve_auth(params),
         :ok <- check_connection_limit(profile_slug) do
      state = %{
        profile: profile,
        subscription: auth[:subscription],
        key_meta: auth[:key_meta],
        subscriptions: %{}
      }
      {:ok, state}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Note: Actual message handling preserves JSON passthrough
  # No JSON decoding/encoding in hot path for large results
  def handle_in({text, _opts}, state) do
    # Forward raw text to providers, return raw response
    # JSON parsing only for routing decisions (method extraction)
    case extract_method(text) do
      {:ok, "eth_subscribe", _} -> handle_subscribe(text, state)
      {:ok, "eth_unsubscribe", _} -> handle_unsubscribe(text, state)
      {:ok, _method, _} -> forward_to_provider(text, state)
      {:error, _} -> {:reply, :ok, {:text, parse_error_response()}, state}
    end
  end

  # Lightweight method extraction without full JSON parse
  defp extract_method(text) do
    # Use pattern matching or streaming JSON parser for efficiency
    # Implementation detail - avoid full Jason.decode for large payloads
    :implementation_detail
  end
end
```

---

## 11. Security

### 11.1 BYOK URL Validation (SSRF Prevention)

Full SSRF protection with DNS resolution. Validates both the URL format and the resolved IP address to prevent DNS rebinding attacks.

```elixir
defmodule Lasso.Security.URLValidator do
  @moduledoc """
  Validates user-provided RPC URLs to prevent SSRF attacks.

  Security measures:
  - Blocks private/internal IP ranges (RFC1918, link-local, loopback)
  - Resolves hostnames and validates resolved IPs
  - Blocks dangerous ports
  - Supports both IPv4 and IPv6

  Note: DNS resolution happens at validation time. For runtime protection
  against DNS rebinding, consider re-validating periodically or using
  HTTP client IP restrictions.
  """

  @blocked_hosts ~w(localhost localhost.localdomain)

  # Private IPv4 CIDR ranges
  @private_ipv4_ranges [
    {{127, 0, 0, 0}, 8},      # Loopback
    {{10, 0, 0, 0}, 8},       # Private class A
    {{172, 16, 0, 0}, 12},    # Private class B
    {{192, 168, 0, 0}, 16},   # Private class C
    {{169, 254, 0, 0}, 16},   # Link-local (AWS metadata endpoint!)
    {{100, 64, 0, 0}, 10},    # Carrier-grade NAT
    {{0, 0, 0, 0}, 8}         # "This" network
  ]

  # Private IPv6 ranges
  @private_ipv6_ranges [
    {{0, 0, 0, 0, 0, 0, 0, 1}, 128},        # Loopback (::1)
    {{0xfe80, 0, 0, 0, 0, 0, 0, 0}, 10},    # Link-local
    {{0xfc00, 0, 0, 0, 0, 0, 0, 0}, 7}      # Unique local (ULA)
  ]

  @blocked_ports [22, 23, 25, 53, 3306, 5432, 6379, 27017]

  @doc """
  Validate a provider RPC URL with full DNS resolution.

  Returns :ok or {:error, reason}
  """
  def validate_rpc_url(url) do
    with {:ok, uri} <- parse_uri(url),
         :ok <- validate_scheme(uri.scheme),
         :ok <- validate_host_format(uri.host),
         :ok <- validate_port(uri.port),
         {:ok, ip} <- resolve_to_ip(uri.host),
         :ok <- validate_ip_not_private(ip) do
      :ok
    end
  end

  defp parse_uri(url) do
    case URI.new(url) do
      {:ok, uri} when uri.host != nil -> {:ok, uri}
      _ -> {:error, "Invalid URL format"}
    end
  end

  defp validate_scheme(scheme) when scheme in ["http", "https", "ws", "wss"], do: :ok
  defp validate_scheme(_), do: {:error, "URL scheme must be http, https, ws, or wss"}

  defp validate_host_format(host) when host in @blocked_hosts do
    {:error, "localhost URLs not allowed"}
  end
  defp validate_host_format(_host), do: :ok

  defp validate_port(nil), do: :ok
  defp validate_port(port) when port in @blocked_ports do
    {:error, "Port #{port} not allowed"}
  end
  defp validate_port(_), do: :ok

  defp resolve_to_ip(host) do
    # First check if it's already an IP address
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, :einval} ->
        # It's a hostname - resolve it
        # Try IPv4 first, fall back to IPv6
        case :inet.getaddr(String.to_charlist(host), :inet) do
          {:ok, ip} -> {:ok, ip}
          {:error, _} ->
            case :inet.getaddr(String.to_charlist(host), :inet6) do
              {:ok, ip} -> {:ok, ip}
              {:error, reason} -> {:error, "DNS resolution failed: #{reason}"}
            end
        end
    end
  end

  defp validate_ip_not_private(ip) when tuple_size(ip) == 4 do
    if ip_in_any_range?(ip, @private_ipv4_ranges) do
      {:error, "Private/internal IP addresses not allowed"}
    else
      :ok
    end
  end

  defp validate_ip_not_private(ip) when tuple_size(ip) == 8 do
    if ip_in_any_range?(ip, @private_ipv6_ranges) do
      {:error, "Private/internal IP addresses not allowed"}
    else
      :ok
    end
  end

  defp ip_in_any_range?(ip, ranges) do
    Enum.any?(ranges, fn {network, prefix} ->
      ip_in_cidr?(ip, network, prefix)
    end)
  end

  defp ip_in_cidr?(ip, network, prefix_len) do
    ip_int = ip_to_integer(ip)
    network_int = ip_to_integer(network)
    bits = tuple_size(ip) * 8
    mask = ((1 <<< bits) - 1) <<< (bits - prefix_len)

    (ip_int &&& mask) == (network_int &&& mask)
  end

  defp ip_to_integer(ip) when tuple_size(ip) == 4 do
    {a, b, c, d} = ip
    (a <<< 24) ||| (b <<< 16) ||| (c <<< 8) ||| d
  end

  defp ip_to_integer(ip) when tuple_size(ip) == 8 do
    ip
    |> Tuple.to_list()
    |> Enum.reduce(0, fn word, acc -> (acc <<< 16) ||| word end)
  end
end
```

**Integration with Profile Validation:**

```elixir
defmodule Lasso.Config.ProfileValidator do
  alias Lasso.Security.URLValidator

  def validate(yaml) do
    with {:ok, data} <- YamlElixir.read_from_string(yaml),
         :ok <- validate_structure(data),
         :ok <- validate_chains(data["chains"]),
         :ok <- validate_provider_urls(data) do
      :ok
    end
  end

  defp validate_provider_urls(data) do
    providers = data["chains"]
    |> Enum.flat_map(fn {_, chain} -> chain["providers"] || [] end)

    Enum.reduce_while(providers, :ok, fn provider, _ ->
      case URLValidator.validate_rpc_url(provider["url"]) do
        :ok -> {:cont, :ok}
        {:error, reason} ->
          {:halt, {:error, "Provider '#{provider["id"]}' URL invalid: #{reason}"}}
      end
    end)
  end
end
```

### 11.2 Rate Limit on Auth Failures

Prevent brute-force API key guessing:

```elixir
defmodule Lasso.Auth.BruteForceProtection do
  @max_failures_per_minute 10

  def check_and_record_failure(client_ip) do
    bucket = "auth_failures:#{client_ip}"

    case Hammer.check_rate(bucket, 60_000, @max_failures_per_minute) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :too_many_failures}
    end
  end
end
```

---

## 12. Profile-Scoped Metrics & Routing Architecture

Profiles require complete isolation of metrics, circuit breakers, and routing state. This section defines how provider identity changes to support profile-scoped isolation.

### 12.1 Composite Provider Identity

**Key Design Decision**: Provider identity becomes a composite of `profile_slug:provider_id`.

This approach minimizes code changes by treating the composite as a single string that flows through the existing architecture unchanged.

```elixir
# At config load time, provider IDs are prefixed with profile slug
defmodule Lasso.Config.ProfileLoader do
  def load_profile(profile_slug, yaml) do
    config = YamlElixir.read_from_string!(yaml)

    # Transform provider IDs to composite form
    chains = config["chains"]
    |> Enum.map(fn {chain_name, chain_config} ->
      providers = chain_config["providers"]
      |> Enum.map(fn provider ->
        # Composite ID: "profile_slug:original_id"
        %{provider | "id" => "#{profile_slug}:#{provider["id"]}"}
      end)
      {chain_name, %{chain_config | "providers" => providers}}
    end)
    |> Map.new()

    %{config | "chains" => chains}
  end
end
```

**Examples:**
```
Profile: "free"     + Provider: "alchemy"  → "free:alchemy"
Profile: "premium"  + Provider: "alchemy"  → "premium:alchemy"
Profile: "byok-xyz" + Provider: "custom"   → "byok-xyz:custom"
```

### 12.2 How Isolation Works

With composite provider IDs, all existing systems naturally isolate by profile:

**Metrics Storage (ETS):**
```elixir
# Score table key structure (unchanged)
{provider_id, method, :rpc}

# But provider_id is now composite:
{"free:alchemy", "eth_call@http", :rpc}     # Free tier metrics
{"premium:alchemy", "eth_call@http", :rpc}  # Premium tier metrics (separate)
```

**Circuit Breakers (Registry):**
```elixir
# Circuit breaker key (unchanged structure)
"ethereum:provider_id:http"

# But provider_id is composite:
"ethereum:free:alchemy:http"     # Free tier circuit breaker
"ethereum:premium:alchemy:http"  # Premium tier circuit breaker (separate)
```

**Selection Strategies:**
- Strategies query metrics by `provider_id` (which is now composite)
- Each profile's providers have unique composite IDs
- No cross-profile metric pollution

### 12.3 Benefits of This Approach

| Benefit | Explanation |
|---------|-------------|
| **Minimal code changes** | ~50-75 LOC vs ~400 LOC for explicit field approach |
| **Natural isolation** | Same Alchemy endpoint in different profiles = different IDs |
| **BYOK isolation** | BYOK profiles have unique IDs regardless |
| **No API changes** | All existing function signatures unchanged |
| **Dashboard compatible** | Parse composite ID for display: `"free:alchemy"` → `"alchemy (free)"` |

### 12.4 Integration Points

**Config Loading** (primary change point):
```elixir
defmodule Lasso.Config.ConfigStore do
  # When loading a profile, transform provider IDs
  defp load_profile_chains(profile_slug, yaml) do
    chains = parse_yaml(yaml)

    Enum.map(chains, fn {chain_name, chain_config} ->
      providers = Enum.map(chain_config.providers, fn provider ->
        %{provider | id: "#{profile_slug}:#{provider.id}"}
      end)
      {chain_name, %{chain_config | providers: providers}}
    end)
  end
end
```

**Dashboard Display** (parse for UI):
```elixir
defmodule LassoWeb.Helpers.ProviderDisplay do
  @doc "Parse composite ID for display"
  def parse_provider_id(composite_id) do
    case String.split(composite_id, ":", parts: 2) do
      [profile, provider] -> %{profile: profile, provider: provider}
      [provider] -> %{profile: nil, provider: provider}  # Legacy fallback
    end
  end

  def display_name(composite_id) do
    %{provider: provider} = parse_provider_id(composite_id)
    provider
  end
end
```

**Profile Filtering** (for dashboard/API):
```elixir
def filter_providers_by_profile(providers, profile_slug) do
  prefix = "#{profile_slug}:"
  Enum.filter(providers, fn %{id: id} ->
    String.starts_with?(id, prefix)
  end)
end
```

### 12.5 Circuit Breaker Behavior

With composite IDs, circuit breakers are naturally profile-scoped:

| Scenario | Circuit Breaker Key | Isolated? |
|----------|---------------------|-----------|
| Free tier rate limited | `ethereum:free:alchemy:http` | ✅ Yes |
| Premium tier unaffected | `ethereum:premium:alchemy:http` | ✅ Separate |
| BYOK provider down | `ethereum:byok-xyz:custom:http` | ✅ Isolated |

**Important**: This means if Alchemy is truly DOWN (not just rate limited), each profile discovers this independently. This is acceptable because:
1. Different profiles may have different rate limit quotas
2. Circuit breaker recovery is fast (30-60s)
3. Operational simplicity outweighs shared-failure-detection optimization

### 12.6 Metrics Lifecycle

**Recording:**
```
Request arrives for profile "premium", chain "ethereum"
  → Provider selected: "premium:alchemy"
  → Request executes, takes 45ms
  → Observability.record_success("ethereum", "premium:alchemy", "eth_call", 45, :http)
  → BenchmarkStore updates: {"premium:alchemy", "eth_call@http", :rpc}
```

**Selection:**
```
New request for profile "premium", chain "ethereum"
  → Selection.select_provider("ethereum", ...)
  → Lists candidates: ["premium:alchemy", "premium:infura"]
  → Fastest.rank_channels() queries metrics for each composite ID
  → Returns provider with best metrics FOR THIS PROFILE
```

### 12.7 Migration from Single-Config

For existing single-config deployments upgrading to profiles:

1. Create `default` profile with existing config
2. Provider IDs become `default:original_id`
3. Existing metrics are orphaned (fresh start for profile-scoped metrics)
4. Circuit breaker state resets (acceptable - short-lived anyway)

### 12.8 Request Context Integration

Profile must flow through the entire request pipeline. This requires changes to `RequestOptions` and `RequestContext`.

**RequestOptions Changes:**

```elixir
# lib/lasso/core/request/request_options.ex
defmodule Lasso.Core.Request.RequestOptions do
  @moduledoc """
  Options for configuring request behavior through the pipeline.
  """

  defstruct [
    # ... existing fields ...
    :chain,
    :method,
    :strategy,
    :transport,
    :timeout,

    # NEW: Profile context (required for multi-profile support)
    :profile_slug,        # The profile slug from URL path
    :profile_meta         # Profile metadata from ETS (rate limits, etc.)
  ]

  @type t :: %__MODULE__{
    chain: String.t() | nil,
    method: String.t() | nil,
    strategy: atom() | nil,
    transport: :http | :ws | nil,
    timeout: pos_integer() | nil,
    profile_slug: String.t() | nil,
    profile_meta: map() | nil
  }
end
```

**Request Pipeline Changes:**

```elixir
# In controller/socket, profile flows into options
defp build_request_options(conn) do
  %RequestOptions{
    chain: conn.path_params["chain"],
    strategy: conn.assigns[:strategy],
    profile_slug: conn.assigns.profile_slug,
    profile_meta: conn.assigns.profile
  }
end
```

**Provider Selection Integration:**

The profile_slug in RequestOptions enables the selection module to filter providers:

```elixir
defmodule Lasso.Core.Selection do
  def select_provider(opts) do
    # Get candidates from profile-scoped config
    candidates = ConfigStore.get_chain(opts.profile_slug, opts.chain)
    |> Map.get(:providers, [])

    # Candidates already have composite IDs: "profile:provider"
    # Selection strategies work unchanged
    apply_strategy(opts.strategy, candidates, opts)
  end
end
```

### 12.9 Telemetry & Observability

Profile awareness is critical for telemetry, but cardinality must be managed carefully.

**Cardinality Guidelines:**

| Metadata Field | Cardinality | Use In Labels? |
|----------------|-------------|----------------|
| `profile_type` | Low (3-5: free, standard, premium, byok) | ✅ Yes |
| `profile_slug` | High (unbounded with BYOK) | ❌ No - use in log metadata only |
| `provider_id` | Medium (composite, but bounded per profile) | ⚠️ Caution |
| `chain` | Low (~20 chains) | ✅ Yes |

**Telemetry Events:**

```elixir
# Request lifecycle events include profile context
:telemetry.execute(
  [:lasso, :rpc, :request, :complete],
  %{
    duration: duration_ms,
    bytes_in: request_size,
    bytes_out: response_size
  },
  %{
    # Low-cardinality labels (safe for Prometheus)
    profile_type: get_profile_type(profile_slug),  # "free", "standard", "byok"
    chain: chain,
    method: method,
    provider_id: provider_id,  # Composite ID
    status: :success | :error,

    # High-cardinality context (logs only, not labels)
    profile_slug: profile_slug,
    request_id: request_id
  }
)
```

**Profile Type from Config:**

```elixir
defmodule Lasso.Telemetry.ProfileType do
  @moduledoc """
  Get profile type for low-cardinality telemetry labeling.

  Profile type is an explicit field in the profile config YAML,
  ensuring consistent categorization without slug parsing heuristics.
  """

  @valid_types ~w(free standard premium byok)

  @doc """
  Get profile type from profile metadata.
  Falls back to "standard" if type is missing or invalid.
  """
  def get_type(%{type: type}) when type in @valid_types, do: type
  def get_type(%{"type" => type}) when type in @valid_types, do: type
  def get_type(_profile), do: "standard"
end
```

**Profile Type Values:** See Section 13.4 for the list of valid types and their use cases.

**Prometheus Metrics:**

```elixir
# Safe labels (bounded cardinality)
lasso_rpc_request_duration_seconds{profile_type="free", chain="ethereum", status="success"}
lasso_rpc_request_duration_seconds{profile_type="byok", chain="polygon", status="error"}

# NOT safe (unbounded with BYOK slugs)
# lasso_rpc_request_duration_seconds{profile_slug="byok-user-abc123-xyz789", ...}
```

### 12.10 WebSocket & Subscription Integration

WebSocket connections must be profile-aware for proper isolation.

**Endpoint Routes:**

```elixir
# lib/lasso_web/endpoint.ex
socket "/ws/rpc/:profile/:chain", LassoWeb.RPCSocket,
  websocket: [
    connect_info: [:peer_data, :x_headers],
    path_params: [:profile, :chain]
  ]
```

**RPCSocket Integration:**

```elixir
defmodule LassoWeb.RPCSocket do
  @behaviour Phoenix.Socket.Transport

  def connect(%{path_params: path_params} = info) do
    profile_slug = path_params["profile"]
    chain = path_params["chain"]

    with {:ok, profile} <- ConfigStore.get_profile(profile_slug),
         {:ok, chain_config} <- ConfigStore.get_chain(profile_slug, chain),
         {:ok, auth} <- resolve_auth(info.params) do

      state = %{
        profile_slug: profile_slug,
        profile: profile,
        chain: chain,
        chain_config: chain_config,
        subscription: auth[:subscription],
        subscriptions: %{},
        request_options: %RequestOptions{
          profile_slug: profile_slug,
          profile_meta: profile,
          chain: chain
        }
      }

      {:ok, state}
    else
      {:error, :profile_not_found} ->
        {:error, %{code: 4004, reason: "Profile not found"}}
      {:error, :chain_not_found} ->
        {:error, %{code: 4004, reason: "Chain not found for profile"}}
      {:error, reason} ->
        {:error, %{code: 4000, reason: inspect(reason)}}
    end
  end
end
```

**SubscriptionRouter Changes:**

The upstream subscription routing (for eth_subscribe forwarding) uses profile-scoped providers:

```elixir
defmodule Lasso.Core.SubscriptionRouter do
  @doc """
  Route subscription to upstream provider.
  Provider selection is profile-scoped via composite IDs.
  """
  def route_subscription(state, subscription_params) do
    # Selection uses profile from state
    opts = %{
      profile_slug: state.profile_slug,
      chain: state.chain,
      strategy: :fastest,
      transport: :ws
    }

    case Selection.select_provider(opts) do
      {:ok, provider} ->
        # Provider ID is composite: "profile:original_id"
        connect_upstream(provider, subscription_params, state)
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

### 12.11 HTTP Connection Pool Isolation (Finch)

**Decision: Shared pools with per-profile rate limiting.**

Connection pools are NOT profile-scoped. Rationale:

1. **Resource efficiency**: Separate pools per profile would multiply connection count
2. **Provider relationship**: Same upstream endpoint regardless of profile
3. **Isolation via rate limiting**: Profile isolation achieved through Hammer, not connection limits
4. **BYOK exception**: BYOK profiles with custom URLs naturally get separate pools (different hosts)

**Implementation:**

```elixir
# Finch pools keyed by URL host, not profile
# config/config.exs
config :lasso, :finch_pools,
  default: [
    size: 100,
    count: 4
  ]

# Different BYOK URLs automatically get separate pools
# "https://my-node.example.com" → separate pool from "https://eth-mainnet.alchemyapi.io"
```

**Rate Limit Isolation (existing):**

```elixir
# Profile isolation via Hammer buckets (already designed)
defp rate_limit_bucket(conn) do
  profile_slug = conn.assigns.profile.slug
  "profile:#{profile_slug}:ip:#{client_ip}"
end
```

**When Profile-Scoped Pools Might Be Needed:**

If future requirements demand connection-level isolation (e.g., premium profiles get dedicated connections), consider:

```elixir
# Future: Named Finch pools per profile tier
Finch.start_link(name: LassoFinch.Premium, pools: premium_config)
Finch.start_link(name: LassoFinch.Standard, pools: standard_config)

# Select pool based on profile type
defp get_finch_pool(profile_type) do
  case profile_type do
    "premium" -> LassoFinch.Premium
    "enterprise" -> LassoFinch.Premium
    _ -> LassoFinch.Standard
  end
end
```

This is NOT implemented in Phase 0 - shared pools are sufficient.

### 12.12 ChainSupervisor Architecture

**Decision: Flat structure, no per-profile supervision trees.**

ChainSupervisor manages per-chain processes (health monitors, circuit breakers). With composite provider IDs, these naturally isolate by profile without structural changes.

**Current Architecture (Profile-Aware via Composite IDs):**

```
Application
└── ChainSupervisor (DynamicSupervisor)
    ├── Chain:ethereum
    │   ├── HealthMonitor (monitors "free:alchemy", "free:infura", "premium:alchemy", ...)
    │   └── CircuitBreakerRegistry (keys: "ethereum:free:alchemy:http", ...)
    ├── Chain:polygon
    │   └── ...
    └── ...
```

**Key Points:**

1. **Single ChainSupervisor** - No per-profile supervisor trees
2. **Composite IDs in monitoring** - HealthMonitor tracks `"free:alchemy"` separately from `"premium:alchemy"`
3. **No process explosion** - Adding profiles doesn't multiply supervision trees
4. **Simple operational model** - One place to monitor chain health

**Why Not Per-Profile Supervision?**

| Approach | Pros | Cons |
|----------|------|------|
| Per-profile trees | Complete isolation, independent restarts | Process explosion (profiles × chains × providers), complex |
| Flat with composite IDs | Simple, efficient, sufficient isolation | Shared failure domain at chain level |

For Phase 0, flat structure is correct. Per-profile trees only make sense if:
- Profile failures must be completely isolated (not needed for OSS)
- Profiles have different reliability requirements (SaaS Phase 2+)

**HealthMonitor Integration:**

```elixir
defmodule Lasso.Core.HealthMonitor do
  @doc """
  Monitor provider health. Works unchanged with composite IDs.
  """
  def check_provider(provider_id, chain) do
    # provider_id is already composite: "profile:original"
    # Metrics stored under composite key
    result = ping_provider(provider_id)
    record_health(chain, provider_id, result)
  end
end
```

---

## 13. Implementation Phases

### Phase 0: Multi-Profile OSS (Foundation)

**Goal**: Multiple profiles in OSS with file-based storage.

1. Implement Config.Backend behaviour
2. Create Backend.File implementation
3. Extend ConfigStore with profile-scoped lookups
4. Add ProfileResolver plug (no fallback, profile always required)
5. Add RateLimiter plug with Hammer
6. Update router for `/rpc/:profile/:chain` pattern
7. Update WebSocket routes
8. Add ProfileValidator with SSRF checks

**No auth, no billing, no metering** - just multiple configs with rate limiting.

### Phase 1: API Keys + Auth (SaaS Foundation)

**Goal**: Multi-tenant access with account-scoped API keys.

1. Add accounts, api_keys tables
2. Implement SHA256 key validation with ETS cache
3. Create Backend.Database implementation
4. Add key resolution to request pipeline
5. Add `?key=` and header auth support

### Phase 2: Subscriptions + Metering

**Goal**: Subscription-based access with usage tracking.

1. Add subscriptions table
2. Implement subscription ETS cache
3. Add bytes-based CU metering (async)
4. Add periodic CU limit enforcement
5. Add usage_records for billing

### Phase 3: Dashboard + UI

**Goal**: Admin interface for profile management.

1. Profile list page
2. Profile YAML editor with validation
3. Subscription management (if SaaS)
4. Usage dashboard

---

## 13. Phase 0 Implementation Details

### 13.1 File Changes Summary

**Total: ~12 files (5 new, 7 modified)**

| File                                          | Action | Description                          |
| --------------------------------------------- | ------ | ------------------------------------ |
| `lib/lasso/config/backend.ex`                 | CREATE | Backend behaviour definition         |
| `lib/lasso/config/backend/file.ex`            | CREATE | File-based backend implementation    |
| `lib/lasso/config/profile_validator.ex`       | CREATE | YAML + SSRF validation               |
| `lib/lasso/config/config_store.ex`            | MODIFY | Profile-scoped storage extension     |
| `lib/lasso_web/plugs/profile_resolver.ex`     | CREATE | Extract profile from path            |
| `lib/lasso_web/plugs/rate_limiter.ex`         | CREATE | Hammer-based rate limiting           |
| `lib/lasso_web/router.ex`                     | MODIFY | Profile routes                       |
| `lib/lasso_web/endpoint.ex`                   | MODIFY | WebSocket routes with profile        |
| `lib/lasso_web/channels/rpc_socket.ex`        | MODIFY | Profile resolution for WebSocket     |
| `lib/lasso/application.ex`                    | MODIFY | Add Hammer to supervision tree       |
| `lib/lasso/core/request/request_options.ex`   | MODIFY | Add profile_slug field               |
| `mix.exs`                                     | MODIFY | Add Hammer dependency (already done) |

### 13.2 ProfileResolver Plug

```elixir
defmodule LassoWeb.Plugs.ProfileResolver do
  @moduledoc """
  Extracts and validates the profile from the request path.
  Profile is always required - no fallbacks.

  Provides migration-friendly error messages for clients using old URL formats.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Lasso.Config.ConfigStore
  alias Lasso.JSONRPC.Error, as: JError

  def init(opts), do: opts

  def call(conn, _opts) do
    profile_slug = conn.path_params["profile"]

    case profile_slug do
      nil ->
        # Migration hint: detect old URL format and suggest new format
        chain = detect_chain_from_path(conn)
        handle_missing_profile(conn, chain)

      slug ->
        case ConfigStore.get_profile(slug) do
          {:ok, profile} ->
            conn
            |> assign(:profile, profile)
            |> assign(:profile_slug, slug)

          {:error, :not_found} ->
            # Check if slug looks like a chain (migration from old format)
            if looks_like_chain?(slug) do
              handle_legacy_chain_request(conn, slug)
            else
              error = JError.new(-32600, "Profile not found: #{slug}",
                data: %{
                  "profile" => slug,
                  "available_profiles" => list_available_profiles()
                }
              )
              conn |> put_status(:not_found) |> json(JError.to_response(error, nil)) |> halt()
            end
        end
    end
  end

  # Detect if path looks like old format: /rpc/ethereum or /rpc/1
  defp detect_chain_from_path(conn) do
    conn.path_info
    |> Enum.drop_while(&(&1 != "rpc"))
    |> Enum.drop(1)
    |> List.first()
  end

  defp handle_missing_profile(conn, nil) do
    error = JError.new(-32600, "Profile parameter required in URL path",
      data: %{
        "message" => "URL format changed. Profile is now required.",
        "example" => "/rpc/{profile}/{chain}",
        "available_profiles" => list_available_profiles()
      }
    )
    conn |> put_status(:bad_request) |> json(JError.to_response(error, nil)) |> halt()
  end

  defp handle_missing_profile(conn, chain) do
    suggested_url = "/rpc/default/#{chain}"
    error = JError.new(-32600, "Profile parameter required in URL path",
      data: %{
        "message" => "URL format changed. Profile is now required.",
        "requested_path" => conn.request_path,
        "suggested_url" => suggested_url,
        "available_profiles" => list_available_profiles()
      }
    )

    conn
    |> put_resp_header("x-lasso-upgrade-url", suggested_url)
    |> put_status(:bad_request)
    |> json(JError.to_response(error, nil))
    |> halt()
  end

  defp handle_legacy_chain_request(conn, chain_or_id) do
    suggested_url = "/rpc/default/#{chain_or_id}"
    error = JError.new(-32600, "Profile not found - did you mean to use the new URL format?",
      data: %{
        "message" => "URL format changed. Use /rpc/{profile}/{chain} format.",
        "requested_path" => conn.request_path,
        "suggested_url" => suggested_url,
        "hint" => "'#{chain_or_id}' looks like a chain identifier. Try: #{suggested_url}"
      }
    )

    conn
    |> put_resp_header("x-lasso-upgrade-url", suggested_url)
    |> put_status(:bad_request)
    |> json(JError.to_response(error, nil))
    |> halt()
  end

  # Heuristic: looks like a chain if it's a number or known chain name
  defp looks_like_chain?(value) do
    is_numeric?(value) or value in known_chain_names()
  end

  defp is_numeric?(str), do: String.match?(str, ~r/^\d+$/)

  defp known_chain_names do
    ~w(ethereum mainnet sepolia goerli polygon arbitrum optimism base avalanche bsc)
  end

  defp list_available_profiles do
    case ConfigStore.list_profiles() do
      {:ok, profiles} -> Enum.map(profiles, & &1.slug)
      _ -> []
    end
  end
end
```

### 13.3 Directory Structure

```
config/
├── config.exs
└── profiles/
    ├── default.yml      # Default profile
    ├── production.yml   # Additional profiles
    └── staging.yml
```

### 13.4 Profile YAML Format

```yaml
---
name: Production
slug: production
type: standard          # NEW: Explicit profile type for telemetry/billing
default_rps_limit: 500
default_burst_limit: 1000
---
chains:
  ethereum:
    chain_id: 1
    name: "Ethereum Mainnet"
    providers:
      - id: "alchemy"
        url: "https://eth-mainnet.g.alchemy.com/v2/..."
        priority: 1
```

**Profile Type Values:**

| Type | Description | Use Case |
|------|-------------|----------|
| `free` | Public/anonymous access tier | Rate-limited free tier |
| `standard` | Default paid tier | Individual users |
| `premium` | High-limit tier | Teams, enterprises |
| `byok` | Bring Your Own Keys | Custom provider URLs |

The `type` field is used for:
- Low-cardinality telemetry labels (safe for Prometheus)
- Billing tier identification (SaaS)
- Dashboard grouping

### 13.5 Configuration

```elixir
# config/config.exs
config :lasso,
  config_backend: Lasso.Config.Backend.File,
  config_backend_config: [profiles_dir: "config/profiles"],
  max_batch_size: 100,
  rate_limit_enabled: true
```

---

## 14. Success Criteria

### Phase 0

- [ ] Multiple profiles load from `config/profiles/` directory
- [ ] `/rpc/:profile/:chain` routes to correct profile config
- [ ] Unknown profile returns 404
- [ ] WebSocket `/ws/rpc/:profile/:chain` works
- [ ] Rate limiting enforces per-profile limits
- [ ] Global batch size limit works
- [ ] Profile YAML validation with SSRF checks works
- [ ] All hot path operations < 1ms (ETS only)

### Phase 1+

- [ ] API key authentication works
- [ ] Account-profile subscriptions work
- [ ] Bytes-based CU metering works
- [ ] CU limits enforced (async)

---

## 15. Distributed Deployment Considerations

This section documents the implications of single-instance vs multi-instance (clustered) deployment. OSS Lasso targets single-instance deployment; clustering is a proprietary extension for Lasso Cloud.

### 15.1 State Classification

All runtime state falls into two categories:

| Category | Scope | Examples | Clustering Impact |
|----------|-------|----------|-------------------|
| **Instance-Local** | Per-node, not shared | Metrics, circuit breakers, Finch pools | None - correct per-instance |
| **Logically-Global** | Should be consistent across cluster | Subscription cache, API key cache, rate limits | Requires distributed coordination |

### 15.2 Instance-Local State (No Clustering Required)

These are **correctly per-instance** and work fine without clustering:

**Metrics (BenchmarkStore):**
- Each instance measures its own latencies to providers
- Different instances may have different network paths → different optimal providers
- Per-instance metrics lead to locally-optimal routing decisions
- ✅ No fix needed

**Circuit Breakers:**
- Each instance protects its own outbound connections
- If provider fails, each instance discovers independently (within seconds)
- Slight delay in cluster-wide awareness is acceptable (circuit recovery is fast)
- ✅ No fix needed

**HTTP Connection Pools (Finch):**
- Connection pools are inherently per-process/per-node
- Cannot share TCP connections across instances
- ✅ No fix needed

**Block Consensus (BlockCache):**
- Latest block height is truly global (blockchain property)
- Each instance queries providers and converges to same consensus
- Slight temporary divergence is acceptable
- ✅ No fix needed - kept global, not per-profile

### 15.3 Logically-Global State (Clustering Enables)

These features **work correctly only with clustering**:

**Subscription Cache Invalidation:**
```
Without clustering:
  Instance A: User upgrades subscription → cache invalidated locally
  Instance B: Still has stale cache → user gets old limits for up to 60s

With clustering (PubSub broadcast reaches all nodes):
  Instance A: Broadcasts invalidation → all instances update immediately
```

**API Key Cache Invalidation:**
- Same pattern as subscription cache
- Without clustering: revoked keys may work on some instances for up to 60s

**Rate Limiting:**
```
Without clustering (Hammer ETS backend):
  User sends 100 requests → 50 hit Instance A, 50 hit Instance B
  Each instance sees only 50 → user bypasses limit by 2x

With clustering (Redis backend):
  All requests counted in shared Redis → accurate enforcement
```

**Config Hot-Reload:**
- Without clustering: reload only affects one instance
- With clustering: PubSub broadcast triggers reload on all instances

### 15.4 OSS Single-Instance Behavior

For OSS deployments (single instance), all features work correctly:
- ETS caches are authoritative (only one instance)
- PubSub broadcasts reach all subscribers (same node)
- Rate limits are accurate (single counter)
- Config reload is immediate (one instance to update)

**Recommendation:** OSS users should deploy single-instance or accept the limitations documented above.

### 15.5 Multi-Instance Limitations (Without Clustering)

When running multiple instances without clustering:

| Feature | Behavior | Severity |
|---------|----------|----------|
| **Rate Limiting** | Per-instance (Nx bypass with N instances) | Medium - document in profile config |
| **Subscription Cache** | 60s max staleness window | Medium - acceptable for most cases |
| **API Key Revocation** | 60s max window where revoked key works | Medium - acceptable |
| **Config Changes** | Require redeployment (all instances) | Low - expected for file-based config |
| **Metrics/Routing** | Per-instance optimization | None - this is correct behavior |

### 15.6 Path to Clustering (Lasso Cloud)

For Lasso Cloud (SaaS), clustering enables full consistency:

```elixir
# Required dependencies
{:libcluster, "~> 3.3"}
{:hammer_backend_redis, "~> 6.1"}  # Optional: accurate rate limiting

# Clustering configuration (Fly.io example)
config :libcluster,
  topologies: [
    fly6pn: [
      strategy: Cluster.Strategy.DNSPoll,
      config: [
        query: "lasso-cloud.internal",
        node_basename: "lasso-cloud"
      ]
    ]
  ]

# Distributed PubSub (works automatically with libcluster)
# Phoenix.PubSub.PG2 uses Erlang distribution for cross-node messaging
```

**Clustering enables:**
- Instant cache invalidation across all instances
- Coordinated config hot-reload
- (Optional) Cluster-wide rate limiting with Redis

**OSS Extension Point:** The architecture supports clustering without code changes - just add libcluster and configure topology. All PubSub broadcasts automatically reach clustered nodes.

### 15.7 PubSub Topics: Local vs Global

| Topic | Scope | Needs Profile? | Clustering Behavior |
|-------|-------|----------------|---------------------|
| `subscriptions:cache` | Global | No | Broadcast to all nodes |
| `config:updates` | Global | No | Broadcast to all nodes |
| `circuit:events` | Per-profile | Yes → `circuit:events:#{profile}` | Local observation OK |
| `ws:conn:#{chain}` | Per-profile | Yes → `ws:conn:#{chain}:#{profile}` | Local observation OK |
| `provider_pool:events:#{chain}` | Per-profile | Yes | Local observation OK |
| `routing:decisions` | Observability | Optional | Local OK (dashboard) |
| `block_cache:updates` | Global | No | Local OK (consensus converges) |

**Design Principle:** Cache invalidation topics must be global (cluster-wide). Observability topics can be local (each instance observes its own traffic).

---

## 16. Architectural Decisions Summary

This section records key architectural decisions made during design.

### 16.1 ProviderPool: Isolated Per (Chain, Profile)

**Decision:** Separate ProviderPool instance per (chain, profile) pair.

**Rationale:**
- Clean isolation - no cross-profile interference
- Simpler code - no profile filtering in every method
- Matches composite provider ID philosophy
- Process count scales with profiles × chains (acceptable)

**Trade-off:** More memory/processes with many profiles. Acceptable - "lots of profiles" is a good problem to have.

### 16.2 Block Consensus: Global (Not Per-Profile)

**Decision:** Block height consensus is shared across all profiles.

**Rationale:**
- Blockchains have a single canonical chain head
- Different profiles querying different providers should converge to same height
- Per-profile consensus would be artificial and confusing

**Implementation:** `BlockCache` stores single `:latest` key per chain, shared across profiles.

### 16.3 Rate Limiting: Per-Instance (Not Distributed)

**Decision:** Rate limits enforced per-instance using Hammer with ETS backend.

**Rationale:**
- Simplicity - no Redis dependency
- Latency - no network round-trip for rate check
- Acceptable accuracy for OSS (single-instance) and documented behavior for multi-instance

**Trade-off:** Multi-instance deployments have Nx effective limit with N instances. Documented in profile config comments.

### 16.4 Profile Deletion: Deferred

**Decision:** Profile deletion not supported in Phase 0.

**Rationale:**
- Simplifies implementation
- Orphaned state (metrics, circuit breakers) is bounded and eventually ages out
- Full cleanup strategy deferred to when deletion feature is needed

### 16.5 SSRF DNS Re-validation: Accept Risk

**Decision:** DNS resolution happens at profile validation time only, not per-request.

**Rationale:**
- Per-request DNS adds latency
- DNS rebinding attacks require attacker-controlled DNS
- Risk is acceptable for BYOK (user's own infrastructure)

**Mitigation:** Document that BYOK URLs should use static IPs or trusted DNS.

### 16.6 Cache Staleness: 60s Window Acceptable

**Decision:** Subscription/API key caches refresh every 60 seconds.

**Rationale:**
- 60s max staleness is acceptable for most billing scenarios
- Immediate invalidation via PubSub handles normal cases
- 60s fallback only matters if PubSub fails (rare)

---

## Document History

| Version | Date     | Changes                                                                                                   |
| ------- | -------- | --------------------------------------------------------------------------------------------------------- |
| 4.1     | Dec 2024 | Added: Distributed deployment considerations (Section 15), Architectural decisions summary (Section 16), Explicit profile type field, PubSub topic scoping, Multi-instance limitations documentation |
| 4.0     | Dec 2024 | Major simplification: removed default profile concept, simplified data model (profile=config, subscription=billing), billing agnostic, ETS-only hot path, bytes-based CU metering, global batch limits, simplified SSRF, hand-waved UI code |

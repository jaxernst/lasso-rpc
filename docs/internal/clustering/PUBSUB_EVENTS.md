# PubSub Events and Topic Hierarchy

**Version**: 1.0
**Last Updated**: January 2026
**Related**: [DASHBOARD_CLUSTER_ARCHITECTURE_V2.md](./DASHBOARD_CLUSTER_ARCHITECTURE_V2.md)

---

## 1. Overview

This document defines the typed event schemas and topic hierarchy for Lasso RPC's distributed PubSub system. Events are broadcast via Phoenix.PubSub and automatically propagate across all connected cluster nodes.

### Design Principles

1. **Profile-scoped by default**: All events include `profile` and use profile-scoped topics
2. **Typed schemas**: Use idiomatic Elixir structs with `@type` specs
3. **Source attribution**: All events include `source_node` and `source_region`
4. **Account isolation (Cloud)**: Additional account-scoped topics for SaaS tenant isolation

---

## 2. Topic Hierarchy

### 2.1 Profile-Scoped Topics

These topics are used for OSS deployments and Cloud operator views.

```
routing:decisions:{profile}         # RPC routing decisions (success/failure)
circuit:events:{profile}:{chain}    # Circuit breaker state transitions
provider_pool:events:{profile}:{chain}  # Provider health status changes
ws:conn:{profile}:{chain}           # WebSocket connection events
block_sync:{profile}:{chain}        # Block height updates
health_probe:{profile}:{chain}      # Health check results
```

### 2.2 Account-Scoped Topics (Cloud Only)

These topics provide tenant isolation for SaaS deployments.

```
routing:decisions:{profile}:account:{account_id}  # Account-specific routing events
```

### 2.3 Topic Selection Logic

**Note**: OSS and Cloud are separate repositories with different code. Do not embed `oss_mode?()` runtime branching in shared application code. The differences are documented below at the deployment level.

#### OSS Repository
All users are operators. Subscribe to profile-scoped topics:
```elixir
def routing_topic(_socket, profile) do
  "routing:decisions:#{profile}"
end
```

#### Cloud Repository
Default to account-scoped topics for "My App" view. Provide admin toggle for full profile view ("Profile Benchmark"):
```elixir
def routing_topic(socket, profile) do
  if admin_full_view?(socket) do
    "routing:decisions:#{profile}"
  else
    account_id = socket.assigns.current_account.id
    "routing:decisions:#{profile}:account:#{account_id}"
  end
end

defp admin_full_view?(socket) do
  account = socket.assigns[:current_account]
  account && is_admin?(account) && socket.assigns[:show_all_events] == true
end
```

**Note on Shared Profiles**: Shared profiles (Free/Premium) intentionally show profile-wide analytics in the "Profile Benchmark" view. This is by design to support public benchmarking. BYOK profiles are private by construction.

---

## 3. Event Schemas

### 3.0 OSS/Cloud Schema Boundary

**Critical**: Event structs in OSS (lasso-rpc) must not contain Cloud-specific fields. Cloud extends events at publish time.

| Field | OSS (lasso-rpc) | Cloud (lasso-cloud) |
|-------|-----------------|---------------------|
| `request_id`, `ts`, `profile` | ✓ in struct | inherits |
| `source_node`, `source_region` | ✓ in struct | inherits |
| `chain`, `method`, `strategy` | ✓ in struct | inherits |
| `provider_id`, `transport` | ✓ in struct | inherits |
| `duration_ms`, `result`, `failover_count` | ✓ in struct | inherits |
| `error_category`, `error_code` | ✓ in struct | inherits |
| `account_id` | ✗ NOT in OSS | added at publish time |
| `api_key_id` | ✗ NOT in OSS | added at publish time |

**Why?** OSS has no concept of accounts. Including `account_id` in OSS structs would:
- Leak Cloud concepts into OSS codebase
- Create dead fields that are always nil
- Confuse OSS contributors

### 3.1 RoutingDecision (OSS)

The primary event for RPC request routing outcomes.

**Module**: `lib/lasso/events/routing_decision.ex` (OSS)

```elixir
defmodule Lasso.Events.RoutingDecision do
  @moduledoc """
  Typed schema for routing decision events broadcast via PubSub.

  Published on successful and failed RPC requests to track routing behavior,
  provider performance, and failover patterns.

  NOTE: This is the OSS base schema. Cloud (lasso-cloud) extends events with
  account_id and api_key_id at publish time - those fields are NOT in this struct.
  """

  @type t :: %__MODULE__{
    request_id: String.t(),
    ts: non_neg_integer(),
    profile: String.t(),
    source_node: node(),
    source_region: String.t(),
    chain: String.t(),
    method: String.t(),
    strategy: String.t(),
    provider_id: String.t(),
    transport: :http | :ws,
    duration_ms: non_neg_integer(),
    result: :success | :error,
    failover_count: non_neg_integer(),
    error_category: atom() | nil,
    error_code: integer() | nil
  }

  @enforce_keys [
    :request_id,
    :ts,
    :profile,
    :source_node,
    :source_region,
    :chain,
    :method,
    :strategy,
    :provider_id,
    :transport,
    :duration_ms,
    :result,
    :failover_count
  ]

  defstruct [
    :request_id,
    :ts,
    :profile,
    :source_node,
    :source_region,
    :chain,
    :method,
    :strategy,
    :provider_id,
    :transport,
    :duration_ms,
    :result,
    :failover_count,
    :error_category,
    :error_code
  ]

  @doc """
  Creates a new RoutingDecision event from a map of attributes.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Creates a success event.
  """
  @spec success(map()) :: t()
  def success(attrs) do
    new(Map.merge(attrs, %{result: :success, error_category: nil, error_code: nil}))
  end

  @doc """
  Creates an error event.
  """
  @spec error(map()) :: t()
  def error(attrs) do
    new(Map.put(attrs, :result, :error))
  end
end
```

### 3.1.1 Cloud Extension Pattern (lasso-cloud only)

Cloud adds account attribution at event publish time, not in the struct:

```elixir
# Cloud-only file: lib/lasso_cloud/observability/account_events.ex
defmodule LassoCloud.Observability.AccountEvents do
  @moduledoc """
  Cloud extension for account-scoped event publishing.
  Wraps OSS event publishing with account attribution.
  """

  @doc """
  Publishes routing decision to both profile and account topics.
  Called from Cloud's request pipeline (replaces direct OSS call).
  """
  def publish_routing_decision(event, account_id, api_key_id) do
    profile = event.profile

    # 1. Publish to profile topic (OSS behavior, all operators see this)
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "routing:decisions:#{profile}",
      event
    )

    # 2. Cloud addition: publish enriched event to account topic
    if account_id do
      enriched = Map.merge(Map.from_struct(event), %{
        account_id: account_id,
        api_key_id: api_key_id
      })

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "routing:decisions:#{profile}:account:#{account_id}",
        enriched
      )
    end
  end
end
```

**Key insight**: The account-scoped topic receives a plain map with extra fields, not a struct. This avoids struct version conflicts between OSS and Cloud.

### 3.2 CircuitEvent

Circuit breaker state transitions.

**Module**: `lib/lasso/events/circuit_event.ex`

```elixir
defmodule Lasso.Events.CircuitEvent do
  @moduledoc """
  Typed schema for circuit breaker state transition events.
  """

  @type state :: :closed | :open | :half_open

  @type t :: %__MODULE__{
    ts: non_neg_integer(),
    profile: String.t(),
    source_node: node(),
    source_region: String.t(),
    chain: String.t(),
    provider_id: String.t(),
    transport: :http | :ws,
    previous_state: state(),
    new_state: state(),
    failure_count: non_neg_integer(),
    last_failure_reason: atom() | nil
  }

  @enforce_keys [
    :ts,
    :profile,
    :source_node,
    :source_region,
    :chain,
    :provider_id,
    :transport,
    :previous_state,
    :new_state,
    :failure_count
  ]

  defstruct [
    :ts,
    :profile,
    :source_node,
    :source_region,
    :chain,
    :provider_id,
    :transport,
    :previous_state,
    :new_state,
    :failure_count,
    :last_failure_reason
  ]

  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
```

### 3.3 ProviderHealthEvent

Provider health status changes.

**Module**: `lib/lasso/events/provider_health_event.ex`

```elixir
defmodule Lasso.Events.ProviderHealthEvent do
  @moduledoc """
  Typed schema for provider health status change events.
  """

  @type health_status :: :healthy | :degraded | :unhealthy

  @type t :: %__MODULE__{
    ts: non_neg_integer(),
    profile: String.t(),
    source_node: node(),
    source_region: String.t(),
    chain: String.t(),
    provider_id: String.t(),
    previous_status: health_status(),
    new_status: health_status(),
    http_circuit: :closed | :open | :half_open,
    ws_circuit: :closed | :open | :half_open,
    block_lag: non_neg_integer() | nil,
    rate_limited: boolean()
  }

  @enforce_keys [
    :ts,
    :profile,
    :source_node,
    :source_region,
    :chain,
    :provider_id,
    :previous_status,
    :new_status,
    :http_circuit,
    :ws_circuit,
    :rate_limited
  ]

  defstruct [
    :ts,
    :profile,
    :source_node,
    :source_region,
    :chain,
    :provider_id,
    :previous_status,
    :new_status,
    :http_circuit,
    :ws_circuit,
    :block_lag,
    :rate_limited
  ]

  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
```

### 3.4 BlockSyncEvent

Block height synchronization updates.

**Module**: `lib/lasso/events/block_sync_event.ex`

```elixir
defmodule Lasso.Events.BlockSyncEvent do
  @moduledoc """
  Typed schema for block synchronization events.
  """

  @type t :: %__MODULE__{
    ts: non_neg_integer(),
    profile: String.t(),
    source_node: node(),
    source_region: String.t(),
    chain: String.t(),
    provider_id: String.t(),
    block_number: non_neg_integer(),
    consensus_height: non_neg_integer() | nil,
    lag: non_neg_integer()
  }

  @enforce_keys [
    :ts,
    :profile,
    :source_node,
    :source_region,
    :chain,
    :provider_id,
    :block_number,
    :lag
  ]

  defstruct [
    :ts,
    :profile,
    :source_node,
    :source_region,
    :chain,
    :provider_id,
    :block_number,
    :consensus_height,
    :lag
  ]

  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
```

---

## 4. Event Sampling Policy

**Critical**: Publishing every successful request via PubSub can become a bottleneck at scale. Use publisher-side gating to preserve signal while avoiding PubSub becoming the scaling limit.

### 4.1 Always Publish (High Signal)
These events are always published regardless of sampling:
- `result = :error` (all errors)
- `failover_count > 0` (any failover)
- Circuit breaker state transitions
- Provider health status transitions

### 4.2 Sample Successes (Configurable)
- Default: `success_sample_rate = 0.01` to `0.05` (1-5%)
- Per-profile configuration available for high-traffic shared profiles (may need lower rates)
- Keeps activity feed "alive" and supports benchmarking UX without overwhelming the system

### 4.3 Implementation

```elixir
defp should_publish_event?(%{result: :error}), do: true
defp should_publish_event?(%{failover_count: n}) when n > 0, do: true
defp should_publish_event?(_event) do
  sample_rate = Application.get_env(:lasso, :success_event_sample_rate, 0.05)
  :rand.uniform() < sample_rate
end

defp maybe_publish_routing_decision(event) do
  if should_publish_event?(event) do
    broadcast_routing_decision(event)
  end
end
```

### 4.4 Configuration

**Application config** (`config/config.exs`):
```elixir
config :lasso, :routing_events,
  success_sample_rate: 0.05,
  always_publish_errors: true,
  always_publish_failovers: true
```

**Profile-specific rates** (recommendations):

| Profile Type | Recommended Sample Rate | Rationale |
|--------------|------------------------|-----------|
| BYOK (low traffic) | 0.10 (10%) | Private profile, lower volume |
| Shared Free | 0.01-0.02 (1-2%) | High volume, many users |
| Shared Premium | 0.02-0.05 (2-5%) | Moderate volume |

### 4.5 Volume Impact

At 1000 RPS baseline (typical for a busy profile):

| Sample Rate | Success Events/sec | Total Events/sec* | Cluster Reduction |
|-------------|-------------------|-------------------|-------------------|
| 100% (no sampling) | 950 | 1000 | 0% |
| 5% (recommended) | 47.5 | ~100 | **90%** |
| 2% | 19 | ~70 | **93%** |
| 1% | 9.5 | ~60 | **94%** |

*Assumes 95% success rate, 3% errors, 2% failovers (errors and failovers always published)

**Why sampling is mandatory at scale:**
- CLUSTERING_SPEC_V1.md Section 1.4: ">10K req/s can bottleneck PubSub"
- Cross-region PubSub latency: 10-50ms per message over WireGuard
- Without sampling, a 3-node cluster at 1000 RPS generates 3000 broadcasts/sec

---

## 5. Publishing Events

### 5.1 RoutingDecision Publishing (OSS)

Update `lib/lasso/core/request/request_pipeline/observability.ex`:

```elixir
defp publish_routing_decision(ctx, channel, method, strategy, duration_ms, result, error_info \\ nil) do
  profile = ctx.opts.profile

  event = %Lasso.Events.RoutingDecision{
    request_id: ctx.request_id,
    ts: System.system_time(:millisecond),
    profile: profile,
    source_node: node(),
    source_region: System.get_env("CLUSTER_REGION", "local"),
    chain: ctx.chain,
    method: method,
    strategy: to_string(strategy),
    provider_id: channel.provider_id,
    transport: channel.transport,
    duration_ms: duration_ms,
    result: result,
    failover_count: ctx.retries,
    error_category: get_in(error_info, [:category]),
    error_code: get_in(error_info, [:code])
  }

  # Apply sampling before broadcast
  if should_publish_event?(event) do
    Phoenix.PubSub.broadcast(Lasso.PubSub, "routing:decisions:#{profile}", event)
  end

  :ok
end
```

**Note:** This is the OSS implementation. The event struct does NOT include `account_id` - that's added by Cloud at publish time (see Section 3.1.1).

### 5.2 CircuitEvent Publishing

Update `lib/lasso/core/support/circuit_breaker.ex`:

```elixir
defp broadcast_state_change(profile, chain, provider_id, transport, prev_state, new_state, failure_count, reason) do
  event = %Lasso.Events.CircuitEvent{
    ts: System.system_time(:millisecond),
    profile: profile,
    source_node: node(),
    source_region: System.get_env("CLUSTER_REGION", "local"),
    chain: chain,
    provider_id: provider_id,
    transport: transport,
    previous_state: prev_state,
    new_state: new_state,
    failure_count: failure_count,
    last_failure_reason: reason
  }

  Phoenix.PubSub.broadcast(
    Lasso.PubSub,
    "circuit:events:#{profile}:#{chain}",
    event
  )
end
```

---

## 6. Subscribing to Events

### 6.1 Dashboard Subscription (Cloud Example)

**Note**: This example is for the Cloud repository. The OSS repository uses simpler profile-scoped subscriptions only.

```elixir
defmodule LassoWeb.Dashboard.EventSubscription do
  @moduledoc """
  Handles PubSub subscription logic for Cloud deployments.

  Default: Account-scoped subscriptions ("My App" view)
  Admin toggle: Profile-scoped subscriptions ("Profile Benchmark" view)
  """

  alias Phoenix.PubSub

  @doc """
  Subscribe to routing events with appropriate scoping.
  Returns the subscribed topic for later unsubscription.
  """
  def subscribe_routing_events(socket, profile) do
    topic = routing_topic(socket, profile)
    PubSub.subscribe(Lasso.PubSub, topic)
    topic
  end

  @doc """
  Subscribe to circuit events for a profile/chain.
  Circuit events are profile-scoped (shared signal).
  """
  def subscribe_circuit_events(profile, chain) do
    topic = "circuit:events:#{profile}:#{chain}"
    PubSub.subscribe(Lasso.PubSub, topic)
    topic
  end

  @doc """
  Subscribe to provider health events for a profile/chain.
  Provider health is profile-scoped (shared signal).
  """
  def subscribe_provider_events(profile, chain) do
    topic = "provider_pool:events:#{profile}:#{chain}"
    PubSub.subscribe(Lasso.PubSub, topic)
    topic
  end

  @doc """
  Unsubscribe from a topic.
  """
  def unsubscribe(topic) do
    PubSub.unsubscribe(Lasso.PubSub, topic)
  end

  # Private

  defp routing_topic(socket, profile) do
    if admin_full_view?(socket) do
      # Admin "Profile Benchmark" view
      "routing:decisions:#{profile}"
    else
      # Default "My App" view
      account_id = socket.assigns.current_account.id
      "routing:decisions:#{profile}:account:#{account_id}"
    end
  end

  defp admin_full_view?(socket) do
    account = socket.assigns[:current_account]
    account && is_admin?(account) && socket.assigns[:show_all_events] == true
  end

  defp is_admin?(account) do
    account.role in [:admin, :operator]
  end
end
```

### 6.2 Dashboard Event Handlers

```elixir
# In dashboard.ex

def handle_info(%Lasso.Events.RoutingDecision{} = event, socket) do
  socket = update_routing_events(socket, event)
  {:noreply, socket}
end

def handle_info(%Lasso.Events.CircuitEvent{} = event, socket) do
  socket = update_circuit_state(socket, event)
  {:noreply, socket}
end

def handle_info(%Lasso.Events.ProviderHealthEvent{} = event, socket) do
  socket = update_provider_status(socket, event)
  {:noreply, socket}
end

defp update_routing_events(socket, event) do
  update(socket, :routing_events, fn events ->
    [event | events]
    |> Enum.uniq_by(& &1.request_id)
    |> Enum.sort_by(& &1.ts, :desc)
    |> Enum.take(100)
  end)
end
```

---

## 7. Event Deduplication

Events may arrive multiple times during partition recovery. Use deduplication to prevent duplicates in the activity feed.

**Primary dedup key**: `request_id` (unique per request)

### 7.1 Simplified Deduplication Module

A simple MapSet-based approach with periodic full clear. This is sufficient because:
- Duplicates only slip through briefly after the 60s clear window
- Visual impact is minimal (extra event in feed)
- No correctness issues (metrics are already aggregated at source)

```elixir
defmodule LassoWeb.Dashboard.EventDedup do
  @moduledoc """
  Simple bounded deduplication using MapSet with periodic clear.
  Trades LRU precision for simplicity (~10 lines vs ~70).
  """

  @max_age_seconds 60

  @doc "Create new dedup state as {seen_set, created_at_seconds}"
  def new, do: {MapSet.new(), System.monotonic_time(:second)}

  @doc """
  Check if event is duplicate and insert if not.
  Returns {:emit, new_state} or {:duplicate, state}.
  """
  def check({seen, created_at}, %{request_id: id}) when is_binary(id) and id != "" do
    now = System.monotonic_time(:second)

    # Clear entire set after max_age (simple but effective)
    seen = if now - created_at > @max_age_seconds, do: MapSet.new(), else: seen

    if MapSet.member?(seen, id) do
      {:duplicate, {seen, now}}
    else
      {:emit, {MapSet.put(seen, id), now}}
    end
  end

  # Fallback for events without request_id (shouldn't happen with typed structs)
  def check(state, _event), do: {:emit, state}
end
```

### 7.2 Usage in LiveView

```elixir
def mount(_params, _session, socket) do
  socket = assign(socket, :event_dedup, EventDedup.new())
  {:ok, socket}
end

def handle_info(%Lasso.Events.RoutingDecision{} = event, socket) do
  case EventDedup.check(socket.assigns.event_dedup, event) do
    {:emit, new_dedup} ->
      socket =
        socket
        |> assign(:event_dedup, new_dedup)
        |> update_routing_events(event)
      {:noreply, socket}

    {:duplicate, new_dedup} ->
      {:noreply, assign(socket, :event_dedup, new_dedup)}
  end
end
```

---

## 8. Migration Strategy

### 8.1 Immediate Deploy Strategy (Recommended)

For Fly.io deployments, use immediate strategy which updates all nodes together:

1. Update publisher and subscriber in same commit
2. Deploy with `fly deploy --strategy immediate`
3. Verify all nodes reconnect to cluster
4. Brief dashboard gap (~30s) during deploy is acceptable

```bash
fly deploy --strategy immediate -a lasso-rpc
```

**Why not dual-write?** Dual-write/dual-read migration adds complexity for marginal benefit. The 30-second gap is acceptable for dashboard data (not user-facing requests). If zero-downtime becomes critical later, dual-write can be added at that time.

---

## 9. PubSub Behavior Notes

### 9.1 Message Ordering

Phoenix.PubSub provides **NO ordering guarantees** across distributed nodes:
- **Local delivery**: Messages from same node arrive in order
- **Remote delivery**: Messages from different nodes can arrive out of order

**Mitigation**: Sort events by `ts` on arrival.

### 9.2 Message Delivery

Phoenix.PubSub provides **at-most-once delivery**:
- If subscriber process crashes during handling, message is lost
- If network partition occurs mid-broadcast, some nodes may not receive message

**Acceptable for**: Dashboard events (ephemeral)
**Not acceptable for**: Billing events (use database writes)

### 9.3 Cross-Region Latency

Cross-region broadcasts traverse WireGuard tunnels:
- Expected latency: 10-50ms additional
- High-frequency broadcasts (>100/sec) may saturate inter-node links

---

## 10. Telemetry Events

### 10.1 PubSub Telemetry

```elixir
:telemetry.attach_many(
  "lasso-pubsub-metrics",
  [
    [:phoenix, :pubsub, :broadcast, :start],
    [:phoenix, :pubsub, :broadcast, :stop],
    [:phoenix, :pubsub, :broadcast, :exception]
  ],
  &handle_pubsub_event/4,
  nil
)

defp handle_pubsub_event([:phoenix, :pubsub, :broadcast, :stop], measurements, metadata, _) do
  if measurements[:duration] > 1_000_000 do  # 1ms in native units
    Logger.warning("Slow PubSub broadcast",
      topic: metadata.topic,
      duration_us: div(measurements[:duration], 1000)
    )
  end
end
```

### 10.2 Event Metrics

```elixir
# Add to telemetry metrics
counter("lasso.events.routing_decision.count",
  event_name: [:lasso, :events, :routing_decision],
  tags: [:profile, :result, :source_region]
),
counter("lasso.events.circuit_event.count",
  event_name: [:lasso, :events, :circuit_event],
  tags: [:profile, :chain, :new_state]
)
```

# Blockchain Metadata Cache - Engineering Spec

**Status**: Draft
**Created**: 2025-01-10
**Owner**: Engineering
**Reviewers**: TBD

---

## Executive Summary

This spec defines a centralized blockchain metadata caching system for Lasso RPC that provides real-time access to blockchain state information (block heights, chain IDs, network status) across the system. This system will replace hardcoded estimates in adapter parameter validation, improve failover gap calculation accuracy, and enable advanced features like provider lag detection.

**Key Benefits**:
- **Accurate parameter validation**: Adapters use real-time block heights instead of hardcoded estimates
- **Faster failover**: StreamCoordinator gap calculation uses cached values instead of blocking HTTP requests
- **Provider lag detection**: Track which providers are falling behind and adjust routing accordingly
- **Unified metadata source**: Single source of truth for blockchain state across all modules
- **Low overhead**: Sub-millisecond ETS lookups with async background refresh

---

## Problem Statement

### Current Issues

1. **Hardcoded block height estimates** (`lib/lasso/core/providers/adapters/*.ex:87`)
   ```elixir
   # Merkle, LlamaRPC, Alchemy adapters
   defp estimate_current_block do
     # Ethereum mainnet is ~21M blocks as of Jan 2025
     # This is just for validation, doesn't need to be precise
     21_000_000  # ❌ Inaccurate, outdated over time
   end
   ```
   - Used for `eth_getLogs` block range validation
   - Becomes stale quickly (13s per block on Ethereum)
   - Different chains have different block numbers
   - No way to update without code changes

2. **Blocking HTTP requests during failover** (`lib/lasso/core/streaming/stream_coordinator.ex:729`)
   ```elixir
   defp fetch_head(chain, provider_id) do
     # Blocks during critical failover path
     case RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], ...) do
       {:ok, hex} -> String.to_integer(String.trim_leading(hex, "0x"), 16)
       _ -> 0  # ❌ Falls back to 0 on error
     end
   end
   ```
   - Adds latency to failover process (P99: 200-500ms)
   - Can fail during provider instability
   - No caching between multiple failover attempts

3. **No provider lag detection**
   - Cannot detect when a provider is 10+ blocks behind
   - Routing treats lagging providers same as healthy ones
   - May route to stale provider during critical operations

4. **Scattered block height fetching**
   - ProviderHealthMonitor: Uses `eth_chainId` (doesn't track block height)
   - UpstreamSubscriptionPool: Tracks heights per subscription stream
   - StreamCoordinator: Fetches on-demand during backfill
   - No unified interface or cache

### Success Criteria

✅ Adapters can retrieve current block height with <1ms P99 latency
✅ StreamCoordinator failover uses cached block heights (no blocking HTTP)
✅ Provider lag detection identifies providers >10 blocks behind
✅ System handles multiple chains (Ethereum, Base, Polygon, Arbitrum, etc.)
✅ Cache stays fresh (<30s staleness) under normal operation
✅ Graceful degradation when metadata unavailable (fail open)
✅ Minimal memory overhead (<1MB per chain)

---

## Architecture Design

### System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    Lasso Application                            │
│                                                                 │
│  ┌──────────────┐   ┌──────────────┐   ┌────────────────┐     │
│  │   Adapters   │   │StreamCoord.  │   │  Selection     │     │
│  │              │   │              │   │                │     │
│  │ validate_    │   │ fetch_head() │   │ pick_provider()│     │
│  │ params()     │   │              │   │                │     │
│  └──────┬───────┘   └──────┬───────┘   └────────┬───────┘     │
│         │                  │                     │             │
│         └──────────────────┴─────────────────────┘             │
│                           │                                    │
│                           ▼                                    │
│         ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓                │
│         ┃   BlockchainMetadataCache          ┃  ◄─── New      │
│         ┃                                    ┃                │
│         ┃  • get_block_height(chain)         ┃                │
│         ┃  • get_chain_id(chain)             ┃                │
│         ┃  • get_provider_lag(chain, id)     ┃                │
│         ┃  • get_network_status(chain)       ┃                │
│         ┗━━━━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━┛                │
│                           │                                    │
│         ┌─────────────────┴────────────────┐                  │
│         │                                  │                  │
│         ▼                                  ▼                  │
│  ┌──────────────┐                  ┌──────────────┐          │
│  │   ETS Table  │                  │   Monitor    │  ◄─── New│
│  │   :metadata  │                  │   GenServer  │          │
│  │              │                  │              │          │
│  │ {chain, key} │                  │ - Probes     │          │
│  │    => value  │                  │ - Refreshes  │          │
│  └──────────────┘                  │ - Telemetry  │          │
│                                    └──────┬───────┘          │
│                                           │                  │
│                                           ▼                  │
│                                    ┌──────────────┐          │
│                                    │  Providers   │          │
│                                    │ (eth_block   │          │
│                                    │  Number)     │          │
│                                    └──────────────┘          │
└─────────────────────────────────────────────────────────────────┘
```

### Core Components

#### 1. **BlockchainMetadataCache** (Public API Module)

**File**: `lib/lasso/core/blockchain_metadata_cache.ex`

**Responsibilities**:
- Exposes public API for metadata lookups
- Handles cache misses gracefully (fail open)
- Provides typed return values with error handling

**API**:
```elixir
@spec get_block_height(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
@spec get_block_height!(String.t()) :: non_neg_integer()
@spec get_chain_id(String.t()) :: {:ok, String.t()} | {:error, term()}
@spec get_provider_block_height(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
@spec get_provider_lag(String.t(), String.t()) :: {:ok, integer()} | {:error, term()}
@spec get_network_status(String.t()) :: {:ok, map()} | {:error, term()}
```

#### 2. **BlockchainMetadataMonitor** (GenServer per chain)

**File**: `lib/lasso/core/blockchain_metadata_monitor.ex`

**Responsibilities**:
- Background refresh of metadata at configurable intervals
- Probes multiple providers for block heights
- Computes aggregate "best known height" per chain
- Tracks per-provider block heights and lag
- Emits telemetry for monitoring

**State**:
```elixir
%{
  chain: "ethereum",
  refresh_interval_ms: 10_000,
  last_refresh: ~U[2025-01-10 12:00:00Z],
  provider_heights: %{
    "alchemy" => %{height: 21_234_567, updated_at: ~U[...], latency_ms: 45},
    "infura" => %{height: 21_234_565, updated_at: ~U[...], latency_ms: 52},
    "llamarpc" => %{height: 21_234_567, updated_at: ~U[...], latency_ms: 38}
  },
  best_known_height: 21_234_567,
  chain_id: "0x1"
}
```

**Supervision**: Lives under `ChainSupervisor` (one monitor per chain)

#### 3. **ETS Table** (`:blockchain_metadata`)

**Table**: `:blockchain_metadata` (named table, public read access)

**Schema**:
```elixir
# Primary metadata
{{:chain, "ethereum", :block_height}, 21_234_567}
{{:chain, "ethereum", :chain_id}, "0x1"}
{{:chain, "ethereum", :updated_at}, 1704902400}

# Per-provider metadata
{{:provider, "ethereum", "alchemy", :block_height}, 21_234_567}
{{:provider, "ethereum", "alchemy", :updated_at}, 1704902400}
{{:provider, "ethereum", "alchemy", :latency_ms}, 45}

# Provider lag (computed)
{{:provider, "ethereum", "alchemy", :lag_blocks}, 0}
{{:provider, "ethereum", "infura", :lag_blocks}, -2}  # 2 blocks behind

# Network status
{{:chain, "ethereum", :status}, :healthy}
{{:chain, "ethereum", :stale_threshold_ms}, 30_000}
```

**Table Configuration**:
- Type: `:set` (unique keys)
- Access: `:public` (read), `:protected` (write by monitor only)
- Named: `true` (accessible by name)
- Heir: `none` (monitor owns table, recreated on restart)

---

## Data Structures

### ChainMetadata

```elixir
defmodule Lasso.RPC.ChainMetadata do
  @moduledoc """
  Represents cached metadata for a blockchain network.
  """

  @type t :: %__MODULE__{
    chain: String.t(),
    block_height: non_neg_integer(),
    chain_id: String.t(),
    updated_at: DateTime.t(),
    status: :healthy | :stale | :unknown
  }

  @enforce_keys [:chain, :block_height]
  defstruct [
    :chain,
    :block_height,
    :chain_id,
    :updated_at,
    status: :healthy
  ]
end
```

### ProviderMetadata

```elixir
defmodule Lasso.RPC.ProviderMetadata do
  @moduledoc """
  Represents cached metadata for a specific provider.
  """

  @type t :: %__MODULE__{
    chain: String.t(),
    provider_id: String.t(),
    block_height: non_neg_integer(),
    lag_blocks: integer(),
    updated_at: DateTime.t(),
    latency_ms: non_neg_integer()
  }

  @enforce_keys [:chain, :provider_id, :block_height]
  defstruct [
    :chain,
    :provider_id,
    :block_height,
    lag_blocks: 0,
    :updated_at,
    :latency_ms
  ]
end
```

---

## API Specification

### BlockchainMetadataCache Module

#### `get_block_height/1`

Returns the best known block height for a chain.

```elixir
@spec get_block_height(chain :: String.t()) ::
  {:ok, non_neg_integer()} | {:error, :not_found | :stale}

# Examples
{:ok, 21_234_567} = BlockchainMetadataCache.get_block_height("ethereum")
{:error, :not_found} = BlockchainMetadataCache.get_block_height("unknown_chain")
```

**Behavior**:
- Returns cached value if fresh (<30s stale by default)
- Returns `{:error, :stale}` if data exists but exceeds staleness threshold
- Returns `{:error, :not_found}` if chain not monitored
- Does NOT block or trigger refresh (use monitor's async refresh)

#### `get_block_height!/1`

Bang version that returns value directly or raises.

```elixir
@spec get_block_height!(chain :: String.t()) :: non_neg_integer()

# Examples
21_234_567 = BlockchainMetadataCache.get_block_height!("ethereum")
# Raises ArgumentError if not found
```

**Behavior**:
- Returns integer directly on success
- Raises `ArgumentError` on error
- Use in contexts where cache hit is expected

#### `get_block_height_or_estimate/1`

Returns cached height or falls back to conservative estimate.

```elixir
@spec get_block_height_or_estimate(chain :: String.t()) :: non_neg_integer()

# Examples
21_234_567 = BlockchainMetadataCache.get_block_height_or_estimate("ethereum")
21_000_000 = BlockchainMetadataCache.get_block_height_or_estimate("unknown")
```

**Behavior**:
- Returns cached value if available
- Falls back to chain-specific estimates if cache miss
- NEVER errors (fail open for validation use cases)
- Estimates configured per chain in application config

**Use case**: Adapter parameter validation where graceful degradation is preferred

#### `get_provider_block_height/2`

Returns the last known block height for a specific provider.

```elixir
@spec get_provider_block_height(chain :: String.t(), provider_id :: String.t()) ::
  {:ok, non_neg_integer()} | {:error, term()}

# Examples
{:ok, 21_234_567} = BlockchainMetadataCache.get_provider_block_height("ethereum", "alchemy")
{:error, :not_found} = BlockchainMetadataCache.get_provider_block_height("ethereum", "unknown")
```

**Use case**: Health monitoring, debugging provider-specific issues

#### `get_provider_lag/2`

Returns how many blocks behind the best known height a provider is.

```elixir
@spec get_provider_lag(chain :: String.t(), provider_id :: String.t()) ::
  {:ok, integer()} | {:error, term()}

# Examples
{:ok, 0} = BlockchainMetadataCache.get_provider_lag("ethereum", "alchemy")  # Up to date
{:ok, -5} = BlockchainMetadataCache.get_provider_lag("ethereum", "infura")  # 5 blocks behind
```

**Behavior**:
- Positive lag: Provider ahead (unusual, clock skew or reorg)
- Zero lag: Provider at best known height
- Negative lag: Provider behind by N blocks
- `{:error, :not_found}`: Provider not tracked

**Use case**: Provider selection filtering, health scoring

#### `get_network_status/1`

Returns aggregate network health status for a chain.

```elixir
@spec get_network_status(chain :: String.t()) :: {:ok, map()} | {:error, term()}

# Example
{:ok, %{
  status: :healthy,
  best_known_height: 21_234_567,
  providers_tracked: 3,
  providers_healthy: 3,
  providers_lagging: 0,
  cache_age_ms: 5_234,
  updated_at: ~U[2025-01-10 12:00:00Z]
}} = BlockchainMetadataCache.get_network_status("ethereum")
```

**Use case**: Dashboard, health checks, alerting

---

## Integration Points

### 1. Adapter Parameter Validation

**Current** (`lib/lasso/core/providers/adapters/merkle.ex:88`):
```elixir
defp estimate_current_block do
  21_000_000  # Hardcoded
end
```

**Updated**:
```elixir
alias Lasso.RPC.BlockchainMetadataCache

defp estimate_current_block(chain \\ "ethereum") do
  # Falls back to conservative estimate if cache unavailable
  BlockchainMetadataCache.get_block_height_or_estimate(chain)
end
```

**Benefits**:
- Accurate `eth_getLogs` block range validation
- No breaking changes (fail-open behavior)
- Automatic updates as blockchain progresses

### 2. StreamCoordinator Failover

**Current** (`lib/lasso/core/streaming/stream_coordinator.ex:729`):
```elixir
defp fetch_head(chain, provider_id) do
  # Blocking HTTP request during failover
  case RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], ...) do
    {:ok, hex} -> String.to_integer(String.trim_leading(hex, "0x"), 16)
    _ -> 0
  end
end
```

**Updated**:
```elixir
alias Lasso.RPC.BlockchainMetadataCache

defp fetch_head(chain, _provider_id) do
  # Use cached value (updated every 10s)
  case BlockchainMetadataCache.get_block_height(chain) do
    {:ok, height} -> height
    {:error, _} ->
      # Fallback to blocking request if cache unavailable
      fetch_head_blocking(chain)
  end
end
```

**Benefits**:
- Sub-millisecond failover gap calculation (vs 200-500ms)
- No dependency on failing provider during failover
- Still works if monitor is down (fallback to old behavior)

### 3. Provider Selection (Future Enhancement)

**New capability**:
```elixir
# In Selection.filter_by_health/2
def filter_by_health(channels, chain) do
  max_lag_blocks = 10  # Configurable

  Enum.reject(channels, fn channel ->
    case BlockchainMetadataCache.get_provider_lag(chain, channel.provider_id) do
      {:ok, lag} when lag < -max_lag_blocks -> true  # Reject lagging providers
      _ -> false  # Keep if unknown or healthy
    end
  end)
end
```

**Benefits**:
- Avoid routing to providers >10 blocks behind
- Improve data freshness for time-sensitive operations
- Optional filter (disabled by default)

### 4. ProviderHealthMonitor

**Current** (`lib/lasso/core/providers/provider_health_monitor.ex:66`):
```elixir
HttpClient.request(%{url: http_url, ...}, "eth_chainId", [], ...)
```

**Enhanced**:
```elixir
# Add eth_blockNumber check alongside eth_chainId
HttpClient.request(%{url: http_url, ...}, "eth_blockNumber", [], ...)
```

**Monitor reports to cache**:
```elixir
# After successful health check
case response do
  {:ok, %{"result" => "0x" <> height_hex}} ->
    height = String.to_integer(height_hex, 16)
    BlockchainMetadataMonitor.report_provider_height(
      chain,
      provider_id,
      height,
      latency_ms
    )
end
```

**Benefits**:
- Reuse existing health check infrastructure
- Minimal additional overhead (one extra method)
- Integrates with existing 30s refresh interval

---

## Implementation Phases

### Phase 1: Core Infrastructure (Week 1)

**Goal**: Basic cache functionality operational

**Tasks**:
1. Create `BlockchainMetadataCache` module with ETS table
2. Implement `get_block_height/1` and `get_block_height!/1`
3. Create `BlockchainMetadataMonitor` GenServer
4. Add monitor to `ChainSupervisor` tree
5. Implement basic refresh loop (eth_blockNumber polling)
6. Add telemetry events
7. Write unit tests for cache operations

**Deliverables**:
- [ ] `lib/lasso/core/blockchain_metadata_cache.ex`
- [ ] `lib/lasso/core/blockchain_metadata_monitor.ex`
- [ ] `test/lasso/core/blockchain_metadata_cache_test.exs`
- [ ] `test/lasso/core/blockchain_metadata_monitor_test.exs`
- [ ] Basic integration test showing cache refresh

**Success Criteria**:
- ✅ Monitor refreshes metadata every 10s (configurable)
- ✅ Cache lookups return correct values
- ✅ Telemetry events emitted
- ✅ Tests pass

### Phase 2: Adapter Integration (Week 1)

**Goal**: Remove hardcoded block height estimates

**Tasks**:
1. Add `get_block_height_or_estimate/1` with fallback logic
2. Update `Merkle` adapter to use cache
3. Update `LlamaRPC` adapter to use cache
4. Update `Alchemy` adapter to use cache
5. Configure per-chain fallback estimates
6. Integration tests for parameter validation

**Deliverables**:
- [ ] Updated adapters using metadata cache
- [ ] Configuration for fallback estimates
- [ ] Integration tests for `eth_getLogs` validation

**Success Criteria**:
- ✅ Adapters use real-time block heights when available
- ✅ Graceful fallback when cache unavailable
- ✅ No breaking changes to existing behavior

### Phase 3: StreamCoordinator Integration (Week 2)

**Goal**: Optimize failover performance

**Tasks**:
1. Update `StreamCoordinator.fetch_head/2` to use cache
2. Add fallback to blocking request on cache miss
3. Integration tests for failover scenarios
4. Performance benchmarks (before/after)
5. Battle test for failover under cache unavailability

**Deliverables**:
- [ ] Updated `stream_coordinator.ex`
- [ ] Failover performance benchmarks
- [ ] Battle test scenario

**Success Criteria**:
- ✅ Failover gap calculation <10ms P99 (vs 200-500ms)
- ✅ No failover failures when cache available
- ✅ Graceful fallback when cache unavailable

### Phase 4: Provider Lag Tracking (Week 2)

**Goal**: Enable provider lag detection and filtering

**Tasks**:
1. Implement `get_provider_block_height/2`
2. Implement `get_provider_lag/2`
3. Add provider-specific metadata to ETS schema
4. Update monitor to track per-provider heights
5. Integrate with `ProviderHealthMonitor` (optional)
6. Dashboard visualization of provider lag

**Deliverables**:
- [ ] Provider lag APIs functional
- [ ] Dashboard shows provider lag metrics
- [ ] Telemetry for lagging providers

**Success Criteria**:
- ✅ Track per-provider block heights
- ✅ Compute lag relative to best known height
- ✅ Dashboard visualizes lag in real-time

### Phase 5: Advanced Features (Future)

**Optional enhancements**:
- [ ] Chain ID caching and validation
- [ ] Network status aggregation
- [ ] Provider selection filter based on lag
- [ ] Alerting for providers >20 blocks behind
- [ ] Prometheus metrics export
- [ ] Historical lag tracking

---

## Configuration

### Application Config

```elixir
# config/config.exs
config :lasso, :metadata_cache,
  # How often to refresh metadata per chain
  refresh_interval_ms: 10_000,  # 10 seconds

  # How stale before cache considered invalid
  staleness_threshold_ms: 30_000,  # 30 seconds

  # Fallback estimates when cache unavailable (per chain)
  fallback_estimates: %{
    "ethereum" => 21_000_000,
    "base" => 10_000_000,
    "polygon" => 52_000_000,
    "arbitrum" => 180_000_000
  },

  # Lag detection threshold
  max_acceptable_lag_blocks: 10,

  # Provider selection (number to probe per refresh)
  providers_to_probe: 3,  # Probe top 3 providers each refresh

  # Timeout for block height requests
  probe_timeout_ms: 2_000,

  # Enable telemetry
  telemetry_enabled: true
```

### Runtime Config

```elixir
# config/runtime.exs
config :lasso, :metadata_cache,
  refresh_interval_ms: System.get_env("METADATA_REFRESH_MS", "10000") |> String.to_integer()
```

---

## Telemetry Events

### Cache Operations

```elixir
# Cache hit
:telemetry.execute([:lasso, :metadata, :cache, :hit], %{count: 1}, %{
  chain: "ethereum",
  key: :block_height
})

# Cache miss
:telemetry.execute([:lasso, :metadata, :cache, :miss], %{count: 1}, %{
  chain: "ethereum",
  key: :block_height,
  reason: :not_found
})

# Cache stale
:telemetry.execute([:lasso, :metadata, :cache, :stale], %{age_ms: 45_000}, %{
  chain: "ethereum",
  threshold_ms: 30_000
})
```

### Monitor Operations

```elixir
# Refresh started
:telemetry.execute([:lasso, :metadata, :refresh, :started], %{count: 1}, %{
  chain: "ethereum"
})

# Refresh completed
:telemetry.execute([:lasso, :metadata, :refresh, :completed], %{
  duration_ms: 234,
  providers_probed: 3,
  providers_successful: 3
}, %{chain: "ethereum"})

# Provider height updated
:telemetry.execute([:lasso, :metadata, :provider, :height_updated], %{
  height: 21_234_567,
  latency_ms: 45
}, %{
  chain: "ethereum",
  provider_id: "alchemy"
})

# Provider lag detected
:telemetry.execute([:lasso, :metadata, :provider, :lag_detected], %{
  lag_blocks: -15
}, %{
  chain: "ethereum",
  provider_id: "infura"
})
```

---

## Error Handling

### Cache Read Errors

**Scenario**: Cache lookup returns error

**Behavior**:
- `get_block_height/1` → `{:error, reason}`
- `get_block_height!/1` → Raises `ArgumentError`
- `get_block_height_or_estimate/1` → Returns fallback estimate

**Examples**:
```elixir
# Not found
{:error, :not_found} = get_block_height("unknown_chain")

# Stale data
{:error, :stale} = get_block_height("ethereum")
# (if data older than staleness_threshold_ms)
```

### Monitor Refresh Failures

**Scenario**: Provider probing fails

**Behavior**:
- Log warning with provider ID and error
- Emit telemetry event
- Continue with remaining providers
- Cache retains last known good value
- Status remains `:healthy` if cache not stale

**Example**:
```elixir
# Provider timeout
Logger.warning("Metadata probe failed",
  chain: "ethereum",
  provider_id: "alchemy",
  error: :timeout
)

:telemetry.execute([:lasso, :metadata, :probe, :failed], %{count: 1}, %{
  chain: "ethereum",
  provider_id: "alchemy",
  reason: :timeout
})
```

### Monitor Crash Recovery

**Scenario**: Monitor GenServer crashes

**Behavior**:
- Supervisor restarts monitor automatically
- ETS table is recreated (empty)
- Monitor begins fresh refresh cycle
- Callers see `{:error, :not_found}` until first refresh
- Adapters fall back to estimates (fail open)

**Recovery Time**: ~10 seconds (one refresh interval)

---

## Performance Characteristics

### Cache Read Performance

**Target**: <1ms P99 latency

**Expected**:
- ETS `:set` table lookup: ~1-2μs
- Pattern matching on result: ~1μs
- Staleness check: ~1μs
- Total: <5μs P99 (single-digit microseconds)

**Benchmark**:
```elixir
# test/benchmark/metadata_cache_bench.exs
Benchee.run(%{
  "get_block_height" => fn ->
    BlockchainMetadataCache.get_block_height("ethereum")
  end
}, time: 10, warmup: 2)

# Expected output:
# Name                      ips        average  deviation  median  99th %
# get_block_height      500.00 K        2.00 μs    ±10%    1.90 μs  3.00 μs
```

### Monitor Refresh Performance

**Target**: Complete refresh in <2 seconds

**Expected**:
- Probe 3 providers concurrently: ~500ms P95
- ETS write operations: <100μs total
- Telemetry events: <1ms
- Total refresh: <600ms P95

**Behavior**:
- Refresh runs every 10s
- Overlapping refreshes prevented (skip if previous still running)
- Non-blocking (runs in monitor process)

### Memory Overhead

**Target**: <1MB per chain

**Expected**:
- ETS table: ~10KB per chain (10 entries × ~1KB each)
- Monitor GenServer state: ~5KB
- Total per chain: <20KB
- 5 chains: <100KB total

**Scaling**:
- Linear with number of chains
- Constant with number of providers (only probe top 3)

---

## Testing Strategy

### Unit Tests

**File**: `test/lasso/core/blockchain_metadata_cache_test.exs`

```elixir
defmodule Lasso.RPC.BlockchainMetadataCacheTest do
  use ExUnit.Case, async: false  # ETS table requires serial tests

  describe "get_block_height/1" do
    test "returns cached value when fresh"
    test "returns error when not found"
    test "returns error when stale"
  end

  describe "get_block_height!/1" do
    test "returns value on success"
    test "raises on error"
  end

  describe "get_block_height_or_estimate/1" do
    test "returns cached value when available"
    test "returns estimate when cache miss"
    test "returns estimate when stale"
  end

  describe "get_provider_lag/2" do
    test "calculates lag correctly"
    test "handles provider ahead of best known"
    test "returns error when provider not tracked"
  end
end
```

**File**: `test/lasso/core/blockchain_metadata_monitor_test.exs`

```elixir
defmodule Lasso.RPC.BlockchainMetadataMonitorTest do
  use ExUnit.Case, async: false

  describe "refresh cycle" do
    test "probes providers and updates cache"
    test "handles provider failures gracefully"
    test "emits telemetry events"
    test "computes best known height correctly"
  end

  describe "provider lag tracking" do
    test "detects lagging providers"
    test "updates lag in cache"
  end

  describe "crash recovery" do
    test "recreates ETS table on restart"
    test "resumes refresh after restart"
  end
end
```

### Integration Tests

**File**: `test/integration/metadata_cache_integration_test.exs`

```elixir
defmodule Lasso.MetadataCacheIntegrationTest do
  use Lasso.Testing.IntegrationHelper

  test "adapter uses cached block height for validation" do
    # Setup chain with metadata cache
    # Make eth_getLogs request with "latest" block
    # Verify adapter used cached value (not hardcoded)
  end

  test "stream coordinator uses cache during failover" do
    # Setup subscription with active provider
    # Kill provider to trigger failover
    # Verify gap calculation used cached height (fast)
  end

  test "cache refresh updates provider lag metrics" do
    # Setup providers at different heights
    # Wait for refresh
    # Verify lag calculated correctly
  end
end
```

### Battle Tests

**File**: `test/battle/metadata_cache_chaos_test.exs`

```elixir
defmodule Lasso.Battle.MetadataCacheChaosTest do
  use Lasso.Battle.ScenarioHelper

  test "failover works when cache unavailable" do
    Scenario.new("Failover with cache down")
    |> Scenario.setup_chain(:ethereum, providers: [:alchemy, :infura])
    |> Scenario.run_workload(duration: 60_000, method: "eth_subscribe")
    |> Scenario.inject_chaos(:kill_provider, target: :metadata_monitor, delay: 10_000)
    |> Scenario.inject_chaos(:kill_provider, target: :alchemy, delay: 20_000)
    |> Scenario.verify_slo(success_rate: 0.99, max_downtime_ms: 5_000)
  end

  test "cache refresh handles provider instability" do
    Scenario.new("Cache refresh under chaos")
    |> Scenario.setup_chain(:ethereum, providers: [:a, :b, :c])
    |> Scenario.inject_chaos(:flap_provider, target: :a, interval: 15_000)
    |> Scenario.run_for(duration: 120_000)
    |> Scenario.verify(fn ->
      # Cache remains functional despite provider flapping
      assert {:ok, _height} = BlockchainMetadataCache.get_block_height("ethereum")
    end)
  end
end
```

---

## Migration Strategy

### Backward Compatibility

**Goal**: Zero breaking changes

**Approach**:
1. Add new cache system alongside existing code
2. Update adapters to use `get_block_height_or_estimate/1` (fails open)
3. Update StreamCoordinator to use cache with fallback
4. All changes gracefully degrade if cache unavailable

**No changes required**:
- Existing adapter behavior unchanged if cache miss
- StreamCoordinator falls back to blocking request
- Provider selection unaffected (lag filtering optional)

### Rollout Plan

**Stage 1: Deploy cache infrastructure** (Phase 1)
- Deploy `BlockchainMetadataCache` and `BlockchainMetadataMonitor`
- Monitor telemetry to verify refresh working
- No functional changes yet

**Stage 2: Enable adapter integration** (Phase 2)
- Deploy adapter updates using cache
- Monitor for errors or unexpected behavior
- Can rollback by reverting adapter changes only

**Stage 3: Enable failover optimization** (Phase 3)
- Deploy StreamCoordinator updates
- Monitor failover latency improvements
- Can rollback independently of adapters

**Stage 4: Enable lag tracking** (Phase 4)
- Deploy provider lag tracking
- Optionally enable lag-based filtering
- Monitor impact on provider selection

### Rollback Plan

**If issues detected**:

1. **Adapter issues**: Revert adapter changes, hardcoded estimates still work
2. **Failover issues**: Revert StreamCoordinator, blocking requests still work
3. **Monitor crashes**: Supervisor keeps restarting, cache falls back to estimates
4. **Complete rollback**: Remove monitor from supervision tree, all code degrades gracefully

**No data loss risk**: Cache is ephemeral, no persistent state

---

## Open Questions

1. **Should we cache chain ID in addition to block height?**
   - Use case: Validate user requests against correct chain
   - Cost: Minimal (one extra ETS entry per chain)
   - Decision: Yes, add in Phase 1

2. **Should lag-based provider filtering be enabled by default?**
   - Risk: May exclude valid but slightly behind providers
   - Benefit: Improves data freshness
   - Decision: Add in Phase 4 but disabled by default (opt-in via config)

3. **Should monitor probe all providers or just top N?**
   - All providers: More accurate lag tracking, higher overhead
   - Top N: Efficient, covers most traffic
   - Decision: Top 3 by default (configurable)

4. **How to handle chain reorgs?**
   - Block heights may decrease temporarily
   - Decision: Accept reorg risk (ephemeral cache, refreshes quickly), log telemetry for deep reorgs

5. **Should we expose HTTP endpoint for cache status?**
   - Use case: Health checks, debugging
   - Decision: Yes, add to dashboard in Phase 4

---

## Success Metrics

### Functionality Metrics

- ✅ **Cache hit rate** >95% during normal operation
- ✅ **Cache staleness** <30s P99
- ✅ **Adapter accuracy** eliminates hardcoded estimates in 100% of cases
- ✅ **Failover performance** <10ms P99 gap calculation (vs 200-500ms baseline)

### Reliability Metrics

- ✅ **No breaking changes** to existing behavior
- ✅ **Graceful degradation** when cache unavailable
- ✅ **Monitor uptime** >99.9% (supervisor restarts on crash)
- ✅ **Zero data loss** (ephemeral cache, no persistence)

### Performance Metrics

- ✅ **Read latency** <1ms P99 for cache lookups
- ✅ **Refresh latency** <2s P95 for full chain refresh
- ✅ **Memory overhead** <1MB per chain
- ✅ **CPU overhead** <1% during refresh

### Operational Metrics

- ✅ **Telemetry coverage** 100% of cache operations
- ✅ **Dashboard visibility** real-time provider lag display
- ✅ **Alert coverage** for monitor failures and stale cache
- ✅ **Documentation** complete API docs and integration examples

---

## Appendix A: Example Usage

### Adapter Validation

```elixir
defmodule Lasso.RPC.Providers.Adapters.Merkle do
  alias Lasso.RPC.BlockchainMetadataCache

  def validate_params("eth_getLogs", [%{"fromBlock" => from, "toBlock" => to}], _t, ctx) do
    chain = ctx.chain || "ethereum"
    current_block = BlockchainMetadataCache.get_block_height_or_estimate(chain)

    with {:ok, from_num} <- parse_block(from, current_block),
         {:ok, to_num} <- parse_block(to, current_block),
         true <- (to_num - from_num) <= @max_block_range do
      :ok
    else
      false -> {:error, {:param_limit, "max #{@max_block_range} blocks"}}
      err -> err
    end
  end
end
```

### Failover Gap Calculation

```elixir
defmodule Lasso.RPC.StreamCoordinator do
  alias Lasso.RPC.BlockchainMetadataCache

  defp fetch_head(chain, _provider_id) do
    case BlockchainMetadataCache.get_block_height(chain) do
      {:ok, height} ->
        Logger.debug("Using cached block height for failover",
          chain: chain, height: height)
        height

      {:error, reason} ->
        Logger.warning("Cache miss during failover, using blocking request",
          chain: chain, reason: reason)
        fetch_head_blocking(chain)
    end
  end

  defp fetch_head_blocking(chain) do
    # Fallback to existing blocking implementation
    case RequestPipeline.execute_via_channels(chain, "eth_blockNumber", []) do
      {:ok, "0x" <> hex} -> String.to_integer(hex, 16)
      _ -> 0
    end
  end
end
```

### Provider Lag Filtering

```elixir
defmodule Lasso.RPC.Selection do
  alias Lasso.RPC.BlockchainMetadataCache

  def filter_lagging_providers(channels, chain, opts \\ []) do
    max_lag = Keyword.get(opts, :max_lag_blocks, 10)

    Enum.reject(channels, fn channel ->
      case BlockchainMetadataCache.get_provider_lag(chain, channel.provider_id) do
        {:ok, lag} when lag < -max_lag ->
          Logger.info("Filtering lagging provider",
            chain: chain,
            provider_id: channel.provider_id,
            lag_blocks: lag)
          true

        _ ->
          false
      end
    end)
  end
end
```

---

## Appendix B: Alternative Approaches Considered

### Alternative 1: Piggyback on ProviderHealthMonitor

**Approach**: Extend existing health monitor to track block heights

**Pros**:
- Reuses existing infrastructure
- No new GenServer processes
- Single source of provider health data

**Cons**:
- ProviderHealthMonitor tied to per-provider supervision
- Not chain-scoped (provider monitor may not know chain context)
- Mixing health checks with metadata caching (violates single responsibility)
- Harder to test independently

**Decision**: Rejected - prefer dedicated monitor for clean separation

### Alternative 2: Pull-Based Cache (No Background Refresh)

**Approach**: Fetch block heights on-demand, cache for TTL

**Pros**:
- Simpler implementation (no GenServer)
- No background overhead when idle
- Lazy initialization

**Cons**:
- First request after cache expiry pays latency penalty
- Thundering herd problem (multiple requests refresh simultaneously)
- No proactive staleness detection
- Harder to track provider lag (requires probing all providers on every request)

**Decision**: Rejected - background refresh provides more consistent performance

### Alternative 3: Integrate with Benchmarking System

**Approach**: Store block heights in BenchmarkStore ETS table

**Pros**:
- Reuses existing ETS table
- Consolidated metrics storage

**Cons**:
- Couples metadata to benchmarking (conceptually separate concerns)
- BenchmarkStore schema not designed for metadata
- Harder to query (benchmark store has complex composite keys)

**Decision**: Rejected - metadata cache deserves dedicated storage

---

## Appendix C: Future Enhancements

### Chain Metadata Beyond Block Height

Expand cache to include:
- **Chain ID**: Validate requests target correct chain
- **Gas price**: Fast estimates without provider request
- **Base fee**: EIP-1559 chains, used for gas estimation
- **Network status**: Upgrade status, hard fork detection

### Historical Lag Tracking

Store provider lag time series:
- Detect chronic lagging providers
- Identify lag patterns (time of day, load correlation)
- Feed into provider scoring algorithm

### Cross-Region Consensus

For multi-region deployments:
- Share metadata across Lasso instances
- Detect regional provider issues
- Improve global routing decisions

### Smart Contract Event Cache

Extend pattern to cache smart contract state:
- Token prices (Uniswap, Chainlink)
- ENS name resolutions
- Contract ABIs

---

**End of Specification**

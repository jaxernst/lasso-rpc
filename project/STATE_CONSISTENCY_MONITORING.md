# State Consistency & Hidden Issues Analysis

**Date:** 2025-01-10 (Updated: 2025-01-18)
**Scope:** Deep dive into blockchain state consistency, reorgs, and other critical infrastructure issues for Lasso RPC proxy
**Status:** Design document - basic probing implemented, advanced features pending

---

## Implementation Status

**Implemented (Jan 2025):**
- ✅ Provider probing via `ProviderProbe` (periodic `eth_blockNumber` checks)
- ✅ Consensus height calculation via `ChainState` (lazy on-demand calculation)
- ✅ Provider lag tracking in ProviderPool ETS
- ✅ Basic telemetry for probe cycles

**Pending Implementation:**
- ❌ Lag-aware provider selection (filtering providers >N blocks behind)
- ❌ Reorg detection and handling
- ❌ Finality-aware routing ("safe" vs "finalized" blocks)
- ❌ Chain ID validation in selection logic

---

## Executive Summary

**Your concern is valid and represents a real production risk.** The issue of routing requests to nodes with inconsistent state is a well-documented problem in blockchain RPC infrastructure. However, you're **well-positioned to solve this** with your current architecture - you already have most of the primitives needed.

**Good News:**
- You're already tracking provider block heights and lag via `ProviderProbe` + `ChainState`
- Your architecture has the foundation for solving this (see "Best Sync Strategy" in your roadmap)
- You have WebSocket gap-filling during failover, which handles some consistency issues
- Provider lag detection is already implemented and stored in ProviderPool

**Bad News:**
- This system is not currently integrated into provider selection
- Reorg detection and handling is completely absent
- You could serve stale data or inconsistent states during rapid failovers
- Several related "unknown unknowns" exist (detailed below)

---

## Part 1: The State Consistency Problem

### 1.1 What is the Problem?

**Temporal Skew Between Providers:**

Different RPC providers are at different block heights at any given moment due to:

1. **Network propagation delays** - Blocks take 100-500ms to propagate across the network
2. **Node synchronization differences** - Some nodes sync faster than others
3. **Provider infrastructure** - Different node clients, geographic distribution, peering relationships
4. **Load-based delays** - Heavily loaded nodes may lag in processing new blocks

**Example Scenario:**

```
Time T: Client requests eth_getBalance(address, "latest")
  Provider A: Block 21,845,678 (most recent)
  Provider B: Block 21,845,676 (2 blocks behind)
  Provider C: Block 21,845,670 (8 blocks behind)
```

If you route to Provider C, you get **8-block-old state**. For many applications, this is unacceptable.

### 1.2 When Does This Matter?

**Critical Impact Scenarios:**

1. **DeFi Trading/Arbitrage**
   - Price data must be current within 1-2 blocks
   - Stale prices = failed trades or bad execution

2. **NFT Minting**
   - Ownership queries must reflect latest state
   - Stale data = double-mint attempts

3. **Multi-Transaction Workflows**
   - Transaction 1 submitted via Provider A (block N)
   - Query via Provider B (block N-5) shows transaction hasn't landed
   - Client logic breaks, retry logic triggers incorrectly

4. **Smart Contract State Reads**
   - Reading contract storage that was just updated
   - Stale reads return old values, breaking application logic

**Low Impact Scenarios:**

- Historical queries (eth_getBlockByNumber with specific block number)
- Archive node queries (old events, past balances)
- Gas price estimation (tolerate 1-2 block lag)

### 1.3 The Reorg Problem

**What is a Reorg?**

A blockchain reorganization occurs when the network consensus switches to a different chain fork, causing previously confirmed blocks to be replaced.

**Reorg Characteristics (Ethereum Post-Merge):**

- **Common**: 1-2 block reorgs happen frequently (~daily) due to network latency
- **Rare**: 3+ block reorgs are uncommon but possible
- **Finality**: Blocks become "finalized" after ~2 epochs (12.8 minutes)
- **Safe blocks**: Lower probability of reorg after 1 epoch (6.4 minutes)

**How Reorgs Break Your Proxy:**

```
Scenario:
1. Provider A sees block 100 with tx_hash ABC
2. Your client queries via Provider A: "Did tx ABC confirm?" → Yes (block 100)
3. Network reorgs: block 100 replaced with alternate block 100'
4. Provider B now at block 101' (different chain)
5. Your client queries via Provider B: "Did tx ABC confirm?" → No (doesn't exist)
```

**Your System's Vulnerability:**

Currently, Lasso has **no reorg detection**. If you failover from Provider A to Provider B during a reorg, clients may see:
- Transactions "disappearing" from confirmed to pending
- Balance changes reversing
- Event logs appearing/disappearing

---

## Part 2: Current State of Your Architecture

### 2.1 What You Have (Good Foundation)

#### ProviderProbe + ChainState ✅ (Implemented Jan 2025)
**Files:**
- `lib/lasso/core/providers/provider_probe.ex` - Probe execution
- `lib/lasso/core/chain_state.ex` - Consensus calculation
- `lib/lasso/core/providers/provider_pool.ex` - State storage

```elixir
# ProviderProbe: Executes periodic probes (every 12s default)
# - Probes all providers concurrently via eth_blockNumber
# - Reports results to ProviderPool (fire-and-forget)
# - Tracks latency and errors

# ChainState: On-demand consensus calculation
{:ok, consensus_height} = ChainState.consensus_height("ethereum")
# => {:ok, 21_845_678}  # Max height from recent probes (<1ms)

# Provider lag lookup
{:ok, lag} = ChainState.provider_lag("ethereum", "alchemy")
# => {:ok, -5}  # 5 blocks behind consensus
```

**What this gives you:**
- Real-time block height tracking per provider
- Lazy consensus calculation (no stale cache issues)
- Provider lag detection relative to consensus
- Fast lookups (<1ms consensus, <5μs lag)

**What it DOESN'T give you:**
- Integration with provider selection (lag data not used in routing)
- Reorg detection (height alone doesn't detect chain forks)
- Chain ID validation (not enforced during selection)
- Finality awareness (no concept of "safe" vs "finalized" blocks)

#### Provider Lag Data ✅
```elixir
ChainState.provider_lag("ethereum", "alchemy")
# => {:ok, -5}  (5 blocks behind consensus)
```

This exists but is **not used in selection logic** (Selection.ex doesn't check lag).

### 2.2 What You're Missing (Critical Gaps)

#### 1. Lag-Aware Provider Selection ❌
**File:** `lib/lasso/core/selection/selection.ex`

Current selection strategies (`:fastest`, `:cheapest`, `:priority`, `:round_robin`) **do not consider block height or lag**.

**Implication:** You can route to a provider 50 blocks behind and serve stale data.

#### 2. Reorg Detection & Handling ❌
No reorg detection exists in the codebase. Search results: 0 occurrences of "reorg" or "reorganization".

**Needed mechanisms:**
- Monitor for block hash changes at same height
- Detect when block N's parent hash doesn't match block N-1
- Invalidate cached data during reorgs
- Re-query from consistent provider set

#### 3. Finality Awareness ❌
Ethereum has three block states:
- **Latest** - Most recent block (can be reorged)
- **Safe** - Low probability of reorg (~1 epoch old)
- **Finalized** - Guaranteed permanent (~2 epochs old)

Your system treats all blocks as "latest" without finality guarantees.

**Methods to track finality:**
```json
eth_getBlockByNumber("safe", false)
eth_getBlockByNumber("finalized", false)
```

Currently not fetched or cached.

#### 4. Chain ID Enforcement ❌
You cache `chain_id` but don't validate it during selection.

**Attack vector:** Provider misconfiguration or malicious actor serves wrong chain.

**Example:**
```elixir
# Provider "ethereum_rogue" configured for mainnet
# But actually connected to Sepolia testnet
# Your proxy routes mainnet requests → returns testnet data
```

#### 5. Quorum Validation ❌
For critical queries, you should validate responses across multiple providers.

**Example (DeFi safety):**
```elixir
# Query eth_getBalance from 3 providers
# Require 2/3 agreement before returning result
# Protects against single-provider failures or stale data
```

---

## Part 3: Real-World Impact Analysis

### 3.1 Likelihood Assessment

**Probability of encountering state inconsistency issues:**

| Scenario | Likelihood | Impact | Severity |
|----------|-----------|--------|----------|
| Serving data 1-2 blocks old | **High** (daily) | Low-Medium | ⚠️ Medium |
| Serving data 5+ blocks old | Medium (weekly) | High | 🔴 Critical |
| Failover during reorg | Low (monthly) | Critical | 🔴 Critical |
| Wrong chain ID served | Very Low | Catastrophic | 💀 Critical |
| Provider returning inconsistent data | Low | High | 🔴 Critical |

### 3.2 Example Failure Scenarios

#### Scenario 1: DeFi Price Arbitrage Failure
```
1. User monitors USDC/ETH price via your proxy
2. Price drops due to large trade (block 21,845,678)
3. User submits arbitrage tx via your proxy
4. Your proxy routes query to lagging provider (block 21,845,670)
5. Query returns OLD price (pre-trade)
6. User's arbitrage logic fails, loses gas on failed tx
```

**Current likelihood:** High if using round-robin or cheapest strategies.

#### Scenario 2: Transaction Confirmation Race
```
1. User submits tx via Provider A → mined in block 100
2. User polls tx status via your proxy
3. First poll: Routes to Provider A → "confirmed" ✅
4. Provider A fails, you failover to Provider B (lagging by 3 blocks, at block 97)
5. Second poll: Routes to Provider B → "pending" ⏳
6. User's app thinks tx reverted, triggers retry logic
7. Duplicate transaction submitted
```

**Current likelihood:** Medium during provider failovers.

#### Scenario 3: Reorg Data Inconsistency
```
1. NFT mint transaction confirmed in block 100 via Provider A
2. Network reorgs: block 100 replaced with 100'
3. Your gap-filling logic backfills blocks 98-100 from Provider B
4. Block 100 from Provider B has different transactions
5. Client sees: "NFT mint succeeded" → failover → "NFT mint missing"
6. Client retries mint → double-mint or failure
```

**Current likelihood:** Low but catastrophic when it happens.

---

## Part 4: Solution Roadmap

### 4.1 Phase 1: Immediate Fixes (P0 - 2 weeks)

#### A. Integrate Lag Filtering into Selection
**File:** `lib/lasso/core/selection/selection.ex`

```elixir
# Add lag filtering to candidates_ready/2 in ProviderPool
defp candidates_ready(state, filters) do
  max_lag = Map.get(filters, :max_lag_blocks, 2)  # Default: 2 blocks

  state.active_providers
  |> Enum.map(&Map.get(state.providers, &1))
  |> Enum.filter(fn p ->
    case BlockchainMetadataCache.get_provider_lag(state.chain_name, p.id) do
      {:ok, lag} when lag >= -max_lag -> true  # -2 or better
      _ -> false  # Unknown lag or too far behind
    end
  end)
  # ... existing transport and circuit breaker filters
end
```

**Configuration:**
```elixir
# config/config.exs
config :lasso, :selection,
  default_max_lag_blocks: 2,
  method_overrides: %{
    "eth_getBalance" => %{max_lag_blocks: 1},
    "eth_gasPrice" => %{max_lag_blocks: 5},  # Gas price can tolerate lag
    "eth_getLogs" => %{max_lag_blocks: 0}     # Historical queries need consistency
  }
```

**Impact:** Prevents routing to severely lagging providers.

#### B. Add Chain ID Validation
**File:** `lib/lasso/core/providers/provider_pool.ex`

```elixir
def validate_chain_id(chain, provider_id) do
  expected = ConfigStore.get_chain_id(chain)

  case BlockchainMetadataCache.get_chain_id(chain) do
    {:ok, ^expected} -> :ok
    {:ok, wrong} ->
      Logger.error("Chain ID mismatch",
        chain: chain,
        provider: provider_id,
        expected: expected,
        got: wrong
      )
      {:error, :chain_id_mismatch}
    {:error, _} = err -> err
  end
end
```

**When to validate:**
- During provider registration
- Periodically during health checks
- Before routing critical methods (transfers, contract calls)

#### C. Expose Lag Metrics in Dashboard
**File:** `lib/lasso_web/dashboard/dashboard.ex`

Add provider lag visualization:
- Green: 0-1 blocks behind
- Yellow: 2-5 blocks behind
- Red: 6+ blocks behind
- Gray: Unknown/unhealthy

### 4.2 Phase 2: Reorg Detection (P1 - 4 weeks)

#### A. Track Block Hashes
**New module:** `lib/lasso/core/caching/block_hash_tracker.ex`

```elixir
defmodule Lasso.RPC.BlockHashTracker do
  @moduledoc """
  Tracks recent block hashes to detect reorgs.

  Maintains a rolling window of recent blocks (last 100) per chain.
  Detects reorgs by comparing parent hashes.
  """

  use GenServer

  @type block_info :: %{
    number: non_neg_integer(),
    hash: String.t(),
    parent_hash: String.t(),
    timestamp: non_neg_integer(),
    provider_id: String.t()
  }

  def track_block(chain, block_info) do
    GenServer.cast(via(chain), {:track_block, block_info})
  end

  def detect_reorg(chain, new_block) do
    GenServer.call(via(chain), {:check_reorg, new_block})
  end

  defp check_reorg_internal(state, new_block) do
    prev_block = get_block_at_height(state, new_block.number - 1)

    cond do
      is_nil(prev_block) ->
        :no_data

      prev_block.hash != new_block.parent_hash ->
        {:reorg_detected,
         old_hash: prev_block.hash,
         new_parent: new_block.parent_hash,
         depth: 1}

      true ->
        :no_reorg
    end
  end
end
```

#### B. Integrate with ProviderProbe
```elixir
# In provider_probe.ex probe_provider/3
defp probe_provider(chain, provider, sequence) do
  # ... existing eth_blockNumber probe

  # Add block hash tracking
  case fetch_recent_block_with_hash(channel) do
    {:ok, block} ->
      case BlockHashTracker.detect_reorg(chain, block) do
        {:reorg_detected, details} ->
          handle_reorg_detected(chain, provider.id, details)

        :no_reorg ->
          BlockHashTracker.track_block(chain, block)
      end
  end
end
```

#### C. Reorg Response Strategy
```elixir
defp handle_reorg_detected(chain, provider_id, details) do
  Logger.warning("Reorg detected",
    chain: chain,
    provider: provider_id,
    depth: details.depth,
    old_hash: details.old_hash
  )

  # 1. Emit telemetry
  :telemetry.execute([:lasso, :reorg, :detected], %{depth: details.depth}, %{
    chain: chain,
    provider_id: provider_id
  })

  # 2. Trigger consensus recalculation
  # ChainState automatically recalculates on next call (no caching)

  # 3. Trigger consistency check across providers
  # (ensure all providers see same chain)
  spawn(fn -> verify_provider_consensus(chain) end)

  # 4. Optional: Pause routing briefly while providers sync
  # ProviderPool.enter_reorg_cooldown(chain, duration_ms: 3000)
end
```

### 4.3 Phase 3: Finality Awareness (P1 - 6 weeks)

#### A. Track Safe & Finalized Heads
**Extend ProviderProbe:**

```elixir
defp probe_provider(chain, provider, sequence) do
  # Existing: eth_blockNumber (latest)

  # Add:
  probes = [
    {:latest, "eth_getBlockByNumber", ["latest", false]},
    {:safe, "eth_getBlockByNumber", ["safe", false]},
    {:finalized, "eth_getBlockByNumber", ["finalized", false]}
  ]

  results = Task.async_stream(probes, &execute_probe/1)

  # Cache all three heads
  BlockchainMetadataCache.put_block_height(chain, :latest, latest_num)
  BlockchainMetadataCache.put_block_height(chain, :safe, safe_num)
  BlockchainMetadataCache.put_block_height(chain, :finalized, finalized_num)
end
```

#### B. Finality-Aware Selection
```elixir
# In Selection.select_channels/3
defp apply_finality_filter(channels, method, chain) do
  finality_requirement = get_method_finality(method)

  case finality_requirement do
    :latest -> channels  # No filtering

    :safe ->
      safe_head = BlockchainMetadataCache.get_block_height(chain, :safe)
      Enum.filter(channels, fn ch ->
        provider_head = get_provider_head(chain, ch.provider_id)
        provider_head >= safe_head - 1  # Within 1 block of safe
      end)

    :finalized ->
      finalized_head = BlockchainMetadataCache.get_block_height(chain, :finalized)
      Enum.filter(channels, fn ch ->
        provider_head = get_provider_head(chain, ch.provider_id)
        provider_head >= finalized_head  # Must be at or past finalized
      end)
  end
end

defp get_method_finality(method) do
  case method do
    "eth_sendRawTransaction" -> :safe      # Wait for safety
    "eth_getTransactionReceipt" -> :safe   # Ensure tx is stable
    "eth_call" -> :latest                  # Read latest state
    "eth_getBalance" -> :latest            # Balance queries tolerate reorgs
    _ -> :latest
  end
end
```

#### C. Configuration Per Method
```yaml
# config/chains.yml
ethereum:
  chain_id: 1
  finality:
    safe_block_lag: 32    # Blocks behind latest considered "safe"
    finalized_block_lag: 64
  method_policies:
    eth_sendRawTransaction:
      finality: safe
      max_lag_blocks: 1
    eth_getTransactionReceipt:
      finality: safe
      max_lag_blocks: 2
```

### 4.4 Phase 4: Quorum Validation (P2 - 8 weeks)

For critical methods, query multiple providers and validate consensus.

```elixir
defmodule Lasso.RPC.QuorumValidator do
  @doc """
  Execute query across N providers, require M/N agreement.
  """
  def quorum_request(chain, method, params, opts) do
    quorum_size = Keyword.get(opts, :quorum_size, 3)
    threshold = Keyword.get(opts, :threshold, 2)  # 2 of 3

    # Select N providers
    channels = Selection.select_channels(chain, method,
      limit: quorum_size,
      strategy: :fastest
    )

    # Query all in parallel
    results =
      channels
      |> Task.async_stream(fn ch ->
        Channel.request(ch, build_request(method, params), 5_000)
      end, timeout: 6_000)
      |> Enum.to_list()

    # Find consensus
    case find_consensus(results, threshold) do
      {:consensus, value} -> {:ok, value}
      {:no_consensus, disagreements} ->
        Logger.warning("Quorum failed", disagreements: disagreements)
        {:error, :no_consensus}
    end
  end

  defp find_consensus(results, threshold) do
    # Group by response value
    groups =
      results
      |> Enum.filter(&match?({:ok, {:ok, _}}, &1))
      |> Enum.group_by(fn {:ok, {:ok, val}} -> val end)

    # Find majority
    groups
    |> Enum.find(fn {_val, list} -> length(list) >= threshold end)
    |> case do
      {value, _} -> {:consensus, value}
      nil -> {:no_consensus, groups}
    end
  end
end
```

**When to use quorum:**
- High-value transactions (`eth_sendRawTransaction` > $X threshold)
- Balance checks before transfers
- Critical smart contract reads
- Configurable per method + per client

---

## Part 5: Other Hidden Issues (Unknown Unknowns)

### 5.1 MEV & Front-Running Exposure

**Problem:** When you forward `eth_sendRawTransaction` to providers, you expose transaction data to multiple parties.

**Risk:**
- Public RPC providers may sell transaction data to MEV searchers
- Transaction can be front-run before mining
- User suffers worse execution prices

**Your exposure:**
- If you failover a `sendRawTransaction` call, you send same tx to multiple providers
- Even successful sends expose tx to multiple parties

**Mitigation:**
```elixir
# In RequestPipeline for sendRawTransaction
defp execute_send_transaction(chain, params, opts) do
  # 1. Pick single best provider (no failover)
  # 2. Use private RPC provider if available
  # 3. Never retry/failover (exposes tx twice)
  # 4. Consider flashbots integration for sensitive txs

  case Selection.select_channels(chain, "eth_sendRawTransaction",
    strategy: :priority,  # Use most trusted provider
    limit: 1,             # Only one provider
    prefer_private: true  # Skip public RPCs
  ) do
    [channel] -> Channel.request(channel, rpc_request, 30_000)
    [] -> {:error, :no_trusted_provider}
    _many -> {:error, :expected_single_provider}
  end
end
```

### 5.2 Rate Limit Amplification

**Problem:** Your proxy multiplexes many clients → few upstream providers.

**Risk:**
- Client A uses 100 req/s legitimately
- Client B uses 100 req/s legitimately
- You forward 200 req/s to Provider X → rate limit triggered
- Both clients affected by shared limit

**Current state:** You handle 429s with backoff, but don't proactively manage quotas.

**Needed:**
```elixir
defmodule Lasso.RPC.QuotaManager do
  @doc """
  Track per-provider quota consumption.
  Proactively distribute load before hitting limits.
  """

  def track_request(provider_id, method, cost \\ 1) do
    # Increment counter
    current = :ets.update_counter(@table, {provider_id, method}, cost)

    # Check against known limits
    limit = get_provider_limit(provider_id, method)

    if current > limit * 0.8 do
      # Approaching limit, reduce weight in selection
      ProviderPool.reduce_weight(provider_id, 0.5)
    end
  end
end
```

**Configuration:**
```yaml
providers:
  - id: alchemy_eth
    rate_limits:
      global: 300_000  # requests per day
      per_second: 50
      methods:
        eth_getLogs: 10  # Lower limit for expensive methods
```

### 5.3 WebSocket Subscription Consistency

**Problem:** During WS failover with gap-filling, you may serve events out-of-order or duplicated.

**Current protection:**
- `StreamState` deduplicates by block number
- Events buffered during backfill

**Remaining risk:**
```
1. Subscribe to "newHeads" via Provider A
2. Receive blocks 100, 101, 102
3. Provider A fails, failover to Provider B
4. Gap-fill fetches blocks 102-105 via HTTP (Provider C)
5. Provider B starts sending blocks 105, 106, 107 via WS
6. Client receives: 100,101,102,102,103,104,105,105,106,107
```

Your `StreamState.ingest_new_head` should dedupe, but verify with test:

```elixir
# test/lasso/rpc/stream_state_deduplication_test.exs
test "deduplicates blocks during gap-fill and failover" do
  state = StreamState.new()

  # Simulate normal flow
  {state, :emit} = StreamState.ingest_new_head(state, block(100))
  {state, :emit} = StreamState.ingest_new_head(state, block(101))

  # Failover: gap-fill sends 101 again (HTTP), then 102 (WS)
  {state, :skip} = StreamState.ingest_new_head(state, block(101))  # Should dedupe
  {state, :emit} = StreamState.ingest_new_head(state, block(102))

  assert state.last_block_num == 102
end
```

### 5.4 Provider-Specific JSON-RPC Quirks

**Problem:** Different providers return slightly different response formats.

**Examples (real-world):**

1. **Alchemy:** Returns extra `uncles` field in block objects
2. **Infura:** Some methods return `null` vs `"0x0"` for empty values
3. **QuickNode:** Different timestamp precision (seconds vs milliseconds)
4. **Public nodes:** May lack archive data, return `null` for old blocks

**Current state:** Your `Generic` adapter normalizes basics, but provider-specific adapters may not handle all quirks.

**Recommendation:**
- Extensive integration testing with real providers
- Record/replay test fixtures from each provider
- Adapter tests for known quirks

### 5.5 Circular Failover Risk

**Problem:** Provider selection can get stuck in failover loops.

**Scenario:**
```
1. Request routed to Provider A → fails
2. Failover to Provider B → fails
3. Failover to Provider C → fails
4. Failover to Provider A → fails (same issue)
5. Infinite loop or max retry limit
```

**Current protection:**
- Circuit breakers prevent immediate retry to failed provider
- `:exclude` param in selection avoids recently failed providers

**Additional safety:**
```elixir
# In RequestPipeline.execute_with_failover
defp execute_with_failover(chain, method, params, opts, attempt \\ 1) do
  max_attempts = Keyword.get(opts, :max_attempts, 3)

  if attempt > max_attempts do
    {:error, :all_providers_exhausted}
  else
    # Track globally failed providers this request
    global_exclude = get_request_failed_providers()

    case execute_single(chain, method, params, exclude: global_exclude) do
      {:ok, result} -> {:ok, result}
      {:error, reason} ->
        record_request_failure(provider_id)
        execute_with_failover(chain, method, params, opts, attempt + 1)
    end
  end
end
```

### 5.6 DNS/Network Partitions

**Problem:** If your Lasso instance has network connectivity issues, provider health checks may report false negatives.

**Scenario:**
```
1. Your Lasso node loses internet connectivity (ISP issue, AWS region outage)
2. Health checks fail for ALL providers
3. All providers marked unhealthy
4. No requests can be routed
5. Lasso returns 503 to all clients
```

**Detection:**
```elixir
defmodule Lasso.RPC.NetworkHealthMonitor do
  @doc """
  Monitor Lasso's own network connectivity.
  Distinguish local network issues from provider failures.
  """

  def check_network_health do
    # Ping multiple independent endpoints
    targets = [
      "https://1.1.1.1",           # Cloudflare DNS
      "https://8.8.8.8",           # Google DNS
      "https://www.google.com",    # Public web
      "https://mainnet.infura.io"  # Known RPC endpoint
    ]

    results = Enum.map(targets, &ping/1)
    success_rate = Enum.count(results, &match?(:ok, &1)) / length(results)

    if success_rate < 0.5 do
      Logger.error("Network health check failed, possible local connectivity issue")
      {:error, :network_unreachable}
    else
      :ok
    end
  end
end
```

### 5.7 Clock Skew & Timestamp Issues

**Problem:** Your cooldown logic relies on `System.monotonic_time(:millisecond)` and `System.system_time(:millisecond)`.

**Risk:**
- If system clock jumps (NTP sync, VM migration), cooldowns behave incorrectly
- Provider may reject requests if your timestamp is too far off

**Best practice:**
- Use monotonic time for durations/intervals (already doing this ✅)
- Use system time only for wall-clock timestamps
- Handle clock drift in cooldown calculations

---

## Part 6: Recommendations

### Critical (Do Now)

1. **Integrate lag filtering** into provider selection (Phase 1A)
   - Prevents serving 10+ block old data
   - Low complexity, high impact
   - Estimated: 3-5 days

2. **Add chain ID validation** (Phase 1B)
   - Catches provider misconfigurations
   - Prevents wrong-chain data serving
   - Estimated: 2 days

3. **Monitor for reorg frequency** (observability only)
   - Track how often reorgs happen in your chains
   - Determine urgency of reorg handling
   - Estimated: 1 day

4. **Add integration tests** for state consistency scenarios
   - Test failover when providers at different heights
   - Test behavior during simulated reorgs
   - Estimated: 1 week

### Important (Do Soon)

5. **Implement reorg detection** (Phase 2)
   - Block hash tracking
   - Parent hash validation
   - Estimated: 2-3 weeks

6. **Finality awareness** (Phase 3)
   - Track safe/finalized heads
   - Method-specific finality requirements
   - Estimated: 3-4 weeks

7. **Quota management** (5.2)
   - Proactive rate limit awareness
   - Load balancing based on quota consumption
   - Estimated: 2 weeks

### Nice to Have (Later)

8. **Quorum validation** (Phase 4)
   - Multi-provider consensus for critical ops
   - Estimated: 4-6 weeks

9. **MEV protection** (5.1)
   - Private RPC routing for sendRawTransaction
   - Flashbots integration
   - Estimated: 2-3 weeks

10. **Network health monitoring** (5.6)
    - Self-check for connectivity issues
    - Estimated: 1 week

---

## Part 7: Testing Strategy

### Unit Tests

```elixir
# test/lasso/rpc/selection_lag_filter_test.exs
defmodule Lasso.RPC.SelectionLagFilterTest do
  test "excludes providers lagging beyond threshold" do
    # Setup: 3 providers at blocks 100, 98, 90
    # Threshold: 2 blocks
    # Expected: Only first two providers selected
  end

  test "includes all providers when all within threshold" do
    # Setup: 3 providers at blocks 100, 100, 99
    # Expected: All three candidates
  end

  test "falls back to ignoring lag when no providers within threshold" do
    # Setup: All providers 10+ blocks behind
    # Expected: Use fastest/priority strategy, log warning
  end
end
```

### Integration Tests

```elixir
# test/integration/state_consistency_test.exs
defmodule Lasso.Integration.StateConsistencyTest do
  test "does not route to severely lagging provider" do
    # Setup: Provider A at block 100, Provider B at block 85
    # Make request via proxy
    # Assert: Not routed to Provider B
  end

  test "recovers from provider lag during failover" do
    # Setup: Provider A fails, Provider B lagging
    # Make request via proxy
    # Assert: Eventually routes to healthy, synced provider
  end

  test "handles reorg during failover" do
    # Setup: Simulate reorg on Provider A during backfill
    # Make subscription request
    # Assert: No duplicate or missing events
  end
end
```

### Battle Tests

```elixir
# test/battle/state_consistency_battle_test.exs
test "state consistency under chaos" do
  Scenario.new("State consistency battle")
  |> Scenario.setup_chain(:ethereum, providers: [:alchemy, :infura, :ankr])
  |> Scenario.inject_lag(:infura, blocks: 10)  # Simulate lag
  |> Scenario.inject_chaos(:kill_provider, target: :alchemy, interval: 30_000)
  |> Scenario.run_workload(duration: 600_000, concurrency: 50)
  |> Scenario.verify_slo(
    success_rate: 0.99,
    p95_latency_ms: 500,
    max_stale_blocks: 2  # New metric!
  )
end
```

---

## Part 8: Metrics & Monitoring

### New Telemetry Events

```elixir
# Provider lag metrics
[:lasso, :selection, :lag_filter_applied]
%{excluded_count: 2, reason: :exceeded_threshold}
%{chain: "ethereum", threshold: 2}

# Reorg detection
[:lasso, :reorg, :detected]
%{depth: 1, affected_blocks: ["0x123..."]}
%{chain: "ethereum", provider_id: "alchemy"}

# State consistency
[:lasso, :selection, :stale_data_risk]
%{max_lag_observed: 15, threshold: 2}
%{chain: "ethereum", method: "eth_getBalance"}

# Quorum validation
[:lasso, :quorum, :consensus_failed]
%{quorum_size: 3, agreeing: 1, disagreements: 2}
%{chain: "ethereum", method: "eth_call"}
```

### Dashboard Additions

1. **Provider Lag Heatmap**
   - Real-time lag per provider
   - Color-coded by severity

2. **Reorg Events Log**
   - Recent reorgs with depth and time
   - Per-chain reorg frequency

3. **Stale Data Warnings**
   - Alert when routing to lagging providers
   - Show max lag observed per chain

---

## Conclusion

**Bottom Line:**

1. ✅ **You have a real problem** - State consistency is a legitimate concern
2. ✅ **You can solve it** - Your architecture has the foundation needed
3. ⚠️ **It's not solved yet** - Requires implementing lag-aware selection + reorg detection
4. 🔴 **Other issues exist** - MEV exposure, quota management, circular failovers

**Priority order:**
1. Lag-aware selection (highest ROI)
2. Chain ID validation (easy win)
3. Reorg detection (critical for production)
4. Finality awareness (DeFi/high-value apps)
5. Quorum validation (paranoid mode for critical ops)

**Estimated timeline:**
- Phase 1 (lag filtering + chain ID): 1-2 weeks
- Phase 2 (reorg detection): 3-4 weeks
- Phase 3 (finality): 4-6 weeks
- Total: 2-3 months to production-grade state consistency

Your current system is **solid for development/testing** but needs these enhancements for **production DeFi/high-value applications**. The good news: you're 70% there, just need to connect the pieces.

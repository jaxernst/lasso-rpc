# WebSocket Subscription Failover - Production Design Specification

## Executive Summary

This specification defines a production-ready failover system for blockchain WebSocket subscriptions that guarantees gap-free continuity, duplicate-free delivery (by content identity), and preserved ordering across provider failures. The design addresses four critical flaws in the current implementation: incomplete message chains, dead confirmation mechanisms, async backfill race conditions, and provider selection mismatches. Reorg policy is explicit: the system does not perform rewinds; it deduplicates by block hash for blocks and by (blockHash, transactionHash, logIndex) for logs, and allows block-number replays.

The solution adopts a **coordinator-driven, synchronous transition model** where the StreamCoordinator owns failover orchestration while the UpstreamSubscriptionPool manages subscription lifecycle. During failover, the system enters a transitional state that buffers incoming events, performs HTTP backfill to close gaps (using the best available HTTP provider, decoupled from the new WS provider), establishes a new WebSocket subscription, and atomically switches to the new provider (with old-upstream cleanup). This approach prioritizes correctness over latency, completing failover in under 30 seconds for typical scenarios (≤32 missed blocks).

The design minimizes architectural changes by building on existing components (Pool, Coordinator, GapFiller, StreamState) and introduces a clear state machine for failover lifecycle management. Implementation includes comprehensive telemetry, retry logic with exponential backoff, and graceful degradation strategies for cascading failures.

---

## Design Decisions (Q1-Q12)

### Architecture Decisions

#### Q1: Should Pool or Coordinator own failover decisions?

**Decision: Option C - Hybrid with Coordinator Orchestration**

**Rationale:**

- **Coordinator owns continuity state**: StreamCoordinator maintains `last_block_num` and dedupe cache, making it the authoritative source for gap detection and backfill requirements
- **Pool owns provider health**: UpstreamSubscriptionPool receives health events from ProviderPool and has access to all provider metadata
- **Separation of concerns**: Pool manages "which provider is healthy", Coordinator manages "how to maintain stream continuity"

**Implementation:**

```elixir
# Pool detects unhealthy provider, proposes candidate
Pool -> Coordinator: {:provider_unhealthy, failed_id, proposed_new_id}

# Coordinator orchestrates failover
Coordinator:
  1. Calculate gap range (based on last_block_num)
  2. Execute backfill (via GapFiller)
  3. Request subscription switch

Coordinator -> Pool: {:resubscribe, key, new_provider_id, coordinator_pid}

# Pool executes subscription change
Pool -> WSTransport: eth_subscribe(new_provider)
Pool -> Coordinator: {:subscription_confirmed, new_provider_id, upstream_id}
                  or {:subscription_failed, reason}
```

**Advantages:**

- Coordinator can make intelligent backfill decisions based on current stream position
- Pool remains focused on subscription multiplexing and health monitoring
- Clear ownership: Coordinator = continuity guarantees, Pool = subscription lifecycle

#### Q2: Synchronous or Asynchronous failover?

**Decision: Synchronous with Buffering**

**Rationale:**

- **Correctness over latency**: A 5-30 second pause is acceptable for failover; gaps/duplicates are not
- **Simplified reasoning**: No complex stream merging logic or race conditions between backfill and live events
- **Atomic transition**: Clear boundary between "old provider active" and "new provider active"

**Implementation:**

```elixir
# Coordinator state machine during failover
:active -> :backfilling -> :switching -> :active

# While in :backfilling or :switching states:
# - Buffer events from old provider (in case still trickling in)
# - Reject/ignore events until transition completes
# - After switch: sort buffers deterministically and process through dedupe, then resume
#   - Blocks: sort by blockNumber asc; if same number appears, dedupe by block hash and emit once
#   - Logs: sort by (blockNumber, transactionIndex, logIndex); dedupe by (blockHash, transactionHash, logIndex)
```

**Why not async?**

- Async requires complex merge logic: "Is this event from backfill or live? Which came first?"
- Race conditions: backfill Task completes while WS events still arriving from old provider
- Duplicate handling becomes probabilistic instead of deterministic

**Latency Analysis:**

- Typical failover: 10-15s (fetch head, backfill 5-10 blocks, resubscribe)
- Worst case: 30s (max 32 blocks backfill, network delays)
- Alternative: clients wait for TCP timeout (60s+) with zero events

#### Q3: Where to track failover state?

**Decision: Coordinator state with explicit FSM**

**Rationale:**

- **Single source of truth**: Failover state is tightly coupled with continuity state (last_block_num, dedupe)
- **Crash recovery**: If Coordinator crashes during failover, supervisor restarts it and Pool re-initiates subscription (same as initial subscription flow)
- **Simplicity**: No additional GenServer process to manage

**State Structure:**

```elixir
%StreamCoordinator{
  chain: "ethereum",
  key: {:newHeads},
  primary_provider_id: "alchemy",

  # New failover state
  failover_status: :active | :backfilling | :switching,
  failover_context: nil | %{
    old_provider_id: "infura",
    new_provider_id: "alchemy",
    backfill_task_ref: #Reference<>,
    started_at: monotonic_time,
    event_buffer: []  # Events received during transition
  },

  # Existing continuity state
  state: %StreamState{markers: %{last_block_num: 12345}, dedupe: ...}
}
```

### Message Flow Decisions

#### Q4: How should resubscription work?

**Decision: Coordinator-initiated, Pool-executed with confirmation**

**Message Flow:**

```elixir
# 1. Coordinator requests resubscription after backfill completes
Coordinator -> Pool: {:resubscribe, key, new_provider_id, coordinator_pid}

# 2. Pool validates and executes
Pool:
  - Validate provider supports required capability (newHeads/logs)
  - Call send_upstream_subscribe(chain, new_provider_id, key)
  - Update upstream_index mapping

# 3. Pool confirms result
Pool -> Coordinator: {:subscription_confirmed, provider_id, upstream_id}
                  or {:subscription_failed, reason}

# 4. Coordinator completes transition
Coordinator:
  - Update primary_provider_id
  - Set failover_status = :active
  - Process buffered events through dedupe
  - Resume normal operation
```

#### Q4a: Target provider head alignment

**Decision: Head-alignment gate (non-blocking fallback)**

**Rationale:** Avoid switching to a WS provider that is behind our last seen height. Prefer a provider whose head ≥ last_seen to minimize initial staleness and reduce buffer growth.

**Implementation sketch:**

```elixir
last_seen = StreamState.last_block_num(state.state)
candidate_head = fetch_head(state.chain, new_provider_id)

cond do
  candidate_head >= last_seen ->
    send(pool_pid, {:resubscribe, state.key, new_provider_id, self()})

  true ->
    case pick_next_provider_with_min_head(state, exclude: [state.failover_context.old_provider_id, new_provider_id], min_head: last_seen) do
      {:ok, better_provider} ->
        send(pool_pid, {:resubscribe, state.key, better_provider, self()})
      {:error, :no_match} ->
        # Gate briefly and retry; do not rewind
        Process.send_after(self(), {:retry_switch_if_aligned, new_provider_id, last_seen}, 1_000)
    end
end
```

**Why not Option B (Coordinator manages directly)?**

- Pool maintains `upstream_index` (provider_id => upstream_id => key) for routing
- Pool already implements subscription multiplexing logic
- Duplicating this in Coordinator violates DRY

**Why not Option C (Pool-driven)?**

- Pool doesn't have continuity state to calculate gap ranges
- Would require Pool to wait for Coordinator confirmation before switching, adding round-trip latency

**Critical Fix for Critical Flaw #1:**
Add missing handler to UpstreamSubscriptionPool (with old-upstream cleanup):

```elixir
def handle_info({:resubscribe, key, new_provider_id, coordinator_pid}, state) do
  case send_upstream_subscribe(state.chain, new_provider_id, key) do
    {:ok, upstream_id} ->
      # Unsubscribe old upstream if present to avoid stragglers and leaks
      {state, old_provider_id, old_upstream_id} =
        case fetch_current_upstream_for_key(state, key) do
          {:ok, {prov_id, up_id}} ->
            _ = safe_eth_unsubscribe(state.chain, prov_id, up_id)
            {state, prov_id, up_id}
          _ -> {state, nil, nil}
        end

      # Update state mappings
      new_state =
        state
        |> update_upstream_for_key(key, new_provider_id, upstream_id)
        |> remove_upstream_index(old_provider_id, old_upstream_id)

      # Confirm to coordinator
      send(coordinator_pid, {:subscription_confirmed, new_provider_id, upstream_id})

      {:noreply, new_state}

    {:error, reason} ->
      send(coordinator_pid, {:subscription_failed, reason})
      {:noreply, state}
  end
end
```

#### Q5: How to handle events during failover?

**Decision: Buffer, sort deterministically, then dedupe after transition**

**Implementation:**

```elixir
# In StreamCoordinator.handle_cast({:upstream_event, ...}, state)
case state.failover_status do
  :active ->
    # Normal path: ingest and emit
    process_event(state, payload)

  :backfilling ->
    # Buffer events from old provider (may still be arriving)
    # Typically these are duplicates or out-of-order stragglers
    buffer_event(state, payload)

  :switching ->
    # Brief window after backfill, before new subscription confirmed
    # Buffer any events (could be from old OR new provider)
    buffer_event(state, payload)
end

# After transition to :active, drain buffer:
defp drain_event_buffer(state) do
  # Deterministic ordering prior to dedupe
  ordered =
    case state.key do
      {:newHeads} -> Enum.sort_by(state.failover_context.event_buffer, &decode_hex(&1["number"]))
      {:logs, _filter} -> Enum.sort_by(state.failover_context.event_buffer, fn l -> {decode_hex(l["blockNumber"]), decode_hex(l["transactionIndex"] || "0x0"), decode_hex(l["logIndex"] || "0x0")} end)
    end

  Enum.reduce(ordered, state, fn payload, acc ->
    {new_stream_state, action} =
      case acc.key do
        {:newHeads} -> StreamState.ingest_new_head(acc.state, payload)
        {:logs, _} -> StreamState.ingest_log(acc.state, payload)
      end

    case action do
      :emit -> ClientSubscriptionRegistry.dispatch(acc.chain, acc.key, payload)
      :skip -> :ok
    end

    %{acc | state: new_stream_state}
  end)
  |> clear_failover_context()
end
```

**Why buffer instead of reject?**

- Network delays: events from old provider may arrive after failover initiated
- Reordering: TCP can deliver messages out of order during disconnect
- Safety: dedupe ensures we don't emit duplicates even if we buffer aggressively

**Buffer size and concurrency limits:**

- Max 100 events buffered (or 1000 for logs); if exceeded, log warning and drop oldest
- Limit concurrent backfills per chain to 3 using a per-chain semaphore
- Enforce HTTP backfill timeout (e.g., 30s per range) with cancellation of tasks
- Telemetry for queue depth and timeouts

### Gap Management Decisions

#### Q6: Who determines gap range?

**Decision: Coordinator determines, GapFiller executes (HTTP provider decoupled from WS provider)**

**Rationale:**

- **Coordinator has authoritative state**: `last_block_num` is the source of truth for gap detection
- **GapFiller remains pure**: No state, just HTTP fetch utility
- **Pool doesn't need continuity state**: Keeps Pool focused on subscription lifecycle

**Implementation:**

```elixir
# In StreamCoordinator.do_backfill_and_switch/3
defp do_backfill_and_switch(state, old_provider_id, new_provider_id) do
  last_seen = StreamState.last_block_num(state.state)

  # Fetch current head from new provider
  head = fetch_head(state.chain, new_provider_id)

  # Calculate gap using ContinuityPolicy
  case ContinuityPolicy.needed_block_range(
    last_seen,
    head,
    state.max_backfill_blocks,
    state.continuity_policy
  ) do
    {:none} ->
      # No gap, proceed to resubscribe
      {:ok, []}

    {:range, from_n, to_n} ->
      # Normal backfill via best available HTTP provider (may differ from WS)
      http_provider = pick_best_http_provider(state, exclude: [old_provider_id])
      GapFiller.ensure_blocks(state.chain, http_provider, from_n, to_n)

    {:exceeded, from_n, to_n} ->
      # Gap larger than max_backfill_blocks
      Logger.warning("Gap exceeded max backfill: #{from_n}-#{to_n}")

      case state.continuity_policy do
        :best_effort ->
          # Fill what we can using HTTP provider
          http_provider = pick_best_http_provider(state, exclude: [old_provider_id])
          GapFiller.ensure_blocks(state.chain, http_provider, from_n, to_n)

        :strict_abort ->
          # Fail the subscription
          {:error, :gap_too_large}
      end
  end
end
```

#### Q7: How to handle backfill failures?

**Decision: Retry with exponential backoff, then cascade to next provider**

**Strategy:**

```elixir
# Retry logic for transient HTTP errors
@max_backfill_retries 3
@backfill_retry_base_ms 1_000

defp backfill_with_retry(chain, provider_id, from_n, to_n, attempt \\ 1) do
  case GapFiller.ensure_blocks(chain, provider_id, from_n, to_n) do
    {:ok, blocks} ->
      {:ok, blocks}

    {:error, reason} when attempt < @max_backfill_retries ->
      # Exponential backoff: 1s, 2s, 4s
      delay = @backfill_retry_base_ms * :math.pow(2, attempt - 1)
      Process.sleep(round(delay))

      Logger.warning("Backfill attempt #{attempt} failed, retrying after #{delay}ms")
      backfill_with_retry(chain, provider_id, from_n, to_n, attempt + 1)

    {:error, reason} ->
      # All retries exhausted for this provider
      Logger.error("Backfill failed after #{attempt} attempts: #{inspect(reason)}")
      {:error, {:backfill_failed, reason}}
  end
end

# In handle_cast({:provider_unhealthy, ...})
# After backfill failure, try next provider
case backfill_with_retry(state.chain, new_provider_id, from_n, to_n) do
  {:ok, blocks} ->
    # Success, proceed to resubscribe

  {:error, _reason} ->
    # Backfill failed, cascade to next provider
    next_provider = pick_next_provider(state, [old_provider_id, new_provider_id])

    if next_provider do
      retry_failover_with_provider(state, next_provider)
    else
      # All providers exhausted
      terminate_subscription_with_error(state)
    end
end
```

**Error Classification:**

- **Transient (retry same provider)**: Timeout, 429 rate limit, 503 service unavailable
- **Provider-specific (try next provider)**: 404 not found (pruned node), 500 internal error
- **Fatal (abort)**: Invalid filter (client error), all providers exhausted

#### Q8: How to merge backfill with live stream?

**Decision: Option C - Buffering with ordered merge**

**Implementation:**

```elixir
# Phase 1: Backfill (failover_status = :backfilling)
# - Buffer any WS events arriving during backfill
# - Fetch blocks N to M via HTTP

backfilled_blocks = GapFiller.ensure_blocks(chain, provider_id, from_n, to_n)

# Phase 2: Ingest backfilled data through normal dedupe pipeline
Enum.each(backfilled_blocks, fn block ->
  {new_stream_state, action} = StreamState.ingest_new_head(state.state, block)

  case action do
    :emit -> ClientSubscriptionRegistry.dispatch(chain, key, block)
    :skip -> :ok  # Already seen (shouldn't happen for gap fills)
  end

  state = %{state | state: new_stream_state}
end)

# Phase 3: Resubscribe (failover_status = :switching)
send_to_pool({:resubscribe, key, new_provider_id, self()})

# Wait for confirmation...

# Phase 4: Resume (failover_status = :active)
# - Drain event_buffer through dedupe
# - Resume normal WS event processing

drain_event_buffer(state)
```

**Why this approach?**

- **Ordering guaranteed**: Backfill blocks processed before any buffered events
- **Dedupe guarantees no duplicates**: Even if buffer contains overlap
- **Simple state machine**: Clear transitions between phases

### Error Handling Decisions

#### Q9: How to handle cascading failures?

**Decision: Cascade to next provider with circuit breaker**

**Strategy:**

```elixir
defmodule Lasso.RPC.StreamCoordinator do
  @max_failover_attempts 3
  @failover_cooldown_ms 5_000

  # Track recent failover attempts
  %StreamCoordinator{
    failover_history: [
      {provider_id: "alchemy", failed_at: monotonic_time},
      {provider_id: "infura", failed_at: monotonic_time}
    ]
  }

  defp handle_failover_cascade(state, failed_provider_id) do
    recent_failures = count_recent_failures(state, @failover_cooldown_ms)

    cond do
      recent_failures >= @max_failover_attempts ->
        # Circuit breaker: too many rapid failures
        Logger.error("Failover circuit breaker triggered after #{recent_failures} attempts")

        # Options:
        # 1. Enter degraded mode (pause, retry after cooldown)
        # 2. Terminate subscription with error to clients
        # 3. Fall back to polling (eth_getBlockByNumber every 2s)

        enter_degraded_mode(state)

      true ->
        # Try next provider
        excluded = Enum.map(state.failover_history, & &1.provider_id)

        case pick_next_provider(state, excluded) do
          {:ok, next_provider_id} ->
            Logger.info("Cascading failover to #{next_provider_id}")
            initiate_failover(state, failed_provider_id, next_provider_id)

          {:error, :no_providers_available} ->
            Logger.error("All providers exhausted")
            enter_degraded_mode(state)
        end
    end
  end

  defp enter_degraded_mode(state) do
    # Option 1: Pause and retry after cooldown
    Process.send_after(self(), :retry_failover, 30_000)
    %{state | failover_status: :degraded}

    # Option 2: Notify clients of subscription error
    # (Let them decide to reconnect)
  end
end
```

**Circuit Breaker Rationale:**

- Prevents infinite failover loops during widespread outages
- Gives time for provider health to recover
- Avoids thundering herd (all subscriptions failing over simultaneously)

#### Q10: How to handle partial gaps?

**Decision: Validate completeness, log anomalies, proceed with best effort**

**Implementation:**

```elixir
defp validate_backfill(blocks, from_n, to_n) do
  expected_count = to_n - from_n + 1
  actual_count = length(blocks)

  cond do
    actual_count == 0 ->
      # Could be legitimate (no blocks produced) or provider issue
      Logger.warning("Backfill returned 0 blocks for range #{from_n}-#{to_n}")
      :telemetry.execute([:lasso, :failover, :empty_backfill], %{}, %{
        from: from_n, to: to_n, chain: chain
      })
      {:ok, blocks}

    actual_count < expected_count ->
      # Partial result: some blocks missing
      missing = find_missing_block_numbers(blocks, from_n, to_n)
      Logger.warning("Partial backfill: got #{actual_count}/#{expected_count}, missing: #{inspect(missing)}")

      # Best effort: use what we got
      {:ok, blocks}

    actual_count > expected_count ->
      # Anomaly: provider returned extra blocks
      Logger.error("Backfill returned too many blocks: got #{actual_count}, expected #{expected_count}")

      # Trim to requested range
      filtered = Enum.filter(blocks, fn b ->
        num = decode_hex(b["number"])
        num >= from_n and num <= to_n
      end)

      {:ok, filtered}

    true ->
      {:ok, blocks}
  end
end
```

**Handling eth_getLogs with 0 results:**

```elixir
# For log subscriptions, 0 results is often legitimate
# (no matching logs in that block range)

# But track metrics to detect anomalies:
:telemetry.execute([:lasso, :failover, :log_backfill], %{count: 0}, %{
  chain: chain,
  from: from_n,
  to: to_n,
  filter: inspect(filter)
})

# If consistently getting 0 logs but blocks ARE being produced,
# may indicate provider issue or filter misconfiguration
```

### State Management Decisions

#### Q11: What state needs persistence?

**Decision: Only last_block_num requires durability; dedupe is ephemeral**

**Rationale:**

- **last_block_num is critical**: Determines gap detection after Coordinator restart
- **dedupe cache is acceptable to lose**: Worst case = a few duplicate events after restart (clients should dedupe anyway)
- **failover state is ephemeral**: If Coordinator crashes during failover, Pool will re-initiate subscription on restart

**Persistence Strategy:**

```elixir
# Option 1: In-memory only (current approach)
# - Simple, no I/O overhead
# - On crash: Pool restarts Coordinator, re-establishes subscription
# - Gap detection: use last_block_num = nil, fetch current head

# Option 2: Periodic snapshot to ETS
# - Every 10 blocks, write to ETS table
# - On restart, load last known position
# - Reduces gap after crashes

# Option 3: Persistent Term (for read-heavy access)
# - Store per-key position in :persistent_term
# - Update on every block (cheap writes)
# - On restart, check persistent_term first

# Recommendation: Option 2 (ETS snapshot)
# - Balance durability vs performance
# - ETS backed by Mnesia or periodic disk writes
```

**Implementation:**

```elixir
defmodule Lasso.RPC.StreamStateStore do
  @moduledoc """
  ETS-backed store for stream positions.
  Periodically snapshots to disk for durability.
  """

  def save_position(chain, key, block_num) do
    :ets.insert(:stream_positions, {{chain, key}, block_num, System.monotonic_time()})
  end

  def load_position(chain, key) do
    case :ets.lookup(:stream_positions, {chain, key}) do
      [{{^chain, ^key}, block_num, _timestamp}] -> {:ok, block_num}
      [] -> {:error, :not_found}
    end
  end
end

# In StreamCoordinator, update position every block
def handle_cast({:upstream_event, ...}, state) do
  case StreamState.ingest_new_head(state.state, payload) do
    {stream_state, :emit} ->
      # Dispatch to clients
      ClientSubscriptionRegistry.dispatch(state.chain, state.key, payload)

      # Snapshot position
      block_num = StreamState.last_block_num(stream_state)
      StreamStateStore.save_position(state.chain, state.key, block_num)

      {:noreply, %{state | state: stream_state}}
  end
end
```

#### Q12: How to handle Coordinator crashes during failover?

**Decision: Restart from last known state, Pool re-initiates subscription**

**Crash Recovery Flow:**

```elixir
# Scenario: Coordinator crashes during backfill

1. Supervisor detects crash, restarts Coordinator
2. Coordinator.init/1 loads last known position from ETS (if available)
3. Pool detects Coordinator restart (upstream_event messages fail)
4. Pool calls ensure_upstream_for_key again
5. Pool -> Coordinator: upstream_event messages resume
6. Coordinator: gap detection kicks in (if last_block_num was saved)
   - last_block_num = 12345 (from ETS)
   - Current head from new WS event = 12360
   - Gap detected: 12346-12360
   - Initiates backfill

# Alternative: Coordinator initializes with last_block_num = nil
# - First event from WS becomes new baseline
# - No backfill (assumes crash was during initial startup)
```

**Pool's role in crash recovery:**

```elixir
# Pool maintains subscription even if Coordinator crashes
# upstream_index still maps: provider_id => upstream_id => key

# If Pool tries to send to Coordinator and it's dead:
case StreamCoordinator.upstream_event(chain, key, ...) do
  # GenServer.cast never fails, but we can detect via monitoring
  :ok -> :ok
end

# Alternative: Pool monitors Coordinator
def handle_info({:DOWN, _ref, :process, coordinator_pid, _reason}, state) do
  # Coordinator crashed, restart it
  key = find_key_for_coordinator(state, coordinator_pid)
  StreamSupervisor.ensure_coordinator(state.chain, key, opts)

  {:noreply, state}
end
```

---

## Architecture Specification

### Component Responsibilities

#### UpstreamSubscriptionPool

**Primary Role**: Subscription lifecycle management and provider health monitoring

**Responsibilities:**

- Establish upstream WebSocket subscriptions via `send_upstream_subscribe/3`
- Maintain `upstream_index` mapping: `provider_id => upstream_id => key`
- Subscribe to provider health events via PubSub
- Detect unhealthy providers and notify StreamCoordinator
- Execute resubscription requests from Coordinator
- Multiplex client subscriptions onto minimal upstream connections
- Clean up subscriptions when last client disconnects

**New Handlers Required:**

```elixir
# Resubscription handler (fixes Critical Flaw #1)
def handle_info({:resubscribe, key, new_provider_id, coordinator_pid}, state)

# Resubscription with validation
def handle_info({:resubscribe_validated, key, new_provider_id, coordinator_pid, capabilities}, state)
```

**State Changes:**

```elixir
# Add to state
%{
  # ... existing fields ...

  # Track provider capabilities for validation
  provider_capabilities: %{
    "alchemy" => [:newHeads, :logs, :pendingTransactions],
    "infura" => [:newHeads, :logs]
  }
}
```

#### StreamCoordinator

**Primary Role**: Stream continuity orchestration and failover management

**Responsibilities:**

- Maintain stream position (`last_block_num`, `last_log_block`) via StreamState
- Detect gaps between old and new provider streams
- Orchestrate failover: backfill → resubscribe → transition
- Manage failover state machine (:active → :backfilling → :switching → :active)
- Buffer events during transition
- Deduplicate events using DedupeCache
- Dispatch validated events to ClientSubscriptionRegistry
- Emit telemetry for observability

**State Machine:**

```
┌─────────┐
│ :active │ ◄─────────────────────────────────────────┐
└────┬────┘                                            │
     │                                                 │
     │ {:provider_unhealthy, old_id, new_id}          │
     │                                                 │
     ▼                                                 │
┌──────────────┐                                      │
│ :backfilling │                                      │
└──────┬───────┘                                      │
       │                                               │
       │ backfill complete                            │
       │ send {:resubscribe, ...}                     │
       │                                               │
       ▼                                               │
┌─────────────┐                                       │
│ :switching  │                                       │
└──────┬──────┘                                       │
       │                                               │
       │ {:subscription_confirmed, provider, upstream} │
       │                                               │
       └───────────────────────────────────────────────┘
```

**New State Fields:**

```elixir
%StreamCoordinator{
  # ... existing fields ...

  # Failover state
  failover_status: :active | :backfilling | :switching | :degraded,
  failover_context: nil | %{
    old_provider_id: String.t(),
    new_provider_id: String.t(),
    backfill_task_ref: reference(),
    started_at: integer(),
    event_buffer: [map()],  # Max 100 events
    attempt_count: integer()
  },

  # Circuit breaker
  failover_history: [%{provider_id: String.t(), failed_at: integer()}],

  # Retry config
  max_failover_attempts: 3,
  failover_cooldown_ms: 5_000
}
```

#### GapFiller

**Primary Role**: HTTP backfill execution (no changes needed)

**Current Implementation**: Perfect for requirements

- Pure functional API
- Handles `ensure_blocks/5` and `ensure_logs/6`
- Emits telemetry

**Enhancement (optional)**: Add retry logic internally

```elixir
def ensure_blocks_with_retry(chain, provider_id, from_n, to_n, opts \\ []) do
  max_attempts = Keyword.get(opts, :max_attempts, 3)
  retry_delay = Keyword.get(opts, :retry_delay, 1_000)

  do_ensure_blocks_with_retry(chain, provider_id, from_n, to_n, max_attempts, retry_delay, 1)
end
```

#### StreamState

**Primary Role**: Per-subscription stream position tracking (no changes needed)

**Current Implementation**: Handles requirements correctly

- Dedupe via DedupeCache
- Position tracking via `last_block_num`, `last_log_block`
- Pure functional API

#### ProviderHeadCache (new, optional but recommended)

**Primary Role**: Maintain per-provider best known head height and freshness to improve selection and failover decisions.

**Responsibilities:**

- Store `{provider_id => %{best_head: non_neg_integer(), last_update_ms: integer(), stall_ms: integer()}}` in ETS
- Background `HeadProber` periodically calls `eth_blockNumber` via `RequestPipeline` per provider (HTTP preferred), updating the cache
- Expose read API used by `Selection` and `StreamCoordinator` head-alignment gate

**APIs:**

```elixir
ProviderHeadCache.put(provider_id, height)
ProviderHeadCache.get(provider_id) :: {:ok, %{best_head: n, last_update_ms: t, stall_ms: s}} | :error
ProviderHeadCache.global_best() :: non_neg_integer()
```

**Selection integration:**

- Exclude or down-rank providers with `lag_blocks > max_head_lag_blocks`
- Open a height-lag circuit when `stall_ms > stall_open_ms`; half-open closes on next successful probe

**Coordinator integration:**

- Use cached heads in Q4a head-alignment gate; fall back to `fetch_head/2` if cache stale or missing

### Message Flow Diagrams

#### Normal Operation (No Failures)

```
Client                Pool                 Coordinator              Registry
  │                    │                        │                      │
  │──subscribe────────>│                        │                      │
  │                    │──ensure_coord────────> │                      │
  │                    │                        │◄─────────────────────┤
  │                    │──eth_subscribe────────>│ (to WSTransport)     │
  │                    │◄──upstream_id──────────│                      │
  │◄─sub_id────────────│                        │                      │
  │                    │                        │                      │
  │                    │◄──:subscription_event──┤ (from WSTransport)   │
  │                    │──upstream_event───────>│                      │
  │                    │                        │──ingest_new_head────>│
  │                    │                        │──dedupe──────────────>│
  │                    │                        │──dispatch───────────>│
  │◄───────────────────┴────────────────────────┴──────────────────────┤
  │                {:subscription_event, payload}                      │
```

#### Provider Failover (Complete Flow)

```
Pool                  Coordinator              GapFiller          WSTransport
  │                        │                       │                  │
  │◄─provider_unhealthy────│ (from PubSub)         │                  │
  │──{:provider_unhealthy, │                       │                  │
  │    old_id, new_id}────>│                       │                  │
  │                        │                       │                  │
  │                        ├─[Status: :backfilling]│                  │
  │                        │──fetch_head──────────>│                  │
  │                        │◄─current_height───────│                  │
  │                        │──ensure_blocks───────>│                  │
  │                        │    (gap: N to M)      │                  │
  │                        │◄─blocks───────────────│                  │
  │                        │──ingest_each_block────┤                  │
  │                        │──dispatch_backfilled──┤                  │
  │                        │                       │                  │
  │                        ├─[Status: :switching]  │                  │
  │◄─{:resubscribe,        │                       │                  │
  │    key, new_id, pid}───│                       │                  │
  │──eth_subscribe(new)───┼───────────────────────┼─────────────────>│
  │◄─upstream_id───────────┼───────────────────────┼──────────────────│
  │──{:subscription_       │                       │                  │
  │    confirmed, id}─────>│                       │                  │
  │                        │                       │                  │
  │                        ├─[Status: :active]     │                  │
  │                        │──drain_buffer─────────┤                  │
  │                        │──resume_normal_ops────┤                  │
```

#### Cascading Failure (Provider B also fails)

```
Pool                  Coordinator              Selection
  │                        │                       │
  │──{:provider_unhealthy, │                       │
  │    A, B}──────────────>│                       │
  │                        ├─backfill from B───────┤
  │                        ├─resubscribe to B──────┤
  │──{:subscription_failed,│                       │
  │    reason}────────────>│                       │
  │                        │                       │
  │                        ├─[Check circuit breaker]
  │                        ├─attempts < max? YES   │
  │                        │──pick_next_provider──>│
  │                        │◄─C (exclude A, B)─────│
  │                        │                       │
  │                        ├─backfill from C───────┤
  │◄─{:resubscribe, key, C}│                       │
  │──eth_subscribe(C)─────>│                       │
  │──{:subscription_       │                       │
  │    confirmed, C}──────>│                       │
  │                        ├─[Status: :active]     │
```

#### Coordinator Crash Recovery

```
Pool                  Supervisor            Coordinator         ETS Store
  │                        │                      │                │
  │──upstream_event───────>│ (GenServer.cast)     │                │
  │                        │  [Process dead]      │                │
  │                        │──detect_crash───────>│                │
  │                        │──restart─────────────┤                │
  │                        │                      │──init──────────┤
  │                        │                      │──load_position─>│
  │                        │                      │◄─last_block_num─│
  │                        │◄─────────────────────│                │
  │                        │  (Coordinator alive) │                │
  │──upstream_event───────>│                      │                │
  │                        │──handle_cast────────>│                │
  │                        │                      ├─detect gap?    │
  │                        │                      ├─initiate backfill
```

---

## API Contracts

### Pool → Coordinator Messages

#### 1. Provider Health Notification

```elixir
# Sent when Pool detects unhealthy provider
GenServer.cast(
  coordinator_pid,
  {:provider_unhealthy, failed_provider_id, proposed_new_provider_id}
)

# Parameters:
# - failed_provider_id: String.t() - Provider that became unhealthy
# - proposed_new_provider_id: String.t() - Suggested replacement provider
#
# Coordinator Action:
# 1. Transition to :backfilling state
# 2. Calculate gap range
# 3. Execute backfill via GapFiller
# 4. Request resubscription
```

#### 2. Upstream Event Delivery

```elixir
# Sent for every WebSocket subscription event
GenServer.cast(
  coordinator_pid,
  {:upstream_event, provider_id, upstream_id, payload, received_at}
)

# Parameters:
# - provider_id: String.t() - Provider that sent the event
# - upstream_id: String.t() - Upstream subscription ID
# - payload: map() - Event data (block header or log)
# - received_at: integer() - Monotonic timestamp
#
# Coordinator Action:
# - If failover_status == :active: process immediately
# - If failover_status == :backfilling: buffer event
# - If failover_status == :switching: buffer event
```

### Coordinator → Pool Messages

#### 1. Resubscription Request

```elixir
# Sent after backfill completes, requests new subscription
send(pool_pid, {:resubscribe, key, new_provider_id, coordinator_pid})

# Parameters:
# - key: {:newHeads} | {:logs, filter} - Subscription key
# - new_provider_id: String.t() - Target provider for resubscription
# - coordinator_pid: pid() - Coordinator to send confirmation to
#
# Pool Action:
# 1. Validate provider supports required capability
# 2. Execute send_upstream_subscribe(chain, new_provider_id, key)
# 3. Update upstream_index mapping
# 4. Send confirmation back to coordinator
```

### Pool → Coordinator Confirmations

#### 1. Subscription Confirmed

```elixir
# Sent when resubscription succeeds
send(coordinator_pid, {:subscription_confirmed, provider_id, upstream_id})

# Parameters:
# - provider_id: String.t() - Provider that accepted subscription
# - upstream_id: String.t() - New upstream subscription ID
#
# Coordinator Action:
# 1. Update primary_provider_id
# 2. Transition to :active state
# 3. Drain event buffer through dedupe
# 4. Resume normal operation
```

#### 2. Subscription Failed

```elixir
# Sent when resubscription fails
send(coordinator_pid, {:subscription_failed, reason})

# Parameters:
# - reason: term() - Error reason (JSONRPC.Error or other)
#
# Coordinator Action:
# 1. Increment attempt_count
# 2. Check circuit breaker (attempts < max?)
# 3. If within limits: cascade to next provider
# 4. If exhausted: enter degraded mode or terminate
```

### PubSub Events (Existing)

#### Provider Health Events

```elixir
# Already subscribed in Pool.init/1
Phoenix.PubSub.subscribe(Lasso.PubSub, "provider_pool:events:#{chain}")

# Events received:
# - %Provider.Unhealthy{provider_id: "alchemy", ...}
# - %Provider.CooldownStart{provider_id: "infura", ...}
# - %Provider.HealthCheckFailed{provider_id: "quicknode", ...}
# - %Provider.WSClosed{provider_id: "alchemy", ...}
# - %Provider.WSDisconnected{provider_id: "infura", ...}
```

### Telemetry Events (New)

#### Failover Lifecycle

```elixir
# Failover initiated
:telemetry.execute(
  [:lasso, :subs, :failover, :initiated],
  %{count: 1},
  %{
    chain: "ethereum",
    key: "{:newHeads}",
    old_provider: "infura",
    new_provider: "alchemy",
    last_block_num: 12345
  }
)

# Backfill started
:telemetry.execute(
  [:lasso, :subs, :failover, :backfill_started],
  %{count: 1, block_count: 15},
  %{
    chain: "ethereum",
    provider: "alchemy",
    from_block: 12346,
    to_block: 12360
  }
)

# Backfill completed
:telemetry.execute(
  [:lasso, :subs, :failover, :backfill_completed],
  %{count: 1, duration_ms: 3456, blocks_fetched: 15},
  %{
    chain: "ethereum",
    provider: "alchemy",
    from_block: 12346,
    to_block: 12360
  }
)

# Resubscription succeeded
:telemetry.execute(
  [:lasso, :subs, :failover, :resubscribe_success],
  %{count: 1, duration_ms: 234},
  %{
    chain: "ethereum",
    key: "{:newHeads}",
    provider: "alchemy",
    upstream_id: "0xabc123"
  }
)

# Failover completed (end-to-end)
:telemetry.execute(
  [:lasso, :subs, :failover, :completed],
  %{count: 1, duration_ms: 12345, events_buffered: 3},
  %{
    chain: "ethereum",
    key: "{:newHeads}",
    old_provider: "infura",
    new_provider: "alchemy"
  }
)

# Failover failed
:telemetry.execute(
  [:lasso, :subs, :failover, :failed],
  %{count: 1, attempts: 3},
  %{
    chain: "ethereum",
    key: "{:newHeads}",
    reason: "all_providers_exhausted",
    tried_providers: ["infura", "alchemy", "quicknode"]
  }
)
```

---

## Implementation Specification

### Phase 1: Fix Critical Flaws (Core Failover)

#### 1.1 Add Resubscription Handler to Pool

**File**: `/Users/jacksonernst/Documents/GitHub/lazer/lasso-rpc/lib/lasso/core/streaming/upstream_subscription_pool.ex`

**Changes:**

```elixir
# Add handler for resubscription requests
@impl true
def handle_info({:resubscribe, key, new_provider_id, coordinator_pid}, state) do
  Logger.info("Resubscribing key #{inspect(key)} to provider #{new_provider_id}")

  # Get existing entry to preserve refcount
  entry = Map.get(state.keys, key)

  if entry do
    # Execute new subscription
    case send_upstream_subscribe(state.chain, new_provider_id, key) do
      {:ok, upstream_id} ->
        # Update entry with new provider
        updated_entry = %{
          entry
          | primary_provider_id: new_provider_id,
            upstream: Map.put(entry.upstream, new_provider_id, upstream_id)
        }

        # Update upstream_index
        new_upstream_index =
          Map.update(state.upstream_index, new_provider_id, %{upstream_id => key}, fn m ->
            Map.put(m, upstream_id, key)
          end)

        new_state = %{
          state
          | keys: Map.put(state.keys, key, updated_entry),
            upstream_index: new_upstream_index
        }

        # Confirm to coordinator
        send(coordinator_pid, {:subscription_confirmed, new_provider_id, upstream_id})

        telemetry_resubscribe_success(state.chain, key, new_provider_id)

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Resubscription failed for #{inspect(key)} to #{new_provider_id}: #{inspect(reason)}")

        # Notify coordinator of failure
        send(coordinator_pid, {:subscription_failed, reason})

        telemetry_resubscribe_failed(state.chain, key, new_provider_id, reason)

        {:noreply, state}
    end
  else
    # Key no longer exists (all clients unsubscribed during failover)
    Logger.debug("Resubscription skipped: key #{inspect(key)} no longer active")
    send(coordinator_pid, {:subscription_failed, :key_inactive})
    {:noreply, state}
  end
end

defp telemetry_resubscribe_success(chain, key, provider_id) do
  :telemetry.execute([:lasso, :subs, :resubscribe, :success], %{count: 1}, %{
    chain: chain,
    key: inspect(key),
    provider_id: provider_id
  })
end

defp telemetry_resubscribe_failed(chain, key, provider_id, reason) do
  :telemetry.execute([:lasso, :subs, :resubscribe, :failed], %{count: 1}, %{
    chain: chain,
    key: inspect(key),
    provider_id: provider_id,
    reason: inspect(reason)
  })
end
```

#### 1.2 Add Failover State Machine to Coordinator

**File**: `/Users/jacksonernst/Documents/GitHub/lazer/lasso-rpc/lib/lasso/core/streaming/stream_coordinator.ex`

**Changes:**

```elixir
defmodule Lasso.RPC.StreamCoordinator do
  # ... existing code ...

  @impl true
  def init({chain, key, opts}) do
    state = %{
      chain: chain,
      key: key,
      primary_provider_id: Keyword.get(opts, :primary_provider_id),
      state: StreamState.new(
        dedupe_max_items: Keyword.get(opts, :dedupe_max_items, 256),
        dedupe_max_age_ms: Keyword.get(opts, :dedupe_max_age_ms, 30_000)
      ),

      # Backfill config
      max_backfill_blocks: Keyword.get(opts, :max_backfill_blocks, 32),
      backfill_timeout: Keyword.get(opts, :backfill_timeout, 30_000),
      continuity_policy: Keyword.get(opts, :continuity_policy, :best_effort),

      # NEW: Failover state
      failover_status: :active,
      failover_context: nil,
      failover_history: [],
      max_failover_attempts: 3,
      failover_cooldown_ms: 5_000,
      max_event_buffer: 100
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:upstream_event, provider_id, upstream_id, payload, received_at}, state) do
    case state.failover_status do
      :active ->
        # Normal processing path
        process_event_normal(state, payload)

      :backfilling ->
        # Buffer events during backfill
        buffer_event(state, payload)

      :switching ->
        # Buffer events during subscription switch
        buffer_event(state, payload)

      :degraded ->
        # Circuit breaker triggered, drop events
        Logger.warning("Dropping event in degraded mode")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:provider_unhealthy, failed_id, proposed_new_id}, state) do
    if state.failover_status == :active do
      initiate_failover(state, failed_id, proposed_new_id)
    else
      Logger.warning("Ignoring provider_unhealthy signal during active failover")
      {:noreply, state}
    end
  end

  # NEW: Handle subscription confirmation
  @impl true
  def handle_info({:subscription_confirmed, provider_id, upstream_id}, state) do
    if state.failover_status == :switching do
      complete_failover(state, provider_id, upstream_id)
    else
      Logger.warning("Unexpected subscription_confirmed in status #{state.failover_status}")
      {:noreply, state}
    end
  end

  # NEW: Handle subscription failure
  @impl true
  def handle_info({:subscription_failed, reason}, state) do
    if state.failover_status == :switching do
      handle_resubscribe_failure(state, reason)
    else
      Logger.warning("Unexpected subscription_failed in status #{state.failover_status}")
      {:noreply, state}
    end
  end

  # NEW: Handle backfill task completion
  @impl true
  def handle_info({ref, :backfill_complete}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if state.failover_status == :backfilling do
      transition_to_switching(state)
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if state.failover_context && state.failover_context.backfill_task_ref == ref do
      Logger.error("Backfill task crashed: #{inspect(reason)}")
      handle_backfill_failure(state, reason)
    else
      {:noreply, state}
    end
  end

  # ... implementation functions ...

  defp process_event_normal(state, payload) do
    case state.key do
      {:newHeads} ->
        case StreamState.ingest_new_head(state.state, payload) do
          {stream_state, :emit} ->
            ClientSubscriptionRegistry.dispatch(state.chain, state.key, payload)
            {:noreply, %{state | state: stream_state}}

          {stream_state, :skip} ->
            {:noreply, %{state | state: stream_state}}
        end

      {:logs, _filter} ->
        case StreamState.ingest_log(state.state, payload) do
          {stream_state, :emit} ->
            ClientSubscriptionRegistry.dispatch(state.chain, state.key, payload)
            {:noreply, %{state | state: stream_state}}

          {stream_state, :skip} ->
            {:noreply, %{state | state: stream_state}}
        end
    end
  end

  defp buffer_event(state, payload) do
    if state.failover_context do
      buffer = state.failover_context.event_buffer

      if length(buffer) < state.max_event_buffer do
        updated_context = %{state.failover_context | event_buffer: buffer ++ [payload]}
        {:noreply, %{state | failover_context: updated_context}}
      else
        Logger.warning("Event buffer full (#{state.max_event_buffer}), dropping event")
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  defp initiate_failover(state, old_provider_id, new_provider_id) do
    Logger.info("Initiating failover: #{old_provider_id} -> #{new_provider_id}")

    # Check circuit breaker
    recent_failures = count_recent_failures(state.failover_history, state.failover_cooldown_ms)

    if recent_failures >= state.max_failover_attempts do
      Logger.error("Circuit breaker triggered: #{recent_failures} attempts in #{state.failover_cooldown_ms}ms")
      enter_degraded_mode(state)
    else
      # Start backfill task
      parent = self()
      task = Task.async(fn ->
        execute_backfill(state, new_provider_id)
        send(parent, {self(), :backfill_complete})
      end)

      failover_context = %{
        old_provider_id: old_provider_id,
        new_provider_id: new_provider_id,
        backfill_task_ref: task.ref,
        started_at: System.monotonic_time(:millisecond),
        event_buffer: [],
        attempt_count: recent_failures + 1
      }

      new_history = [
        %{provider_id: old_provider_id, failed_at: System.monotonic_time(:millisecond)}
        | state.failover_history
      ]

      telemetry_failover_initiated(state.chain, state.key, old_provider_id, new_provider_id)

      {:noreply, %{
        state
        | failover_status: :backfilling,
          failover_context: failover_context,
          failover_history: new_history
      }}
    end
  end

  defp execute_backfill(state, new_provider_id) do
    try do
      case state.key do
        {:newHeads} ->
          backfill_blocks(state, new_provider_id)

        {:logs, filter} ->
          backfill_logs(state, new_provider_id, filter)
      end
    rescue
      e ->
        Logger.error("Backfill error: #{inspect(e)}")
        :error
    end
  end

  defp backfill_blocks(state, provider_id) do
    last = StreamState.last_block_num(state.state)
    head = fetch_head(state.chain, provider_id)

    case ContinuityPolicy.needed_block_range(
      last,
      head,
      state.max_backfill_blocks,
      state.continuity_policy
    ) do
      {:none} ->
        :ok

      {:range, from_n, to_n} ->
        telemetry_backfill_started(state.chain, from_n, to_n, provider_id)

        # Use decoupled HTTP backfill provider
        http_provider = pick_best_http_provider(state, exclude: [state.failover_context.old_provider_id, provider_id])
        case GapFiller.ensure_blocks(state.chain, http_provider, from_n, to_n) do
          {:ok, blocks} ->
            Enum.each(blocks, fn block ->
              GenServer.cast(self(), {:upstream_event, provider_id, nil, block, System.monotonic_time(:millisecond)})
            end)

            telemetry_backfill_completed(state.chain, from_n, to_n, length(blocks))
            :ok

          {:error, reason} ->
            Logger.error("Backfill failed: #{inspect(reason)}")
            :error
        end

      {:exceeded, from_n, to_n} ->
        Logger.warning("Gap exceeds max_backfill_blocks: #{from_n}-#{to_n}")

        case state.continuity_policy do
          :best_effort ->
            backfill_blocks(state, provider_id)

          :strict_abort ->
            :error
        end
    end
  end

  defp backfill_logs(state, provider_id, filter) do
    last = StreamState.last_log_block(state.state) || StreamState.last_block_num(state.state)
    head = fetch_head(state.chain, provider_id)

    case ContinuityPolicy.needed_block_range(
      last,
      head,
      state.max_backfill_blocks,
      state.continuity_policy
    ) do
      {:none} ->
        :ok

      {:range, from_n, to_n} ->
        telemetry_backfill_started(state.chain, from_n, to_n, provider_id)

        # Use decoupled HTTP backfill provider
        http_provider = pick_best_http_provider(state, exclude: [state.failover_context.old_provider_id, provider_id])
        case GapFiller.ensure_logs(state.chain, http_provider, filter, from_n, to_n) do
          {:ok, logs} ->
            Enum.each(logs, fn log ->
              GenServer.cast(self(), {:upstream_event, provider_id, nil, log, System.monotonic_time(:millisecond)})
            end)

            telemetry_backfill_completed(state.chain, from_n, to_n, length(logs))
            :ok

          {:error, reason} ->
            Logger.error("Log backfill failed: #{inspect(reason)}")
            :error
        end

      {:exceeded, from_n, to_n} ->
        Logger.warning("Gap exceeds max_backfill_blocks: #{from_n}-#{to_n}")
        backfill_logs(state, provider_id, filter)
    end
  end

  defp transition_to_switching(state) do
    Logger.info("Backfill complete, transitioning to :switching")

    # Request resubscription from Pool
    pool_pid = Lasso.RPC.UpstreamSubscriptionPool.via(state.chain)
    send(pool_pid, {:resubscribe, state.key, state.failover_context.new_provider_id, self()})

    telemetry_resubscribe_initiated(state.chain, state.key, state.failover_context.new_provider_id)

    {:noreply, %{state | failover_status: :switching}}
  end

  defp complete_failover(state, provider_id, _upstream_id) do
    Logger.info("Failover complete: now on provider #{provider_id}")

    # Drain buffered events through dedupe
    new_state = drain_event_buffer(state)

    # Update primary provider
    final_state = %{
      new_state
      | primary_provider_id: provider_id,
        failover_status: :active,
        failover_context: nil
    }

    duration_ms = System.monotonic_time(:millisecond) - state.failover_context.started_at
    telemetry_failover_completed(final_state.chain, final_state.key, duration_ms)

    {:noreply, final_state}
  end

  defp drain_event_buffer(state) do
    if state.failover_context && length(state.failover_context.event_buffer) > 0 do
      Logger.debug("Draining #{length(state.failover_context.event_buffer)} buffered events")

      Enum.reduce(state.failover_context.event_buffer, state, fn payload, acc ->
        case acc.key do
          {:newHeads} ->
            case StreamState.ingest_new_head(acc.state, payload) do
              {stream_state, :emit} ->
                ClientSubscriptionRegistry.dispatch(acc.chain, acc.key, payload)
                %{acc | state: stream_state}

              {stream_state, :skip} ->
                %{acc | state: stream_state}
            end

          {:logs, _filter} ->
            case StreamState.ingest_log(acc.state, payload) do
              {stream_state, :emit} ->
                ClientSubscriptionRegistry.dispatch(acc.chain, acc.key, payload)
                %{acc | state: stream_state}

              {stream_state, :skip} ->
                %{acc | state: stream_state}
            end
        end
      end)
    else
      state
    end
  end

  defp handle_resubscribe_failure(state, reason) do
    Logger.error("Resubscription failed: #{inspect(reason)}")

    # Check if we should cascade to another provider
    recent_failures = count_recent_failures(state.failover_history, state.failover_cooldown_ms)

    if recent_failures >= state.max_failover_attempts do
      Logger.error("Max failover attempts reached, entering degraded mode")
      enter_degraded_mode(state)
    else
      # Try next provider
      excluded = [
        state.failover_context.old_provider_id,
        state.failover_context.new_provider_id
      ]

      case pick_next_provider(state, excluded) do
        {:ok, next_provider_id} ->
          Logger.info("Cascading to next provider: #{next_provider_id}")

          # Reset to active and re-initiate
          reset_state = %{state | failover_status: :active, failover_context: nil}
          initiate_failover(reset_state, state.failover_context.new_provider_id, next_provider_id)

        {:error, :no_providers} ->
          Logger.error("No more providers available")
          enter_degraded_mode(state)
      end
    end
  end

  defp handle_backfill_failure(state, _reason) do
    Logger.error("Backfill task failed")

    # Treat as resubscribe failure
    handle_resubscribe_failure(state, :backfill_failed)
  end

  defp enter_degraded_mode(state) do
    Logger.error("Entering degraded mode")

    # Schedule retry after cooldown
    Process.send_after(self(), :retry_from_degraded, 30_000)

    telemetry_failover_degraded(state.chain, state.key)

    {:noreply, %{
      state
      | failover_status: :degraded,
        failover_context: nil
    }}
  end

  defp count_recent_failures(history, window_ms) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms

    Enum.count(history, fn entry -> entry.failed_at > cutoff end)
  end

  defp pick_next_provider(state, excluded) do
    case Lasso.RPC.Selection.select_provider(
      Lasso.RPC.SelectionContext.new(state.chain, "eth_subscribe",
        strategy: :priority,
        protocol: :ws,
        exclude: excluded
      )
    ) do
      {:ok, provider_id} -> {:ok, provider_id}
      _ -> {:error, :no_providers}
    end
  end

  # Telemetry helpers
  defp telemetry_failover_initiated(chain, key, old_id, new_id) do
    :telemetry.execute([:lasso, :subs, :failover, :initiated], %{count: 1}, %{
      chain: chain,
      key: inspect(key),
      old_provider: old_id,
      new_provider: new_id
    })
  end

  defp telemetry_backfill_started(chain, from_n, to_n, provider_id) do
    :telemetry.execute([:lasso, :subs, :failover, :backfill_started], %{count: to_n - from_n + 1}, %{
      chain: chain,
      provider_id: provider_id,
      from_block: from_n,
      to_block: to_n
    })
  end

  defp telemetry_backfill_completed(chain, from_n, to_n, fetched_count) do
    :telemetry.execute([:lasso, :subs, :failover, :backfill_completed], %{count: fetched_count}, %{
      chain: chain,
      from_block: from_n,
      to_block: to_n
    })
  end

  defp telemetry_resubscribe_initiated(chain, key, provider_id) do
    :telemetry.execute([:lasso, :subs, :failover, :resubscribe_initiated], %{count: 1}, %{
      chain: chain,
      key: inspect(key),
      provider_id: provider_id
    })
  end

  defp telemetry_failover_completed(chain, key, duration_ms) do
    :telemetry.execute([:lasso, :subs, :failover, :completed], %{duration_ms: duration_ms}, %{
      chain: chain,
      key: inspect(key)
    })
  end

  defp telemetry_failover_degraded(chain, key) do
    :telemetry.execute([:lasso, :subs, :failover, :degraded], %{count: 1}, %{
      chain: chain,
      key: inspect(key)
    })
  end

  defp fetch_head(chain, provider_id) do
    case Lasso.RPC.RequestPipeline.execute_via_channels(
      chain,
      "eth_blockNumber",
      [],
      strategy: :priority,
      provider_override: provider_id,
      failover_on_override: false
    ) do
      {:ok, "0x" <> _ = hex} ->
        String.to_integer(String.trim_leading(hex, "0x"), 16)

      _ ->
        0
    end
  end
end
```

### Phase 2: Testing Strategy

#### Unit Tests

**Test StreamCoordinator Failover State Machine**

```elixir
defmodule Lasso.RPC.StreamCoordinatorTest do
  use ExUnit.Case, async: false

  describe "failover state machine" do
    test "transitions from :active to :backfilling on provider_unhealthy" do
      # Setup coordinator in :active state
      # Send {:provider_unhealthy, "infura", "alchemy"}
      # Assert failover_status == :backfilling
      # Assert failover_context is set
    end

    test "transitions from :backfilling to :switching after backfill completes" do
      # Setup coordinator in :backfilling state
      # Complete backfill task
      # Assert failover_status == :switching
      # Assert {:resubscribe, ...} message sent to Pool
    end

    test "transitions from :switching to :active on subscription_confirmed" do
      # Setup coordinator in :switching state
      # Send {:subscription_confirmed, "alchemy", "0xabc"}
      # Assert failover_status == :active
      # Assert primary_provider_id == "alchemy"
    end

    test "buffers events during :backfilling status" do
      # Setup coordinator in :backfilling state
      # Send {:upstream_event, ...} messages
      # Assert events are buffered (not emitted to clients)
      # Complete failover
      # Assert buffered events are drained through dedupe
    end

    test "drains event buffer after failover completes" do
      # Setup coordinator with buffered events
      # Transition to :active
      # Assert buffered events processed through StreamState.ingest_*
      # Assert dedupe prevents duplicates
    end
  end

  describe "circuit breaker" do
    test "enters degraded mode after max_failover_attempts" do
      # Trigger 3 rapid failovers
      # Assert failover_status == :degraded
      # Assert telemetry event emitted
    end

    test "respects failover_cooldown_ms window" do
      # Trigger failover at T=0
      # Advance time by cooldown_ms
      # Trigger failover at T=cooldown_ms+1
      # Assert circuit breaker does NOT trigger
    end
  end

  describe "backfill error handling" do
    test "retries backfill on transient HTTP errors" do
      # Mock GapFiller.ensure_blocks to fail 2 times, succeed on 3rd
      # Trigger failover
      # Assert backfill retried with exponential backoff
      # Assert failover completes successfully
    end

    test "cascades to next provider on persistent backfill failure" do
      # Mock GapFiller.ensure_blocks to always fail for provider A
      # Mock successful for provider B
      # Trigger failover to A
      # Assert cascade to B
      # Assert failover completes successfully with B
    end
  end
end
```

**Test UpstreamSubscriptionPool Resubscription**

```elixir
defmodule Lasso.RPC.UpstreamSubscriptionPoolTest do
  use ExUnit.Case, async: false

  describe "resubscription" do
    test "handles {:resubscribe, ...} message successfully with old-upstream cleanup" do
      # Setup Pool with active subscription to provider A
      # Send {:resubscribe, key, provider_b, coordinator_pid}
      # Assert send_upstream_subscribe called with provider B
      # Assert eth_unsubscribe called for old upstream
      # Assert {:subscription_confirmed, provider_b, upstream_id} sent to coordinator
      # Assert upstream_index updated
    end

    test "sends {:subscription_failed, reason} on eth_subscribe error" do
      # Mock send_upstream_subscribe to return {:error, reason}
      # Send {:resubscribe, ...}
      # Assert {:subscription_failed, reason} sent to coordinator
    end

    test "handles resubscribe when key no longer exists" do
      # Setup Pool with no active subscriptions for key
      # Send {:resubscribe, key, provider, coordinator_pid}
      # Assert {:subscription_failed, :key_inactive} sent to coordinator
    end
  end
end
```

#### Integration Tests

**End-to-End Failover Flow**

```elixir
defmodule Lasso.RPC.FailoverIntegrationTest do
  use ExUnit.Case, async: false

  setup do
    # Start full supervision tree
    # Setup mock providers (A, B, C)
    # Subscribe test client to newHeads
    on_exit(fn -> cleanup_supervision_tree() end)
  end

  test "complete failover with gap filling and deterministic buffer ordering" do
    # 1. Establish subscription on provider A
    {:ok, sub_id} = subscribe_to_newheads()

    # 2. Receive blocks 100-110 from provider A
    assert_receive {:subscription_event, %{"result" => %{"number" => "0x64"}}}
    # ... blocks 101-110 ...

    # 3. Simulate provider A failure
    trigger_provider_failure("provider_a")

    # 4. Assert Pool notifies Coordinator
    # (internal assertion via telemetry or logs)

    # 5. Assert backfill fetches blocks 111-120 via HTTP
    # (mock HTTP responses)

    # 6. Assert resubscription to provider B
    # (mock WebSocket subscription success)

    # 7. Assert blocks 111-120 delivered to client (gap filled)
    for n <- 111..120 do
      hex = "0x" <> Integer.to_string(n, 16)
      assert_receive {:subscription_event, %{"result" => %{"number" => ^hex}}}
    end

    # 8. Assert blocks 121+ delivered from provider B (live)
    assert_receive {:subscription_event, %{"result" => %{"number" => "0x79"}}}

    # 9. Assert no duplicates delivered by block hash; ordering by blockNumber asc
  end

  test "cascading failover when first candidate fails (decoupled HTTP provider)" do
    # 1. Establish subscription on provider A
    # 2. Trigger provider A failure
    # 3. Mock provider B backfill failure
    # 4. Assert cascade to provider C
    # 5. Assert successful failover to C
    # 6. Assert no gaps in delivered blocks
  end

  test "circuit breaker after multiple rapid failures" do
    # 1. Establish subscription
    # 2. Trigger 3 rapid provider failures
    # 3. Assert coordinator enters degraded mode
    # 4. Assert no more failover attempts
    # 5. Wait for cooldown
    # 6. Trigger retry
    # 7. Assert failover resumes
  end
end
```

#### Chaos Tests (Failure Injection)

**Timing and Race Condition Tests**

```elixir
defmodule Lasso.RPC.ChaosTest do
  use ExUnit.Case, async: false

  test "events arrive during backfill" do
    # 1. Start failover
    # 2. While in :backfilling, send upstream_event from old provider
    # 3. Assert event buffered
    # 4. Complete failover
    # 5. Assert buffered event deduplicated if also in backfill
  end

  test "head-lag gating excludes lagging providers" do
    # 1. Mark provider A lagging in ProviderHeadCache (lag > threshold)
    # 2. Trigger failover; assert selection skips A and picks B
  end

  test "all providers lagging selects least-lagging and still completes" do
    # 1. Mark all WS providers lagging with varying lags
    # 2. Trigger failover; assert least-lagging chosen, buffer drains, no duplicates
  end

  test "stalled provider opens height-lag circuit" do
    # 1. Simulate no head updates for stall_open_ms
    # 2. Assert circuit opens; selection excludes provider until probe succeeds
  end

  test "coordinator crashes during backfill" do
    # 1. Start failover
    # 2. During backfill, crash coordinator process
    # 3. Assert supervisor restarts coordinator
    # 4. Assert Pool re-initiates subscription
    # 5. Assert continuity maintained (no gaps)
  end

  test "pool crashes during resubscription" do
    # 1. Start failover, reach :switching state
    # 2. Crash Pool process
    # 3. Assert supervisor restarts Pool
    # 4. Assert coordinator times out waiting for confirmation
    # 5. Assert coordinator retries or enters degraded mode
  end

  test "network partition during failover" do
    # 1. Start failover
    # 2. During backfill, simulate network partition (HTTP timeouts)
    # 3. Assert backfill retries
    # 4. Restore network
    # 5. Assert failover completes successfully
  end

  test "concurrent failovers for multiple keys" do
    # 1. Subscribe to {:newHeads} and {:logs, filter}
    # 2. Trigger provider failure affecting both
    # 3. Assert both coordinators initiate failover concurrently
    # 4. Assert both complete successfully
    # 5. Assert no resource contention issues
  end
end
```

### Phase 3: Rollout Strategy

#### Stage 1: Feature Flag (Week 1)

- Deploy code with failover disabled by default
- Enable via config per-chain:
  ```elixir
  config :lasso, :failover_enabled, %{
    "ethereum" => false,
    "polygon" => false
  }
  ```
- Validate no regressions in normal operation

#### Stage 2: Canary (Week 2)

- Enable failover for low-traffic chain (e.g., "goerli" testnet)
- Monitor telemetry:
  - Failover initiation count
  - Backfill duration (p50, p99)
  - Resubscription success rate
  - Event buffer sizes
- Inject chaos tests in staging

#### Stage 3: Gradual Rollout (Week 3-4)

- Enable for 10% of production chains
- Monitor error rates, latency, correctness metrics
- Increase to 50%, then 100%

#### Stage 4: Remove Old Code (Week 5)

- After 100% rollout and 1 week of stable operation
- Remove dead code (old incomplete failover attempts)
- Remove feature flags

### Rollback Plan

If critical issues discovered:

1. **Immediate**: Set `failover_enabled: false` via hot config update
2. **Fallback**: Revert to previous git commit (pre-failover code)
3. **Investigation**: Use telemetry and logs to diagnose issue
4. **Fix**: Address issue in development environment with additional tests
5. **Re-deploy**: Follow staged rollout again

---

## Summary of Critical Flaw Resolutions

### Critical Flaw #1: Incomplete Message Chain ✅

**Fixed by**: Adding `handle_info({:resubscribe, ...})` handler to UpstreamSubscriptionPool

- Pool now responds to resubscription requests from Coordinator
- Executes `send_upstream_subscribe/3` with new provider
- Updates `upstream_index` mapping
- Sends confirmation back to Coordinator

### Critical Flaw #2: Dead Confirmation Mechanism ✅

**Fixed by**: Implementing bidirectional confirmation flow

- Pool sends `{:subscription_confirmed, provider_id, upstream_id}` on success
- Pool sends `{:subscription_failed, reason}` on error
- Coordinator handles both messages with appropriate state transitions
- Retry logic in Coordinator handles failures

### Critical Flaw #3: Async Backfill Race Condition ✅

**Fixed by**: Synchronous state machine with event buffering

- Coordinator enters :backfilling state before spawning Task
- All upstream_event messages buffered during :backfilling and :switching
- Backfill completes → resubscribe → confirmation → drain buffer → resume
- Atomic transition prevents race conditions

### Critical Flaw #4: Provider Selection Mismatch ✅

**Fixed by**: Coordinator validates provider and Pool confirms capabilities

- Pool validates provider supports required capability (newHeads/logs)
- Selection.select_provider uses `:exclude` to avoid recently failed providers
- Coordinator cascades to next provider if resubscription fails
- Circuit breaker prevents infinite loops

---

## Appendix: Configuration Reference

```elixir
# Per-chain failover configuration
config :lasso, :failover, %{
  # Enable/disable failover per chain
  enabled: true,

  # Max blocks to backfill during failover (prevents unbounded HTTP fetches)
  max_backfill_blocks: 32,

# HTTP timeout for backfill requests
backfill_timeout_ms: 30_000,
backfill_concurrency_per_chain: 3,

  # Continuity policy: :best_effort (fill what we can) or :strict_abort (fail if gap too large)
  continuity_policy: :best_effort,

  # Circuit breaker settings
  max_failover_attempts: 3,
  failover_cooldown_ms: 5_000,

  # Event buffer limits during transition
  max_event_buffer: 100,

  # Degraded mode recovery
  degraded_mode_retry_delay_ms: 30_000
}
```

```elixir
# Provider head monitoring (optional but recommended)
config :lasso, :head_monitoring, %{
  head_probe_interval_ms: 2_000,
  head_probe_timeout_ms: 1_000,
  head_cache_ttl_ms: 5_000,
  max_head_lag_blocks: 4,
  stall_open_ms: 10_000
}
```

---

## Success Metrics

### Correctness (Must be 100%)

- [ ] Zero gap events detected in telemetry
- [ ] Zero duplicate events detected by content identity (block hash for blocks; (blockHash, transactionHash, logIndex) for logs)
- [ ] Ordering preserved: blocks sorted by blockNumber asc; logs by (blockNumber, transactionIndex, logIndex)

### Resilience

- [ ] 99.9% failover success rate (single provider failure)
- [ ] 95% success rate for cascading failures (2+ providers)
- [ ] <1% of subscriptions enter degraded mode

### Performance

- [ ] P50 failover duration: <10 seconds
- [ ] P99 failover duration: <30 seconds
- [ ] Normal event latency: <100ms (no regression)
- [ ] Memory bounded: dedupe cache cleanup works

### Observability

- [ ] Telemetry events emitted for all failover phases
- [ ] Dashboards track: failover rate, duration, success rate
- [ ] Alerts trigger on: degraded mode, circuit breaker, high failure rate

---

**End of Specification**

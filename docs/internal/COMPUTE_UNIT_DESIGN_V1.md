Compute Unit System Design

Key Insights from Product Spec

From docs/internal/PRODUCT_SPEC_V3.md:

CU cost = (bytes_in + bytes_out) / 1024 \* method_multiplier

Method Multipliers:

- Core: 1.0 (eth_blockNumber, eth_chainId)
- State: 1.5 (eth_call, eth_estimateGas)
- Filters: 2.0 (eth_getLogs)
- Debug: 5.0 (debug_traceTransaction, trace_block)

Minimum: 1 CU per request

Async Metering:

- Writes to ETS buffer, flushes periodically to DB
- CU limits checked every 60s (not per-request)
- Over-limit subscriptions marked in ETS for rate limiting

Design Principles (from auth optimization)

1. Zero DB queries on hot path - everything from ETS
2. Async processing for writes - telemetry/GenServer pattern
3. Eventual consistency acceptable - periodic sync, not per-request

---

Architecture

                            HOT PATH (~0.1ms)

┌─────────────────────────────────────────────────────────┐
│ Request │
│ ↓ │
│ KeyCache.lookup(key) → check cu_over_limit flag │
│ ↓ │
│ RPC Pipeline → Response │
│ ↓ │
│ Emit telemetry: {:cu_usage, account_id, profile, cu} │
└─────────────────────────────────────────────────────────┘
│
│ async
▼
┌─────────────────────────────────────────────────────────┐
│ BACKGROUND WORKERS │
│ │
│ CUAccumulator (GenServer) │
│ ├── Receives telemetry events │
│ ├── Buffers in ETS: {account_id, profile} → count │
│ └── Flushes to DB every 10s or 1000 events │
│ │
│ CULimitChecker (periodic task) │
│ ├── Runs every 60s │
│ ├── Queries DB for accounts over limit │
│ └── Updates KeyCache with cu_over_limit flag │
└─────────────────────────────────────────────────────────┘

---

1. Method Cost Map

# lib/lasso_cloud/metering/cu_cost.ex

defmodule LassoCloud.Metering.CUCost do
@method_multipliers %{ # Core (1.0)
"eth_blockNumber" => 1.0,
"eth_chainId" => 1.0,
"eth_gasPrice" => 1.0,
"eth_syncing" => 1.0,
"net_version" => 1.0,

      # State (1.5)
      "eth_call" => 1.5,
      "eth_estimateGas" => 1.5,
      "eth_getBalance" => 1.5,
      "eth_getCode" => 1.5,
      "eth_getStorageAt" => 1.5,
      "eth_getTransactionCount" => 1.5,

      # Filters (2.0)
      "eth_getLogs" => 2.0,
      "eth_newFilter" => 2.0,
      "eth_getFilterLogs" => 2.0,

      # Debug/Trace (5.0)
      "debug_traceTransaction" => 5.0,
      "debug_traceCall" => 5.0,
      "trace_block" => 5.0,
      "trace_transaction" => 5.0
    }

    @default_multiplier 1.0

    def calculate(method, bytes_in, bytes_out) do
      multiplier = Map.get(@method_multipliers, method, @default_multiplier)
      raw_cu = (bytes_in + bytes_out) / 1024 * multiplier
      max(1, ceil(raw_cu))  # Minimum 1 CU
    end

    def multiplier(method), do: Map.get(@method_multipliers, method, @default_multiplier)

end

---

2. Extended KeyCache Structure

# Already in KeyCache, extend subscription data:

%{
account_id: uuid,
enabled: boolean,
subscriptions: %{
"lasso-free" => %{
rps_limit: 10,
burst_limit: 20,
cu_limit: 100_000, # From subscription
cu_over_limit: false # Updated by CULimitChecker
}
}
}

Hot-path check (already happening in auth):

# In check_subscription_access

case cached_subs[profile_slug] do
%{cu_over_limit: true} -> {:error, :cu_limit_exceeded}
%{} = sub_data -> {:ok, sub_data}
...
end

---

3. CU Accumulator (Async Buffer)

# lib/lasso_cloud/metering/cu_accumulator.ex

defmodule LassoCloud.Metering.CUAccumulator do
use GenServer

    @table :cu_accumulator
    @flush_interval 10_000        # 10 seconds
    @flush_threshold 1_000        # Or 1000 events

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def record(account_id, profile_slug, cu_amount) do
      # Direct ETS write - no GenServer bottleneck
      key = {account_id, profile_slug}
      :ets.update_counter(@table, key, {2, cu_amount}, {key, 0})
    end

    @impl true
    def init(_opts) do
      :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
      schedule_flush()
      {:ok, %{}}
    end

    @impl true
    def handle_info(:flush, state) do
      flush_to_database()
      schedule_flush()
      {:noreply, state}
    end

    defp flush_to_database do
      entries = :ets.tab2list(@table)
      :ets.delete_all_objects(@table)

      # Batch upsert to usage_daily table
      Enum.each(entries, fn {{account_id, profile_slug}, cu_amount} ->
        Metering.increment_daily_usage(account_id, profile_slug, cu_amount)
      end)
    end

    defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval)

end

---

4. CU Limit Checker (Periodic)

# lib/lasso_cloud/metering/cu_limit_checker.ex

defmodule LassoCloud.Metering.CULimitChecker do
use GenServer

    @check_interval 60_000  # 60 seconds

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      schedule_check()
      {:ok, %{}}
    end

    @impl true
    def handle_info(:check_limits, state) do
      check_and_update_limits()
      schedule_check()
      {:noreply, state}
    end

    defp check_and_update_limits do
      # Query accounts that are over their CU limit this period
      over_limit_accounts = Metering.list_over_limit_subscriptions()

      # Update KeyCache for each affected account
      Enum.each(over_limit_accounts, fn {account_id, profile_slug} ->
        KeyCache.set_cu_over_limit(account_id, profile_slug, true)
      end)

      # Also reset flag for accounts back under limit
      under_limit_accounts = Metering.list_under_limit_subscriptions()
      Enum.each(under_limit_accounts, fn {account_id, profile_slug} ->
        KeyCache.set_cu_over_limit(account_id, profile_slug, false)
      end)
    end

    defp schedule_check, do: Process.send_after(self(), :check_limits, @check_interval)

end

---

5. Integration Point (Post-Request)

# In RPC handler, after response:

defp record_usage(ctx, response) do
cu = CUCost.calculate(ctx.method, ctx.request_bytes, byte_size(response))
CUAccumulator.record(ctx.account_id, ctx.profile_slug, cu)

    # Optional: Include in response metadata
    %{cu_cost: cu}

end

---

6. Database Schema Addition

-- Daily usage aggregation (append-only, efficient for writes)
CREATE TABLE usage_daily (
id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
account_id UUID NOT NULL REFERENCES accounts(id),
profile_slug VARCHAR(50) NOT NULL,
date DATE NOT NULL DEFAULT CURRENT_DATE,
cu_used BIGINT NOT NULL DEFAULT 0,
request_count INTEGER NOT NULL DEFAULT 0,
UNIQUE (account_id, profile_slug, date)
);

-- Add to subscriptions
ALTER TABLE subscriptions ADD COLUMN cu_limit BIGINT DEFAULT 100000;
ALTER TABLE subscriptions ADD COLUMN period_start DATE DEFAULT CURRENT_DATE;

---

Latency Analysis
┌──────────────────────────────┬──────────┬────────────────────────────────┐
│ Component │ Latency │ Notes │
├──────────────────────────────┼──────────┼────────────────────────────────┤
│ CU cost lookup │ ~0.001ms │ Module attribute map │
├──────────────────────────────┼──────────┼────────────────────────────────┤
│ KeyCache cu_over_limit check │ ~0.001ms │ Already in subscription lookup │
├──────────────────────────────┼──────────┼────────────────────────────────┤
│ CUAccumulator.record │ ~0.001ms │ Direct ETS counter update │
├──────────────────────────────┼──────────┼────────────────────────────────┤
│ Total hot-path addition │ ~0.003ms │ Negligible │
└──────────────────────────────┴──────────┴────────────────────────────────┘
Background processing (not on hot path):

- Flush to DB: Every 10s, batched
- Limit check: Every 60s, single query

---

Edge Cases
┌─────────────────────────────┬───────────────────────────────────────────────────────────┐
│ Scenario │ Behavior │
├─────────────────────────────┼───────────────────────────────────────────────────────────┤
│ New account (no usage yet) │ cu_over_limit defaults to false │
├─────────────────────────────┼───────────────────────────────────────────────────────────┤
│ Exactly at limit │ Next check marks over_limit │
├─────────────────────────────┼───────────────────────────────────────────────────────────┤
│ Period rollover │ Cron job resets period_start, clears daily usage │
├─────────────────────────────┼───────────────────────────────────────────────────────────┤
│ Account upgrades mid-period │ Limit increases, check clears flag │
├─────────────────────────────┼───────────────────────────────────────────────────────────┤
│ Cache miss on new key │ subscription data includes cu_limit, cu_over_limit: false │
└─────────────────────────────┴───────────────────────────────────────────────────────────┘

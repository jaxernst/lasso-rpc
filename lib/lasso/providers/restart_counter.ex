defmodule Lasso.Providers.RestartCounter do
  @moduledoc """
  Per-child restart counter for the BlockSync.Worker and ProbeCoordinator
  supervision subtrees.

  See `docs/internal/custom-profiles/CHAIN_ARCHITECTURE_V2.md` §6 for the
  full rationale. Summary:

    * `BlockSync.DynamicSupervisor` and `Providers.ProbeSupervisor` keep
      the OTP default `max_restarts: 3, max_seconds: 5`. A flapping child
      would otherwise take the whole `DynamicSupervisor` down within
      seconds, blocking block-sync cluster-wide.
    * Per-child backoff is implemented here, applied from
      `handle_continue(:deferred_start, …)` so init returns immediately
      and the restart window doesn't fill up.

  ## Key shapes

    * `{:block_sync, instance_id :: String.t()}` — BlockSync.Worker
    * `{:probe_coord, chain_id :: pos_integer()}` — ProbeCoordinator

  ## Ownership

  The ETS table `:lasso_restart_counts` is owned by
  `Lasso.Providers.Catalog.Owner` (a long-lived GenServer that already
  owns the Catalog persistent_term-backed table). Owning ETS from a
  process that outlives every worker means counters survive worker
  restarts but die cleanly with the application.

  ## Why ETS over persistent_term

  Restart counts are high-churn under burst conditions (cluster-wide
  config push triggers many worker crashes simultaneously).
  `:persistent_term.put/2` triggers a global GC on every write — OTP
  flags it for "rarely-changing data." ETS writes are cheap.
  """

  @table :lasso_restart_counts

  @type key :: {:block_sync, String.t()} | {:probe_coord, pos_integer()}

  @doc """
  Creates the restart-counter ETS table. Called by `Catalog.Owner.init/1`.

  Idempotent: a duplicate create from a test reload is a no-op.
  """
  @spec init_table() :: :ok
  def init_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Atomically increments the counter for `key`, creating it with a base
  of 0 if absent. Returns the post-increment value.
  """
  @spec bump(key()) :: pos_integer()
  def bump(key) do
    :ets.update_counter(@table, key, 1, {key, 0})
  end

  @doc """
  Deletes the counter for `key`. Idempotent.
  """
  @spec clear(key()) :: :ok
  def clear(key) do
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Per-child backoff schedule.

  Counts:

    * 1   — cold start jitter (100–300ms)
    * 2   — ~1–2s
    * 3   — ~5–10s
    * <10 — ~15–30s
    * 10+ — ~60–120s (capped)

  The first call after a clean spawn returns 100–300ms so a healthy
  first start is barely slower than the previous fixed 2s delay.
  """
  @spec backoff_for(pos_integer()) :: pos_integer()
  def backoff_for(1), do: 100 + :rand.uniform(200)
  def backoff_for(2), do: 1_000 + :rand.uniform(1_000)
  def backoff_for(3), do: 5_000 + :rand.uniform(5_000)
  def backoff_for(n) when n < 10, do: 15_000 + :rand.uniform(15_000)
  def backoff_for(_), do: 60_000 + :rand.uniform(60_000)
end

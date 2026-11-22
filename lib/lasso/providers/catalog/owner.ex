defmodule Lasso.Providers.Catalog.Owner do
  @moduledoc """
  Long-lived owner of the `Lasso.Providers.Catalog` ETS tables.

  Catalog reads stay lockless via `:persistent_term`. Writes (atomic-swap
  rebuilds) are serialized through this GenServer so that:

    1. The freshly-built ETS table is owned by a stable process. ETS
       tables die with their owner; without a long-lived owner, callers
       like test processes or transient Tasks leave `:persistent_term`
       pointing at a dead tid.
    2. Old tables can be deleted properly. `:ets.delete/1` requires the
       calling process to be the owner — only this GenServer satisfies
       that for tables it created.
  """

  use GenServer
  require Logger

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{Catalog, RestartCounter}
  alias Lasso.RPC.{AttemptProjection, RequestAggregate}

  @grace_period_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Rebuilds the catalog from current `ConfigStore` state.

  Synchronous: the caller blocks until the new table is published. A failed
  build discards its candidate and raises in the caller; the owner and the
  previously published table remain alive.
  """
  @spec rebuild() :: :ok
  def rebuild do
    case GenServer.call(__MODULE__, :rebuild, :infinity) do
      :ok -> :ok
      {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  ## GenServer callbacks

  @impl true
  def init(_) do
    RestartCounter.init_table()
    {:ok, %{}, {:continue, :self_heal_catalog}}
  end

  # If the previous Owner crashed, `:persistent_term` still points at
  # the dead ETS tid. Reads via `Catalog.safe_lookup/1` would silently
  # return empty until a profile config change triggers a rebuild —
  # which can be hours of degraded routing in the worst case. On a
  # fresh boot (no persistent_term entry) `InfrastructureStarter`
  # handles the initial population, so this self-heal is a no-op.
  # Failed crash-recovery rebuilds retry while the published table is dead.
  @impl true
  def handle_continue(:self_heal_catalog, state) do
    case Catalog.snapshot() do
      nil ->
        :ok

      %{table: tid} ->
        if :ets.info(tid, :size) == :undefined do
          try do
            do_rebuild()
            Logger.info("Catalog.Owner self-healed catalog after a crash restart")
          rescue
            e ->
              message = Exception.message(e)
              Logger.warning("Catalog.Owner self-heal failed: " <> message)
              emit_rebuild_failed(:crash_recovery, message)
              Process.send_after(self(), :retry_self_heal_catalog, 1_000)
          end
        end
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:rebuild, _from, state) do
    do_rebuild()
    {:reply, :ok, state}
  catch
    kind, reason ->
      # Only the unpublished candidate is discarded by do_rebuild. The
      # owner and its last coherent table must survive malformed config.
      Logger.warning("Catalog rebuild failed; retaining published snapshot",
        failure_kind: kind
      )

      emit_rebuild_failed(:config_change, Exception.format_banner(kind, reason))
      {:reply, {:raised, kind, reason, __STACKTRACE__}, state}
  end

  @impl true
  def handle_info(:retry_self_heal_catalog, state) do
    handle_continue(:self_heal_catalog, state)
  end

  @impl true
  def handle_info({:delete_table, table}, state) do
    try do
      :ets.delete(table)
    rescue
      ArgumentError -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:catalog_publication_continue, _ref, _phase}, state), do: {:noreply, state}

  defp emit_rebuild_failed(trigger, message) do
    :telemetry.execute([:lasso, :provider_catalog, :rebuild_failed], %{count: 1}, %{
      trigger: trigger,
      message: message
    })
  end

  defp do_rebuild do
    new_table = :ets.new(:lasso_provider_catalog, [:public, :set, read_concurrency: true])

    try do
      generation = ConfigStore.route_generation()
      :ok = Catalog.populate(new_table, generation)
      publication_barrier(:after_catalog_populate, generation)
      continue_rebuild(new_table, generation)
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        if :ets.info(new_table, :owner) == self(), do: :ets.delete(new_table)
        restore_published_routes()
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp continue_rebuild(new_table, generation) do
    if ConfigStore.route_generation() == generation do
      routes = Catalog.routing_control_routes(new_table)
      # Finish all candidate derivation before changing shared control rows.
      plans = Catalog.routing_plans(new_table)
      aggregates = RequestAggregate.prepare(generation, plans, Catalog.snapshot())
      heads = Catalog.head_scopes_by_instance(plans)

      snapshot = %{
        table: new_table,
        generation: generation,
        routing_plans: plans,
        request_budgets: Catalog.request_budgets(new_table),
        request_aggregates: aggregates,
        head_scopes_by_instance: heads
      }

      if ConfigStore.route_generation() == generation do
        finish_rebuild(new_table, generation, routes, snapshot)
      else
        retry_rebuild(new_table)
      end
    else
      retry_rebuild(new_table)
    end
  end

  defp finish_rebuild(new_table, generation, routes, snapshot) do
    if ConfigStore.route_generation() != generation do
      retry_rebuild(new_table)
    else
      AttemptProjection.reconcile_routes(generation, routes)

      unless AttemptProjection.routes_ready?(generation, routes),
        do: raise("routing control publication was incomplete")

      publication_barrier(:after_control_populate, generation)

      if ConfigStore.route_generation() == generation do
        publication_barrier(:before_pointer_swap, generation)

        if ConfigStore.route_generation() == generation,
          do: publish(snapshot),
          else: retry_rebuild(new_table)
      else
        retry_rebuild(new_table)
      end
    end
  end

  defp restore_published_routes do
    case Catalog.snapshot() do
      %{table: table, generation: generation} ->
        # A cold owner restart has no retained live catalog to restore.
        if :ets.info(table, :size) != :undefined do
          AttemptProjection.reconcile_routes(generation, Catalog.routing_control_routes(table))
        end

      nil ->
        :ok
    end
  end

  defp retry_rebuild(new_table) do
    restore_published_routes()
    :ets.delete(new_table)
    do_rebuild()
  end

  defp publish(snapshot) do
    old_table = Catalog.table()
    :persistent_term.put(Catalog.persistent_term_key(), snapshot)
    Lasso.BlockSync.Registry.clear_scoped_head_snapshots()
    Lasso.BlockSync.Registry.retain_head_lags(snapshot.routing_plans)
    if old_table, do: Process.send_after(self(), {:delete_table, old_table}, @grace_period_ms)
    :ok
  end

  defp publication_barrier(phase, generation) do
    case Application.get_env(:lasso, :catalog_publication_barrier) do
      {observer, ref} when is_pid(observer) and is_reference(ref) ->
        send(observer, {:catalog_publication_phase, self(), ref, phase, generation})

        receive do
          {:catalog_publication_continue, ^ref, ^phase} -> :ok
        end

      _other ->
        :ok
    end
  end
end

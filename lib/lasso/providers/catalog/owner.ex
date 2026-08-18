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
  alias Lasso.RPC.AttemptProjection

  @grace_period_ms 2_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Rebuilds the catalog from current `ConfigStore` state.

  Synchronous: the caller blocks until the new table is published.
  """
  @spec rebuild() :: :ok
  def rebuild do
    GenServer.call(__MODULE__, :rebuild, :infinity)
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
  # Rebuild attempts are tolerated to fail (ConfigStore may not be up
  # yet on a co-restart) — the InfrastructureStarter path still runs
  # afterwards on first boot.
  @impl true
  def handle_continue(:self_heal_catalog, state) do
    case Catalog.snapshot() do
      nil ->
        :ok

      %{table: tid} ->
        try do
          _ = :ets.info(tid, :size)
          :ok
        rescue
          ArgumentError ->
            try do
              do_rebuild()
              Logger.info("Catalog.Owner self-healed catalog after a crash restart")
            rescue
              e ->
                Logger.warning(
                  "Catalog.Owner self-heal deferred to InfrastructureStarter: " <>
                    Exception.message(e)
                )
            end
        end
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:rebuild, _from, state) do
    do_rebuild()
    {:reply, :ok, state}
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

  defp do_rebuild do
    new_table = :ets.new(:lasso_provider_catalog, [:public, :set, read_concurrency: true])
    generation = ConfigStore.route_generation()

    try do
      Catalog.populate(new_table, generation)
      publication_barrier(:after_catalog_populate, generation)
    rescue
      e ->
        # Drop the half-built table so it doesn't leak; `:persistent_term`
        # still points at the previous good table, so readers are unaffected.
        :ets.delete(new_table)
        reraise e, __STACKTRACE__
    end

    continue_rebuild(new_table, generation)
  end

  defp continue_rebuild(new_table, generation) do
    if ConfigStore.route_generation() == generation do
      routes = Catalog.routing_control_routes(new_table)
      AttemptProjection.reconcile_routes(generation, routes)

      if ConfigStore.route_generation() == generation do
        finish_rebuild(new_table, generation, routes)
      else
        retry_rebuild(new_table)
      end
    else
      retry_rebuild(new_table)
    end
  end

  defp finish_rebuild(new_table, generation, routes) do
    unless AttemptProjection.routes_ready?(generation, routes) do
      :ets.delete(new_table)
      raise "routing control publication was incomplete"
    end

    publication_barrier(:after_control_populate, generation)

    if ConfigStore.route_generation() != generation do
      :ets.delete(new_table)
      do_rebuild()
    else
      routing_plans = Catalog.routing_plans(new_table)
      publication_barrier(:before_pointer_swap, generation)

      if ConfigStore.route_generation() != generation do
        :ets.delete(new_table)
        do_rebuild()
      else
        publish(new_table, generation, routing_plans)
      end
    end
  end

  defp retry_rebuild(new_table) do
    :ets.delete(new_table)
    do_rebuild()
  end

  defp publish(new_table, generation, routing_plans) do
    key = Catalog.persistent_term_key()
    old_table = Catalog.table()

    snapshot = %{
      table: new_table,
      generation: generation,
      routing_plans: routing_plans
    }

    :persistent_term.put(key, snapshot)

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

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

  alias Lasso.Providers.{Catalog, RestartCounter}

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
    key = Catalog.persistent_term_key()

    case :persistent_term.get(key, nil) do
      nil ->
        :ok

      tid ->
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

  defp do_rebuild do
    new_table = :ets.new(:lasso_provider_catalog, [:public, :set, read_concurrency: true])

    try do
      Catalog.populate(new_table)
    rescue
      e ->
        # Drop the half-built table so it doesn't leak; `:persistent_term`
        # still points at the previous good table, so readers are unaffected.
        :ets.delete(new_table)
        reraise e, __STACKTRACE__
    end

    key = Catalog.persistent_term_key()
    old_table = :persistent_term.get(key, nil)
    :persistent_term.put(key, new_table)

    if old_table, do: Process.send_after(self(), {:delete_table, old_table}, @grace_period_ms)
    :ok
  end
end

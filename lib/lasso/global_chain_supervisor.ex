defmodule Lasso.GlobalChainSupervisor do
  @moduledoc """
  DynamicSupervisor for per-chain global processes shared across profiles.

  This supervisor manages chain-level components that are shared across all profiles
  using that chain:
  - BlockSync.Supervisor - Tracks block heights from all profiles' providers
  - HealthProbe.Supervisor - Monitors provider health for circuit breaker recovery

  ## Reference Counting

  Global chain processes are started when the first profile using a chain loads,
  and stopped when the last profile using that chain unloads. Reference counts
  are stored in the `:lasso_chain_refcount` ETS table.

  ## Architecture

  ```
  GlobalChainSupervisor (DynamicSupervisor)
  └── GlobalChainProcesses (per chain, Supervisor)
      ├── BlockSync.Supervisor
      └── HealthProbe.Supervisor
  ```

  Workers within BlockSync.Supervisor and HealthProbe.Supervisor use composite
  keys `{profile, provider_id}` to track providers across profiles.
  """

  use DynamicSupervisor
  require Logger

  @ets_table :lasso_chain_refcount

  ## Client API

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensure global processes are running for a chain.

  This function is idempotent - calling it multiple times for the same chain
  has no effect if processes are already running. Increments the reference
  count for the chain.

  Call this when a profile that uses this chain is loaded.
  """
  @spec ensure_chain_processes(String.t()) :: :ok | {:error, term()}
  def ensure_chain_processes(chain) when is_binary(chain) do
    # Increment reference count atomically
    new_count = increment_ref(chain)

    if new_count == 1 do
      # First profile using this chain - start processes
      start_chain_processes(chain)
    else
      # Processes already running
      :ok
    end
  end

  @doc """
  Stop global processes for a chain when no longer needed.

  This function decrements the reference count and only stops processes
  when the count reaches zero (no profiles using this chain).

  Call this when a profile that uses this chain is unloaded.
  """
  @spec stop_chain_processes(String.t()) :: :ok
  def stop_chain_processes(chain) when is_binary(chain) do
    new_count = decrement_ref(chain)

    if new_count == 0 do
      # Last profile using this chain - stop processes
      do_stop_chain_processes(chain)
    else
      :ok
    end
  end

  @doc """
  Get the current reference count for a chain.
  """
  @spec get_ref_count(String.t()) :: non_neg_integer()
  def get_ref_count(chain) when is_binary(chain) do
    case :ets.lookup(@ets_table, chain) do
      [{^chain, count}] -> count
      [] -> 0
    end
  end

  @doc """
  Check if global processes are running for a chain.
  """
  @spec chain_running?(String.t()) :: boolean()
  def chain_running?(chain) when is_binary(chain) do
    GenServer.whereis(via_processes(chain)) != nil
  end

  @doc """
  List all chains with running global processes.
  """
  @spec list_running_chains() :: [String.t()]
  def list_running_chains do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} ->
      case Registry.keys(Lasso.Registry, pid) do
        [{:global_chain_processes, chain}] -> chain
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  ## DynamicSupervisor Callbacks

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  ## Private Functions

  defp start_chain_processes(chain) do
    spec = {Lasso.GlobalChainProcesses, chain}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _pid} ->
        Logger.info("Started global chain processes", chain: chain)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to start global chain processes",
          chain: chain,
          reason: inspect(reason)
        )

        # Rollback ref count
        decrement_ref(chain)
        {:error, reason}
    end
  end

  defp do_stop_chain_processes(chain) do
    case GenServer.whereis(via_processes(chain)) do
      nil ->
        :ok

      pid ->
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok ->
            Logger.info("Stopped global chain processes", chain: chain)
            :ok

          {:error, :not_found} ->
            :ok
        end
    end
  end

  defp via_processes(chain) do
    {:via, Registry, {Lasso.Registry, {:global_chain_processes, chain}}}
  end

  defp increment_ref(chain) do
    :ets.update_counter(@ets_table, chain, {2, 1}, {chain, 0})
  end

  defp decrement_ref(chain) do
    new_count = :ets.update_counter(@ets_table, chain, {2, -1, 0, 0}, {chain, 0})

    # Clean up ETS entry if count is zero
    if new_count == 0 do
      :ets.delete(@ets_table, chain)
    end

    new_count
  end
end

defmodule Lasso.GlobalChainProcesses do
  @moduledoc """
  Per-chain Supervisor grouping global processes shared across all profiles.

  This supervisor is a child of GlobalChainSupervisor and manages:
  - BlockSync.Supervisor - Tracks block heights from all profiles' providers
  - HealthProbe.Supervisor - Monitors provider health for circuit breaker recovery

  ## Lifecycle

  Started when the first profile using a chain is loaded, stopped when the
  last profile using that chain is unloaded. Reference counting is handled
  by GlobalChainSupervisor.

  ## Worker Keys

  Workers within BlockSync and HealthProbe supervisors use composite keys
  `{profile, provider_id}` to track providers across profiles.
  """

  use Supervisor
  require Logger

  alias Lasso.BlockSync
  alias Lasso.HealthProbe

  def start_link(chain_name) when is_binary(chain_name) do
    Supervisor.start_link(__MODULE__, chain_name, name: via(chain_name))
  end

  @doc """
  Returns the via tuple for Registry lookup.
  """
  def via(chain_name) do
    {:via, Registry, {Lasso.Registry, {:global_chain_processes, chain_name}}}
  end

  @doc """
  Start BlockSync workers for all global providers of a chain.

  Should be called after providers are registered with ConfigStore.
  """
  def start_block_sync_workers(chain_name) do
    BlockSync.Supervisor.start_all_workers(chain_name)
  end

  @doc """
  Start HealthProbe workers for all global providers of a chain.

  Should be called after providers are registered with ConfigStore.
  """
  def start_health_probe_workers(chain_name) do
    HealthProbe.Supervisor.start_all_workers(chain_name)
  end

  @doc """
  Start a BlockSync worker for a specific provider.
  """
  def start_block_sync_worker(chain_name, provider_id) do
    BlockSync.Supervisor.start_worker(chain_name, provider_id)
  end

  @doc """
  Start a HealthProbe worker for a specific provider.
  """
  def start_health_probe_worker(chain_name, provider_id, opts \\ []) do
    HealthProbe.Supervisor.start_worker(chain_name, provider_id, opts)
  end

  @doc """
  Stop a BlockSync worker for a specific provider.
  """
  def stop_block_sync_worker(chain_name, provider_id) do
    BlockSync.Supervisor.stop_worker(chain_name, provider_id)
  end

  @doc """
  Stop a HealthProbe worker for a specific provider.
  """
  def stop_health_probe_worker(chain_name, provider_id) do
    HealthProbe.Supervisor.stop_worker(chain_name, provider_id)
  end

  ## Supervisor Callbacks

  @impl true
  def init(chain_name) do
    Logger.debug("Starting GlobalChainProcesses", chain: chain_name)

    children = [
      # BlockSync tracks block heights via WS subscriptions and HTTP polling
      {BlockSync.Supervisor, chain_name},

      # HealthProbe monitors provider health for circuit breaker recovery
      {HealthProbe.Supervisor, chain_name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

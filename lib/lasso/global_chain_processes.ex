defmodule Lasso.GlobalChainProcesses do
  @moduledoc """
  Per-chain Supervisor for global processes shared across all profiles.

  Note: BlockSync and HealthProbe supervisors are now managed by ChainSupervisor
  (profile-scoped), not this module. This supervisor exists for reference counting
  and potential future global chain-level processes.

  ## Lifecycle

  Started when the first profile using a chain is loaded, stopped when the
  last profile using that chain is unloaded. Reference counting is handled
  by GlobalChainSupervisor.
  """

  use Supervisor
  require Logger

  def start_link(chain_name) when is_binary(chain_name) do
    Supervisor.start_link(__MODULE__, chain_name, name: via(chain_name))
  end

  @doc """
  Returns the via tuple for Registry lookup.
  """
  def via(chain_name) do
    {:via, Registry, {Lasso.Registry, {:global_chain_processes, chain_name}}}
  end

  ## Supervisor Callbacks

  @impl true
  def init(chain_name) do
    Logger.debug("Starting GlobalChainProcesses", chain: chain_name)

    # BlockSync and HealthProbe are now managed by ChainSupervisor (profile-scoped)
    # This supervisor is kept for reference counting and potential future use
    children = []

    Supervisor.init(children, strategy: :one_for_one)
  end
end

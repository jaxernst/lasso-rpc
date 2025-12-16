defmodule Lasso.BlockSync.Supervisor do
  @moduledoc """
  Per-chain supervisor for BlockSync Workers.

  Manages one Worker per provider for a chain. Started by ChainSupervisor.

  ## Dynamic Children

  Workers are started dynamically when providers are discovered.
  Each worker handles one provider and orchestrates its sync strategies.
  """

  use DynamicSupervisor
  require Logger

  alias Lasso.BlockSync.Worker
  alias Lasso.Config.ConfigStore

  ## Client API

  def start_link(chain) when is_binary(chain) do
    DynamicSupervisor.start_link(__MODULE__, chain, name: via(chain))
  end

  def via(chain), do: {:via, Registry, {Lasso.Registry, {:block_sync_supervisor, chain}}}

  @doc """
  Start a worker for a specific provider.
  """
  def start_worker(chain, provider_id) do
    spec = {Worker, {chain, provider_id}}

    case DynamicSupervisor.start_child(via(chain), spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("Failed to start BlockSync worker",
          chain: chain,
          provider_id: provider_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc """
  Stop a worker for a specific provider.
  """
  def stop_worker(chain, provider_id) do
    case GenServer.whereis(Worker.via(chain, provider_id)) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(via(chain), pid)
    end
  end

  @doc """
  Start workers for all providers in the chain.
  """
  def start_all_workers(chain) do
    providers = get_provider_ids(chain)

    Logger.info("Starting BlockSync workers",
      chain: chain,
      provider_count: length(providers)
    )

    Enum.each(providers, fn provider_id ->
      start_worker(chain, provider_id)
    end)
  end

  @doc """
  List all running workers for a chain.
  """
  def list_workers(chain) do
    DynamicSupervisor.which_children(via(chain))
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.reject(&is_nil/1)
  end

  ## DynamicSupervisor Callbacks

  @impl true
  def init(chain) do
    Logger.debug("BlockSync.Supervisor starting", chain: chain)

    # Note: Workers are started by ChainSupervisor after this supervisor is up
    # via start_all_workers/1 call

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  ## Private Functions

  defp get_provider_ids(chain) do
    case ConfigStore.get_chain(chain) do
      {:ok, chain_config} ->
        Enum.map(chain_config.providers, & &1.id)

      {:error, _} ->
        []
    end
  end
end

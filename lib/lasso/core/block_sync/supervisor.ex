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

  ## Client API

  def start_link(chain) when is_binary(chain) do
    DynamicSupervisor.start_link(__MODULE__, chain, name: via(chain))
  end

  def via(chain), do: {:via, Registry, {Lasso.Registry, {:block_sync_supervisor, chain}}}

  @doc """
  Start a worker for a specific provider.
  """
  def start_worker(chain, profile, provider_id) when is_binary(profile) do
    spec = {Worker, {chain, profile, provider_id}}

    case DynamicSupervisor.start_child(via(chain), spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("Failed to start BlockSync worker",
          chain: chain,
          profile: profile,
          provider_id: provider_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc """
  Stop a worker for a specific provider.
  """
  def stop_worker(chain, profile, provider_id) when is_binary(profile) do
    case GenServer.whereis(Worker.via(chain, profile, provider_id)) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(via(chain), pid)
    end
  end

  @doc """
  Start workers for a profile's providers in the chain.
  """
  def start_all_workers(chain, profile, provider_ids) when is_binary(profile) and is_list(provider_ids) do
    Logger.info("Starting BlockSync workers",
      chain: chain,
      profile: profile,
      provider_count: length(provider_ids)
    )

    Enum.each(provider_ids, fn provider_id ->
      start_worker(chain, profile, provider_id)
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

end

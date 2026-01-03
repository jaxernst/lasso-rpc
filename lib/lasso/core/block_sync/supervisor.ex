defmodule Lasso.BlockSync.Supervisor do
  @moduledoc """
  Per-profile, per-chain supervisor for BlockSync Workers.

  Manages one Worker per provider for a (profile, chain) pair.
  Started as a child of ChainSupervisor.

  ## Dynamic Children

  Workers are started dynamically when providers are discovered.
  Each worker handles one provider and orchestrates its sync strategies.
  """

  use DynamicSupervisor
  require Logger

  alias Lasso.BlockSync.Worker

  ## Client API

  def start_link({profile, chain}) when is_binary(profile) and is_binary(chain) do
    DynamicSupervisor.start_link(__MODULE__, {profile, chain}, name: via(profile, chain))
  end

  def via(profile, chain), do: {:via, Registry, {Lasso.Registry, {:block_sync_supervisor, profile, chain}}}

  @doc """
  Start a worker for a specific provider.
  """
  def start_worker(profile, chain, provider_id) when is_binary(profile) and is_binary(chain) do
    spec = {Worker, {chain, profile, provider_id}}

    case DynamicSupervisor.start_child(via(profile, chain), spec) do
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
  def stop_worker(profile, chain, provider_id) when is_binary(profile) and is_binary(chain) do
    case GenServer.whereis(Worker.via(chain, profile, provider_id)) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(via(profile, chain), pid)
    end
  end

  @doc """
  Start workers for a profile's providers in the chain.
  """
  def start_all_workers(profile, chain, provider_ids) when is_binary(profile) and is_binary(chain) and is_list(provider_ids) do
    Logger.info("Starting BlockSync workers",
      chain: chain,
      profile: profile,
      provider_count: length(provider_ids)
    )

    Enum.each(provider_ids, fn provider_id ->
      start_worker(profile, chain, provider_id)
    end)
  end

  @doc """
  List all running workers for a profile and chain.
  """
  def list_workers(profile, chain) when is_binary(profile) and is_binary(chain) do
    DynamicSupervisor.which_children(via(profile, chain))
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.reject(&is_nil/1)
  end

  ## DynamicSupervisor Callbacks

  @impl true
  def init({profile, chain}) do
    Logger.debug("BlockSync.Supervisor starting", profile: profile, chain: chain)

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end
end

defmodule Lasso.HealthProbe.Supervisor do
  @moduledoc """
  Per-profile, per-chain supervisor for HealthProbe Workers.

  Manages one Worker per provider for a (profile, chain) pair.
  Started as a child of ChainSupervisor.

  ## Purpose

  HealthProbe workers probe providers independently of the circuit breaker
  to detect when providers recover. This allows the circuit breaker to close
  even when no user traffic is being sent to the provider.
  """

  use DynamicSupervisor
  require Logger

  alias Lasso.HealthProbe.Worker
  alias Lasso.Config.ConfigStore

  ## Client API

  def start_link({profile, chain}) when is_binary(profile) and is_binary(chain) do
    DynamicSupervisor.start_link(__MODULE__, {profile, chain}, name: via(profile, chain))
  end

  def via(profile, chain), do: {:via, Registry, {Lasso.Registry, {:health_probe_supervisor, profile, chain}}}

  @doc """
  Start a worker for a specific provider.
  """
  def start_worker(profile, chain, provider_id, opts) when is_binary(profile) and is_binary(chain) and is_list(opts) do
    spec = {Worker, {chain, profile, provider_id, opts}}

    case DynamicSupervisor.start_child(via(profile, chain), spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.warning("Failed to start HealthProbe worker",
          chain: chain,
          profile: profile,
          provider_id: provider_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  def start_worker(profile, chain, provider_id) when is_binary(profile) and is_binary(chain) do
    start_worker(profile, chain, provider_id, [])
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
  def start_all_workers(profile, chain, provider_ids, opts)
      when is_binary(profile) and is_binary(chain) and is_list(provider_ids) and is_list(opts) do
    probe_interval = get_probe_interval(profile, chain)
    worker_opts = Keyword.merge([probe_interval_ms: probe_interval], opts)

    Logger.info("Starting HealthProbe workers",
      chain: chain,
      profile: profile,
      provider_count: length(provider_ids),
      probe_interval_ms: probe_interval
    )

    Enum.each(provider_ids, fn provider_id ->
      start_worker(profile, chain, provider_id, worker_opts)
    end)
  end

  def start_all_workers(profile, chain, provider_ids)
      when is_binary(profile) and is_binary(chain) and is_list(provider_ids) do
    start_all_workers(profile, chain, provider_ids, [])
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
    Logger.debug("HealthProbe.Supervisor starting", profile: profile, chain: chain)

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60
    )
  end

  ## Private Functions

  defp get_probe_interval(profile, chain) do
    case ConfigStore.get_chain(profile, chain) do
      {:ok, chain_config} ->
        # Use the same interval as BlockSync HTTP polling
        chain_config.monitoring.probe_interval_ms

      {:error, _} ->
        10_000
    end
  end
end

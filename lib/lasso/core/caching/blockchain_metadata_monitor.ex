defmodule Lasso.RPC.Caching.BlockchainMetadataMonitor do
  @moduledoc """
  Background monitor that refreshes blockchain metadata for a single chain.

  Probes providers periodically to fetch block heights and chain IDs,
  computing the best known height and tracking per-provider lag.

  One monitor GenServer runs per chain under the ChainSupervisor.

  ## Responsibilities

  - Probe providers for `eth_blockNumber` every 10s (configurable)
  - Update BlockchainMetadataCache with latest values
  - Compute best known height across all providers
  - Track per-provider lag
  - Emit telemetry for monitoring

  ## Configuration

      config :lasso, :metadata_cache,
        refresh_interval_ms: 10_000,
        providers_to_probe: 3,
        probe_timeout_ms: 2_000
  """

  use GenServer
  require Logger

  alias Lasso.Config.ConfigStore
  alias Lasso.RPC.{RequestPipeline, CircuitBreaker}
  alias Lasso.RPC.Caching.BlockchainMetadataCache

  @default_refresh_interval_ms 10_000
  @default_probe_timeout_ms 2_000
  @default_providers_to_probe 3

  ## Client API

  def start_link(chain) do
    GenServer.start_link(__MODULE__, chain, name: via(chain))
  end

  def via(chain), do: {:via, Registry, {Lasso.Registry, {:metadata_monitor, chain}}}

  @doc """
  Manually trigger a refresh cycle (useful for testing).
  """
  def refresh_now(chain) do
    GenServer.cast(via(chain), :refresh)
  end

  @doc """
  Report a provider height from an external source (e.g., ProviderHealthMonitor).
  """
  def report_provider_height(chain, provider_id, height, latency_ms) do
    GenServer.cast(via(chain), {:report_provider_height, provider_id, height, latency_ms})
  end

  ## GenServer Callbacks

  @impl true
  def init(chain) do
    # Ensure ETS table exists
    BlockchainMetadataCache.ensure_table()

    state = %{
      chain: chain,
      refresh_interval_ms: refresh_interval_ms(),
      probe_timeout_ms: probe_timeout_ms(),
      providers_to_probe: providers_to_probe(),
      last_refresh: nil,
      refresh_in_progress: false
    }

    # Schedule first refresh after a short delay to allow providers to start
    Process.send_after(self(), :tick, 2_000)

    Logger.info("BlockchainMetadataMonitor started",
      chain: chain,
      refresh_interval_ms: state.refresh_interval_ms
    )

    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    # Skip if previous refresh still running
    if state.refresh_in_progress do
      Logger.debug("Skipping refresh, previous still in progress", chain: state.chain)
      schedule_next_tick(state)
      {:noreply, state}
    else
      new_state = perform_refresh(state)
      schedule_next_tick(new_state)
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast(:refresh, state) do
    new_state = perform_refresh(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:report_provider_height, provider_id, height, latency_ms}, state) do
    # External height report (e.g., from health monitor)
    BlockchainMetadataCache.put_provider_block_height(
      state.chain,
      provider_id,
      height,
      latency_ms
    )

    # Recompute best known height and lag
    update_best_known_height(state.chain)

    {:noreply, state}
  end

  ## Private Implementation

  defp perform_refresh(state) do
    telemetry_refresh_started(state.chain)
    start_time = System.monotonic_time(:millisecond)

    # Get providers to probe
    providers = get_providers_to_probe(state.chain, state.providers_to_probe)

    if providers == [] do
      Logger.debug("No providers configured for metadata refresh", chain: state.chain)

      telemetry_refresh_completed(state.chain, 0, 0, 0)

      %{state | refresh_in_progress: false, last_refresh: DateTime.utc_now()}
    else
      # Probe providers concurrently
      results =
        providers
        |> Task.async_stream(
          fn provider ->
            probe_provider(state.chain, provider, state.probe_timeout_ms)
          end,
          timeout: state.probe_timeout_ms + 1_000,
          on_timeout: :kill_task
        )
        |> Enum.to_list()

      # Process results
      successful =
        results
        |> Enum.filter(fn
          {:ok, {:ok, _provider_id, _height, _latency}} -> true
          _ -> false
        end)
        |> Enum.map(fn {:ok, {:ok, provider_id, height, latency}} ->
          BlockchainMetadataCache.put_provider_block_height(
            state.chain,
            provider_id,
            height,
            latency
          )

          telemetry_provider_height_updated(state.chain, provider_id, height, latency)

          {provider_id, height}
        end)

      # Update best known height and compute lag
      if successful != [] do
        update_best_known_height(state.chain)
      end

      duration_ms = System.monotonic_time(:millisecond) - start_time

      telemetry_refresh_completed(
        state.chain,
        duration_ms,
        length(providers),
        length(successful)
      )

      Logger.debug("Metadata refresh completed",
        chain: state.chain,
        duration_ms: duration_ms,
        providers_probed: length(providers),
        successful: length(successful)
      )

      %{state | refresh_in_progress: false, last_refresh: DateTime.utc_now()}
    end
  end

  defp probe_provider(chain, provider, timeout_ms) do
    start_time = System.monotonic_time(:millisecond)

    # Use RequestPipeline to fetch block number
    result =
      RequestPipeline.execute_via_channels(
        chain,
        "eth_blockNumber",
        [],
        strategy: :priority,
        provider_override: provider.id,
        failover_on_override: false,
        timeout: timeout_ms
      )

    latency_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, "0x" <> hex} ->
        height = String.to_integer(hex, 16)
        {:ok, provider.id, height, latency_ms}

      {:error, reason} ->
        Logger.debug("Metadata probe failed",
          chain: chain,
          provider_id: provider.id,
          reason: inspect(reason)
        )

        telemetry_probe_failed(chain, provider.id, reason)
        {:error, provider.id, reason}
    end
  rescue
    e ->
      Logger.warning("Metadata probe crashed",
        chain: chain,
        provider_id: provider.id,
        error: Exception.format(:error, e, __STACKTRACE__)
      )

      {:error, provider.id, :crashed}
  end

  defp get_providers_to_probe(chain, max_count) do
    case ConfigStore.get_chain(chain) do
      {:ok, chain_config} ->
        # Get all providers, prioritize by health/priority
        chain_config.providers
        |> Enum.take(max_count)

      {:error, _} ->
        Logger.warning("Chain config not found for metadata refresh", chain: chain)
        []
    end
  end

  defp update_best_known_height(chain) do
    # Get all provider heights from cache
    provider_heights =
      :ets.match(:blockchain_metadata, {{:provider, chain, :"$1", :block_height}, :"$2"})

    if provider_heights != [] do
      # Find best (highest) known height
      best_height =
        provider_heights
        |> Enum.map(fn [_provider_id, height] -> height end)
        |> Enum.max()

      # Update cache with best known height
      BlockchainMetadataCache.put_block_height(chain, best_height)

      # Compute and store lag for each provider
      Enum.each(provider_heights, fn [provider_id, provider_height] ->
        lag = provider_height - best_height
        BlockchainMetadataCache.put_provider_lag(chain, provider_id, lag)

        if lag < -10 do
          telemetry_provider_lag_detected(chain, provider_id, lag)

          Logger.info("Provider lagging behind",
            chain: chain,
            provider_id: provider_id,
            lag_blocks: lag
          )
        end
      end)
    end
  end

  defp schedule_next_tick(state) do
    Process.send_after(self(), :tick, state.refresh_interval_ms)
  end

  ## Configuration

  defp refresh_interval_ms do
    get_in(config(), [:refresh_interval_ms]) || @default_refresh_interval_ms
  end

  defp probe_timeout_ms do
    get_in(config(), [:probe_timeout_ms]) || @default_probe_timeout_ms
  end

  defp providers_to_probe do
    get_in(config(), [:providers_to_probe]) || @default_providers_to_probe
  end

  defp config do
    Application.get_env(:lasso, :metadata_cache, [])
  end

  ## Telemetry

  defp telemetry_refresh_started(chain) do
    :telemetry.execute([:lasso, :metadata, :refresh, :started], %{count: 1}, %{chain: chain})
  end

  defp telemetry_refresh_completed(chain, duration_ms, providers_probed, providers_successful) do
    :telemetry.execute(
      [:lasso, :metadata, :refresh, :completed],
      %{
        duration_ms: duration_ms,
        providers_probed: providers_probed,
        providers_successful: providers_successful
      },
      %{chain: chain}
    )
  end

  defp telemetry_provider_height_updated(chain, provider_id, height, latency_ms) do
    :telemetry.execute(
      [:lasso, :metadata, :provider, :height_updated],
      %{height: height, latency_ms: latency_ms},
      %{chain: chain, provider_id: provider_id}
    )
  end

  defp telemetry_probe_failed(chain, provider_id, reason) do
    :telemetry.execute(
      [:lasso, :metadata, :probe, :failed],
      %{count: 1},
      %{chain: chain, provider_id: provider_id, reason: inspect(reason)}
    )
  end

  defp telemetry_provider_lag_detected(chain, provider_id, lag_blocks) do
    :telemetry.execute(
      [:lasso, :metadata, :provider, :lag_detected],
      %{lag_blocks: lag_blocks},
      %{chain: chain, provider_id: provider_id}
    )
  end
end

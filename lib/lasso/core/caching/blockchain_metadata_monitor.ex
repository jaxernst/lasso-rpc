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
  alias Lasso.RPC.TransportRegistry
  alias Lasso.RPC.Channel
  alias Lasso.RPC.Caching.BlockchainMetadataCache

  @default_refresh_interval_ms 10_000
  @default_probe_timeout_ms 2_000
  @default_providers_to_probe 3
  @default_lag_threshold_blocks 10
  @default_refresh_deadline_ms 30_000

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
    # Table is created by MetadataTableOwner, just verify it exists
    BlockchainMetadataCache.ensure_table()

    state = %{
      chain: chain,
      refresh_interval_ms: refresh_interval_ms(),
      probe_timeout_ms: probe_timeout_ms(),
      providers_to_probe: providers_to_probe(),
      lag_threshold_blocks: lag_threshold_blocks(),
      refresh_deadline_ms: refresh_deadline_ms(),
      last_refresh: nil,
      refresh_in_progress: false
    }

    # Schedule first refresh after a short delay to allow providers to start
    Process.send_after(self(), :tick, 2_000)

    Logger.info("BlockchainMetadataMonitor started",
      chain: chain,
      refresh_interval_ms: state.refresh_interval_ms,
      lag_threshold_blocks: state.lag_threshold_blocks
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
    update_best_known_height(state.chain, state.lag_threshold_blocks)

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
      # Probe providers concurrently with deadline enforcement
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

      # Check if we exceeded refresh deadline
      elapsed_ms = System.monotonic_time(:millisecond) - start_time

      if elapsed_ms > state.refresh_deadline_ms do
        Logger.warning("Refresh exceeded deadline",
          chain: state.chain,
          elapsed_ms: elapsed_ms,
          deadline_ms: state.refresh_deadline_ms
        )

        telemetry_refresh_deadline_exceeded(state.chain, elapsed_ms, state.refresh_deadline_ms)
      end

      # Process block height results
      successful =
        results
        |> Enum.filter(fn
          {:ok, {:ok, _provider_id, _height, _latency, _chain_id}} -> true
          _ -> false
        end)
        |> Enum.map(fn {:ok, {:ok, provider_id, height, latency, chain_id}} ->
          BlockchainMetadataCache.put_provider_block_height(
            state.chain,
            provider_id,
            height,
            latency
          )

          # Cache chain ID if returned (first provider wins for chain-level ID)
          if chain_id do
            BlockchainMetadataCache.put_chain_id(state.chain, chain_id)
          end

          telemetry_provider_height_updated(state.chain, provider_id, height, latency)

          {provider_id, height}
        end)

      # Update best known height and compute lag
      if successful != [] do
        update_best_known_height(state.chain, state.lag_threshold_blocks)
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

    # Health checks bypass circuit breakers by calling channels directly
    # This prevents health check traffic from polluting circuit breaker state
    case TransportRegistry.get_channel(chain, provider.id, :http) do
      {:ok, channel} ->
        # Probe both block number and chain ID in parallel
        probes = [
          {:block_number, "eth_blockNumber", []},
          {:chain_id, "eth_chainId", []}
        ]

        results =
          probes
          |> Task.async_stream(
            fn {key, method, params} ->
              rpc_request = %{
                "jsonrpc" => "2.0",
                "method" => method,
                "params" => params,
                "id" => :rand.uniform(1_000_000)
              }

              result = Channel.request(channel, rpc_request, div(timeout_ms, 2))
              {key, result}
            end,
            timeout: timeout_ms,
            on_timeout: :kill_task
          )
          |> Enum.to_list()

        latency_ms = System.monotonic_time(:millisecond) - start_time

        # Extract results
        block_number_result =
          Enum.find_value(results, fn
            {:ok, {:block_number, result}} -> result
            _ -> nil
          end)

        chain_id_result =
          Enum.find_value(results, fn
            {:ok, {:chain_id, result}} -> result
            _ -> nil
          end)

        handle_probe_results(
          chain,
          provider,
          block_number_result,
          chain_id_result,
          latency_ms
        )

      {:error, reason} ->
        Logger.debug("Failed to get channel for metadata probe",
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

  defp handle_probe_results(chain, provider, block_number_result, chain_id_result, latency_ms) do

    case block_number_result do
      {:ok, "0x" <> hex} ->
        height = String.to_integer(hex, 16)

        # Extract chain ID if available
        chain_id =
          case chain_id_result do
            {:ok, chain_id_hex} -> chain_id_hex
            _ -> nil
          end

        {:ok, provider.id, height, latency_ms, chain_id}

      {:error, reason} ->
        Logger.debug("Metadata probe failed",
          chain: chain,
          provider_id: provider.id,
          reason: inspect(reason)
        )

        telemetry_probe_failed(chain, provider.id, reason)
        {:error, provider.id, reason}

      nil ->
        Logger.debug("Metadata probe timeout",
          chain: chain,
          provider_id: provider.id
        )

        telemetry_probe_failed(chain, provider.id, :timeout)
        {:error, provider.id, :timeout}
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
        # Health checks bypass circuit breakers, so we probe all providers to detect recovery
        chain_config.providers
        |> Enum.take(max_count)

      {:error, _} ->
        Logger.warning("Chain config not found for metadata refresh", chain: chain)
        []
    end
  end

  defp update_best_known_height(chain, lag_threshold_blocks) do
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

        # Use configurable threshold
        if lag < -lag_threshold_blocks do
          telemetry_provider_lag_detected(chain, provider_id, lag)

          Logger.info("Provider lagging behind",
            chain: chain,
            provider_id: provider_id,
            lag_blocks: lag,
            threshold: lag_threshold_blocks
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

  defp lag_threshold_blocks do
    get_in(config(), [:lag_threshold_blocks]) || @default_lag_threshold_blocks
  end

  defp refresh_deadline_ms do
    get_in(config(), [:refresh_deadline_ms]) || @default_refresh_deadline_ms
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

  defp telemetry_refresh_deadline_exceeded(chain, elapsed_ms, deadline_ms) do
    :telemetry.execute(
      [:lasso, :metadata, :refresh, :deadline_exceeded],
      %{elapsed_ms: elapsed_ms, deadline_ms: deadline_ms},
      %{chain: chain}
    )
  end
end

defmodule Lasso.RPC.Selection do
  @moduledoc """
  Unified provider selection module that handles all provider picking logic.

  This module provides a single interface for selecting providers across
  different protocols (HTTP vs WS) and fallback strategies. It first tries
  to use the ProviderPool for intelligent selection, then falls back to
  ConfigStore-based selection if the pool is unavailable.

  Selection strategies:
  - Pool-based (preferred): Uses ProviderPool health and performance data
  - Config-based (fallback): Uses static configuration priority ordering

  This eliminates the need for channels/controllers to load configuration
  or directly manage provider selection logic.
  """

  require Logger

  alias Lasso.RPC.{
    Channel,
    ChainState,
    ProviderPool,
    RequestAnalysis,
    SelectionFilters,
    TransportRegistry
  }

  alias Lasso.RPC.Strategies.Registry, as: StrategyRegistry
  # Selection should be transport-policy agnostic. Transport constraints
  # should be provided by the caller via opts.

  @doc """
  Picks the best provider using simple parameters.

  Options:
  - :params => [term()] (RPC params for request analysis, default [])
  - :strategy => :fastest | :cheapest | :priority | :round_robin (default :cheapest)
  - :protocol => :http | :ws | :both (default :both)
  - :exclude => [provider_id] (default [])
  - :timeout => ms (default 30_000)

  Returns {:ok, provider_id} or {:error, reason}
  """
  @spec select_provider(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def select_provider(profile, chain, method, opts \\ [])
      when is_binary(profile) and is_binary(chain) and is_binary(method) do
    params = Keyword.get(opts, :params, [])
    strategy = Keyword.get(opts, :strategy, :cheapest)
    protocol = Keyword.get(opts, :protocol, :both)
    exclude = Keyword.get(opts, :exclude, [])
    timeout = Keyword.get(opts, :timeout, 30_000)

    do_select_provider(profile, chain, method, params, strategy, protocol, exclude, timeout)
  end

  # Private implementation

  defp do_select_provider(profile, chain, method, params, strategy, protocol, exclude, timeout) do
    filters = build_selection_filters(profile, chain, method, params, exclude, protocol)
    candidates = ProviderPool.list_candidates(profile, chain, filters)

    case candidates do
      [] ->
        {:error, :no_providers_available}

      _ ->
        strategy_mod = StrategyRegistry.resolve(strategy)
        prepared_ctx = strategy_mod.prepare_context(profile, chain, method, timeout)

        channels =
          candidates
          |> Enum.flat_map(fn %{id: provider_id, config: provider_config} ->
            transports =
              case protocol do
                :http -> [:http]
                :ws -> [:ws]
                :both -> [:http, :ws]
              end

            Enum.flat_map(transports, fn t ->
              case TransportRegistry.get_channel(profile, chain, provider_id, t,
                     method: method,
                     provider_config: provider_config
                   ) do
                {:ok, ch} -> [ch]
                _ -> []
              end
            end)
          end)

        ordered =
          strategy_mod.rank_channels(channels, method, prepared_ctx, profile, chain)

        case List.first(ordered) do
          %Channel{provider_id: pid} ->
            :telemetry.execute([:lasso, :selection, :success], %{count: 1}, %{
              chain: chain,
              method: method,
              strategy: strategy,
              protocol: protocol,
              provider_id: pid
            })

            {:ok, pid}

          _ ->
            {:error, :no_providers_available}
        end
    end
  end

  # Strategy resolution moved to StrategyRegistry for DRY pluggability.

  @doc """
  Selects the best channels for a method across all available transports.

  onsiders provider capabilities,
  health, and performance metrics to return ordered candidate channels.

  Options:
  - :strategy => :fastest | :cheapest | :priority | :round_robin
  - :transport => :http | :ws | :both (default :both)
  - :exclude => [provider_id]
  - :limit => integer (maximum channels to return)
  - :include_half_open => boolean (default true) - include providers with half-open circuits (deprioritized after closed)

  Returns a list of Channel structs ordered by strategy preference.
  """
  @spec select_channels(String.t(), String.t(), String.t(), keyword()) :: [Channel.t()]
  def select_channels(profile, chain, method, opts \\ [])
      when is_binary(profile) and is_binary(chain) and is_binary(method) do
    strategy = Keyword.get(opts, :strategy, :round_robin)
    transport = Keyword.get(opts, :transport, :both)
    exclude = Keyword.get(opts, :exclude, [])
    limit = Keyword.get(opts, :limit, 1000)
    include_half_open = Keyword.get(opts, :include_half_open, true)
    params = Keyword.get(opts, :params, [])

    pool_protocol =
      case transport do
        :http -> :http
        :ws -> :ws
        _ -> nil
      end

    # Analyze request to determine archival requirements
    archival_threshold = get_archival_threshold(profile, chain)
    consensus_height = get_consensus_height(chain)

    requirements =
      Lasso.RPC.RequestAnalysis.analyze(
        method,
        params,
        consensus_height: consensus_height,
        archival_threshold: archival_threshold
      )

    pool_filters =
      SelectionFilters.new(
        protocol: pool_protocol,
        exclude: exclude,
        include_half_open: include_half_open,
        max_lag_blocks: get_max_lag(profile, chain),
        requires_archival: requirements.requires_archival
      )

    # Instrument ProviderPool.list_candidates call time
    pool_start = System.monotonic_time(:microsecond)
    provider_candidates = ProviderPool.list_candidates(profile, chain, pool_filters)

    pool_duration_us = System.monotonic_time(:microsecond) - pool_start

    :telemetry.execute(
      [:lasso, :selection, :pool_candidates],
      %{duration_us: pool_duration_us, candidate_count: length(provider_candidates)},
      %{chain: chain, method: method, strategy: strategy}
    )

    # Build circuit state lookup map: {provider_id, transport} => :closed | :half_open
    # Use defensive access in case circuit_state field is missing or nil
    circuit_state_map =
      provider_candidates
      |> Enum.flat_map(fn %{id: provider_id} = candidate ->
        cs = Map.get(candidate, :circuit_state, %{})

        [
          {{provider_id, :http}, Map.get(cs, :http, :closed)},
          {{provider_id, :ws}, Map.get(cs, :ws, :closed)}
        ]
      end)
      |> Map.new()

    # Build channel candidates via TransportRegistry (enforces channel-level health/capabilities)
    # Map provider list into channels, lazily opening as needed
    registry_start = System.monotonic_time(:microsecond)

    channels =
      provider_candidates
      |> Enum.flat_map(&build_provider_channels(&1, transport, profile, chain, method))
      |> Enum.reject(&is_nil/1)

    registry_duration_us = System.monotonic_time(:microsecond) - registry_start

    :telemetry.execute(
      [:lasso, :selection, :channel_building],
      %{duration_us: registry_duration_us, channel_count: length(channels)},
      %{chain: chain, method: method, provider_count: length(provider_candidates)}
    )

    # Filter channels by method capability (adapter-based filtering)
    capable_channels =
      case Lasso.RPC.Providers.AdapterFilter.filter_channels(channels, method) do
        {:ok, capable, filtered} ->
          if length(filtered) > 0 do
            Logger.debug(
              "Filtered #{length(filtered)} channels for #{method}: #{inspect(Enum.map(filtered, & &1.provider_id))}"
            )
          end

          capable

        {:error, reason} ->
          Logger.error(
            "Adapter filtering failed for #{method}: #{inspect(reason)}, using all channels"
          )

          # Fail open: use all channels if filtering fails
          channels
      end

    # Strategy delegation: allow strategy modules to rank channels when available.
    strategy_mod = StrategyRegistry.resolve(strategy)
    timeout = Keyword.get(opts, :timeout, 30_000)
    prepared_ctx = strategy_mod.prepare_context(profile, chain, method, timeout)

    ordered_channels =
      strategy_mod.rank_channels(capable_channels, method, prepared_ctx, profile, chain)

    # Tiered selection: partition by circuit state to deprioritize half-open channels.
    # Closed-circuit channels come first (healthy), half-open channels come last (recovering).
    # Within each tier, the strategy's ranking is preserved (maintains randomization for round-robin).
    {closed_channels, half_open_channels} =
      Enum.split_with(ordered_channels, fn channel ->
        cb_state = Map.get(circuit_state_map, {channel.provider_id, channel.transport}, :closed)
        cb_state == :closed
      end)

    tiered_channels = closed_channels ++ half_open_channels

    tiered_channels |> Enum.take(limit)
  end

  @doc """
  Selects the best channel for a specific provider and transport combination.

  Returns {:ok, channel} or {:error, reason}.
  """
  @spec select_provider_channel(String.t(), String.t(), String.t(), :http | :ws, keyword()) ::
          {:ok, Channel.t()} | {:error, term()}
  def select_provider_channel(profile, chain, provider_id, transport, opts \\ []) do
    TransportRegistry.get_channel(profile, chain, provider_id, transport, opts)
  end

  ## Private Functions

  # Channel building helpers

  defp build_provider_channels(
         %{id: provider_id, config: config},
         transport,
         profile,
         chain,
         method
       ) do
    transport
    |> transports_to_check()
    |> Enum.filter(fn t -> provider_supports_transport?(config, t) end)
    |> Enum.flat_map(fn t -> fetch_channel(profile, chain, provider_id, t, method, config) end)
  end

  defp transports_to_check(:http), do: [:http]
  defp transports_to_check(:ws), do: [:ws]
  defp transports_to_check(_), do: [:http, :ws]

  defp provider_supports_transport?(config, :http), do: is_binary(Map.get(config, :url))
  defp provider_supports_transport?(config, :ws), do: is_binary(Map.get(config, :ws_url))

  defp fetch_channel(profile, chain, provider_id, transport, method, provider_config) do
    case TransportRegistry.get_channel(profile, chain, provider_id, transport,
           method: method,
           provider_config: provider_config
         ) do
      {:ok, channel} -> [channel]
      _ -> []
    end
  end

  # Configuration helper: Get max lag threshold for a specific profile/chain
  # Returns nil if no lag filtering should be applied
  # Configuration precedence (highest to lowest):
  # 1. Per-chain default (from profile config)
  # 2. Global application default
  defp get_max_lag(profile, chain) do
    # Try to get chain-specific config from the profile
    case Lasso.Config.ConfigStore.get_chain(profile, chain) do
      {:ok, %{selection: %{max_lag_blocks: chain_default}}} ->
        # Use chain-level default
        chain_default || get_global_max_lag()

      _ ->
        # No chain config or selection config, use global default
        get_global_max_lag()
    end
  end

  defp get_global_max_lag do
    # Get global default from application config
    # Returns nil if not configured (no lag filtering)
    Application.get_env(:lasso, :selection, [])
    |> Keyword.get(:max_lag_blocks)
  end

  defp get_archival_threshold(profile, chain) do
    case Lasso.Config.ConfigStore.get_chain(profile, chain) do
      {:ok, %{selection: %{archival_threshold: threshold}}} when is_integer(threshold) ->
        threshold

      _ ->
        Lasso.Config.ChainConfig.Selection.default_archival_threshold()
    end
  end

  defp get_consensus_height(chain) do
    case ChainState.consensus_height(chain) do
      {:ok, height} -> height
      {:error, _} -> nil
    end
  end

  defp build_selection_filters(profile, chain, method, params, exclude, protocol) do
    archival_threshold = get_archival_threshold(profile, chain)
    consensus_height = get_consensus_height(chain)

    requirements =
      RequestAnalysis.analyze(
        method,
        params,
        consensus_height: consensus_height,
        archival_threshold: archival_threshold
      )

    SelectionFilters.new(
      exclude: exclude,
      protocol: protocol,
      max_lag_blocks: get_max_lag(profile, chain),
      requires_archival: requirements.requires_archival
    )
  end
end

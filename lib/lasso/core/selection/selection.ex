defmodule Lasso.RPC.Selection do
  @moduledoc """
  Unified provider selection module that handles all provider picking logic.

  This module provides a single interface for selecting providers across
  different protocols (HTTP vs WS) and fallback strategies. It uses
  CandidateListing for ETS-backed health-aware selection, then falls back to
  ConfigStore-based selection if the catalog is unavailable.

  Selection strategies:
  - Catalog-based (preferred): Uses CandidateListing health and performance data
  - Config-based (fallback): Uses static configuration priority ordering

  This eliminates the need for channels/controllers to load configuration
  or directly manage provider selection logic.
  """

  require Logger

  alias Lasso.Providers.CandidateListing

  alias Lasso.RPC.{
    ChainState,
    Channel,
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
  - :strategy => :fastest | :priority | :load_balanced | :latency_weighted (default :load_balanced)
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
    strategy = Keyword.get(opts, :strategy, :load_balanced)
    protocol = Keyword.get(opts, :protocol, :both)
    exclude = Keyword.get(opts, :exclude, [])
    timeout = Keyword.get(opts, :timeout, 30_000)

    do_select_provider(profile, chain, method, params, strategy, protocol, exclude, timeout)
  end

  # Private implementation

  defp do_select_provider(profile, chain, method, params, strategy, protocol, exclude, timeout) do
    filters = build_selection_filters(profile, chain, method, params, exclude, protocol)
    candidates = CandidateListing.list_candidates(profile, chain, filters)

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
  - :strategy => :fastest | :priority | :load_balanced | :latency_weighted
  - :transport => :http | :ws | :both (default :both)
  - :exclude => [provider_id]
  - :limit => integer (maximum channels to return)
  - :include_half_open => boolean (default true) - include providers with half-open circuits (deprioritized after closed)

  Returns a list of Channel structs ordered by strategy preference.
  """
  @spec select_channels(String.t(), String.t(), String.t(), keyword()) :: [Channel.t()]
  def select_channels(profile, chain, method, opts \\ [])
      when is_binary(profile) and is_binary(chain) and is_binary(method) do
    strategy = Keyword.get(opts, :strategy, :load_balanced)
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

    # Instrument CandidateListing.list_candidates call time
    pool_start = System.monotonic_time(:microsecond)
    provider_candidates = CandidateListing.list_candidates(profile, chain, pool_filters)

    pool_duration_us = System.monotonic_time(:microsecond) - pool_start

    :telemetry.execute(
      [:lasso, :selection, :pool_candidates],
      %{duration_us: pool_duration_us, candidate_count: length(provider_candidates)},
      %{chain: chain, method: method, strategy: strategy}
    )

    # Build circuit state lookup map: {provider_id, transport} => :closed | :half_open
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

    # Build rate limit lookup map: provider_id => %{http: bool, ws: bool}
    rate_limit_map =
      provider_candidates
      |> Enum.map(fn %{id: id, rate_limited: rl} -> {id, rl} end)
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

    # Health-based tiering: reorder providers by circuit breaker state and rate limit status.
    #
    # The 4-tier system ensures healthy providers receive traffic first while allowing
    # recovering providers to gradually reintegrate:
    #
    # 1. Tier 1: Closed circuit + not rate-limited (preferred)
    # 2. Tier 2: Closed circuit + rate-limited
    # 3. Tier 3: Half-open circuit + not rate-limited
    # 4. Tier 4: Half-open circuit + rate-limited
    #
    # Open-circuit providers are filtered out earlier in the pipeline.
    #
    # Within each tier, the strategy's ranking is preserved. For example, with
    # load-balanced strategy, Tier 1 providers remain shuffled relative to each other,
    # but all Tier 1 providers come before any Tier 2 providers.
    #
    # This tiering explains why traffic may be concentrated on certain providers even
    # with load-balanced: if only one provider is in Tier 1, it receives all traffic
    # that succeeds, with lower tiers acting as fallbacks.

    # Step 1: Split by circuit breaker state
    {closed_channels, half_open_channels} =
      Enum.split_with(ordered_channels, fn channel ->
        cb_state = Map.get(circuit_state_map, {channel.provider_id, channel.transport}, :closed)
        cb_state == :closed
      end)

    tiered_channels = closed_channels ++ half_open_channels

    # Step 2: Within each circuit tier, split by rate limit status
    # Final order: closed+not-rl, closed+rl, half-open+not-rl, half-open+rl
    {not_rate_limited, rate_limited} =
      Enum.split_with(tiered_channels, fn channel ->
        rl = Map.get(rate_limit_map, channel.provider_id, %{http: false, ws: false})
        not Map.get(rl, channel.transport, false)
      end)

    final_channels = not_rate_limited ++ rate_limited

    final_channels |> Enum.take(limit)
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

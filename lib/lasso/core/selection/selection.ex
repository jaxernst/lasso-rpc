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

  alias Lasso.RPC.{Channel, ProviderPool, SelectionContext, TransportRegistry}
  alias Lasso.RPC.Strategies.Registry, as: StrategyRegistry
  # Selection should be transport-policy agnostic. Transport constraints
  # should be provided by the caller via opts.

  @doc """
  Picks the best provider using simple parameters.

  Options:
  - :strategy => :fastest | :cheapest | :priority | :round_robin (default from config)
  - :protocol => :http | :ws | :both (default :both)
  - :exclude => [provider_id]
  - :timeout => ms (default 30_000)
  - :region_filter => String.t() | nil

  Returns {:ok, provider_id} or {:error, reason}
  """
  @spec select_provider(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def select_provider(profile, chain, method, opts \\ [])
      when is_binary(profile) and is_binary(chain) and is_binary(method) do
    ctx = SelectionContext.new(profile, chain, method, opts)
    select_provider(ctx)
  end

  @doc """
  Picks the best provider using a SelectionContext (backward compatibility).

  Returns {:ok, provider_id} or {:error, reason}
  """
  @spec select_provider(SelectionContext.t()) :: {:ok, String.t()} | {:error, term()}
  def select_provider(%SelectionContext{} = ctx) do
    with {:ok, validated_ctx} <- SelectionContext.validate(ctx) do
      do_select_provider(validated_ctx)
    end
  end

  @doc """
  Picks the best provider and returns enriched selection metadata for observability.

  Returns {:ok, %{provider_id: String.t(), metadata: map()}} or {:error, reason}

  Metadata includes:
  - candidates: list of candidate provider IDs considered
  - selected: selected provider with protocol
  - reason: selection reason (e.g., "fastest_method_latency")
  - cb_state: circuit breaker state of selected provider
  """
  @spec select_provider_with_metadata(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{provider_id: String.t(), metadata: map()}} | {:error, term()}
  def select_provider_with_metadata(profile, chain, method, opts \\ [])
      when is_binary(profile) and is_binary(chain) and is_binary(method) do
    ctx = SelectionContext.new(profile, chain, method, opts)

    with {:ok, validated_ctx} <- SelectionContext.validate(ctx) do
      do_select_provider_with_metadata(validated_ctx)
    end
  end

  # Private implementation

  defp do_select_provider(%SelectionContext{} = ctx) do
    max_lag_blocks = get_max_lag(ctx.profile, ctx.chain)
    filters = %{exclude: ctx.exclude, protocol: ctx.protocol, max_lag_blocks: max_lag_blocks}
    candidates = ProviderPool.list_candidates(ctx.profile, ctx.chain, filters)

    case candidates do
      [] ->
        {:error, :no_providers_available}

      _ ->
        strategy_mod = StrategyRegistry.resolve(ctx.strategy)
        prepared_ctx = strategy_mod.prepare_context(ctx)

        channels =
          candidates
          |> Enum.flat_map(fn %{id: provider_id, config: provider_config} ->
            transports =
              case ctx.protocol do
                :http -> [:http]
                :ws -> [:ws]
                :both -> [:http, :ws]
              end

            Enum.flat_map(transports, fn t ->
              case TransportRegistry.get_channel(ctx.profile, ctx.chain, provider_id, t,
                     method: ctx.method,
                     provider_config: provider_config
                   ) do
                {:ok, ch} -> [ch]
                _ -> []
              end
            end)
          end)

        ordered = strategy_mod.rank_channels(channels, ctx.method, prepared_ctx, ctx.profile, ctx.chain)

        case List.first(ordered) do
          %Channel{provider_id: pid} ->
            :telemetry.execute([:lasso, :selection, :success], %{count: 1}, %{
              chain: ctx.chain,
              method: ctx.method,
              strategy: ctx.strategy,
              protocol: ctx.protocol,
              provider_id: pid
            })

            {:ok, pid}

          _ ->
            {:error, :no_providers_available}
        end
    end
  end

  defp do_select_provider_with_metadata(%SelectionContext{} = ctx) do
    max_lag_blocks = get_max_lag(ctx.profile, ctx.chain)
    filters = %{exclude: ctx.exclude, protocol: ctx.protocol, max_lag_blocks: max_lag_blocks}
    candidates = ProviderPool.list_candidates(ctx.profile, ctx.chain, filters)

    case candidates do
      [] ->
        {:error, :no_providers_available}

      _ ->
        candidate_ids = Enum.map(candidates, & &1.id)
        strategy_mod = StrategyRegistry.resolve(ctx.strategy)
        prepared_ctx = strategy_mod.prepare_context(ctx)

        channels =
          candidates
          |> Enum.flat_map(fn %{id: provider_id, config: provider_config} ->
            transports =
              case ctx.protocol do
                :http -> [:http]
                :ws -> [:ws]
                :both -> [:http, :ws]
              end

            Enum.flat_map(transports, fn t ->
              case TransportRegistry.get_channel(ctx.profile, ctx.chain, provider_id, t,
                     method: ctx.method,
                     provider_config: provider_config
                   ) do
                {:ok, ch} -> [ch]
                _ -> []
              end
            end)
          end)

        ordered = strategy_mod.rank_channels(channels, ctx.method, prepared_ctx, ctx.profile, ctx.chain)

        case List.first(ordered) do
          %Channel{provider_id: pid, transport: transport} ->
            metadata = %{
              candidates: candidate_ids,
              selected: %{id: pid, protocol: transport},
              reason: build_selection_reason(ctx.strategy)
            }

            :telemetry.execute([:lasso, :selection, :success], %{count: 1}, %{
              chain: ctx.chain,
              method: ctx.method,
              strategy: ctx.strategy,
              protocol: transport,
              provider_id: pid
            })

            {:ok, %{provider_id: pid, metadata: metadata}}

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

    # Always include half-open providers for recovery opportunities.
    # Half-open channels are deprioritized (ranked after closed) but not excluded.
    # This allows half-open circuits to recover when closed-circuit channels fail.
    include_half_open = Keyword.get(opts, :include_half_open, true)

    # Caller is responsible for policy. Do not force WS here; rely on opts.transport.
    pool_protocol =
      case transport do
        :http -> :http
        :ws -> :ws
        _ -> nil
      end

    max_lag_blocks = get_max_lag(profile, chain)

    pool_filters = %{
      protocol: pool_protocol,
      exclude: exclude,
      include_half_open: include_half_open,
      max_lag_blocks: max_lag_blocks
    }

    # Instrument ProviderPool.list_candidates call time
    pool_start = System.monotonic_time(:microsecond)
    provider_candidates = ProviderPool.list_candidates(profile, chain, pool_filters)
    pool_duration_us = System.monotonic_time(:microsecond) - pool_start

    :telemetry.execute(
      [:lasso, :selection, :pool_candidates],
      %{duration_us: pool_duration_us, candidate_count: length(provider_candidates)},
      %{chain: chain, method: method, strategy: strategy}
    )

    require Logger

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
      |> Enum.flat_map(fn %{id: provider_id, config: provider_config} ->
        transports =
          case transport do
            :http -> [:http]
            :ws -> [:ws]
            _ -> [:http, :ws]
          end

        transports
        |> Enum.flat_map(fn t ->
          has_http? = is_binary(Map.get(provider_config, :url))
          has_ws? = is_binary(Map.get(provider_config, :ws_url))

          cond do
            t == :http and not has_http? ->
              []

            t == :ws and not has_ws? ->
              []

            t == :ws and has_ws? ->
              # WS channels are only cached when connected (TransportRegistry removes on disconnect)
              case TransportRegistry.get_channel(profile, chain, provider_id, t,
                     method: method,
                     provider_config: provider_config
                   ) do
                {:ok, channel} -> [channel]
                _ -> []
              end

            true ->
              case TransportRegistry.get_channel(profile, chain, provider_id, t,
                     method: method,
                     provider_config: provider_config
                   ) do
                {:ok, channel} -> [channel]
                _ -> []
              end
          end
        end)
      end)
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
    selection_ctx = SelectionContext.new(profile, chain, method, strategy: strategy, protocol: transport)
    strategy_mod = StrategyRegistry.resolve(strategy)
    prepared_ctx = strategy_mod.prepare_context(selection_ctx)

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

  # Channel-specific strategy application has been superseded by strategy-provided
  # rank_channels/4. Legacy branches removed.

  # Selection metadata helpers

  defp build_selection_reason(strategy) do
    case strategy do
      :fastest -> "fastest_method_latency"
      :cheapest -> "cost_optimized"
      :priority -> "static_priority"
      :round_robin -> "round_robin_rotation"
      :latency_weighted -> "latency_weighted_balancing"
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
end

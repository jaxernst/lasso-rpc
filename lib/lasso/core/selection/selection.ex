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

  alias Lasso.RPC.{ProviderPool, SelectionContext, TransportRegistry, Channel}

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
  @spec select_provider(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def select_provider(chain, method, opts \\ []) when is_binary(chain) and is_binary(method) do
    ctx = SelectionContext.new(chain, method, opts)
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
  @spec select_provider_with_metadata(String.t(), String.t(), keyword()) ::
          {:ok, %{provider_id: String.t(), metadata: map()}} | {:error, term()}
  def select_provider_with_metadata(chain, method, opts \\ [])
      when is_binary(chain) and is_binary(method) do
    ctx = SelectionContext.new(chain, method, opts)

    with {:ok, validated_ctx} <- SelectionContext.validate(ctx) do
      do_select_provider_with_metadata(validated_ctx)
    end
  end

  # Private implementation

  defp do_select_provider(%SelectionContext{} = ctx) do
    max_lag_blocks = get_max_lag_for_method(ctx.chain, ctx.method)
    filters = %{exclude: ctx.exclude, protocol: ctx.protocol, max_lag_blocks: max_lag_blocks}
    candidates = ProviderPool.list_candidates(ctx.chain, filters)

    case candidates do
      [] ->
        {:error, :no_providers_available}

      _ ->
        strategy_mod = resolve_strategy_module(ctx.strategy)
        prepared_ctx = strategy_mod.prepare_context(ctx)
        selected_candidate = strategy_mod.choose(candidates, ctx.method, prepared_ctx)

        case selected_candidate do
          pid when is_binary(pid) ->
            Logger.debug("Selected provider: #{pid} for #{ctx.chain}.#{ctx.method}")

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
    max_lag_blocks = get_max_lag_for_method(ctx.chain, ctx.method)
    filters = %{exclude: ctx.exclude, protocol: ctx.protocol, max_lag_blocks: max_lag_blocks}
    candidates = ProviderPool.list_candidates(ctx.chain, filters)

    case candidates do
      [] ->
        {:error, :no_providers_available}

      _ ->
        candidate_ids = Enum.map(candidates, & &1.id)
        strategy_mod = resolve_strategy_module(ctx.strategy)
        prepared_ctx = strategy_mod.prepare_context(ctx)
        selected_provider_id = strategy_mod.choose(candidates, ctx.method, prepared_ctx)

        case selected_provider_id do
          pid when is_binary(pid) ->
            Logger.debug("Selected provider: #{pid} for #{ctx.chain}.#{ctx.method}")

            # Build selection metadata (minimal, no external dependencies)
            metadata = %{
              candidates: candidate_ids,
              selected: %{id: pid, protocol: ctx.protocol},
              reason: build_selection_reason(ctx.strategy)
            }

            :telemetry.execute([:lasso, :selection, :success], %{count: 1}, %{
              chain: ctx.chain,
              method: ctx.method,
              strategy: ctx.strategy,
              protocol: ctx.protocol,
              provider_id: pid
            })

            {:ok, %{provider_id: pid, metadata: metadata}}

          _ ->
            {:error, :no_providers_available}
        end
    end
  end

  defp resolve_strategy_module(:priority), do: Lasso.RPC.Strategies.Priority
  defp resolve_strategy_module(:round_robin), do: Lasso.RPC.Strategies.RoundRobin
  defp resolve_strategy_module(:cheapest), do: Lasso.RPC.Strategies.Cheapest
  defp resolve_strategy_module(:fastest), do: Lasso.RPC.Strategies.Fastest

  @doc """
  Selects the best channels for a method across all available transports.

  This is the new channel-based selection API that considers transport capabilities,
  health, and performance metrics to return ordered candidate channels.

  Options:
  - :strategy => :fastest | :cheapest | :priority | :round_robin
  - :transport => :http | :ws | :both (default :both)
  - :exclude => [provider_id]
  - :limit => integer (maximum channels to return)
  - :include_half_open => boolean (default false) - include providers with half-open circuits for degraded mode

  Returns a list of Channel structs ordered by strategy preference.
  """
  @spec select_channels(String.t(), String.t(), keyword()) :: [Channel.t()]
  def select_channels(chain, method, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :round_robin)
    transport = Keyword.get(opts, :transport, :both)
    exclude = Keyword.get(opts, :exclude, [])
    limit = Keyword.get(opts, :limit, 10)
    include_half_open = Keyword.get(opts, :include_half_open, false)

    # Ask pool for provider candidates without over-constraining transport for unary.
    # For subscriptions, strictly require WS at the provider layer.
    pool_protocol =
      case method do
        "eth_subscribe" -> :ws
        "eth_unsubscribe" -> :ws
        _ -> nil
      end

    max_lag_blocks = get_max_lag_for_method(chain, method)
    pool_filters = %{
      protocol: pool_protocol,
      exclude: exclude,
      include_half_open: include_half_open,
      max_lag_blocks: max_lag_blocks
    }
    provider_candidates = ProviderPool.list_candidates(chain, pool_filters)

    require Logger

    Logger.debug(
      "Selection.select_channels for #{chain}/#{method}: found #{length(provider_candidates)} provider candidates: #{inspect(Enum.map(provider_candidates, & &1.id))}"
    )

    # Build channel candidates via TransportRegistry (enforces channel-level health/capabilities)
    # Map provider list into channels, lazily opening as needed
    channels =
      provider_candidates
      |> Enum.flat_map(fn %{id: provider_id, config: provider_config} ->
        transports =
          case method do
            "eth_subscribe" ->
              [:ws]

            "eth_unsubscribe" ->
              [:ws]

            _ ->
              case transport do
                :both -> [:http, :ws]
                :http -> [:http]
                :ws -> [:ws]
              end
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
              # Only include WS if WSConnection shows connected; otherwise skip from candidates
              with status <- safe_ws_status(provider_id),
                   %{connected: true} <- status,
                   {:ok, channel} <-
                     TransportRegistry.get_channel(chain, provider_id, t,
                       method: method,
                       provider_config: provider_config
                     ) do
                [channel]
              else
                _ ->
                  []
              end

            true ->
              case TransportRegistry.get_channel(chain, provider_id, t,
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

    capable_channels
    |> apply_channel_strategy(strategy, method, chain)
    |> Enum.take(limit)
  end

  @doc """
  Selects the best channel for a specific provider and transport combination.

  Returns {:ok, channel} or {:error, reason}.
  """
  @spec select_provider_channel(String.t(), String.t(), :http | :ws, keyword()) ::
          {:ok, Channel.t()} | {:error, term()}
  def select_provider_channel(chain, provider_id, transport, opts \\ []) do
    TransportRegistry.get_channel(chain, provider_id, transport, opts)
  end

  ## Private Functions

  # Channel-specific strategy application

  defp apply_channel_strategy(channels, :priority, _method, _chain) do
    # Sort by provider priority (would need to fetch provider configs)
    # For now, preserve order and prefer HTTP over WebSocket
    Enum.sort_by(channels, fn channel ->
      transport_priority =
        case channel.transport do
          :http -> 0
          :ws -> 1
        end

      # {provider_priority, transport_priority}
      {0, transport_priority}
    end)
  end

  defp apply_channel_strategy(channels, :round_robin, _method, _chain) do
    # Simple shuffle for round-robin (could be improved with state tracking)
    Enum.shuffle(channels)
  end

  defp apply_channel_strategy(channels, :fastest, method, chain) do
    Enum.sort_by(channels, fn channel ->
      # Lower score is better
      perf =
        Lasso.RPC.Metrics.get_provider_transport_performance(
          chain,
          channel.provider_id,
          method,
          channel.transport
        )

      latency_score =
        case perf do
          %{latency_ms: ms} when is_number(ms) and ms > 0 -> ms
          _ -> 10_000
        end

      # Prefer known performance; unknown gets penalized
      latency_score
    end)
  end

  defp apply_channel_strategy(channels, :cheapest, _method, _chain) do
    # Sort by cost (would need provider cost configuration)
    # For now, treat all as equal cost and prefer HTTP
    Enum.sort_by(channels, fn channel ->
      case channel.transport do
        :http -> 0
        :ws -> 1
      end
    end)
  end

  defp apply_channel_strategy(channels, _strategy, _method, _chain) do
    # Default: preserve original order
    channels
  end

  # Selection metadata helpers

  defp build_selection_reason(strategy) do
    case strategy do
      :fastest -> "fastest_method_latency"
      :cheapest -> "cost_optimized"
      :priority -> "static_priority"
      :round_robin -> "round_robin_rotation"
    end
  end

  # Private helpers
  defp safe_ws_status(provider_id) when is_binary(provider_id) do
    try do
      Lasso.RPC.WSConnection.status(provider_id)
    catch
      :exit, _ -> :error
      _ -> :error
    end
  end

  # Configuration helper: Get max lag threshold for a specific chain and method
  # Returns nil if no lag filtering should be applied
  # Configuration precedence (highest to lowest):
  # 1. Per-method override in chain config
  # 2. Per-chain default
  # 3. Global application default
  defp get_max_lag_for_method(chain, method) do
    # Try to get chain-specific config
    case Lasso.Config.ConfigStore.get_chain(chain) do
      {:ok, %{selection: %{max_lag_per_method: method_overrides, max_lag_blocks: chain_default}}}
      when is_map(method_overrides) ->
        # Check for method-specific override first
        Map.get(method_overrides, method) || chain_default || get_global_max_lag()

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

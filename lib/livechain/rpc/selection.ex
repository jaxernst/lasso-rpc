defmodule Livechain.RPC.Selection do
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

  alias Livechain.Config.ConfigStore
  alias Livechain.RPC.{ProviderPool, Strategy, SelectionContext}

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

  # Private implementation

  defp do_select_provider(%SelectionContext{} = ctx) do
    filters = %{exclude: ctx.exclude, protocol: ctx.protocol}
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

            :telemetry.execute([:livechain, :selection, :success], %{count: 1}, %{
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

  defp resolve_strategy_module(:priority), do: Strategy.Priority
  defp resolve_strategy_module(:round_robin), do: Strategy.RoundRobin
  defp resolve_strategy_module(:cheapest), do: Strategy.Cheapest
  defp resolve_strategy_module(:fastest), do: Strategy.Fastest
  defp resolve_strategy_module(_), do: Strategy.Priority

  @doc """
  Gets all available providers for a chain, respecting protocol requirements.

  Returns providers from ProviderPool in the order determined by availability and health.
  """
  @spec get_available_providers(String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def get_available_providers(chain_name, opts \\ []) do
    protocol = Keyword.get(opts, :protocol, :both)
    exclude = Keyword.get(opts, :exclude, [])

    filters = %{protocol: protocol, exclude: exclude}
    candidates = ProviderPool.list_candidates(chain_name, filters)
    provider_ids = Enum.map(candidates, & &1.id)

    {:ok, provider_ids}
  end

  @doc """
  Checks if a specific provider is available for the given chain and protocol.
  """
  @spec provider_available?(String.t(), String.t(), atom()) :: boolean()
  def provider_available?(chain_name, provider_id, protocol \\ :both) do
    case ConfigStore.get_provider(chain_name, provider_id) do
      {:ok, provider_config} ->
        supports_protocol?(provider_config, protocol)

      {:error, :not_found} ->
        false
    end
  end

  ## Private Functions

  defp supports_protocol?(provider, :both),
    do: supports_protocol?(provider, :http) and supports_protocol?(provider, :ws)

  defp supports_protocol?(provider, :http),
    do: is_binary(Map.get(provider, :http_url)) or is_binary(Map.get(provider, :url))

  defp supports_protocol?(provider, :ws), do: is_binary(Map.get(provider, :ws_url))
end

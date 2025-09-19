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
  alias Livechain.RPC.ProviderPool
  alias Livechain.RPC.CircuitBreaker

  @doc """
  Picks the best provider for a given chain and method.

  Options:
  - `:strategy` - Selection strategy (:fastest, :cheapest, :priority, :round_robin)
  - `:protocol` - Required protocol (:http, :ws, :both)
  - `:exclude` - List of provider IDs to exclude

  Returns {:ok, provider_id} or {:error, reason}

  # TODO: Should ha
  """
  @spec pick_provider(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def pick_provider(chain_name, method, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :cheapest)
    protocol = Keyword.get(opts, :protocol, :both)
    exclude = Keyword.get(opts, :exclude, [])

    case pool_selection(chain_name, method, strategy, protocol, exclude) do
      {:ok, provider_id} = result ->
        Logger.debug("Selected provider via pool: #{provider_id} for #{chain_name}.#{method}")

        :telemetry.execute([:livechain, :selection, :success], %{count: 1}, %{
          chain: chain_name,
          method: method,
          strategy: strategy,
          protocol: protocol,
          provider_id: provider_id,
          selection_type: :pool_based
        })

        result

      {:error, reason} ->
        Logger.debug(
          "Pool selection failed (#{inspect(reason)}), falling back to config-based selection"
        )

        config_selection(chain_name, method, protocol, exclude, strategy)
    end
  end

  @doc """
  Gets all available providers for a chain, respecting protocol requirements.

  Returns providers in priority order (pool-based if available, config-based otherwise).
  """
  @spec get_available_providers(String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def get_available_providers(chain_name, opts \\ []) do
    protocol = Keyword.get(opts, :protocol, :both)
    exclude = Keyword.get(opts, :exclude, [])

    # Try to get providers from pool first
    case ProviderPool.get_active_providers(chain_name) do
      provider_ids when is_list(provider_ids) ->
        # Filter by protocol and exclusions
        filtered =
          filter_providers_by_protocol_and_exclusions(
            chain_name,
            provider_ids,
            protocol,
            exclude
          )

        {:ok, filtered}

      {:error, reason} ->
        Logger.debug("Failed to get active providers from pool: #{inspect(reason)}")
        # Fall back to config-based provider list
        config_based_providers(chain_name, protocol, exclude)

      _ ->
        # Fall back to config-based provider list
        config_based_providers(chain_name, protocol, exclude)
    end
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

  # Pool-based selection (preferred when pool is available)
  defp pool_selection(chain_name, method, strategy, protocol, exclude) do
    filters = %{exclude: exclude}

    with {:ok, provider_id} <-
           ProviderPool.get_best_provider(chain_name, strategy, method, filters),
         true <- CircuitBreaker.get_state(provider_id).state != :open,
         {:ok, provider_config} <- ConfigStore.get_provider(chain_name, provider_id),
         true <- supports_protocol?(provider_config, protocol) do
      {:ok, provider_id}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :selected_provider_wrong_protocol}
    end
  end

  # Config-based selection (fallback when pool is unavailable)
  defp config_selection(chain_name, method, protocol, exclude, strategy) do
    case config_based_providers(chain_name, protocol, exclude) do
      {:ok, []} ->
        {:error, :no_available_providers}

      {:ok, available_providers} ->
        # For config-based selection, we use priority-based selection as fallback
        # since provider pool not being available is not a nominal state
        selected_provider = List.first(available_providers)

        Logger.debug(
          "Selected provider via config fallback: #{selected_provider} for #{chain_name}.#{method} (strategy: #{strategy})"
        )

        :telemetry.execute([:livechain, :selection, :success], %{count: 1}, %{
          chain: chain_name,
          method: method,
          strategy: strategy,
          protocol: protocol,
          provider_id: selected_provider,
          selection_type: :config_based
        })

        {:ok, selected_provider}

      {:error, reason} ->
        :telemetry.execute([:livechain, :selection, :failure], %{count: 1}, %{
          chain: chain_name,
          method: method,
          protocol: protocol,
          reason: reason,
          selection_type: :config_based
        })

        {:error, reason}
    end
  end

  # Get providers from config in priority order
  defp config_based_providers(chain_name, protocol, exclude) do
    case ConfigStore.get_providers(chain_name) do
      {:ok, providers} ->
        available_providers =
          providers
          |> Enum.filter(fn provider -> supports_protocol?(provider, protocol) end)
          |> Enum.reject(fn provider -> provider.id in exclude end)
          |> Enum.sort_by(& &1.priority)
          |> Enum.map(& &1.id)

        {:ok, available_providers}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp filter_providers_by_protocol_and_exclusions(chain_name, provider_ids, protocol, exclude) do
    provider_ids
    |> Enum.reject(&(&1 in exclude))
    |> Enum.filter(fn provider_id ->
      case ConfigStore.get_provider(chain_name, provider_id) do
        {:ok, provider_config} -> supports_protocol?(provider_config, protocol)
        _ -> false
      end
    end)
  end

  defp supports_protocol?(provider, :both),
    do: supports_protocol?(provider, :http) and supports_protocol?(provider, :ws)

  defp supports_protocol?(provider, :http),
    do: is_binary(Map.get(provider, :http_url)) or is_binary(Map.get(provider, :url))

  defp supports_protocol?(provider, :ws), do: is_binary(Map.get(provider, :ws_url))
end

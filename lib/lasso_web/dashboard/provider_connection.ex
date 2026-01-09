defmodule LassoWeb.Dashboard.ProviderConnection do
  @moduledoc """
  Handles fetching and building provider connection data for the Dashboard.

  This module encapsulates the logic for:
  - Fetching provider status from ProviderPool
  - Building provider connection maps with enriched data
  - Calculating consensus heights and block sync information
  - Deriving health status and circuit breaker states
  """

  alias Lasso.Config.ConfigStore
  alias Lasso.RPC.{ChainState, ProviderPool}
  require Logger

  @doc """
  Fetches all provider connections for a given profile.
  Returns enriched connection maps with status, health, and sync information.
  """
  def fetch_connections(profile) do
    chains = ConfigStore.list_chains_for_profile(profile)

    provider_ids_by_chain = build_provider_ids_map(profile, chains)
    consensus_by_chain = build_consensus_map(chains, provider_ids_by_chain)

    chains
    |> Enum.flat_map(fn chain_name ->
      consensus_height = Map.get(consensus_by_chain, chain_name)
      provider_ids = Map.get(provider_ids_by_chain, chain_name, [])

      case ProviderPool.get_status(profile, chain_name) do
        {:ok, pool_status} ->
          pool_status.providers
          |> Enum.map(&build_provider_connection(&1, chain_name, consensus_height, provider_ids))

        {:error, reason} ->
          Logger.warning(
            "Failed to get provider status for chain #{chain_name}: #{inspect(reason)}"
          )

          []
      end
    end)
  end

  @doc """
  Builds a provider connection map from ProviderPool status data.
  Enriches with derived fields like health status, circuit state, and block sync.
  """
  def build_provider_connection(provider_map, chain_name, consensus_height, provider_ids) do
    provider_type = derive_provider_type(provider_map.config)

    {block_height, blocks_behind} =
      calculate_block_sync(chain_name, provider_map.id, consensus_height, provider_ids)

    %{
      id: provider_map.id,
      chain: chain_name,
      name: provider_map.name,
      status: provider_map.status,
      health_status: derive_health_status(provider_map.availability),
      type: provider_type,
      circuit_state: derive_circuit_state(provider_map),
      http_circuit_state: provider_map.http_cb_state,
      ws_circuit_state: provider_map.ws_cb_state,
      http_cb_error: Map.get(provider_map, :http_cb_error),
      ws_cb_error: Map.get(provider_map, :ws_cb_error),
      consecutive_failures: provider_map.consecutive_failures,
      consecutive_successes: provider_map.consecutive_successes,
      last_error: provider_map.last_error,
      http_rate_limited: Map.get(provider_map, :http_rate_limited, false),
      ws_rate_limited: Map.get(provider_map, :ws_rate_limited, false),
      rate_limit_remaining: Map.get(provider_map, :rate_limit_remaining, %{http: nil, ws: nil}),
      is_in_cooldown: provider_map.is_in_cooldown,
      cooldown_until: provider_map.cooldown_until,
      reconnect_attempts: 0,
      ws_connected: ws_connected?(provider_type, provider_map),
      subscriptions: 0,
      url: provider_map.config.url,
      ws_url: provider_map.config.ws_url,
      block_height: block_height,
      consensus_height: consensus_height,
      blocks_behind: blocks_behind
    }
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  defp build_provider_ids_map(profile, chains) do
    chains
    |> Enum.map(fn chain_name ->
      provider_ids =
        case ProviderPool.get_status(profile, chain_name) do
          {:ok, pool_status} -> Enum.map(pool_status.providers, & &1.id)
          {:error, _} -> []
        end

      {chain_name, provider_ids}
    end)
    |> Enum.into(%{})
  end

  defp build_consensus_map(chains, provider_ids_by_chain) do
    chains
    |> Enum.map(fn chain_name ->
      provider_ids = Map.get(provider_ids_by_chain, chain_name, [])

      consensus =
        case ChainState.consensus_height(chain_name, provider_ids) do
          {:ok, height} -> height
          {:error, _} -> nil
        end

      {chain_name, consensus}
    end)
    |> Enum.into(%{})
  end

  defp derive_circuit_state(provider_map) do
    cond do
      provider_map.http_cb_state == :open or provider_map.ws_cb_state == :open ->
        :open

      provider_map.http_cb_state == :half_open or provider_map.ws_cb_state == :half_open ->
        :half_open

      true ->
        :closed
    end
  end

  defp derive_provider_type(config) do
    cond do
      config.url && config.ws_url -> :both
      config.ws_url -> :websocket
      true -> :http
    end
  end

  defp derive_health_status(:up), do: :healthy
  defp derive_health_status(:down), do: :unhealthy
  defp derive_health_status(:limited), do: :rate_limited
  defp derive_health_status(:misconfigured), do: :misconfigured
  defp derive_health_status(other), do: other

  defp ws_connected?(provider_type, provider_map) do
    provider_type in [:websocket, :both] and provider_map.ws_status == :healthy
  end

  defp calculate_block_sync(_chain_name, _provider_id, nil, _provider_ids), do: {nil, nil}

  defp calculate_block_sync(chain_name, provider_id, consensus_height, provider_ids) do
    case ChainState.provider_lag(chain_name, provider_id, provider_ids) do
      {:ok, lag} when is_integer(lag) -> {consensus_height + lag, -lag}
      _ -> {nil, nil}
    end
  end
end

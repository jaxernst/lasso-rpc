defmodule LassoWeb.Dashboard.ProviderConnection do
  @moduledoc """
  Fetches and builds provider connection data for the Dashboard from ETS.
  """

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{Catalog, InstanceState}
  alias Lasso.RPC.ChainState
  require Logger

  def fetch_connections(profile) do
    chains = ConfigStore.list_chains_for_profile(profile)

    Enum.flat_map(chains, fn chain_name ->
      fetch_chain_connections(profile, chain_name)
    end)
  end

  defp fetch_chain_connections(profile, chain_name) do
    profile_providers = Catalog.get_profile_providers(profile, chain_name)

    instance_ids =
      profile_providers
      |> Enum.map(& &1.instance_id)
      |> Enum.uniq()

    consensus_height =
      case ChainState.consensus_height(chain_name, provider_ids: instance_ids) do
        {:ok, h} -> h
        {:error, _} -> nil
      end

    Enum.map(profile_providers, fn pp ->
      build_provider_connection(pp, profile, chain_name, consensus_height)
    end)
  end

  defp build_provider_connection(profile_provider, _profile, chain_name, consensus_height) do
    instance_id = profile_provider.instance_id
    provider_id = profile_provider.provider_id

    instance_config =
      case Catalog.get_instance(instance_id) do
        {:ok, config} -> config
        _ -> %{}
      end

    url = Map.get(instance_config, :url)
    ws_url = Map.get(instance_config, :ws_url)
    provider_name = get_in(instance_config, [:canonical_config, :name]) || provider_id

    provider_type =
      cond do
        url && ws_url -> :both
        ws_url -> :websocket
        true -> :http
      end

    health = InstanceState.read_health(instance_id)
    ws_status = InstanceState.read_ws_status(instance_id)
    http_circuit = InstanceState.read_circuit(instance_id, :http)
    ws_circuit = InstanceState.read_circuit(instance_id, :ws)
    http_rl = InstanceState.read_rate_limit(instance_id, :http)
    ws_rl = InstanceState.read_rate_limit(instance_id, :ws)

    availability = InstanceState.status_to_availability(health.status)

    circuit_state =
      cond do
        http_circuit.state == :open or ws_circuit.state == :open -> :open
        http_circuit.state == :half_open or ws_circuit.state == :half_open -> :half_open
        true -> :closed
      end

    is_in_cooldown = http_rl.rate_limited or ws_rl.rate_limited
    now_ms = System.monotonic_time(:millisecond)

    cooldown_until =
      case {http_rl.remaining_ms, ws_rl.remaining_ms} do
        {nil, nil} -> nil
        {http_rem, nil} -> now_ms + http_rem
        {nil, ws_rem} -> now_ms + ws_rem
        {http_rem, ws_rem} -> now_ms + max(http_rem, ws_rem)
      end

    {block_height, blocks_behind} =
      calculate_block_sync(chain_name, instance_id, consensus_height)

    %{
      id: provider_id,
      chain: chain_name,
      name: provider_name,
      status: health.status,
      health_status: derive_health_status(availability),
      type: provider_type,
      instance_id: instance_id,
      circuit_state: circuit_state,
      http_circuit_state: http_circuit.state,
      ws_circuit_state: ws_circuit.state,
      http_cb_error: http_circuit.error,
      ws_cb_error: ws_circuit.error,
      consecutive_failures: health.consecutive_failures,
      consecutive_successes: health.consecutive_successes,
      last_error: health.last_error,
      http_rate_limited: http_rl.rate_limited,
      ws_rate_limited: ws_rl.rate_limited,
      rate_limit_remaining: %{http: http_rl.remaining_ms, ws: ws_rl.remaining_ms},
      is_in_cooldown: is_in_cooldown,
      cooldown_until: cooldown_until,
      reconnect_attempts: ws_status.reconnect_attempts,
      ws_connected: provider_type in [:websocket, :both] and ws_status.status == :connected,
      ws_status: ws_status.status,
      subscriptions: 0,
      url: url,
      ws_url: ws_url,
      block_height: block_height,
      consensus_height: consensus_height,
      blocks_behind: blocks_behind
    }
  end

  defp derive_health_status(:up), do: :healthy
  defp derive_health_status(:down), do: :unhealthy
  defp derive_health_status(:limited), do: :rate_limited
  defp derive_health_status(other), do: other

  defp calculate_block_sync(_, _, nil), do: {nil, nil}

  defp calculate_block_sync(chain_name, instance_id, consensus_height) do
    case ChainState.provider_lag(chain_name, instance_id) do
      {:ok, lag} when is_integer(lag) -> {consensus_height + lag, -lag}
      _ -> {nil, nil}
    end
  end
end

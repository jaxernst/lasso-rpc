defmodule Livechain.RPC.StatusAggregator do
  @moduledoc "Centralized status builder for UI endpoints."

  alias Livechain.RPC.{ProviderDirectory, ChainSupervisor}
  alias Livechain.Config.ConfigStore

  def list_all_providers_comprehensive do
    ConfigStore.get_all_chains()
    |> Enum.flat_map(fn {chain, _cfg} ->
      case ProviderDirectory.snapshot(chain) do
        {:ok, providers} ->
          Enum.map(providers, fn p ->
            %{
              id: p.id,
              name: p.name,
              chain: chain,
              type: infer_type(p),
              status: normalize_status(p.health),
              health_status: p.health,
              circuit_state: p.circuit,
              reconnect_attempts: get_ws(chain, p.id)[:reconnect_attempts] || 0,
              subscriptions: get_ws(chain, p.id)[:subscriptions] || 0,
              last_seen: nil,
              consecutive_failures: nil,
              consecutive_successes: nil,
              last_error: nil,
              is_in_cooldown: not is_nil(p.cooldown_until),
              cooldown_until: p.cooldown_until,
              cooldown_count: nil,
              ws_connected: p.ws_connected,
              pending_messages: get_ws(chain, p.id)[:pending_messages] || 0
            }
          end)

        _ ->
          []
      end
    end)
  end

  defp get_ws(chain, provider_id) do
    case ChainSupervisor.get_chain_status(chain) do
      %{ws_connections: ws} when is_list(ws) ->
        case Enum.find(ws, &(&1.id == provider_id)) do
          nil -> %{}
          m -> m
        end

      _ ->
        %{}
    end
  end

  defp infer_type(p) do
    case {p.protocols.http, p.protocols.ws} do
      {true, true} -> :both
      {true, false} -> :http
      {false, true} -> :websocket
      _ -> :unknown
    end
  end

  defp normalize_status(:healthy), do: :connected
  defp normalize_status(:unhealthy), do: :disconnected
  defp normalize_status(:connecting), do: :connecting
  defp normalize_status(:rate_limited), do: :rate_limited
  defp normalize_status(_), do: :disconnected
end

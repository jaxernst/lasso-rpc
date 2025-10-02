defmodule Lasso.RPC.ProviderDirectory do
  @moduledoc "Produce provider snapshots by joining config, pool health, breaker state, and WS status."

  alias Lasso.Config.ConfigStore
  alias Lasso.RPC.{ChainSupervisor, CircuitBreaker, ProviderPool}

  def snapshot(chain) do
    with {:ok, {_name, chain_cfg}} <- ConfigStore.get_chain_by_name_or_id(chain) do
      # Get pool status if available
      pool_map =
        case ProviderPool.get_status(chain) do
          {:ok, pool_status} -> Map.new(pool_status.providers, &{&1.id, &1})
          _ -> %{}
        end

      ws_map =
        case ChainSupervisor.get_chain_status(chain) do
          %{ws_connections: ws} when is_list(ws) -> Map.new(ws, &{&1.id, &1})
          _ -> %{}
        end

      providers =
        Enum.map(chain_cfg.providers, fn p ->
          cb_state = breaker_state(p.id)
          pool = Map.get(pool_map, p.id)
          ws = Map.get(ws_map, p.id)

          cooldown_until =
            case pool && Map.get(pool, :policy) do
              %Lasso.RPC.HealthPolicy{cooldown_until: cu} -> cu
              _ -> pool && Map.get(pool, :cooldown_until)
            end

          availability =
            case pool && Map.get(pool, :policy) do
              %Lasso.RPC.HealthPolicy{} = pol -> Lasso.RPC.HealthPolicy.availability(pol)
              _ -> :up
            end

          %{
            id: p.id,
            name: p.name,
            config: %{priority: p.priority, type: p.type, chain: chain},
            protocols: %{http: is_binary(p.url), ws: is_binary(p.ws_url)},
            health: (pool && pool.status) || :connecting,
            availability: availability,
            circuit: cb_state,
            cooldown_until: cooldown_until,
            metrics: %{},
            ws_connected: (ws && ws.connected) || false
          }
        end)

      {:ok, providers}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def filter(providers, opts) do
    protocol = Keyword.get(opts, :protocol, :both)
    exclude = MapSet.new(Keyword.get(opts, :exclude, []))

    providers
    |> Enum.reject(&(&1.id in exclude))
    |> Enum.filter(&supports_protocol?(&1, protocol))
    |> Enum.filter(&available?(&1))
  end

  defp supports_protocol?(p, :http), do: p.protocols.http
  defp supports_protocol?(p, :ws), do: p.protocols.ws
  defp supports_protocol?(p, :both), do: p.protocols.http and p.protocols.ws

  defp available?(p) do
    p.health in [:healthy, :connecting] and p.circuit != :open and
      (is_nil(p.cooldown_until) or p.cooldown_until <= System.monotonic_time(:millisecond))
  end

  defp breaker_state(provider_id) do
    try do
      CircuitBreaker.get_state(provider_id).state
    catch
      :exit, {:noproc, _} -> :closed
      _ -> :closed
    end
  end
end

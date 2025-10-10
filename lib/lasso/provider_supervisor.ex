defmodule Lasso.RPC.ProviderSupervisor do
  @moduledoc """
  Per-provider supervisor that owns the lifecycle of circuit breakers and the WS connection.

  Child order matters. We start circuit breakers first and WebSocket last. On shutdown, children
  are terminated in reverse order, ensuring the WS process stops before its circuit breakers.
  """

  use Supervisor
  require Logger

  alias Lasso.RPC.{CircuitBreaker, WSConnection, WSEndpoint}

  @type chain_name :: String.t()
  @type provider_config :: map()

  @spec start_link({chain_name, map(), map()}) :: Supervisor.on_start()
  def start_link({chain_name, chain_config, provider_config}) do
    name = via_name(chain_name, provider_config.id)
    Supervisor.start_link(__MODULE__, {chain_name, chain_config, provider_config}, name: name)
  end

  @impl true
  def init({chain_name, chain_config, provider}) do
    children =
      []
      |> maybe_add_http_circuit(chain_name, provider)
      |> maybe_add_ws_circuit(chain_name, provider)
      |> maybe_add_ws_connection(chain_name, chain_config, provider)

    # Start breakers first, then WS (reverse stop order on shutdown)
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp maybe_add_http_circuit(children, chain_name, provider) do
    if is_binary(Map.get(provider, :url)) do
      circuit_config = %{failure_threshold: 5, recovery_timeout: 60_000, success_threshold: 2}

      child = %{
        id: {:circuit_http, provider.id},
        start:
          {CircuitBreaker, :start_link, [{{chain_name, provider.id, :http}, circuit_config}]},
        type: :worker,
        restart: :permanent,
        shutdown: 5_000
      }

      [child | children]
    else
      children
    end
  end

  defp maybe_add_ws_circuit(children, chain_name, provider) do
    if is_binary(Map.get(provider, :ws_url)) do
      circuit_config = %{failure_threshold: 5, recovery_timeout: 60_000, success_threshold: 2}

      child = %{
        id: {:circuit_ws, provider.id},
        start: {CircuitBreaker, :start_link, [{{chain_name, provider.id, :ws}, circuit_config}]},
        type: :worker,
        restart: :permanent,
        shutdown: 5_000
      }

      [child | children]
    else
      children
    end
  end

  defp maybe_add_ws_connection(children, chain_name, chain_config, provider) do
    case Map.get(provider, :ws_url) do
      url when is_binary(url) ->
        endpoint = %WSEndpoint{
          id: provider.id,
          name: provider.name,
          ws_url: url,
          chain_id: chain_config.chain_id,
          chain_name: chain_name,
          heartbeat_interval: chain_config.connection.heartbeat_interval,
          reconnect_interval: chain_config.connection.reconnect_interval,
          max_reconnect_attempts: chain_config.connection.max_reconnect_attempts
        }

        child = %{
          id: {:ws_conn, provider.id},
          start: {WSConnection, :start_link, [endpoint]},
          type: :worker,
          restart: :permanent,
          shutdown: 5_000
        }

        children ++ [child]

      _ ->
        children
    end
  end

  def via_name(chain_name, provider_id) do
    {:via, Registry, {Lasso.Registry, {:provider_supervisor, chain_name, provider_id}}}
  end
end

defmodule Lasso.Providers.InstanceSupervisor do
  @moduledoc """
  Per-instance supervisor that owns shared circuit breakers and WS runtime.

  One InstanceSupervisor per unique `instance_id`. Children:
  - Shared CircuitBreaker for `:http` (if URL configured)
  - Shared CircuitBreaker for `:ws` (if WS URL configured)
  - Shared WSConnection (if WS URL configured)
  """

  use Supervisor

  alias Lasso.Core.Streaming.InstanceSubscriptionManager
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.Transport.WebSocket.Connection

  @spec start_link(String.t()) :: Supervisor.on_start()
  def start_link(instance_id) when is_binary(instance_id) do
    Supervisor.start_link(__MODULE__, instance_id, name: via_name(instance_id))
  end

  @impl true
  def init(instance_id) do
    case Catalog.get_instance(instance_id) do
      {:ok, instance} ->
        circuit_config = %{
          failure_threshold: 5,
          recovery_timeout: 60_000,
          success_threshold: 2,
          shared_mode: true
        }

        children =
          []
          |> maybe_add_circuit(:http, instance_id, instance.url, circuit_config)
          |> maybe_add_circuit(:ws, instance_id, instance.ws_url, circuit_config)
          |> maybe_add_ws_connection(instance_id, instance.ws_url)
          |> maybe_add_subscription_manager(instance_id, instance.chain, instance.ws_url)

        Supervisor.init(children, strategy: :one_for_one)

      {:error, :not_found} ->
        :ignore
    end
  end

  defp maybe_add_circuit(children, transport, instance_id, url, config) when is_binary(url) do
    child = %{
      id: {:circuit, transport},
      start: {CircuitBreaker, :start_link, [{{instance_id, transport}, config}]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }

    [child | children]
  end

  defp maybe_add_circuit(children, _transport, _instance_id, _url, _config) do
    children
  end

  defp maybe_add_ws_connection(children, instance_id, ws_url) when is_binary(ws_url) do
    child = %{
      id: {:ws_connection, instance_id},
      start: {Connection, :start_shared_link, [instance_id]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }

    [child | children]
  end

  defp maybe_add_ws_connection(children, _instance_id, _ws_url) do
    children
  end

  defp maybe_add_subscription_manager(children, instance_id, chain, ws_url)
       when is_binary(ws_url) do
    child = %{
      id: {:subscription_manager, instance_id},
      start: {InstanceSubscriptionManager, :start_link, [{chain, instance_id}]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }

    [child | children]
  end

  defp maybe_add_subscription_manager(children, _instance_id, _chain, _ws_url), do: children

  @spec via_name(String.t()) :: {:via, Registry, {Lasso.Registry, term()}}
  def via_name(instance_id) do
    {:via, Registry, {Lasso.Registry, {:instance_supervisor, instance_id}}}
  end
end

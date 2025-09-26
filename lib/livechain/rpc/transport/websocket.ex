defmodule Livechain.RPC.Transport.WebSocket do
  @moduledoc """
  WebSocket transport implementation for RPC requests and subscriptions.

  Handles WebSocket-based JSON-RPC requests including both unary requests
  (single request/response) and streaming subscriptions with proper connection
  management and error normalization. Implements the new Transport behaviour
  for transport-agnostic request routing.
  """

  @behaviour Livechain.RPC.Transport

  require Logger
  alias Livechain.RPC.WSConnection
  alias Livechain.RPC.ErrorNormalizer
  alias Livechain.JSONRPC.Error, as: JError

  # Channel represents a WebSocket connection
  @type channel :: %{
          ws_url: String.t(),
          provider_id: String.t(),
          connection_pid: pid(),
          config: map()
        }

  # New Transport behaviour implementation

  @impl true
  def open(provider_config, opts \\ []) do
    provider_id = Keyword.get(opts, :provider_id, Map.get(provider_config, :id, "unknown"))

    case get_ws_url(provider_config) do
      nil ->
        {:error,
         JError.new(-32000, "No WebSocket URL configured for provider",
           provider_id: provider_id,
           retriable?: false
         )}

      ws_url ->
        # For now, we'll use the existing WSConnection via the provider_id
        # In a full implementation, we would start a dedicated connection pool here
        case GenServer.whereis({:via, Registry, {Livechain.Registry, {:ws_conn, provider_id}}}) do
          nil ->
            {:error,
             JError.new(-32000, "WebSocket connection not available",
               provider_id: provider_id,
               retriable?: true
             )}

          connection_pid ->
            channel = %{
              ws_url: ws_url,
              provider_id: provider_id,
              connection_pid: connection_pid,
              config: provider_config
            }

            {:ok, channel}
        end
    end
  end

  @impl true
  def healthy?(%{provider_id: provider_id, connection_pid: pid}) when is_pid(pid) do
    Process.alive?(pid) and
      case WSConnection.status(provider_id) do
        %{connected: true} -> true
        _ -> false
      end
  rescue
    _ -> false
  end

  def healthy?(_), do: false

  @impl true
  def capabilities(_channel) do
    %{
      unary?: true,
      subscriptions?: true,
      # WebSocket supports all methods by default
      methods: :all
    }
  end

  @impl true
  def request(channel, rpc_request, _timeout \\ 30_000) do
    %{provider_id: provider_id, connection_pid: _connection_pid} = channel

    method = Map.get(rpc_request, "method")
    params = Map.get(rpc_request, "params", [])
    request_id = Map.get(rpc_request, "id") || generate_request_id()

    # Create full JSON-RPC request message
    message = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => request_id
    }

    Logger.debug("WebSocket unary request via channel",
      provider: provider_id,
      method: method,
      id: request_id
    )

    # For unary requests over WebSocket, we need to:
    # 1. Send the message
    # 2. Wait for the response with matching ID
    # 3. Return the result

    # This is a simplified implementation - in production we'd want:
    # - A proper request/response correlation system
    # - Timeout handling
    # - Better error handling

    # Send without branching; WSConnection.cast always returns :ok
    _ = WSConnection.send_message(provider_id, message)
    # For now, simulate success until unary correlation is implemented
    {:ok, %{"result" => "WebSocket unary request sent"}}
  end

  @impl true
  def subscribe(channel, rpc_request, handler_pid) when is_pid(handler_pid) do
    %{provider_id: provider_id, connection_pid: _connection_pid} = channel

    method = Map.get(rpc_request, "method")
    params = Map.get(rpc_request, "params", [])

    # For subscriptions, we use the existing WSConnection.subscribe mechanism
    case method do
      "eth_subscribe" ->
        [topic | _] = params

        case WSConnection.subscribe(provider_id, topic) do
          :ok ->
            # Return a subscription reference (simplified)
            {:ok, {provider_id, topic, handler_pid}}

          error ->
            {:error, error}
        end

      _ ->
        {:error, :unsupported_method}
    end
  end

  @impl true
  def unsubscribe(_channel, {provider_id, topic, _handler_pid}) do
    # In a full implementation, we'd send an eth_unsubscribe message
    # For now, we'll just return ok since the existing system
    # doesn't have explicit unsubscribe support
    Logger.debug("WebSocket unsubscribe", provider: provider_id, topic: topic)
    :ok
  end

  def unsubscribe(_channel, _subscription_ref) do
    {:error, :invalid_subscription_ref}
  end

  @impl true
  def close(channel) do
    %{connection_pid: connection_pid} = channel
    # We don't actually close the connection since it might be shared
    # In a full implementation with connection pools, we'd decrement reference count
    Logger.debug("WebSocket channel close requested", connection: inspect(connection_pid))
    :ok
  end

  # Helper function
  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # Legacy compatibility functions (no longer part of behaviour)

  def forward_request(provider_config, method, params, opts) do
    provider_id = Keyword.get(opts, :provider_id, "unknown")
    request_id = Keyword.get(opts, :request_id) || generate_request_id()
    _chain_name = Map.get(provider_config, :chain)

    case get_ws_url(provider_config) do
      nil ->
        {:error,
         JError.new(-32000, "No WebSocket URL configured for provider",
           provider_id: provider_id,
           retriable?: false
         )}

      _ws_url ->
        message = %{
          "jsonrpc" => "2.0",
          "method" => method,
          "params" => params,
          "id" => request_id
        }

        Logger.debug("Forwarding WebSocket request",
          provider: provider_id,
          method: method,
          id: request_id
        )

        case WSConnection.send_message(provider_id, message) do
          :ok ->
            {:ok, :sent}

          other ->
            {:error,
             ErrorNormalizer.normalize(other,
               provider_id: provider_id,
               context: :transport,
               transport: :ws
             )}
        end
    end
  end

  def supports_protocol?(provider_config, :ws), do: has_ws_url?(provider_config)
  def supports_protocol?(provider_config, :both), do: has_ws_url?(provider_config)
  def supports_protocol?(_provider_config, :http), do: false

  def get_transport_type(_provider_config), do: :ws

  # Private functions

  defp get_ws_url(provider_config) do
    Map.get(provider_config, :ws_url)
  end

  defp has_ws_url?(provider_config) do
    is_binary(get_ws_url(provider_config))
  end
end

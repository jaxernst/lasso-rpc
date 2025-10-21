defmodule Lasso.RPC.Transports.WebSocket do
  @moduledoc """
  WebSocket transport implementation for RPC requests and subscriptions.

  Handles WebSocket-based JSON-RPC requests including both unary requests
  (single request/response) and streaming subscriptions with proper connection
  management and error normalization. Implements the new Transport behaviour
  for transport-agnostic request routing.
  """

  @behaviour Lasso.RPC.Transport

  require Logger
  alias Lasso.RPC.WSConnection
  alias Lasso.RPC.ErrorNormalizer
  alias Lasso.JSONRPC.Error, as: JError

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
         JError.new(-32_000, "No WebSocket URL configured for provider",
           provider_id: provider_id,
           retriable?: false
         )}

      ws_url ->
        # For now, we'll use the existing WSConnection via the provider_id
        # In a full implementation, we would start a dedicated connection pool here
        case GenServer.whereis({:via, Registry, {Lasso.Registry, {:ws_conn, provider_id}}}) do
          nil ->
            {:error,
             JError.new(-32_000, "WebSocket connection not available",
               provider_id: provider_id,
               retriable?: true
             )}

          connection_pid when is_pid(connection_pid) ->
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
  def healthy?(%{connection_pid: pid}) when is_pid(pid) do
    Process.alive?(pid)
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
  def request(channel, rpc_request, timeout \\ 30_000) do
    %{provider_id: provider_id} = channel

    method = Map.get(rpc_request, "method")
    params = Map.get(rpc_request, "params", [])
    request_id = Map.get(rpc_request, "id")

    Logger.debug("WebSocket unary request via channel",
      provider: provider_id,
      method: method,
      request_id: request_id
    )

    # Start timing for I/O latency measurement
    io_start_us = System.monotonic_time(:microsecond)

    result =
      case WSConnection.request(provider_id, method, params, timeout, request_id) do
        {:ok, result} ->
          {:ok, result}

        {:error, %JError{} = jerr} ->
          {:error, jerr}

        {:error, other} ->
          {:error,
           ErrorNormalizer.normalize(other,
             provider_id: provider_id,
             context: :transport,
             transport: :ws
           )}
      end

    io_ms = div(System.monotonic_time(:microsecond) - io_start_us, 1000)

    :telemetry.execute(
      [:lasso, :websocket, :request, :io],
      %{io_ms: io_ms},
      %{provider_id: provider_id, method: method}
    )

    case result do
      {:ok, response} -> {:ok, response, io_ms}
      {:error, reason} -> {:error, reason, io_ms}
    end
  end

  @impl true
  def subscribe(channel, rpc_request, handler_pid) when is_pid(handler_pid) do
    %{provider_id: provider_id, connection_pid: _connection_pid} = channel

    method = Map.get(rpc_request, "method")
    params = Map.get(rpc_request, "params", [])

    case method do
      "eth_subscribe" ->
        case WSConnection.request(provider_id, method, params, 30_000) do
          {:ok, subscription_id} ->
            # Return a subscription reference with the upstream subscription ID
            {:ok, {provider_id, subscription_id, handler_pid}}

          {:error, reason} ->
            {:error, reason}
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

  def forward_request(provider_config, method, params, opts) do
    provider_id = Keyword.get(opts, :provider_id, "unknown")
    request_id = Keyword.get(opts, :request_id) || generate_request_id()
    _chain_name = Map.get(provider_config, :chain)

    case get_ws_url(provider_config) do
      nil ->
        {:error,
         JError.new(-32_000, "No WebSocket URL configured for provider",
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

  # Private functions

  defp get_ws_url(provider_config) do
    Map.get(provider_config, :ws_url)
  end
end

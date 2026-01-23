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
  alias Lasso.Core.Support.ErrorNormalizer
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.Response
  alias Lasso.RPC.Transport.WebSocket.Connection, as: WSConnection

  # Channel represents a WebSocket connection
  @type channel :: %{
          profile: String.t(),
          chain: String.t(),
          ws_url: String.t(),
          provider_id: String.t(),
          connection_pid: pid(),
          config: map()
        }

  # New Transport behaviour implementation

  @impl true
  def open(provider_config, opts \\ []) do
    provider_id = Keyword.get(opts, :provider_id, Map.get(provider_config, :id, "unknown"))
    profile = Keyword.get(opts, :profile, Map.get(provider_config, :profile))
    chain = Keyword.get(opts, :chain, Map.get(provider_config, :chain))

    case get_ws_url(provider_config) do
      nil ->
        {:error,
         JError.new(-32_000, "No WebSocket URL configured for provider",
           provider_id: provider_id,
           retriable?: false
         )}

      ws_url ->
        case GenServer.whereis(
               {:via, Registry, {Lasso.Registry, {:ws_conn, profile, chain, provider_id}}}
             ) do
          nil ->
            {:error,
             JError.new(-32_000, "WebSocket connection not available",
               provider_id: provider_id,
               retriable?: true
             )}

          connection_pid when is_pid(connection_pid) ->
            channel = %{
              profile: profile,
              chain: chain,
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
    %{profile: profile, chain: chain, provider_id: provider_id} = channel

    method = Map.get(rpc_request, "method")
    params = Map.get(rpc_request, "params", [])
    request_id = Map.get(rpc_request, "id")

    # Start timing for I/O latency measurement
    io_start_us = System.monotonic_time(:microsecond)

    result =
      case WSConnection.request(
             {profile, chain, provider_id},
             method,
             params,
             timeout,
             request_id
           ) do
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
      %{provider_id: provider_id, method: method, request_id: request_id}
    )

    case result do
      {:ok, response} -> {:ok, response, io_ms}
      {:error, reason} -> {:error, reason, io_ms}
    end
  end

  @impl true
  def subscribe(channel, rpc_request, handler_pid) when is_pid(handler_pid) do
    %{profile: profile, chain: chain, provider_id: provider_id} = channel

    method = Map.get(rpc_request, "method")
    params = Map.get(rpc_request, "params", [])

    case method do
      "eth_subscribe" ->
        case WSConnection.request({profile, chain, provider_id}, method, params, 30_000) do
          {:ok, %Response.Success{} = response} ->
            case Response.Success.decode_result(response) do
              {:ok, subscription_id} ->
                # Return a subscription reference with the upstream subscription ID
                {:ok, {provider_id, subscription_id, handler_pid}}

              {:error, reason} ->
                {:error, {:decode_failed, reason}}
            end

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

  # Private functions

  defp get_ws_url(provider_config) do
    Map.get(provider_config, :ws_url)
  end
end

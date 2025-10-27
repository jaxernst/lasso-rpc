defmodule LassoWeb.RPCCowboyHandler do
  @moduledoc """
  Custom Cowboy handler for WebSocket connections that routes all /rpc/* paths
  to the RPCSocket transport handler.

  This allows WebSocket clients to connect to the same paths as HTTP clients:
  - ws://host/rpc/ethereum
  - ws://host/rpc/fastest/ethereum
  - ws://host/rpc/latency-weighted/ethereum
  etc.
  """

  @behaviour :cowboy_websocket

  require Logger

  # 2 hours
  @websocket_timeout 7_200_000
  @websocket_compress false

  @doc """
  Initialize the WebSocket upgrade.
  This is called during the HTTP upgrade request.
  """
  def init(req, _state) do
    # Check if this is a WebSocket upgrade request
    case :cowboy_req.parse_header("upgrade", req) do
      ["websocket"] ->
        # Validate origin if check_origin is enabled
        case validate_origin(req) do
          :ok ->
            # Valid WebSocket upgrade - extract request information before upgrade
            path = :cowboy_req.path(req)
            peer_data = get_peer_data(req)
            x_headers = get_x_headers(req)

            # Store request info in state for websocket_init
            initial_state = %{
              path: path,
              peer_data: peer_data,
              x_headers: x_headers
            }

            # Upgrade to WebSocket protocol
            {:cowboy_websocket, req, initial_state,
             %{
               idle_timeout: @websocket_timeout,
               compress: @websocket_compress
             }}

          {:error, reason} ->
            # Reject upgrade with 403 Forbidden
            Logger.warning("WebSocket upgrade rejected: #{reason}")

            req =
              :cowboy_req.reply(
                403,
                %{"content-type" => "text/plain"},
                "Forbidden: #{reason}",
                req
              )

            {:ok, req, %{}}
        end

      _ ->
        # Not a WebSocket upgrade - pass through to Phoenix HTTP handler
        # This allows regular HTTP POST requests to /rpc/* to work normally
        Plug.Cowboy.Handler.init(req, {LassoWeb.Endpoint, []})
    end
  end

  @doc """
  Initialize the WebSocket connection after upgrade.
  This delegates to Phoenix's socket transport system.
  """
  def websocket_init(initial_state) do
    # Build transport_info compatible with Phoenix.Socket.Transport
    # We only pass the path as a string since that's all parse_path_strategy needs
    transport_info = %{
      connect_info: %{
        uri: initial_state.path,
        peer_data: initial_state.peer_data,
        x_headers: initial_state.x_headers
      }
    }

    # Call the RPCSocket connect callback
    # Note: RPCSocket.connect/1 always returns {:ok, state} (verified by type checker)
    # If this contract ever changes, the code will fail at compile time
    {:ok, socket_state} = LassoWeb.RPCSocket.connect(transport_info)

    # Initialize the socket
    # Note: RPCSocket.init/1 always returns {:ok, state} (verified by type checker)
    {:ok, final_state} = LassoWeb.RPCSocket.init(socket_state)

    {:ok, final_state}
  end

  @doc """
  Handle incoming WebSocket frames (text, binary, ping, pong).
  """
  def websocket_handle({:ping, payload}, state) do
    {:reply, [{:pong, payload}], state}
  end

  def websocket_handle({:pong, payload}, state) do
    LassoWeb.RPCSocket.handle_control({payload, [opcode: :pong]}, state)
    |> phoenix_to_cowboy_reply()
  end

  def websocket_handle({:text, _text} = frame, state) do
    LassoWeb.RPCSocket.handle_in(frame, state)
    |> phoenix_to_cowboy_reply()
  end

  def websocket_handle({:binary, _data} = frame, state) do
    LassoWeb.RPCSocket.handle_in(frame, state)
    |> phoenix_to_cowboy_reply()
  end

  def websocket_handle(frame, state) do
    Logger.warning("Unhandled WebSocket frame type: #{inspect(frame)}")
    {:ok, state}
  end

  @doc """
  Handle incoming Erlang messages (from OTP processes).
  """
  def websocket_info(msg, state) do
    LassoWeb.RPCSocket.handle_info(msg, state)
    |> phoenix_to_cowboy_reply()
  end

  @doc """
  Called when the WebSocket connection terminates.
  """
  def terminate(reason, _req, state) do
    # Only call RPCSocket.terminate if state is properly initialized
    # State will be a map with socket fields if websocket_init completed successfully
    case state do
      %{chain: _, subscriptions: _} ->
        LassoWeb.RPCSocket.terminate(reason, state)

      _ ->
        # State is initial_state or empty - connection closed before full initialization
        :ok
    end

    :ok
  end

  ## Private helpers

  # Translate Phoenix Socket Transport return values to Cowboy WebSocket return values
  defp phoenix_to_cowboy_reply({:ok, state}), do: {:ok, state}

  defp phoenix_to_cowboy_reply({:push, {opcode, msg}, state}),
    do: {:reply, [{opcode, msg}], state}

  defp phoenix_to_cowboy_reply({:reply, _status, {opcode, msg}, state}),
    do: {:reply, [{opcode, msg}], state}

  defp phoenix_to_cowboy_reply({:stop, _reason, state}), do: {:stop, state}

  defp get_peer_data(req) do
    case :cowboy_req.peer(req) do
      {address, _port} -> %{address: address}
      _ -> %{}
    end
  end

  defp get_x_headers(req) do
    headers = :cowboy_req.headers(req)

    # Extract x- headers
    headers
    |> Enum.filter(fn {name, _value} -> String.starts_with?(name, "x-") end)
    |> Map.new()
  end

  # Origin validation (mirrors Phoenix's check_origin behavior)
  defp validate_origin(req) do
    check_origin = Application.get_env(:lasso, LassoWeb.Endpoint)[:check_origin]

    case check_origin do
      # Origin checking disabled
      false ->
        :ok

      # Check origin matches host
      true ->
        check_origin_header(req)

      # Check origin against whitelist
      origins when is_list(origins) ->
        check_origin_against_list(req, origins)

      # Function-based origin checking
      check_origin when is_function(check_origin, 1) ->
        origin = :cowboy_req.header("origin", req, :undefined)

        case check_origin.(origin) do
          true -> :ok
          false -> {:error, "origin not allowed by check_origin function"}
        end
    end
  end

  defp check_origin_header(req) do
    origin = :cowboy_req.header("origin", req, :undefined)
    host = :cowboy_req.header("host", req, :undefined)

    case origin do
      # No origin header (same-origin request or native client)
      :undefined ->
        :ok

      # Origin matches host (same-origin)
      _ ->
        origin_uri = URI.parse(origin)
        origin_host = origin_uri.host

        if origin_host == host do
          :ok
        else
          {:error, "origin mismatch: #{origin} != #{host}"}
        end
    end
  end

  defp check_origin_against_list(req, allowed_origins) do
    origin = :cowboy_req.header("origin", req, :undefined)

    case origin do
      # No origin header (same-origin request)
      :undefined ->
        :ok

      # Check if origin is in whitelist
      _ ->
        origin_uri = URI.parse(origin)
        origin_host = origin_uri.host

        if Enum.any?(allowed_origins, fn allowed ->
             case allowed do
               # Exact match
               ^origin -> true
               # Wildcard pattern (e.g., "//*.example.com")
               pattern when is_binary(pattern) -> wildcard_match?(origin_host, pattern)
               _ -> false
             end
           end) do
          :ok
        else
          {:error, "origin not in whitelist: #{origin}"}
        end
    end
  end

  defp wildcard_match?(host, pattern) do
    # Simple wildcard matching (supports //*.example.com pattern)
    cond do
      # Exact match
      host == pattern ->
        true

      # Wildcard pattern //*.example.com
      String.starts_with?(pattern, "//*.") ->
        suffix = String.replace_prefix(pattern, "//", "")
        String.ends_with?(host, suffix) or host == String.replace_prefix(suffix, "*.", "")

      # No match
      true ->
        false
    end
  end
end

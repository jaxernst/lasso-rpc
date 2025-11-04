defmodule Lasso.RPC.WSHandler do
  @moduledoc """
  WebSockex handler for managing WebSocket connections.

  This module handles the actual WebSocket communication and reports
  events back to the parent WSConnection GenServer process.

  ## WebSockex Disconnect Behavior (Important!)

  **WebSockex does NOT fire user `handle_frame({:close, ...})` callbacks for close frames.**

  Instead, close frames are handled internally by WebSockex, and your module only receives
  a single `handle_disconnect/2` callback with structured reason information:

  ### Close Frame from Server (Graceful Close)
  - Reason: `{:remote, code, reason_string}` where code is 1000-4999
  - Examples:
    - `{:remote, 1000, "Normal close"}`
    - `{:remote, 1013, "Connection timeout exceeded"}`
    - `{:remote, 1001, "Going away"}`
  - Reason: `{:remote, :normal}` - Normal/expected server-initiated close without a numeric code
  - Examples:
    - `{:remote, :normal}`

  ### Abrupt Disconnect (No Close Frame)
  - Reason: `{:remote, :closed}` - TCP connection dropped without close frame

  ### Network Errors, Timeouts, etc.
  - Reason: varies based on error type (e.g., `{:error, :timeout}`, `:noproc`, etc.)

  This is ONE callback per disconnect event with all available context embedded in the reason.
  """

  use WebSockex
  require Logger

  # WebSockex callbacks

  def handle_connect(_conn, state) do
    send(state.parent, {:ws_connected})
    {:ok, state}
  end

  def handle_frame({:text, message}, state) do
    # Timestamp when frame arrives from network
    received_at = System.monotonic_time(:microsecond)

    case Jason.decode(message) do
      {:ok, decoded} ->
        send(state.parent, {:ws_message, decoded, received_at})
        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to decode WebSocket message: #{reason}")
        send(state.parent, {:ws_error, {:decode_error, reason}})
        {:ok, state}
    end
  end

  def handle_frame({:ping, payload}, state) do
    Logger.debug("Received ping, sending pong")
    {:reply, {:pong, payload}, state}
  end

  def handle_frame({:pong, _payload}, state) do
    Logger.debug("Received pong")
    {:ok, state}
  end

  # This fires for ALL disconnection events.
  # WebSockex embeds close frame info directly in the reason parameter,
  # so we extract it here and send a structured message to the parent.
  def handle_disconnect(%{reason: reason}, state) do
    disconnect_info =
      case reason do
        # Remote close frame with code and message
        {:remote, code, close_reason} when is_integer(code) ->
          {:ws_disconnect, :close_frame, code, close_reason}

        # Remote close without code (graceful close, no code specified)
        {:remote, :normal} ->
          {:ws_disconnect, :close_frame, 1000, "Normal close"}

        # Remote abrupt disconnect (TCP closed without close frame)
        {:remote, :closed} ->
          {:ws_disconnect, :error, {:remote_closed, "TCP connection closed abruptly"}}

        # Local close frame with code and message
        {:local, code, message} when is_integer(code) ->
          {:ws_disconnect, :close_frame, code, message}

        # Local close without code (graceful close, no code specified)
        {:local, :normal} ->
          {:ws_disconnect, :close_frame, 1000, "Normal close"}

        # Any other disconnect reason (network errors, timeouts, crashes, etc.)
        other ->
          {:ws_disconnect, :error, other}
      end

    send(state.parent, disconnect_info)
    {:ok, state}
  end
end

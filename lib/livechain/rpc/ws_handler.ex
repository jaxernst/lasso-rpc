defmodule Livechain.RPC.WSHandler do
  @moduledoc """
  WebSockex handler for managing WebSocket connections.

  This module handles the actual WebSocket communication and reports
  events back to the parent WSConnection GenServer process.
  """

  use WebSockex
  require Logger

  # WebSockex callbacks

  def handle_connect(_conn, state) do
    send(state.parent, {:ws_connected})
    {:ok, state}
  end

  def handle_frame({:text, message}, state) do
    case Jason.decode(message) do
      {:ok, decoded} ->
        send(state.parent, {:ws_message, decoded})
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

  def handle_frame({:close, code, reason}, state) do
    send(state.parent, {:ws_closed, code, reason})
    {:ok, state}
  end

  def handle_disconnect(%{reason: reason}, state) do
    send(state.parent, {:ws_disconnected, reason})
    {:ok, state}
  end
end

defmodule Lasso.RPC.Transport.WebSocket.Handler do
  @moduledoc """
  Projects WebSocket transport callbacks into typed messages for the owning connection process.
  """

  require Logger

  alias Lasso.Core.Transport.UpstreamResponse

  @spec handle_connect(map(), map()) :: {:ok, map()}
  def handle_connect(_conn, state) do
    send(state.parent, {:ws_connected, self(), state.connection_generation})
    {:ok, state}
  end

  @spec handle_frame({:text, String.t()}, map()) :: {:ok, map()}
  def handle_frame({:text, message}, state) do
    received_at = System.monotonic_time(:microsecond)
    parsed = UpstreamResponse.parse_ws_frame(message)
    validated_at = System.monotonic_time(:microsecond)
    send_parsed_frame(state, parsed, message, received_at, validated_at)

    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @spec handle_cast(term(), map()) ::
          {:ok, map()}
          | {:reply, Mint.WebSocket.frame() | Mint.WebSocket.shorthand_frame(), map()}
  def handle_cast(
        {:send_if_live, generation, send_key, deadline_us, cancel_latch, frame},
        state
      ) do
    decided_at_us = System.monotonic_time(:microsecond)

    decision =
      cond do
        generation != state.connection_generation ->
          cancel_send(cancel_latch)
          {:rejected, :stale_generation}

        decided_at_us >= deadline_us ->
          cancel_send(cancel_latch)
          {:rejected, :deadline}

        true ->
          accept_send(cancel_latch)
      end

    send(
      state.parent,
      {:ws_send_decision, self(), state.connection_generation, send_key, decision, decided_at_us}
    )

    case decision do
      :accepted ->
        send(self(), {:lasso_ws_send_written, generation, send_key})
        {:reply, frame, state}

      {:rejected, _reason} ->
        {:ok, state}
    end
  end

  def handle_cast(_message, state), do: {:ok, state}

  @spec handle_info(term(), map()) :: {:ok, map()}
  def handle_info(
        {:lasso_ws_send_written, generation, send_key},
        %{connection_generation: generation} = state
      ) do
    send(
      state.parent,
      {:ws_send_written, self(), generation, send_key, System.monotonic_time(:microsecond)}
    )

    {:ok, state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @spec handle_disconnect(map(), map()) :: {:ok, map()}
  def handle_disconnect(%{reason: reason}, state) do
    Logger.debug("WebSocket client disconnected",
      provider_id: state.endpoint.id,
      reason: inspect(reason)
    )

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

    send(
      state.parent,
      {:ws_disconnect_event, self(), state.connection_generation, disconnect_info}
    )

    {:ok, state}
  end

  defp send_parsed_frame(state, parsed, message, received_at, validated_at) do
    send(
      state.parent,
      {:ws_message, self(), state.connection_generation, parsed, message, received_at,
       validated_at}
    )
  end

  defp accept_send(cancel_latch) do
    case :atomics.compare_exchange(cancel_latch, 1, 0, 2) do
      value when value in [:ok, 0] -> :accepted
      1 -> {:rejected, :cancelled}
      2 -> {:rejected, :already_accepted}
    end
  rescue
    ArgumentError -> {:rejected, :invalid_latch}
  end

  defp cancel_send(cancel_latch) do
    _previous = :atomics.compare_exchange(cancel_latch, 1, 0, 1)
    :ok
  rescue
    ArgumentError -> :ok
  end
end

defmodule Livechain.RPC.MockWSConnection do
  @moduledoc """
  A mock WebSocket connection that simulates blockchain RPC connections.

  This module provides a drop-in replacement for real WebSocket connections
  during development and testing, without requiring actual network connections.
  """

  use GenServer
  require Logger

  alias Livechain.RPC.{MockWSEndpoint, MockProvider}

  # Client API

  @doc """
  Starts a mock WebSocket connection process.
  """
  def start_link(%MockWSEndpoint{} = endpoint) do
    GenServer.start_link(__MODULE__, endpoint, name: via_name(endpoint.id))
  end

  @doc """
  Sends a message to the mock WebSocket connection.
  """
  def send_message(connection_id, message) do
    GenServer.cast(via_name(connection_id), {:send_message, message})
  end

  @doc """
  Subscribes to a topic on the mock WebSocket connection.
  """
  def subscribe(connection_id, topic) do
    GenServer.cast(via_name(connection_id), {:subscribe, topic})
  end

  @doc """
  Gets the current connection status.
  """
  def status(pid_or_connection_id) when is_pid(pid_or_connection_id) do
    GenServer.call(pid_or_connection_id, :status)
  end

  def status(connection_id) do
    GenServer.call(via_name(connection_id), :status)
  end

  # Server Callbacks

  @impl true
  def init(%MockWSEndpoint{} = endpoint) do
    Logger.debug("Starting mock WebSocket connection for #{endpoint.name}")

    # Start the mock provider
    case MockWSEndpoint.start_mock_provider(endpoint) do
      %MockWSEndpoint{} = updated_endpoint ->
        state = %{
          endpoint: updated_endpoint,
          connected: true,
          reconnect_attempts: 0,
          subscriptions: MapSet.new(),
          pending_messages: [],
          heartbeat_ref: nil,
          last_seen: DateTime.utc_now()
        }

        # Broadcast initial connected status
        broadcast_status_change(state, :connected)

        # Schedule heartbeat
        state = schedule_heartbeat(state)

        {:ok, state}

      {:error, reason} ->
        Logger.error("Failed to start mock provider for #{endpoint.name}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:send_message, message}, state) do
    case message do
      %{"method" => "eth_subscribe", "params" => [topic]} ->
        # Handle subscription
        MockProvider.subscribe(state.endpoint.mock_provider, topic)
        state = %{state | subscriptions: MapSet.put(state.subscriptions, topic)}
        {:noreply, state}

      _ ->
        # Handle other RPC calls
        case MockProvider.call(
               state.endpoint.mock_provider,
               message["method"],
               message["params"] || []
             ) do
          {:ok, _result} ->
            # Simulate response (no-op)
            {:noreply, state}

          {:error, reason} ->
            Logger.error("Mock RPC error: #{inspect(reason)}")
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_cast({:subscribe, topic}, state) do
    MockProvider.subscribe(state.endpoint.mock_provider, topic)
    state = %{state | subscriptions: MapSet.put(state.subscriptions, topic)}
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      connected: state.connected,
      endpoint_id: state.endpoint.id,
      endpoint_name: state.endpoint.name,
      reconnect_attempts: state.reconnect_attempts,
      subscriptions: MapSet.size(state.subscriptions),
      pending_messages: length(state.pending_messages),
      last_seen: state.last_seen
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:heartbeat}, state) do
    if state.connected do
      # Simulate heartbeat and update last seen
      state =
        state
        |> Map.put(:last_seen, DateTime.utc_now())
        |> schedule_heartbeat()

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:websocket_message, message}, state) do
    # Handle incoming WebSocket messages (from mock provider)
    case Jason.decode(message) do
      {:ok, decoded} ->
        chain_name = get_chain_name(state.endpoint.chain_id)
        received_at = System.monotonic_time(:millisecond)

        :telemetry.execute(
          [
            :livechain,
            :ws,
            :message,
            :received
          ],
          %{count: 1},
          %{chain: chain_name, provider_id: state.endpoint.id, event_type: :mock}
        )

        Phoenix.PubSub.broadcast(
          Livechain.PubSub,
          "raw_messages:#{chain_name}",
          {:raw_message, state.endpoint.id, decoded, received_at}
        )

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to decode mock WebSocket message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # Private functions

  defp via_name(connection_id) do
    {:via, Registry, {Livechain.Registry, {:ws_conn, connection_id}}}
  end

  defp schedule_heartbeat(state) do
    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    ref = Process.send_after(self(), {:heartbeat}, state.endpoint.heartbeat_interval)
    %{state | heartbeat_ref: ref}
  end

  defp broadcast_status_change(state, status) do
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "ws_connections",
      {:connection_status_changed, state.endpoint.id,
       %{
         id: state.endpoint.id,
         name: state.endpoint.name,
         status: status,
         reconnect_attempts: state.reconnect_attempts,
         subscriptions: MapSet.size(state.subscriptions)
       }}
    )
  end

  defp get_chain_name(chain_id) do
    case chain_id do
      1 -> "ethereum"
      137 -> "polygon"
      42_161 -> "arbitrum"
      56 -> "bsc"
      _ -> "unknown"
    end
  end
end

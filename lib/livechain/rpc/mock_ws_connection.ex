defmodule Livechain.RPC.MockWSConnection do
  @moduledoc """
  A mock WebSocket connection that simulates blockchain RPC connections.

  This module provides a drop-in replacement for real WebSocket connections
  during development and testing, without requiring actual network connections.
  """

  use GenServer
  require Logger

  alias Livechain.RPC.MockWSEndpoint

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
  def status(connection_id) do
    GenServer.call(via_name(connection_id), :status)
  end

  # Server Callbacks

  @impl true
  def init(%MockWSEndpoint{} = endpoint) do
    Logger.info("Starting mock WebSocket connection for #{endpoint.name} (#{endpoint.id})")

    # Start the mock provider
    endpoint = MockWSEndpoint.start_mock_provider(endpoint)

    state = %{
      endpoint: endpoint,
      connected: true,
      reconnect_attempts: 0,
      subscriptions: MapSet.new(),
      pending_messages: [],
      heartbeat_ref: nil
    }

    # Schedule heartbeat
    state = schedule_heartbeat(state)

    {:ok, state}
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
          {:ok, result} ->
            # Simulate response
            Logger.debug("Mock RPC response: #{inspect(result)}")
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
      reconnect_attempts: state.reconnect_attempts,
      subscriptions: MapSet.size(state.subscriptions),
      pending_messages: length(state.pending_messages)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:heartbeat}, state) do
    if state.connected do
      # Simulate heartbeat
      Logger.debug("Mock WebSocket heartbeat for #{state.endpoint.name}")
      state = schedule_heartbeat(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:websocket_message, message}, state) do
    # Handle incoming WebSocket messages (from mock provider)
    Logger.debug("Mock WebSocket received: #{message}")
    {:noreply, state}
  end

  # Private functions

  defp via_name(connection_id) do
    {:via, :global, {:mock_connection, connection_id}}
  end

  defp schedule_heartbeat(state) do
    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    ref = Process.send_after(self(), {:heartbeat}, state.endpoint.heartbeat_interval)
    %{state | heartbeat_ref: ref}
  end
end

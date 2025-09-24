defmodule Livechain.RPC.WSConnection do
  @moduledoc """
  A GenServer that manages a single WebSocket connection to a blockchain RPC endpoint.

  This process handles:
  - WebSocket connection lifecycle
  - Automatic reconnection on failure
  - Heartbeat/ping to keep connection alive
  - Subscription management
  - Message routing and handling

  Each WebSocket connection runs in its own process, allowing for:
  - Fault isolation (one connection failure doesn't affect others)
  - Independent reconnection strategies
  - Process supervision and monitoring
  """

  use GenServer, restart: :permanent
  require Logger

  alias Livechain.RPC.WSEndpoint
  alias Livechain.RPC.CircuitBreaker
  alias Livechain.RPC.ProviderPool
  alias Livechain.RPC.Failover
  alias Livechain.RPC.WSNormalizer
  alias Livechain.JSONRPC.Error, as: JError

  # Client API

  @doc """
  Starts a new WebSocket connection process.

  ## Examples

      iex> {:ok, pid} = Livechain.RPC.WSConnection.start_link(endpoint)
      iex> Process.alive?(pid)
      true
  """
  def start_link(%WSEndpoint{} = endpoint) do
    GenServer.start_link(__MODULE__, endpoint, name: via_name(endpoint.id))
  end

  @doc """
  Sends a message to the WebSocket connection.

  ## Examples

      iex> Livechain.RPC.WSConnection.send_message("ethereum_ws", %{method: "eth_blockNumber"})
      :ok
  """
  def send_message(connection_id, message) do
    GenServer.cast(via_name(connection_id), {:send_message, message})
  end

  @doc """
  Subscribes to a topic on the WebSocket connection.

  ## Examples

      iex> Livechain.RPC.WSConnection.subscribe("ethereum_ws", "newHeads")
      :ok
  """
  def subscribe(connection_id, topic) do
    GenServer.cast(via_name(connection_id), {:subscribe, topic})
  end

  @doc """
  Gets the current connection status.

  ## Examples

      iex> Livechain.RPC.WSConnection.status("ethereum_ws")
      %{connected: true, endpoint_id: "ethereum_ws", reconnect_attempts: 0}
  """
  def status(connection_id) do
    GenServer.call(via_name(connection_id), :status)
  end

  # Server Callbacks

  @impl true
  def init(%WSEndpoint{} = endpoint) do
    state = %{
      endpoint: endpoint,
      chain_name: endpoint.chain_name,
      connection: nil,
      connected: false,
      reconnect_attempts: 0,
      subscriptions: MapSet.new(),
      pending_messages: [],
      heartbeat_ref: nil,
      reconnect_ref: nil
    }

    # Start the connection process
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case CircuitBreaker.call(state.endpoint.id, fn ->
           connect_to_websocket(state.endpoint)
         end) do
      {:ok, connection} ->
        Process.monitor(connection)
        state = %{state | connection: connection}
        # success path continues via {:ws_connected}
        {:noreply, state}

      {:error, %JError{} = jerr} ->
        Logger.error(
          "Failed to connect to #{state.endpoint.name} (WebSocket): #{jerr.message} (code=#{inspect(jerr.code)})"
        )

        broadcast_status_change(state, :disconnected)

        state =
          if jerr.retriable? do
            schedule_reconnect(state)
          else
            state
          end

        {:noreply, state}

      {:error, :circuit_open} ->
        Logger.debug("Circuit breaker open for #{state.endpoint.id}, skipping connect attempt")
        # Try again later (uses existing backoff)
        state = schedule_reconnect(state)
        {:noreply, state}

      {:error, other} ->
        Logger.debug("Circuit breaker call error: #{inspect(other)}")

        jerr = JError.from(other, provider_id: state.endpoint.id)
        broadcast_status_change(state, :disconnected)

        state =
          if jerr.retriable? do
            schedule_reconnect(state)
          else
            state
          end

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_message, message}, %{connected: true, connection: connection} = state) do
    case CircuitBreaker.call(state.endpoint.id, fn ->
           case WebSockex.send_frame(connection, {:text, Jason.encode!(message)}) do
             :ok ->
               :ok

             {:error, reason} ->
               {:error, WSNormalizer.normalize_send_error(reason, state.endpoint.id)}
           end
         end) do
      {:ok, :ok} ->
        {:noreply, state}

      {:error, :circuit_open} ->
        Logger.debug(
          "Circuit breaker open, attempting WebSocket failover for #{state.endpoint.id}"
        )

        case attempt_ws_failover(state, message) do
          :ok ->
            Logger.debug("WebSocket failover successful for #{state.endpoint.id}")
            {:noreply, state}

          {:error, reason} ->
            Logger.debug(
              "WebSocket failover failed for #{state.endpoint.id}: #{inspect(reason)}, queueing message"
            )

            state = %{state | pending_messages: [message | state.pending_messages]}
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.error("Failed to send message: #{inspect(reason)}")
        state = %{state | pending_messages: [message | state.pending_messages]}
        {:noreply, state}
    end
  end

  def handle_cast({:send_message, message}, state) do
    # Queue message for when we reconnect
    state = %{state | pending_messages: [message | state.pending_messages]}
    {:noreply, state}
  end

  @impl true
  def handle_cast({:subscribe, topic}, state) do
    subscription_message = %{
      "jsonrpc" => "2.0",
      "id" => generate_id(),
      "method" => "eth_subscribe",
      "params" => [topic]
    }

    GenServer.cast(self(), {:send_message, subscription_message})
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
  def handle_info({:ws_connected}, state) do
    Logger.debug("Connected to WebSocket: #{state.endpoint.name}")

    # Report successful connection to circuit breaker
    CircuitBreaker.record_success(state.endpoint.id)

    # Report successful connection to provider pool for status tracking (single writer)
    ProviderPool.report_ws_connected(state.chain_name, state.endpoint.id)

    state = %{state | connected: true, reconnect_attempts: 0}
    broadcast_status_change(state, :connected)

    state = schedule_heartbeat(state)
    state = send_pending_messages(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ws_message, decoded}, state) do
    case handle_websocket_message(decoded, state) do
      {:ok, new_state} -> {:noreply, new_state}
      new_state -> {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:ws_error, error}, state) do
    Logger.error("WebSocket error: #{inspect(error)}")
    ProviderPool.report_failure(state.chain_name, state.endpoint.id, error)
    {:noreply, state}
  end

  @impl true
  def handle_info({:ws_closed, code, reason}, state) do
    Logger.info("WebSocket closed: #{code} - #{inspect(reason)}")

    jerr = WSNormalizer.normalize_close(code, reason, state.endpoint.id)

    state = %{state | connected: false, connection: nil}
    broadcast_status_change(state, :disconnected)
    ProviderPool.report_ws_closed(state.chain_name, state.endpoint.id, code, reason)

    state = if jerr.retriable?, do: schedule_reconnect(state), else: state
    {:noreply, state}
  end

  @impl true
  def handle_info({:ws_disconnected, reason}, state) do
    Logger.warning("WebSocket disconnected: #{inspect(reason)}")

    jerr = WSNormalizer.normalize_disconnect(reason, state.endpoint.id)

    ProviderPool.report_ws_disconnected(state.chain_name, state.endpoint.id, reason)
    state = %{state | connected: false, connection: nil}
    broadcast_status_change(state, :disconnected)

    state = if jerr.retriable?, do: schedule_reconnect(state), else: state
    {:noreply, state}
  end

  @impl true
  def handle_info({:heartbeat}, state) do
    if state.connected do
      # Send ping to keep connection alive through circuit breaker
      case CircuitBreaker.call(state.endpoint.id, fn ->
             case WebSockex.send_frame(state.connection, :ping) do
               :ok ->
                 :ok

               {:error, reason} ->
                 {:error, WSNormalizer.normalize_send_error(reason, state.endpoint.id)}
             end
           end) do
        {:ok, :ok} ->
          state = schedule_heartbeat(state)
          {:noreply, state}

        {:error, :circuit_open} ->
          Logger.debug("Circuit breaker open, skipping heartbeat for #{state.endpoint.id}")
          state = schedule_heartbeat(state)
          {:noreply, state}

        {:error, reason} ->
          Logger.debug("Heartbeat failed for #{state.endpoint.id}: #{inspect(reason)}")
          state = schedule_heartbeat(state)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:reconnect}, state) do
    Logger.info("Attempting to reconnect to #{state.endpoint.name}")
    # Clear the reconnect timer ref since it's already fired
    state = %{state | reconnect_ref: nil}
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("WebSocket connection lost: #{inspect(reason)}")

    case reason do
      {exception, stacktrace} when is_list(stacktrace) ->
        formatted = Exception.format(:error, exception, stacktrace)
        Logger.error("WebSocket #{state.endpoint.id} crash detail\n" <> formatted)

      _ ->
        :ok
    end

    state = %{state | connected: false, connection: nil}
    broadcast_status_change(state, :disconnected)
    state = schedule_reconnect(state)
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info(
      "Terminating WebSocket connection #{state.endpoint.id}, reason: #{inspect(reason)}"
    )

    # Clean up heartbeat timer
    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    # Clean up reconnect timer
    if state.reconnect_ref do
      Process.cancel_timer(state.reconnect_ref)
    end

    # Notify of disconnection
    broadcast_status_change(state, :terminated)

    :ok
  end

  # WebSocket event handlers - these are now handled by WSHandler
  # and communicated back via messages

  # Private functions

  defp attempt_ws_failover(state, message) do
    # Extract method and params from the message for failover
    method = Map.get(message, "method")
    params = Map.get(message, "params", [])

    case Failover.execute_with_failover(
           state.chain_name,
           method,
           params,
           strategy: :cheapest,
           protocol: :ws,
           exclude: [state.endpoint.id]
         ) do
      {:ok, _result} ->
        :telemetry.execute(
          [:livechain, :ws, :failover, :success],
          %{count: 1},
          %{
            chain: state.chain_name,
            original_provider: state.endpoint.id,
            method: method,
            subscription_related: is_subscription_method(method)
          }
        )

        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:livechain, :ws, :failover, :failure],
          %{count: 1},
          %{
            chain: state.chain_name,
            original_provider: state.endpoint.id,
            method: method,
            reason: inspect(reason)
          }
        )

        {:error, reason}
    end
  end

  defp is_subscription_method("eth_subscribe"), do: true
  defp is_subscription_method("eth_unsubscribe"), do: true
  defp is_subscription_method(_), do: false

  defp connect_to_websocket(endpoint) do
    # Start a separate WebSocket handler process
    case WebSockex.start_link(
           endpoint.ws_url,
           Livechain.RPC.WSHandler,
           %{endpoint: endpoint, parent: self()}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, WSNormalizer.normalize_connect_error(reason, endpoint.id)}
    end
  end

  defp schedule_heartbeat(state) do
    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    ref = Process.send_after(self(), {:heartbeat}, state.endpoint.heartbeat_interval)
    %{state | heartbeat_ref: ref}
  end

  defp schedule_reconnect(state) do
    # Cancel any existing reconnect timer
    state =
      if state.reconnect_ref do
        Process.cancel_timer(state.reconnect_ref)
        %{state | reconnect_ref: nil}
      else
        state
      end

    max_attempts = state.endpoint.max_reconnect_attempts

    cond do
      max_attempts == :infinity ->
        delay = min(state.endpoint.reconnect_interval * (state.reconnect_attempts + 1), 30_000)
        jitter = :rand.uniform(1000)
        ref = Process.send_after(self(), {:reconnect}, delay + jitter)
        %{state | reconnect_attempts: state.reconnect_attempts + 1, reconnect_ref: ref}

      state.reconnect_attempts < max_attempts ->
        delay = min(state.endpoint.reconnect_interval * (state.reconnect_attempts + 1), 30_000)
        jitter = :rand.uniform(1000)
        ref = Process.send_after(self(), {:reconnect}, delay + jitter)
        %{state | reconnect_attempts: state.reconnect_attempts + 1, reconnect_ref: ref}

      true ->
        Logger.error("Max reconnection attempts reached for #{state.endpoint.name}")
        state
    end
  end

  defp send_pending_messages(%{pending_messages: []} = state), do: state

  defp send_pending_messages(%{pending_messages: messages} = state) do
    Enum.each(messages, fn message ->
      GenServer.cast(self(), {:send_message, message})
    end)

    %{state | pending_messages: []}
  end

  # TODO: Consider consilidating these duplicative function handlers (only difference is in the debug calls)
  defp handle_websocket_message(
         %{
           "method" => "eth_subscription",
           "params" => %{"result" => block_data, "subscription" => _sub_id}
         } = message,
         state
       ) do
    # Handle new block subscription notifications
    Logger.debug("Received new block: #{inspect(block_data)}")

    # Send to MessageAggregator for deduplication and speed optimization
    received_at = System.monotonic_time(:millisecond)

    # Telemetry: message received
    :telemetry.execute(
      [
        :livechain,
        :ws,
        :message,
        :received
      ],
      %{count: 1},
      %{chain: state.chain_name, provider_id: state.endpoint.id, event_type: :newHeads}
    )

    # Send to raw messages channel for aggregation
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "raw_messages:#{state.chain_name}",
      {:raw_message, state.endpoint.id, message, received_at}
    )

    # Backward compatibility removed - all events now route through MessageAggregator

    {:ok, state}
  end

  defp handle_websocket_message(%{"method" => "eth_subscription"} = message, state) do
    # Handle other subscription notifications
    Logger.debug("Received subscription: #{inspect(message)}")

    # Send all subscription messages through aggregator
    received_at = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [
        :livechain,
        :ws,
        :message,
        :received
      ],
      %{count: 1},
      %{chain: state.chain_name, provider_id: state.endpoint.id, event_type: :subscription}
    )

    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "raw_messages:#{state.chain_name}",
      {:raw_message, state.endpoint.id, message, received_at}
    )

    {:ok, state}
  end

  defp handle_websocket_message(message, state) do
    # Handle other RPC responses
    Logger.debug("Received message: #{inspect(message)}")

    # Send through aggregator for consistency
    received_at = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [
        :livechain,
        :ws,
        :message,
        :received
      ],
      %{count: 1},
      %{chain: state.chain_name, provider_id: state.endpoint.id, event_type: :other}
    )

    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "raw_messages:#{state.chain_name}",
      {:raw_message, state.endpoint.id, message, received_at}
    )

    {:ok, state}
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp via_name(connection_id) do
    {:via, Registry, {Livechain.Registry, {:ws_conn, connection_id}}}
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
end

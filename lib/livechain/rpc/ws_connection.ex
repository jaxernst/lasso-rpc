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
  alias Livechain.Benchmarking.BenchmarkStore

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

  @doc """
  Performs a health check request to a provider endpoint.
  Used by ProviderPool for active health monitoring.
  """
  def health_check_request(endpoint, method \\ "eth_chainId", params \\ []) do
    Livechain.RPC.HttpClient.request(
      %{url: endpoint.url, api_key: endpoint.api_key},
      method,
      params,
      5_000
    )
  end

  # Server Callbacks

  @impl true
  def init(%WSEndpoint{} = endpoint) do
    Logger.info("Starting WebSocket connection for #{endpoint.name} (#{endpoint.id})")

    # Cache chain name at startup to avoid config loading on hot path
    chain_name = resolve_chain_name(endpoint.chain_id)

    state = %{
      endpoint: endpoint,
      chain_name: chain_name,
      connection: nil,
      connected: false,
      reconnect_attempts: 0,
      subscriptions: MapSet.new(),
      pending_messages: [],
      heartbeat_ref: nil
    }

    # Start the connection process
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect_to_websocket(state.endpoint) do
      {:ok, connection} ->
        Logger.info("Connected to WebSocket: #{state.endpoint.name}")
        Process.monitor(connection)

        # Report successful connection to circuit breaker
        CircuitBreaker.record_success(state.endpoint.id)

        state = %{state | connection: connection, connected: true, reconnect_attempts: 0}
        broadcast_status_change(state, :connected)
        state = schedule_heartbeat(state)
        state = send_pending_messages(state)
        {:noreply, state}

      {:error, reason} ->
        Logger.error(
          "Failed to connect to #{state.endpoint.name} (WebSocket): #{inspect(reason)}"
        )

        # Report connection failure to circuit breaker
        CircuitBreaker.record_failure(state.endpoint.id)

        broadcast_status_change(state, :disconnected)
        state = schedule_reconnect(state)
        {:noreply, state}

      {:already_started, pid} ->
        Logger.info(
          "WebSocket connection already exists for #{state.endpoint.name}, using existing connection"
        )

        Process.monitor(pid)
        state = %{state | connection: pid, connected: true, reconnect_attempts: 0}
        broadcast_status_change(state, :connected)
        state = schedule_heartbeat(state)
        state = send_pending_messages(state)
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_message, message}, %{connected: true, connection: connection} = state) do
    case WebSockex.send_frame(connection, {:text, Jason.encode!(message)}) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to send message: #{reason}")

        # Report send failure to circuit breaker
        CircuitBreaker.record_failure(state.endpoint.id)

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
  def handle_info({:heartbeat}, state) do
    if state.connected do
      # Send ping to keep connection alive
      WebSockex.send_frame(state.connection, :ping)
      state = schedule_heartbeat(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:reconnect}, state) do
    Logger.info("Attempting to reconnect to #{state.endpoint.name}")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("WebSocket connection lost: #{inspect(reason)}")

    # Report disconnect as failure to circuit breaker
    CircuitBreaker.record_failure(state.endpoint.id)

    state = %{state | connected: false, connection: nil}
    broadcast_status_change(state, :disconnected)
    state = schedule_reconnect(state)
    {:noreply, state}
  end

  # WebSocket event handlers (WebSockex callbacks)

  def handle_connect(_conn, state) do
    Logger.info("WebSocket connected: #{state.endpoint.name}")
    {:ok, state}
  end

  def handle_frame({:text, message}, state) do
    case Jason.decode(message) do
      {:ok, decoded} ->
        handle_websocket_message(decoded, state)

      {:error, reason} ->
        Logger.error("Failed to decode WebSocket message: #{reason}")
        {:ok, state}
    end
  end

  def handle_frame({:binary, data}, state) do
    Logger.debug("Received binary frame: #{byte_size(data)} bytes")
    {:ok, state}
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
    Logger.info("WebSocket closed: #{code} - #{reason}")
    {:ok, state}
  end

  def handle_disconnect(%{reason: reason}, state) do
    Logger.warning("WebSocket disconnected: #{inspect(reason)}")
    state = %{state | connected: false, connection: nil}
    state = schedule_reconnect(state)
    {:reconnect, state}
  end

  # Private functions

  defp connect_to_websocket(endpoint) do
    WebSockex.start_link(
      endpoint.ws_url,
      __MODULE__,
      %{endpoint: endpoint}
    )
  end

  defp schedule_heartbeat(state) do
    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    ref = Process.send_after(self(), {:heartbeat}, state.endpoint.heartbeat_interval)
    %{state | heartbeat_ref: ref}
  end

  defp schedule_reconnect(state) do
    max_attempts = state.endpoint.max_reconnect_attempts

    cond do
      max_attempts == :infinity ->
        delay = min(state.endpoint.reconnect_interval * (state.reconnect_attempts + 1), 30_000)
        jitter = :rand.uniform(1000)
        Process.send_after(self(), {:reconnect}, delay + jitter)
        %{state | reconnect_attempts: state.reconnect_attempts + 1}

      state.reconnect_attempts < max_attempts ->
        delay = min(state.endpoint.reconnect_interval * (state.reconnect_attempts + 1), 30_000)
        jitter = :rand.uniform(1000)
        Process.send_after(self(), {:reconnect}, delay + jitter)
        %{state | reconnect_attempts: state.reconnect_attempts + 1}

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

  # Resolve chain name via config at startup
  defp resolve_chain_name(chain_id) do
    case Livechain.Config.ChainConfig.load_config() do
      {:ok, config} ->
        case Enum.find(config.chains, fn {_name, chain_config} ->
               chain_config.chain_id == chain_id
             end) do
          {name, _} -> name
          nil -> "unknown"
        end

      {:error, _} ->
        "unknown"
    end
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

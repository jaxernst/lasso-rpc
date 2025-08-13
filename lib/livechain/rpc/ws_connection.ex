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
  Forwards an RPC request to the provider via HTTP.
  This is used for HTTP RPC forwarding from the RPC controller.
  """
  def forward_rpc_request(connection_id, method, params) do
    GenServer.call(via_name(connection_id), {:forward_rpc_request, method, params})
  end

  # Server Callbacks

  @impl true
  def init(%WSEndpoint{} = endpoint) do
    Logger.info("Starting WebSocket connection for #{endpoint.name} (#{endpoint.id})")

    state = %{
      endpoint: endpoint,
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
        state = %{state | connection: connection, connected: true, reconnect_attempts: 0}
        broadcast_status_change(state, :connected)
        state = schedule_heartbeat(state)
        state = send_pending_messages(state)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Failed to connect to WebSocket: #{reason}")
        broadcast_status_change(state, :disconnected)
        state = schedule_reconnect(state)
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
  def handle_call({:forward_rpc_request, method, params}, _from, state) do
    case make_http_rpc_request(state.endpoint, method, params) do
      {:ok, result} ->
        {:reply, {:ok, result}, state}

      {:error, reason} ->
        Logger.error("RPC request failed",
          endpoint: state.endpoint.id,
          method: method,
          reason: reason
        )

        {:reply, {:error, reason}, state}
    end
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
      endpoint,
      name: {:via, :global, {:connection, endpoint.id}}
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
    if state.reconnect_attempts < state.endpoint.max_reconnect_attempts do
      delay = state.endpoint.reconnect_interval * (state.reconnect_attempts + 1)
      Process.send_after(self(), {:reconnect}, delay)
      %{state | reconnect_attempts: state.reconnect_attempts + 1}
    else
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
    chain_name = get_chain_name(state.endpoint.chain_id)
    received_at = System.monotonic_time(:millisecond)

    # Send to raw messages channel for aggregation
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "raw_messages:#{chain_name}",
      {:raw_message, state.endpoint.id, message, received_at}
    )

    # TODO: Remove this backward compatibility functionality (don't need to maintain these old functions with hardocded chain names anywhere in the codebase)
    # Also maintain backward compatibility
    broadcast_block_to_channels(state.endpoint, block_data)

    {:ok, state}
  end

  defp handle_websocket_message(%{"method" => "eth_subscription"} = message, state) do
    # Handle other subscription notifications
    Logger.debug("Received subscription: #{inspect(message)}")

    # Send all subscription messages through aggregator
    chain_name = get_chain_name(state.endpoint.chain_id)
    received_at = System.monotonic_time(:millisecond)

    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "raw_messages:#{chain_name}",
      {:raw_message, state.endpoint.id, message, received_at}
    )

    {:ok, state}
  end

  defp handle_websocket_message(message, state) do
    # Handle other RPC responses
    Logger.debug("Received message: #{inspect(message)}")

    # Send through aggregator for consistency
    chain_name = get_chain_name(state.endpoint.chain_id)
    received_at = System.monotonic_time(:millisecond)

    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "raw_messages:#{chain_name}",
      {:raw_message, state.endpoint.id, message, received_at}
    )

    {:ok, state}
  end

  # TODO: use ChainConfig instead of hardcoded names
  defp get_chain_name(chain_id) do
    case chain_id do
      1 -> "ethereum"
      137 -> "polygon"
      42_161 -> "arbitrum"
      56 -> "bsc"
      8453 -> "base"
      84532 -> "base_sepolia"
      _ -> "unknown"
    end
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp via_name(connection_id) do
    {:via, :global, {:connection, connection_id}}
  end

  @doc """
  Makes an RPC request via WebSocket to the provider's endpoint.
  """
  defp make_http_rpc_request(endpoint, method, params) do
    # Build the JSON-RPC request
    request_id = generate_id()

    request_body = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => request_id
    }

    # Convert to JSON and send via WebSocket
    case Jason.encode(request_body) do
      {:ok, json_body} ->
        # For now, return a mock response since we need to implement proper WebSocket RPC handling
        # This is a placeholder until we implement the full WebSocket RPC request/response system
        {:ok, "mock_response_for_#{method}"}

      {:error, reason} ->
        {:error, "Failed to encode request: #{reason}"}
    end
  end

  defp broadcast_block_to_channels(endpoint, block_data) do
    # Map chain_id to chain name for PubSub topics
    chain_name =
      case endpoint.chain_id do
        1 -> "ethereum"
        137 -> "polygon"
        42_161 -> "arbitrum"
        56 -> "bsc"
        8453 -> "base"
        84532 -> "base_sepolia"
        _ -> "unknown"
      end

    # Broadcast to general blockchain channel
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "blockchain:#{chain_name}",
      %{event: "new_block", payload: block_data}
    )

    # Broadcast to specific event type channel
    Phoenix.PubSub.broadcast(
      Livechain.PubSub,
      "blockchain:#{chain_name}:blocks",
      %{event: "new_block", payload: block_data}
    )
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

  # JSON-RPC method implementations

  @doc """
  Gets logs for a specific filter.
  """
  def get_logs(connection_id, filter) do
    GenServer.call(via_name(connection_id), {:get_logs, filter})
  end

  @doc """
  Gets block by number.
  """
  def get_block_by_number(connection_id, block_number, include_transactions) do
    GenServer.call(
      via_name(connection_id),
      {:get_block_by_number, block_number, include_transactions}
    )
  end

  @doc """
  Gets the latest block number.
  """
  def get_block_number(connection_id) do
    GenServer.call(via_name(connection_id), {:get_block_number})
  end

  @doc """
  Gets balance for an address.
  """
  def get_balance(connection_id, address, block) do
    GenServer.call(via_name(connection_id), {:get_balance, address, block})
  end

  # GenServer callbacks for JSON-RPC methods

  @impl true
  def handle_call({:get_logs, filter}, _from, state) do
    start_time = System.monotonic_time(:millisecond)

    request = %{
      jsonrpc: "2.0",
      method: "eth_getLogs",
      params: [filter],
      id: generate_id()
    }

    case send_json_rpc_request(state, request) do
      {:ok, response} ->
        duration = System.monotonic_time(:millisecond) - start_time
        chain_name = get_chain_name(state.endpoint.chain_id)

        # Safe benchmark recording with error handling
        try do
          BenchmarkStore.record_rpc_call(
            chain_name,
            state.endpoint.id,
            "eth_getLogs",
            duration,
            :success
          )
        rescue
          e -> Logger.error("Failed to record benchmark for eth_getLogs success: #{inspect(e)}")
        end

        {:reply, {:ok, response["result"] || []}, state}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        chain_name = get_chain_name(state.endpoint.chain_id)

        # Safe benchmark recording with error handling
        try do
          BenchmarkStore.record_rpc_call(
            chain_name,
            state.endpoint.id,
            "eth_getLogs",
            duration,
            :error
          )
        rescue
          e -> Logger.error("Failed to record benchmark for eth_getLogs error: #{inspect(e)}")
        end

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_block_by_number, block_number, include_transactions}, _from, state) do
    start_time = System.monotonic_time(:millisecond)

    request = %{
      jsonrpc: "2.0",
      method: "eth_getBlockByNumber",
      params: [block_number, include_transactions],
      id: generate_id()
    }

    case send_json_rpc_request(state, request) do
      {:ok, response} ->
        duration = System.monotonic_time(:millisecond) - start_time
        chain_name = get_chain_name(state.endpoint.chain_id)

        # Safe benchmark recording with error handling
        try do
          BenchmarkStore.record_rpc_call(
            chain_name,
            state.endpoint.id,
            "eth_getBlockByNumber",
            duration,
            :success
          )
        rescue
          e ->
            Logger.error(
              "Failed to record benchmark for eth_getBlockByNumber success: #{inspect(e)}"
            )
        end

        {:reply, {:ok, response["result"]}, state}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        chain_name = get_chain_name(state.endpoint.chain_id)

        # TODO: Could this be pushed to a queue for processing? I want to avoid blocking (but maybe this doesn't even block so let's analyze whether this could be meaningfully improved).
        # Safe benchmark recording with error handling
        try do
          BenchmarkStore.record_rpc_call(
            chain_name,
            state.endpoint.id,
            "eth_getBlockByNumber",
            duration,
            :error
          )
        rescue
          e ->
            Logger.error(
              "Failed to record benchmark for eth_getBlockByNumber error: #{inspect(e)}"
            )
        end

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_block_number}, _from, state) do
    start_time = System.monotonic_time(:millisecond)

    request = %{
      jsonrpc: "2.0",
      method: "eth_blockNumber",
      params: [],
      id: generate_id()
    }

    case send_json_rpc_request(state, request) do
      {:ok, response} ->
        duration = System.monotonic_time(:millisecond) - start_time
        chain_name = get_chain_name(state.endpoint.chain_id)

        # Safe benchmark recording with error handling
        try do
          BenchmarkStore.record_rpc_call(
            chain_name,
            state.endpoint.id,
            "eth_blockNumber",
            duration,
            :success
          )
        rescue
          e ->
            Logger.error("Failed to record benchmark for eth_blockNumber success: #{inspect(e)}")
        end

        {:reply, {:ok, response["result"]}, state}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        chain_name = get_chain_name(state.endpoint.chain_id)

        # Safe benchmark recording with error handling
        try do
          BenchmarkStore.record_rpc_call(
            chain_name,
            state.endpoint.id,
            "eth_blockNumber",
            duration,
            :error
          )
        rescue
          e -> Logger.error("Failed to record benchmark for eth_blockNumber error: #{inspect(e)}")
        end

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_balance, address, block}, _from, state) do
    start_time = System.monotonic_time(:millisecond)

    request = %{
      jsonrpc: "2.0",
      method: "eth_getBalance",
      params: [address, block],
      id: generate_id()
    }

    case send_json_rpc_request(state, request) do
      {:ok, response} ->
        duration = System.monotonic_time(:millisecond) - start_time
        chain_name = get_chain_name(state.endpoint.chain_id)

        # Safe benchmark recording with error handling
        try do
          BenchmarkStore.record_rpc_call(
            chain_name,
            state.endpoint.id,
            "eth_getBalance",
            duration,
            :success
          )
        rescue
          e ->
            Logger.error("Failed to record benchmark for eth_getBalance success: #{inspect(e)}")
        end

        {:reply, {:ok, response["result"]}, state}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        chain_name = get_chain_name(state.endpoint.chain_id)

        # Safe benchmark recording with error handling
        try do
          BenchmarkStore.record_rpc_call(
            chain_name,
            state.endpoint.id,
            "eth_getBalance",
            duration,
            :error
          )
        rescue
          e -> Logger.error("Failed to record benchmark for eth_getBalance error: #{inspect(e)}")
        end

        {:reply, {:error, reason}, state}
    end
  end

  defp send_json_rpc_request(state, request) do
    case state.websocket_pid do
      nil ->
        {:error, :not_connected}

      pid ->
        try do
          # For now, return mock data since we're using mock connections
          # In production, this would send the actual request via WebSocket
          # TODO: Replace mocks
          mock_json_rpc_response(request)
        catch
          :exit, _ -> {:error, :connection_lost}
          :error, reason -> {:error, reason}
        end
    end
  end

  defp mock_ssjson_rpc_response(%{method: "eth_getLogs"}) do
    {:ok,
     %{
       "jsonrpc" => "2.0",
       "id" => "mock_id",
       "result" => [
         %{
           "address" => "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
           "topics" => [
             "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
           ],
           "data" => "0x0000000000000000000000000000000000000000000000000000000000000001",
           "blockNumber" => "0x123456",
           "transactionHash" =>
             "0x" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)),
           "transactionIndex" => "0x0",
           "blockHash" => "0x" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)),
           "logIndex" => "0x0",
           "removed" => false
         }
       ]
     }}
  end

  defp mock_json_rpc_response(%{method: "eth_getBlockByNumber"}) do
    {:ok,
     %{
       "jsonrpc" => "2.0",
       "id" => "mock_id",
       "result" => %{
         "number" => "0x123456",
         "hash" => "0x" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)),
         "timestamp" => "0x" <> Integer.to_string(System.system_time(:second), 16),
         "transactions" => []
       }
     }}
  end

  defp mock_json_rpc_response(%{method: "eth_blockNumber"}) do
    {:ok,
     %{
       "jsonrpc" => "2.0",
       "id" => "mock_id",
       "result" => "0x" <> Integer.to_string(:rand.uniform(20_000_000), 16)
     }}
  end

  defp mock_json_rpc_response(%{method: "eth_getBalance"}) do
    {:ok,
     %{
       "jsonrpc" => "2.0",
       "id" => "mock_id",
       "result" => "0x" <> Integer.to_string(:rand.uniform(1_000_000_000_000_000_000), 16)
     }}
  end

  defp mock_json_rpc_response(_) do
    {:ok,
     %{
       "jsonrpc" => "2.0",
       "id" => "mock_id",
       "result" => nil
     }}
  end
end

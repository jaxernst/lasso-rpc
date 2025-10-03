defmodule Lasso.RPC.WSConnection do
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

  alias Lasso.RPC.WSEndpoint
  alias Lasso.RPC.CircuitBreaker
  alias Lasso.RPC.ErrorNormalizer
  alias Lasso.JSONRPC.Error, as: JError

  # Client API

  @doc """
  Starts a new WebSocket connection process.

  ## Examples

      iex> {:ok, pid} = Lasso.RPC.WSConnection.start_link(endpoint)
      iex> Process.alive?(pid)
      true
  """
  def start_link(%WSEndpoint{} = endpoint) do
    GenServer.start_link(__MODULE__, endpoint, name: via_name(endpoint.id))
  end

  @doc """
  Sends a message to the WebSocket connection.

  ## Examples

      iex> Lasso.RPC.WSConnection.send_message("ethereum_ws", %{method: "eth_blockNumber"})
      :ok
  """
  def send_message(connection_id, message) do
    GenServer.call(via_name(connection_id), {:send_message, message})
  end

  @doc """
  Gets the current connection status.

  ## Examples

      iex> Lasso.RPC.WSConnection.status("ethereum_ws")
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
      pending_requests: %{},
      heartbeat_ref: nil,
      reconnect_ref: nil
    }

    # Start the connection process
    {:ok, state, {:continue, :connect}}
  end

  @doc """
  Performs a unary JSON-RPC request over the WebSocket connection with response correlation.

  Returns {:ok, result} | {:error, reason}.
  """
  def request(connection_id, method, params, timeout_ms \\ 30_000, request_id \\ nil) do
    GenServer.call(
      via_name(connection_id),
      {:request, method, params, timeout_ms, request_id},
      timeout_ms + 2_000
    )
  end

  @impl true
  def handle_continue(:connect, state) do
    ws_connection_pid = self()

    case CircuitBreaker.call({state.endpoint.id, :ws}, fn ->
           connect_to_websocket(state.endpoint, ws_connection_pid)
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

        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          "ws:conn:#{state.chain_name}",
          {:connection_error, state.endpoint.id, jerr}
        )

        state =
          if jerr.retriable? do
            schedule_reconnect(state)
          else
            state
          end

        {:noreply, state}

      {:error, :circuit_open} ->
        Logger.debug("Circuit breaker open for #{state.endpoint.id}, skipping connect attempt")

        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          "ws:conn:#{state.chain_name}",
          {:connection_error, state.endpoint.id,
           JError.new(-32000, "Circuit open", provider_id: state.endpoint.id, retriable?: true)}
        )

        # Try again later (uses existing backoff)
        state = schedule_reconnect(state)
        {:noreply, state}

      {:error, other} ->
        Logger.debug("Circuit breaker call error: #{inspect(other)}")

        jerr = JError.from(other, provider_id: state.endpoint.id)

        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          "ws:conn:#{state.chain_name}",
          {:connection_error, state.endpoint.id, jerr}
        )

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
  def handle_call(
        {:send_message, message},
        _from,
        %{connected: true, connection: connection} = state
      ) do
    ws_client().send_frame(connection, {:text, Jason.encode!(message)})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:send_message, _message}, _from, %{connected: false} = state) do
    error =
      ErrorNormalizer.normalize(:not_connected, provider_id: state.endpoint.id, transport: :ws)

    {:reply, {:error, error}, state}
  end

  @impl true
  def handle_call(
        {:request, method, params, timeout_ms, provided_id},
        from,
        %{connected: true} = state
      ) do
    # Use provided request_id if available, otherwise generate one
    request_id = provided_id || generate_id()

    message = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "method" => method,
      "params" => params || []
    }

    sent_at = System.monotonic_time(:microsecond)

    case ws_client().send_frame(state.connection, {:text, Jason.encode!(message)}) do
      :ok ->
        timer = Process.send_after(self(), {:request_timeout, request_id}, timeout_ms)

        pending =
          Map.put(state.pending_requests, request_id, %{
            from: from,
            timer: timer,
            sent_at: sent_at
          })

        {:noreply, %{state | pending_requests: pending}}

      {:error, reason} ->
        jerr = ErrorNormalizer.normalize(reason, provider_id: state.endpoint.id, transport: :ws)
        {:reply, {:error, jerr}, state}
    end
  end

  def handle_call(
        {:request, _method, _params, _timeout_ms, _request_id},
        _from,
        %{connected: false} = state
      ) do
    jerr =
      ErrorNormalizer.normalize(:not_connected, provider_id: state.endpoint.id, transport: :ws)

    {:reply, {:error, jerr}, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      connected: state.connected,
      endpoint_id: state.endpoint.id,
      reconnect_attempts: state.reconnect_attempts,
      pending_requests: map_size(state.pending_requests)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:ws_connected}, state) do
    Logger.debug("Connected to WebSocket: #{state.endpoint.name}")

    # Report successful connection to circuit breaker
    CircuitBreaker.record_success({state.endpoint.id, :ws})

    state = %{state | connected: true, reconnect_attempts: 0}

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.chain_name}",
      {:ws_connected, state.endpoint.id}
    )

    state = schedule_heartbeat(state)
    {:noreply, state}
  end

  def handle_info({:ws_message, decoded, _frame_received_at}, state) do
    case decoded do
      %{"jsonrpc" => "2.0", "id" => id} = resp ->
        case Map.pop(state.pending_requests, id) do
          {nil, _pending} ->
            # Not a tracked request; treat as generic message
            case handle_websocket_message(decoded, state) do
              {:ok, new_state} -> {:noreply, new_state}
              new_state -> {:noreply, new_state}
            end

          {%{from: from, timer: timer, sent_at: _sent_at}, new_pending} ->
            Process.cancel_timer(timer)

            reply =
              case resp do
                %{"result" => result} ->
                  {:ok, result}

                %{"error" => _} ->
                  {:error, JError.from(resp, provider_id: state.endpoint.id, transport: :ws)}

                _ ->
                  {:error,
                   JError.new(-32700, "Invalid JSON-RPC response", provider_id: state.endpoint.id)}
              end

            GenServer.reply(from, reply)

            {:noreply, %{state | pending_requests: new_pending}}
        end

      _other ->
        case handle_websocket_message(decoded, state) do
          {:ok, new_state} -> {:noreply, new_state}
          new_state -> {:noreply, new_state}
        end
    end
  end

  def handle_info({:ws_error, error}, state) do
    Logger.error("WebSocket error: #{inspect(error)}")

    jerr =
      ErrorNormalizer.normalize(error,
        provider_id: state.endpoint.id,
        context: :transport,
        transport: :ws
      )

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.chain_name}",
      {:connection_error, state.endpoint.id, jerr}
    )

    {:noreply, state}
  end

  def handle_info({:ws_closed, code, reason}, state) do
    Logger.info("WebSocket closed: #{code} - #{inspect(reason)}")

    jerr =
      ErrorNormalizer.normalize({:ws_close, code, reason},
        provider_id: state.endpoint.id,
        transport: :ws
      )

    # Clean up any pending requests
    state = cleanup_pending_requests(state, jerr)
    state = %{state | connected: false, connection: nil}

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.chain_name}",
      {:ws_closed, state.endpoint.id, code, jerr}
    )

    state = if jerr.retriable?, do: schedule_reconnect(state), else: state
    {:noreply, state}
  end

  def handle_info({:ws_disconnected, reason}, state) do
    Logger.warning("WebSocket disconnected: #{inspect(reason)}")

    jerr =
      ErrorNormalizer.normalize({:ws_disconnect, reason},
        provider_id: state.endpoint.id,
        transport: :ws
      )

    # Clean up any pending requests
    state = cleanup_pending_requests(state, jerr)
    state = %{state | connected: false, connection: nil}

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.chain_name}",
      {:ws_disconnected, state.endpoint.id, jerr}
    )

    state = if jerr.retriable?, do: schedule_reconnect(state), else: state
    {:noreply, state}
  end

  def handle_info({:heartbeat}, state) do
    if state.connected do
      case ws_client().send_frame(state.connection, :ping) do
        :ok ->
          state = schedule_heartbeat(state)
          {:noreply, state}

        {:error, reason} ->
          jerr = ErrorNormalizer.normalize(reason, provider_id: state.endpoint.id, transport: :ws)

          Logger.debug(
            "[Provider→] Heartbeat ping failed for upstream #{state.endpoint.id}: #{inspect(jerr)}"
          )

          state = schedule_heartbeat(state)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:request_timeout, request_id}, state) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from}, new_pending} ->
        GenServer.reply(
          from,
          {:error,
           JError.new(-32000, "WebSocket request timeout", provider_id: state.endpoint.id)}
        )

        {:noreply, %{state | pending_requests: new_pending}}
    end
  end

  @impl true
  def handle_info({:reconnect}, state) do
    Logger.info("Attempting to reconnect to #{state.endpoint.name}")
    # Clear the reconnect timer ref since it's already fired
    state = %{state | reconnect_ref: nil}
    {:noreply, state, {:continue, :connect}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("WebSocket connection lost: #{inspect(reason)}")

    # Report disconnect as failure to circuit breaker with proper error classification
    # Note: Circuit breaker reporting is handled by ProviderPool.report_failure

    case reason do
      {exception, stacktrace} when is_list(stacktrace) ->
        formatted = Exception.format(:error, exception, stacktrace)
        Logger.error("WebSocket #{state.endpoint.id} crash detail\n" <> formatted)

      _ ->
        :ok
    end

    jerr =
      JError.new(-32000, "Connection process died: #{inspect(reason)}",
        provider_id: state.endpoint.id,
        retriable?: true
      )

    # Clean up any pending requests
    state = cleanup_pending_requests(state, jerr)
    state = %{state | connected: false, connection: nil}

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.chain_name}",
      {:ws_disconnected, state.endpoint.id, jerr}
    )

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

    # Notify of disconnection via typed events
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.chain_name}",
      {:ws_disconnected, state.endpoint.id,
       JError.new(-32000, "terminated", provider_id: state.endpoint.id, retriable?: false)}
    )

    :ok
  end

  # WebSocket event handlers - these are now handled by WSHandler
  # and communicated back via messages

  # Private functions

  defp connect_to_websocket(endpoint, parent_pid) do
    # Start a separate WebSocket handler process
    case ws_client().start_link(
           endpoint.ws_url,
           Lasso.RPC.WSHandler,
           %{endpoint: endpoint, parent: parent_pid}
         ) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, ErrorNormalizer.normalize(reason, provider_id: endpoint.id, transport: :ws)}
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

  defp cleanup_pending_requests(state, error) do
    if map_size(state.pending_requests) > 0 do
      Logger.debug(
        "Cleaning up #{map_size(state.pending_requests)} pending requests due to disconnect"
      )

      Enum.each(state.pending_requests, fn {_id, %{from: from, timer: timer}} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:error, error})
      end)

      %{state | pending_requests: %{}}
    else
      state
    end
  end

  # TODO: Consider consolidating these duplicative function handlers (only difference is in the debug calls)
  defp handle_websocket_message(
         %{
           "method" => "eth_subscription",
           "params" => %{"result" => block_data, "subscription" => sub_id}
         },
         state
       ) do
    # Handle new block subscription notifications
    Logger.debug("Received new block: #{inspect(block_data)}")

    # Send to MessageAggregator for deduplication and speed optimization
    received_at = System.monotonic_time(:millisecond)

    # Telemetry: message received
    :telemetry.execute(
      [
        :lasso,
        :ws,
        :message,
        :received
      ],
      %{count: 1},
      %{chain: state.chain_name, provider_id: state.endpoint.id, event_type: :newHeads}
    )

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:subs:#{state.chain_name}",
      {:subscription_event, state.endpoint.id, sub_id, block_data, received_at}
    )

    {:ok, state}
  end

  # Provider-emitted JSON-RPC error without correlation id -> treat as connection-level
  defp handle_websocket_message(
         %{"jsonrpc" => "2.0", "error" => %{"code" => code, "message" => msg}} = message,
         state
       ) do
    if Map.has_key?(message, "id") do
      # Not our clause; fall through to generic handler
      {:ok, state}
    else
      jerr =
        ErrorNormalizer.normalize(message,
          provider_id: state.endpoint.id,
          context: :jsonrpc,
          transport: :ws
        )

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "ws:conn:#{state.chain_name}",
        {:connection_error, state.endpoint.id, jerr}
      )

      # Proactively close on timeout-like provider errors to force clean reconnect
      try do
        if (is_integer(code) and code == -32701) or
             (is_binary(msg) and String.contains?(String.downcase(msg), "timeout")) do
          _ = ws_client().send_frame(state.connection, {:close, 1013, "connection timeout"})
        end
      rescue
        _ -> :ok
      end

      {:ok, state}
    end
  end

  defp handle_websocket_message(%{"method" => "eth_subscription", "params" => params}, state) do
    # Handle other subscription notifications
    Logger.debug("Received subscription: #{inspect(params)}")

    # Send all subscription messages through aggregator
    received_at = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [
        :lasso,
        :ws,
        :message,
        :received
      ],
      %{count: 1},
      %{chain: state.chain_name, provider_id: state.endpoint.id, event_type: :subscription}
    )

    case params do
      %{"subscription" => sub_id, "result" => payload} ->
        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          "ws:subs:#{state.chain_name}",
          {:subscription_event, state.endpoint.id, sub_id, payload, received_at}
        )

      _ ->
        :ok
    end

    {:ok, state}
  end

  defp handle_websocket_message(message, state) do
    # Handle other RPC responses (unknown IDs, unexpected messages, etc)
    Logger.debug("Received unexpected message from #{state.endpoint.id}: #{inspect(message)}")

    :telemetry.execute(
      [
        :lasso,
        :ws,
        :message,
        :received
      ],
      %{count: 1},
      %{chain: state.chain_name, provider_id: state.endpoint.id, event_type: :other}
    )

    {:ok, state}
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp via_name(connection_id) do
    {:via, Registry, {Lasso.Registry, {:ws_conn, connection_id}}}
  end

  defp ws_client do
    Application.get_env(:lasso, :ws_client_module, WebSockex)
  end
end

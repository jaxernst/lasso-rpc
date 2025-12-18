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

  ## Telemetry Events

  This module emits comprehensive telemetry events for observability:

  ### Connection Lifecycle

  * `[:lasso, :websocket, :connected]` - Connection established successfully
    * Measurements: `%{}`
    * Metadata: `%{provider_id, chain, reconnect_attempt}`

  * `[:lasso, :websocket, :disconnected]` - Connection lost or closed
    * Measurements: `%{}`
    * Metadata: `%{provider_id, chain, reason, unexpected, pending_request_count}`

  * `[:lasso, :websocket, :connection_failed]` - Connection attempt failed
    * Measurements: `%{}`
    * Metadata: `%{provider_id, chain, error_code, error_message, retriable, will_reconnect}`

  ### Reconnection Logic

  * `[:lasso, :websocket, :reconnect_scheduled]` - Reconnection scheduled
    * Measurements: `%{delay_ms, jitter_ms}`
    * Metadata: `%{provider_id, attempt, max_attempts}`

  * `[:lasso, :websocket, :reconnect_exhausted]` - Max reconnection attempts reached
    * Measurements: `%{}`
    * Metadata: `%{provider_id, attempts, max_attempts}`

  ### Request Lifecycle

  * `[:lasso, :websocket, :request, :sent]` - Request sent to WebSocket
    * Measurements: `%{}`
    * Metadata: `%{provider_id, method, request_id, timeout_ms}`

  * `[:lasso, :websocket, :request, :completed]` - Request received response
    * Measurements: `%{duration_ms}`
    * Metadata: `%{provider_id, method, request_id, status}`

  * `[:lasso, :websocket, :request, :timeout]` - Request timed out
    * Measurements: `%{timeout_ms}`
    * Metadata: `%{provider_id, method, request_id}`

  ### Heartbeat

  * `[:lasso, :websocket, :heartbeat, :sent]` - Heartbeat ping sent
    * Measurements: `%{}`
    * Metadata: `%{provider_id}`

  * `[:lasso, :websocket, :heartbeat, :failed]` - Heartbeat ping failed
    * Measurements: `%{}`
    * Metadata: `%{provider_id, reason}`
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
      reconnect_ref: nil,
      # Unique ID per connection instance, regenerated on each reconnect
      # Used by UpstreamSubscriptionManager to detect stale subscriptions
      connection_id: nil
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

    case CircuitBreaker.call({state.chain_name, state.endpoint.id, :ws}, fn ->
           connect_to_websocket(state.endpoint, ws_connection_pid)
         end) do
      {:ok, connection} ->
        state = %{state | connection: connection}
        # success path continues via {:ws_connected}
        {:noreply, state}

      {:error, %JError{} = jerr} ->
        Logger.error(
          "Failed to connect to #{state.endpoint.name} (WebSocket): #{jerr.message} (code=#{inspect(jerr.code)})"
        )

        # Emit telemetry event
        :telemetry.execute(
          [:lasso, :websocket, :connection_failed],
          %{},
          %{
            provider_id: state.endpoint.id,
            chain: state.chain_name,
            error_code: jerr.code,
            error_message: jerr.message,
            retriable: jerr.retriable?,
            will_reconnect: jerr.retriable?
          }
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

        jerr =
          JError.new(-32_000, "Circuit open", provider_id: state.endpoint.id, retriable?: true)

        # Emit telemetry event
        :telemetry.execute(
          [:lasso, :websocket, :connection_failed],
          %{},
          %{
            provider_id: state.endpoint.id,
            chain: state.chain_name,
            error_code: jerr.code,
            error_message: jerr.message,
            retriable: true,
            will_reconnect: true
          }
        )

        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          "ws:conn:#{state.chain_name}",
          {:connection_error, state.endpoint.id, jerr}
        )

        # Try again later (uses existing backoff)
        state = schedule_reconnect(state)
        {:noreply, state}

      {:error, other} ->
        Logger.debug("Circuit breaker call error: #{inspect(other)}")

        jerr = JError.from(other, provider_id: state.endpoint.id)

        # Emit telemetry event
        :telemetry.execute(
          [:lasso, :websocket, :connection_failed],
          %{},
          %{
            provider_id: state.endpoint.id,
            chain: state.chain_name,
            error_code: jerr.code,
            error_message: jerr.message,
            retriable: jerr.retriable?,
            will_reconnect: jerr.retriable?
          }
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
    end
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

    case send_frame(state.connection, {:text, Jason.encode!(message)}) do
      :ok ->
        # Emit telemetry event
        :telemetry.execute(
          [:lasso, :websocket, :request, :sent],
          %{},
          %{
            provider_id: state.endpoint.id,
            method: method,
            request_id: request_id,
            timeout_ms: timeout_ms
          }
        )

        timer = Process.send_after(self(), {:request_timeout, request_id}, timeout_ms)

        pending =
          Map.put(state.pending_requests, request_id, %{
            from: from,
            timer: timer,
            sent_at: sent_at,
            method: method
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
    CircuitBreaker.record_success({state.chain_name, state.endpoint.id, :ws})

    # Generate new connection_id for this connection instance
    # This allows consumers to detect when subscriptions are stale (from previous connection)
    connection_id = generate_connection_id()

    :telemetry.execute(
      [:lasso, :websocket, :connected],
      %{},
      %{
        provider_id: state.endpoint.id,
        chain: state.chain_name,
        reconnect_attempt: state.reconnect_attempts,
        connection_id: connection_id
      }
    )

    # Now reset the state for next potential disconnect/reconnect cycle
    state = %{state | connected: true, reconnect_attempts: 0, connection_id: connection_id}

    # Cancel any pending reconnect timer (stale) now that we're connected
    state =
      if state.reconnect_ref do
        Process.cancel_timer(state.reconnect_ref)
        %{state | reconnect_ref: nil}
      else
        state
      end

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.chain_name}",
      {:ws_connected, state.endpoint.id, connection_id}
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
            {:ok, new_state} = handle_websocket_message(decoded, state)
            {:noreply, new_state}

          {%{from: from, timer: timer, sent_at: sent_at, method: method}, new_pending} ->
            Process.cancel_timer(timer)

            duration_ms = div(System.monotonic_time(:microsecond) - sent_at, 1000)

            reply =
              case resp do
                %{"result" => result} ->
                  {:ok, result}

                %{"error" => _} ->
                  {:error, JError.from(resp, provider_id: state.endpoint.id, transport: :ws)}

                _ ->
                  {:error,
                   JError.new(-32_700, "Invalid JSON-RPC response",
                     provider_id: state.endpoint.id
                   )}
              end

            status = if match?({:ok, _}, reply), do: :success, else: :error

            # Emit telemetry event for request completion
            :telemetry.execute(
              [:lasso, :websocket, :request, :completed],
              %{
                duration_ms: duration_ms
              },
              %{
                provider_id: state.endpoint.id,
                method: method,
                request_id: id,
                status: status
              }
            )

            # Emit I/O-specific telemetry (for comparison with HTTP I/O)
            :telemetry.execute(
              [:lasso, :ws, :request, :io],
              %{io_ms: duration_ms},
              %{provider_id: state.endpoint.id, method: method, request_id: id}
            )

            GenServer.reply(from, reply)

            {:noreply, %{state | pending_requests: new_pending}}
        end

      _other ->
        {:ok, new_state} = handle_websocket_message(decoded, state)
        {:noreply, new_state}
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

  def handle_info({:ws_disconnect, :close_frame, code, reason}, state) do
    # Cancel heartbeat to prevent race condition
    state =
      if state.heartbeat_ref do
        Process.cancel_timer(state.heartbeat_ref)
        %{state | heartbeat_ref: nil}
      else
        state
      end

    had_pending = map_size(state.pending_requests) > 0

    jerr =
      ErrorNormalizer.normalize({:ws_close, code, reason},
        provider_id: state.endpoint.id,
        transport: :ws
      )

    # Graceful codes: 1000 = normal, 1001 = going away, 1013 = try again later
    graceful_codes = [1000, 1001, 1013]
    is_graceful = code in graceful_codes

    # Only log warnings for non-graceful closes or when active traffic was interrupted
    if had_pending or not is_graceful do
      Logger.warning(
        "WebSocket closed: code=#{code}, reason=#{inspect(reason)}, " <>
          "had_active_traffic=#{had_pending} (provider: #{state.endpoint.id})"
      )
    else
      Logger.debug(
        "WebSocket closed gracefully while idle: code=#{code} (provider: #{state.endpoint.id})"
      )
    end

    # Clean up any pending requests
    pending_count = map_size(state.pending_requests)
    state = cleanup_pending_requests(state, jerr)
    state = %{state | connected: false, connection: nil}

    # Emit telemetry event
    :telemetry.execute(
      [:lasso, :websocket, :disconnected],
      %{},
      %{
        provider_id: state.endpoint.id,
        chain: state.chain_name,
        reason: reason,
        code: code,
        had_active_traffic: had_pending,
        unexpected: not is_graceful,
        pending_request_count: pending_count
      }
    )

    # Circuit breaker penalty: penalize if had active traffic OR non-graceful close
    should_penalize = had_pending or not is_graceful
    jerr_with_penalty = %{jerr | breaker_penalty?: should_penalize and jerr.breaker_penalty?}

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.chain_name}",
      {:ws_closed, state.endpoint.id, code, jerr_with_penalty}
    )

    state = if jerr.retriable?, do: schedule_reconnect_with_circuit_check(state), else: state
    {:noreply, state}
  end

  # Handle unexpected disconnects (network errors, crashes, abrupt TCP close)
  def handle_info({:ws_disconnect, :error, reason}, state) do
    # Cancel heartbeat to prevent race condition
    state =
      if state.heartbeat_ref do
        Process.cancel_timer(state.heartbeat_ref)
        %{state | heartbeat_ref: nil}
      else
        state
      end

    had_pending = map_size(state.pending_requests) > 0

    jerr =
      ErrorNormalizer.normalize({:ws_disconnect, reason},
        provider_id: state.endpoint.id,
        transport: :ws
      )

    Logger.warning(
      "WebSocket disconnected unexpectedly: #{inspect(reason)}, " <>
        "had_active_traffic=#{had_pending} (provider: #{state.endpoint.id})"
    )

    # Clean up any pending requests
    pending_count = map_size(state.pending_requests)
    state = cleanup_pending_requests(state, jerr)
    state = %{state | connected: false, connection: nil}

    # Emit telemetry event
    :telemetry.execute(
      [:lasso, :websocket, :disconnected],
      %{},
      %{
        provider_id: state.endpoint.id,
        chain: state.chain_name,
        reason: reason,
        had_active_traffic: had_pending,
        unexpected: true,
        pending_request_count: pending_count
      }
    )

    # Unexpected disconnects always warrant circuit breaker penalty
    jerr_with_penalty = %{jerr | breaker_penalty?: true}

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.chain_name}",
      {:ws_disconnected, state.endpoint.id, jerr_with_penalty}
    )

    state = schedule_reconnect_with_circuit_check(state)
    {:noreply, state}
  end

  def handle_info(
        {:heartbeat},
        %{connected: true, connection: connection, endpoint: endpoint} = state
      ) do
    case send_frame(connection, :ping) do
      :ok ->
        # Emit telemetry event
        :telemetry.execute(
          [:lasso, :websocket, :heartbeat, :sent],
          %{},
          %{
            provider_id: endpoint.id
          }
        )

        state = schedule_heartbeat(state)
        {:noreply, state}

      {:error, :timeout} ->
        Logger.warning(
          "Heartbeat ping timeout for #{endpoint.id} - connection appears hung, reconnecting"
        )

        # Emit telemetry event
        :telemetry.execute(
          [:lasso, :websocket, :heartbeat, :failed],
          %{},
          %{
            provider_id: endpoint.id,
            reason: :timeout
          }
        )

        # Connection is hung - treat as disconnect and reconnect
        jerr =
          JError.new(-32_000, "Heartbeat timeout",
            provider_id: endpoint.id,
            retriable?: true
          )

        state = cleanup_pending_requests(state, jerr)
        state = %{state | connected: false, connection: nil}

        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          "ws:conn:#{state.chain_name}",
          {:ws_disconnected, endpoint.id, jerr}
        )

        state = schedule_reconnect(state)
        {:noreply, state}

      {:error, reason} ->
        Logger.debug("Heartbeat ping failed for #{endpoint.id}: #{inspect(reason)}")

        {:noreply, state}
    end
  end

  def handle_info({:heartbeat}, %{connected: false} = state) do
    {:noreply, state}
  end

  def handle_info({:request_timeout, request_id}, state) do
    case Map.pop(state.pending_requests, request_id) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from, sent_at: sent_at, method: method}, new_pending} ->
        timeout_ms = div(System.monotonic_time(:microsecond) - sent_at, 1000)

        # Emit telemetry event
        :telemetry.execute(
          [:lasso, :websocket, :request, :timeout],
          %{
            timeout_ms: timeout_ms
          },
          %{
            provider_id: state.endpoint.id,
            method: method,
            request_id: request_id
          }
        )

        GenServer.reply(
          from,
          {:error,
           JError.new(-32_000, "WebSocket request timeout", provider_id: state.endpoint.id)}
        )

        {:noreply, %{state | pending_requests: new_pending}}
    end
  end

  @impl true
  def handle_info({:reconnect}, %{connected: true} = state) do
    Logger.debug(
      "Reconnect skipped for #{state.endpoint.name} (provider: #{state.endpoint.id}) - already connected"
    )

    {:noreply, %{state | reconnect_ref: nil}}
  end

  def handle_info({:reconnect}, state) do
    Logger.info(
      "Reconnecting to #{state.endpoint.name} (attempt #{state.reconnect_attempts}, provider: #{state.endpoint.id})"
    )

    # Clear the reconnect timer ref since it's already fired
    state = %{state | reconnect_ref: nil}
    {:noreply, state, {:continue, :connect}}
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
       JError.new(-32_000, "terminated", provider_id: state.endpoint.id, retriable?: false)}
    )

    :ok
  end

  # WebSocket event handlers - these are now handled by WSHandler
  # and communicated back via messages

  # Private functions

  defp connect_to_websocket(endpoint, parent_pid) do
    # Start a separate WebSocket handler process
    # Pass connection_id in opts for test-mode failure injection (MockWSClient)
    # WebSockex ignores unknown opts, so this is safe for production
    opts = [connection_id: endpoint.id]

    case ws_client().start_link(
           endpoint.ws_url,
           Lasso.RPC.WSHandler,
           %{endpoint: endpoint, parent: parent_pid},
           opts
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

  defp schedule_reconnect_with_circuit_check(state) do
    case CircuitBreaker.get_state({state.chain_name, state.endpoint.id, :ws}) do
      :open ->
        # Circuit is open - use longer delay before next reconnect attempt
        Logger.debug("Circuit breaker open for #{state.endpoint.id}, delaying reconnect")

        delay = 10_000 + :rand.uniform(5_000)

        # Emit telemetry
        :telemetry.execute(
          [:lasso, :websocket, :reconnect_scheduled],
          %{delay_ms: delay, jitter_ms: 0},
          %{
            provider_id: state.endpoint.id,
            attempt: state.reconnect_attempts + 1,
            max_attempts: state.endpoint.max_reconnect_attempts,
            circuit_state: :open
          }
        )

        ref = Process.send_after(self(), {:reconnect}, delay)
        %{state | reconnect_attempts: state.reconnect_attempts + 1, reconnect_ref: ref}

      _ ->
        # Circuit closed or half-open - use normal reconnect logic
        schedule_reconnect(state)
    end
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
        # First attempt is immediate, subsequent attempts use backoff
        delay =
          if state.reconnect_attempts == 0 do
            0
          else
            min(state.endpoint.reconnect_interval * state.reconnect_attempts, 30_000)
          end

        jitter = if delay > 0, do: :rand.uniform(1000), else: 0

        Logger.info(
          "Scheduling reconnect for #{state.endpoint.name} (attempt #{state.reconnect_attempts + 1}) in #{delay + jitter}ms"
        )

        # Emit telemetry event
        :telemetry.execute(
          [:lasso, :websocket, :reconnect_scheduled],
          %{
            delay_ms: delay + jitter,
            jitter_ms: jitter
          },
          %{
            provider_id: state.endpoint.id,
            attempt: state.reconnect_attempts + 1,
            max_attempts: :infinity
          }
        )

        # Broadcast reconnection attempt to ProviderPool
        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          "ws:conn:#{state.chain_name}",
          {:ws_reconnecting, state.endpoint.id, state.reconnect_attempts + 1}
        )

        ref = Process.send_after(self(), {:reconnect}, delay + jitter)
        %{state | reconnect_attempts: state.reconnect_attempts + 1, reconnect_ref: ref}

      state.reconnect_attempts < max_attempts ->
        # First attempt is immediate, subsequent attempts use backoff
        delay =
          if state.reconnect_attempts == 0 do
            0
          else
            min(state.endpoint.reconnect_interval * state.reconnect_attempts, 30_000)
          end

        jitter = if delay > 0, do: :rand.uniform(1000), else: 0

        Logger.info(
          "Scheduling reconnect for #{state.endpoint.name} (attempt #{state.reconnect_attempts + 1}/#{max_attempts}) in #{delay + jitter}ms"
        )

        # Emit telemetry event
        :telemetry.execute(
          [:lasso, :websocket, :reconnect_scheduled],
          %{
            delay_ms: delay + jitter,
            jitter_ms: jitter
          },
          %{
            provider_id: state.endpoint.id,
            attempt: state.reconnect_attempts + 1,
            max_attempts: max_attempts
          }
        )

        # Broadcast reconnection attempt to ProviderPool
        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          "ws:conn:#{state.chain_name}",
          {:ws_reconnecting, state.endpoint.id, state.reconnect_attempts + 1}
        )

        ref = Process.send_after(self(), {:reconnect}, delay + jitter)
        %{state | reconnect_attempts: state.reconnect_attempts + 1, reconnect_ref: ref}

      true ->
        # Max attempts reached - continue with extended backoff (5 minutes)
        # This ensures we keep probing so circuit breaker can eventually recover
        extended_delay_ms = 5 * 60 * 1000
        jitter = :rand.uniform(30_000)

        Logger.warning(
          "Max reconnection attempts (#{max_attempts}) reached for #{state.endpoint.name}, " <>
            "continuing with extended backoff (#{div(extended_delay_ms, 60_000)}min)"
        )

        # Emit telemetry event (keeping for observability, but we continue)
        :telemetry.execute(
          [:lasso, :websocket, :reconnect_exhausted],
          %{},
          %{
            provider_id: state.endpoint.id,
            attempts: state.reconnect_attempts,
            max_attempts: max_attempts,
            extended_backoff: true
          }
        )

        # Broadcast reconnection attempt to ProviderPool
        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          "ws:conn:#{state.chain_name}",
          {:ws_reconnecting, state.endpoint.id, state.reconnect_attempts + 1}
        )

        ref = Process.send_after(self(), {:reconnect}, extended_delay_ms + jitter)
        # Keep reconnect_attempts incrementing so we stay in extended backoff mode
        %{state | reconnect_attempts: state.reconnect_attempts + 1, reconnect_ref: ref}
    end
  end

  defp cleanup_pending_requests(state, error) do
    if map_size(state.pending_requests) > 0 do
      Logger.debug(
        "Cleaning up #{map_size(state.pending_requests)} pending requests due to disconnect"
      )

      Enum.each(state.pending_requests, fn {id, req_info} ->
        Process.cancel_timer(req_info.timer)

        Logger.debug("Failing pending WS request due to disconnect",
          provider: state.endpoint.id,
          method: req_info.method,
          request_id: id
        )

        GenServer.reply(req_info.from, {:error, error})
      end)

      %{state | pending_requests: %{}}
    else
      state
    end
  end

  defp handle_websocket_message(
         %{
           "method" => "eth_subscription",
           "params" => %{"subscription" => sub_id, "result" => payload}
         },
         state
       ) do
    received_at = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:lasso, :ws, :message, :received],
      %{count: 1},
      %{chain: state.chain_name, provider_id: state.endpoint.id, event_type: :subscription}
    )

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:subs:#{state.chain_name}",
      {:subscription_event, state.endpoint.id, sub_id, payload, received_at}
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
      if (is_integer(code) and code == -32_701) or
           (is_binary(msg) and String.contains?(String.downcase(msg), "timeout")) do
        # Ignore result - best effort close
        _ = send_frame(state.connection, {:close, 1013, "connection timeout"})
      end

      {:ok, state}
    end
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

  # Generate unique connection ID for tracking connection instances
  # Used to detect stale subscriptions after reconnect
  defp generate_connection_id do
    "conn_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp via_name(connection_id) do
    {:via, Registry, {Lasso.Registry, {:ws_conn, connection_id}}}
  end

  defp ws_client do
    Application.get_env(:lasso, :ws_client_module, WebSockex)
  end

  # Wrapper around ws_client().send_frame that converts exits to error tuples
  #
  # WebSockex.send_frame normally returns:
  #   :ok | {:error, %WebSockex.FrameEncodeError{} | %WebSockex.ConnError{} |
  #                   %WebSockex.NotConnectedError{} | %WebSockex.InvalidFrameError{}}
  #
  # But it uses :gen.call internally (with 5s timeout), which can exit if:
  #   - Process is hung/unresponsive (timeout)
  #   - Process died (noproc)
  #   - Process crashed
  #
  # This wrapper catches those exits and converts them to {:error, reason} tuples
  # for consistent error handling.
  defp send_frame(connection, frame) do
    try do
      ws_client().send_frame(connection, frame)
    catch
      # Process is hung/unresponsive - :gen.call timed out (default 5s)
      :exit, {:timeout, _call_info} ->
        {:error, :timeout}

      # Process died or noproc
      :exit, {:noproc, _call_info} ->
        {:error, :noproc}

      # Other exit reasons (process crash, etc.)
      :exit, {reason, _call_info} ->
        {:error, {:exit, reason}}
    end
  end
end

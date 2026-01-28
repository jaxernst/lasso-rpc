defmodule Lasso.RPC.Transport.WebSocket.Connection do
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

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Core.Support.ErrorNormalizer
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.Response
  alias Lasso.RPC.Transport.WebSocket.Endpoint

  # Client API

  @doc """
  Starts a new WebSocket connection process.

  ## Examples

      iex> {:ok, pid} = Lasso.RPC.Transport.WebSocket.Connection.start_link(endpoint)
      iex> Process.alive?(pid)
      true
  """
  @spec start_link(Endpoint.t()) :: GenServer.on_start()
  def start_link(%Endpoint{} = endpoint) do
    GenServer.start_link(__MODULE__, endpoint,
      name: via_name(endpoint.profile, endpoint.chain_name, endpoint.id)
    )
  end

  @doc """
  Gets the current connection status.

  ## Examples

      iex> Lasso.RPC.Transport.WebSocket.Connection.status("default", "ethereum", "ethereum_ws")
      %{connected: true, endpoint_id: "ethereum_ws", reconnect_attempts: 0}
  """
  @spec status(String.t(), String.t(), String.t()) :: map()
  def status(profile, chain, provider_id) do
    GenServer.call(via_name(profile, chain, provider_id), :status)
  end

  # Server Callbacks

  @impl true
  def init(%Endpoint{} = endpoint) do
    # Trap exits so we receive :EXIT messages from linked WebSockex processes
    # This ensures we handle disconnects even if WebSockex crashes abnormally
    Process.flag(:trap_exit, true)

    state = %{
      endpoint: endpoint,
      profile: endpoint.profile,
      chain_name: endpoint.chain_name,
      connection: nil,
      connected: false,
      reconnect_attempts: 0,
      pending_requests: %{},
      heartbeat_ref: nil,
      reconnect_ref: nil,
      # Timer that fires after connection is stable - only then do we reset reconnect_attempts
      # This prevents thrashing when providers drop connections immediately after connect
      stability_timer_ref: nil,
      # Whether the connection has proven stable (survived the stability window)
      # Disconnects before stability are always penalized to prevent thrashing
      connection_stable: false,
      # Unique ID per connection instance, regenerated on each reconnect
      # Used by UpstreamSubscriptionManager to detect stale subscriptions
      connection_id: nil
    }

    # Start the connection process
    {:ok, state, {:continue, :connect}}
  end

  @doc """
  Performs a unary JSON-RPC request over the WebSocket connection with response correlation.

  The connection is identified by `{profile, chain, provider_id}` tuple.

  Returns {:ok, result} | {:error, reason}.
  """
  @spec request(
          {String.t(), String.t(), String.t()},
          String.t(),
          list() | map() | nil,
          non_neg_integer(),
          String.t() | nil
        ) ::
          {:ok, Response.Success.t()} | {:error, JError.t()}
  def request(
        {profile, chain, provider_id},
        method,
        params,
        timeout_ms \\ 30_000,
        request_id \\ nil
      ) do
    GenServer.call(
      via_name(profile, chain, provider_id),
      {:request, method, params, timeout_ms, request_id},
      timeout_ms + 2_000
    )
  end

  @impl true
  def handle_continue(:connect, state) do
    breaker_id = {state.profile, state.chain_name, state.endpoint.id, :ws}

    # Check circuit state manually instead of using CircuitBreaker.call
    # This prevents successful connections from resetting the failure count,
    # allowing disconnect failures to accumulate for "accept then drop" patterns
    case CircuitBreaker.get_state(breaker_id) do
      %{state: :open} ->
        Logger.debug("Circuit breaker open for #{state.endpoint.id}, skipping connect attempt")

        jerr =
          JError.new(-32_000, "Circuit open", provider_id: state.endpoint.id, retriable?: true)

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
          "ws:conn:#{state.profile}:#{state.chain_name}",
          {:connection_error, state.endpoint.id, jerr}
        )

        state = schedule_reconnect(state)
        {:noreply, state}

      %{state: cb_state} when cb_state in [:closed, :half_open] ->
        # Circuit is closed or half-open - attempt connection
        do_connect(state, breaker_id)

      {:error, _reason} ->
        # Circuit breaker not found or error - attempt connection anyway
        do_connect(state, breaker_id)
    end
  end

  # Attempt WebSocket connection without going through CircuitBreaker.call
  # This ensures successful connections don't reset the failure count
  defp do_connect(state, breaker_id) do
    ws_connection_pid = self()

    case connect_to_websocket(state.endpoint, ws_connection_pid) do
      {:ok, connection} ->
        # Success - don't report to circuit breaker yet!
        # Recovery will be signaled when connection proves stable (5s)
        state = %{state | connection: connection}
        {:noreply, state}

      {:error, %JError{} = jerr} ->
        Logger.error(
          "Failed to connect to #{state.endpoint.name} (WebSocket): #{jerr.message} (code=#{inspect(jerr.code)})"
        )

        # Record connection failure to circuit breaker
        if jerr.breaker_penalty? do
          CircuitBreaker.record_failure(breaker_id, jerr)
        end

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
          "ws:conn:#{state.profile}:#{state.chain_name}",
          {:connection_error, state.endpoint.id, jerr}
        )

        state =
          if jerr.retriable? do
            schedule_reconnect(state)
          else
            state
          end

        {:noreply, state}

      {:error, other} ->
        Logger.debug("Connection function returned error: #{inspect(other)}")

        jerr = JError.from(other, provider_id: state.endpoint.id)

        # Record connection failure to circuit breaker
        if jerr.breaker_penalty? do
          CircuitBreaker.record_failure(breaker_id, jerr)
        end

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
          "ws:conn:#{state.profile}:#{state.chain_name}",
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
      connection_stable: state.connection_stable,
      endpoint_id: state.endpoint.id,
      reconnect_attempts: state.reconnect_attempts,
      pending_requests: map_size(state.pending_requests)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info({:ws_connected}, state) do
    # NOTE: We intentionally do NOT call signal_recovery here.
    # Recovery is signaled only after the connection proves stable (see {:connection_stable}).
    # This allows circuit breaker failures to accumulate when providers accept connections
    # but immediately drop them (e.g., dRPC connection limits).

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

    # Mark as connected but DON'T reset reconnect_attempts yet.
    # Schedule stability timer - only reset attempts after connection proves stable.
    # This prevents thrashing when providers drop connections immediately after connect.
    state = %{state | connected: true, connection_id: connection_id}

    # Cancel any pending reconnect timer (stale) now that we're connected
    state =
      if state.reconnect_ref do
        Process.cancel_timer(state.reconnect_ref)
        %{state | reconnect_ref: nil}
      else
        state
      end

    # Handle stability based on configured stability_ms:
    # - If 0, consider connection immediately stable (useful for tests)
    # - Otherwise, schedule stability check timer
    state =
      if state.endpoint.stability_ms == 0 do
        # Immediate stability - reset attempts and signal recovery now
        CircuitBreaker.signal_recovery({state.profile, state.chain_name, state.endpoint.id, :ws})
        %{state | reconnect_attempts: 0, connection_stable: true}
      else
        schedule_stability_check(state)
      end

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.profile}:#{state.chain_name}",
      {:ws_connected, state.endpoint.id, connection_id}
    )

    state = schedule_heartbeat(state)
    {:noreply, state}
  end

  def handle_info({:ws_message, raw_bytes, _frame_received_at}, state) do
    case Response.from_bytes(raw_bytes) do
      {:ok, %Response.Success{id: nil}} ->
        # Safety guard: Response with nil id is likely a misclassified notification.
        # This shouldn't happen with proper EnvelopeParser method-field detection,
        # but provides defense-in-depth.
        handle_non_response_message(raw_bytes, state)

      {:ok, %Response.Success{id: id} = resp} ->
        handle_response_success(id, resp, state)

      {:ok, %Response.Error{id: id, error: jerr}} ->
        handle_response_error(id, jerr, state)

      {:error, _parse_reason} ->
        handle_non_response_message(raw_bytes, state)
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
      "ws:conn:#{state.profile}:#{state.chain_name}",
      {:connection_error, state.endpoint.id, jerr}
    )

    {:noreply, state}
  end

  def handle_info({:ws_disconnect, :close_frame, _code, _reason}, %{connected: false} = state) do
    Logger.debug("Ignoring ws_disconnect close_frame (already disconnected)",
      provider_id: state.endpoint.id
    )

    {:noreply, state}
  end

  def handle_info({:ws_disconnect, :close_frame, code, reason}, state) do
    Logger.debug("Connection received ws_disconnect close_frame",
      provider_id: state.endpoint.id,
      code: code,
      reason: inspect(reason)
    )

    # Capture stability before canceling timer
    was_stable = state.connection_stable

    # Cancel timers to prevent race conditions
    state = cancel_stability_timer(state)

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

    # Graceful codes that don't warrant circuit breaker penalty (when connection was stable):
    # 1000 = normal closure, 1001 = going away, 1012 = service restart
    # Note: 1013 (try again later) is NOT graceful - it indicates rate limiting
    is_graceful = graceful_close_code?(code)

    # Determine if this disconnect warrants circuit breaker penalty:
    # 1. Always penalize if connection wasn't stable (dropped before proving reliable)
    # 2. Penalize if had pending requests (interrupted active traffic)
    # 3. Penalize if non-graceful close code
    should_penalize = not was_stable or had_pending or not is_graceful

    if should_penalize do
      Logger.warning(
        "WebSocket closed: code=#{code}, reason=#{inspect(reason)}, " <>
          "was_stable=#{was_stable}, had_active_traffic=#{had_pending} (provider: #{state.endpoint.id})"
      )
    else
      Logger.info("WebSocket closed: code=#{code} (provider: #{state.endpoint.id})")
    end

    # Clean up any pending requests
    pending_count = map_size(state.pending_requests)
    state = cleanup_pending_requests(state, jerr)
    state = %{state | connected: false, connection: nil, connection_stable: false}

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
        was_stable: was_stable,
        unexpected: not is_graceful,
        pending_request_count: pending_count
      }
    )

    jerr_with_penalty = %{jerr | breaker_penalty?: should_penalize and jerr.breaker_penalty?}

    # Record failure to circuit breaker synchronously when penalizing
    # This prevents hammering providers that accept connections but immediately drop them
    circuit_state =
      if should_penalize do
        breaker_id = {state.profile, state.chain_name, state.endpoint.id, :ws}

        case CircuitBreaker.record_failure_sync(breaker_id, jerr_with_penalty) do
          {:ok, state} -> state
          {:error, _} -> :closed
        end
      else
        :closed
      end

    Logger.debug("Circuit breaker state after close frame",
      provider_id: state.endpoint.id,
      circuit_state: circuit_state,
      was_penalized: should_penalize
    )

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.profile}:#{state.chain_name}",
      {:ws_closed, state.endpoint.id, code, jerr_with_penalty}
    )

    state = if jerr.retriable?, do: schedule_reconnect_with_circuit_check(state), else: state
    {:noreply, state}
  end

  # Handle unexpected disconnects (network errors, crashes, abrupt TCP close)
  def handle_info({:ws_disconnect, :error, _reason}, %{connected: false} = state) do
    Logger.debug("Ignoring ws_disconnect error (already disconnected)",
      provider_id: state.endpoint.id
    )

    {:noreply, state}
  end

  def handle_info({:ws_disconnect, :error, reason}, state) do
    Logger.debug("Connection received ws_disconnect error",
      provider_id: state.endpoint.id,
      reason: inspect(reason)
    )

    try do
      # Capture stability before canceling timer
      was_stable = state.connection_stable

      # Cancel timers to prevent race conditions
      state = cancel_stability_timer(state)

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
          "was_stable=#{was_stable}, had_active_traffic=#{had_pending} (provider: #{state.endpoint.id})"
      )

      # Clean up any pending requests
      pending_count = map_size(state.pending_requests)
      state = cleanup_pending_requests(state, jerr)
      state = %{state | connected: false, connection: nil, connection_stable: false}

      # Emit telemetry event
      :telemetry.execute(
        [:lasso, :websocket, :disconnected],
        %{},
        %{
          provider_id: state.endpoint.id,
          chain: state.chain_name,
          reason: reason,
          had_active_traffic: had_pending,
          was_stable: false,
          unexpected: true,
          pending_request_count: pending_count
        }
      )

      # Unexpected disconnects always warrant circuit breaker penalty
      jerr_with_penalty = %{jerr | breaker_penalty?: true}

      Logger.debug("Recording circuit breaker failure (sync)",
        provider_id: state.endpoint.id,
        breaker_penalty: jerr_with_penalty.breaker_penalty?
      )

      # Record failure to circuit breaker synchronously
      # This ensures the circuit state is updated before we schedule reconnect
      breaker_id = {state.profile, state.chain_name, state.endpoint.id, :ws}

      circuit_state =
        case CircuitBreaker.record_failure_sync(breaker_id, jerr_with_penalty) do
          {:ok, state} -> state
          {:error, _} -> :closed
        end

      Logger.debug("Circuit breaker state after disconnect",
        provider_id: state.endpoint.id,
        circuit_state: circuit_state
      )

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "ws:conn:#{state.profile}:#{state.chain_name}",
        {:ws_disconnected, state.endpoint.id, jerr_with_penalty}
      )

      state = schedule_reconnect_with_circuit_check(state)
      {:noreply, state}
    rescue
      e ->
        Logger.error("Error in ws_disconnect error handler: #{inspect(e)}")
        reraise e, __STACKTRACE__
    end
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
          "ws:conn:#{state.profile}:#{state.chain_name}",
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

  # Connection has been stable for the grace period - now safe to reset reconnect_attempts
  # and signal recovery to the circuit breaker
  def handle_info({:connection_stable}, %{connected: true} = state) do
    Logger.debug(
      "Connection stable, resetting reconnect attempts (provider: #{state.endpoint.id})"
    )

    # Signal recovery to circuit breaker only after connection proves stable
    # This prevents premature recovery when providers accept connections but immediately drop them
    CircuitBreaker.signal_recovery({state.profile, state.chain_name, state.endpoint.id, :ws})

    {:noreply,
     %{state | reconnect_attempts: 0, stability_timer_ref: nil, connection_stable: true}}
  end

  # Connection was lost before stability timer fired - ignore
  def handle_info({:connection_stable}, state) do
    {:noreply, %{state | stability_timer_ref: nil}}
  end

  # Handle EXIT from linked WebSockex process
  # This catches cases where WebSockex exits before or after sending :ws_disconnect
  # Without this, we might miss disconnects entirely if WebSockex crashes
  def handle_info({:EXIT, pid, reason}, %{connection: pid, connected: true} = state) do
    Logger.debug("WebSockex process exited",
      provider_id: state.endpoint.id,
      reason: inspect(reason)
    )

    # Check if we've already handled this disconnect via :ws_disconnect message
    # If connected is still true, we haven't processed the disconnect yet
    # This is a safety net - process the disconnect now
    was_stable = state.connection_stable

    # Cancel timers
    state = cancel_stability_timer(state)

    state =
      if state.heartbeat_ref do
        Process.cancel_timer(state.heartbeat_ref)
        %{state | heartbeat_ref: nil}
      else
        state
      end

    had_pending = map_size(state.pending_requests) > 0

    jerr =
      ErrorNormalizer.normalize({:ws_exit, reason},
        provider_id: state.endpoint.id,
        transport: :ws
      )

    Logger.warning(
      "WebSockex exited unexpectedly (via :EXIT): #{inspect(reason)}, " <>
        "was_stable=#{was_stable}, had_active_traffic=#{had_pending} (provider: #{state.endpoint.id})"
    )

    # Clean up pending requests
    pending_count = map_size(state.pending_requests)
    state = cleanup_pending_requests(state, jerr)
    state = %{state | connected: false, connection: nil, connection_stable: false}

    :telemetry.execute(
      [:lasso, :websocket, :disconnected],
      %{},
      %{
        provider_id: state.endpoint.id,
        chain: state.chain_name,
        reason: {:exit, reason},
        had_active_traffic: had_pending,
        was_stable: was_stable,
        unexpected: true,
        pending_request_count: pending_count
      }
    )

    # Always penalize circuit breaker for unexpected exits
    jerr_with_penalty = %{jerr | breaker_penalty?: true}
    breaker_id = {state.profile, state.chain_name, state.endpoint.id, :ws}

    circuit_state =
      case CircuitBreaker.record_failure_sync(breaker_id, jerr_with_penalty) do
        {:ok, cb_state} -> cb_state
        {:error, _} -> :closed
      end

    Logger.debug("Circuit breaker state after WebSockex exit",
      provider_id: state.endpoint.id,
      circuit_state: circuit_state
    )

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.profile}:#{state.chain_name}",
      {:ws_disconnected, state.endpoint.id, jerr_with_penalty}
    )

    state = schedule_reconnect_with_circuit_check(state)
    {:noreply, state}
  end

  # Handle EXIT from WebSockex when we already know we're disconnected
  # This can happen if the :ws_disconnect message was processed first
  def handle_info({:EXIT, pid, reason}, %{connection: pid, connected: false} = state) do
    Logger.debug("WebSockex process exited (already disconnected)",
      provider_id: state.endpoint.id,
      reason: inspect(reason)
    )

    # Already disconnected, just clear the connection reference
    {:noreply, %{state | connection: nil}}
  end

  # Handle supervisor shutdown signals - propagate cleanly
  def handle_info({:EXIT, _from, :shutdown}, state) do
    {:stop, :shutdown, state}
  end

  def handle_info({:EXIT, _from, {:shutdown, reason}}, state) do
    {:stop, {:shutdown, reason}, state}
  end

  # Handle EXIT from an old WebSockex process (different pid than current connection)
  # This can happen during rapid reconnection cycles
  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.debug("Received EXIT from old/unknown process",
      provider_id: state.endpoint.id,
      reason: inspect(reason)
    )

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info(
      "Terminating WebSocket connection #{state.endpoint.id}, reason: #{inspect(reason)}"
    )

    # Clean up timers
    if state.heartbeat_ref do
      Process.cancel_timer(state.heartbeat_ref)
    end

    if state.reconnect_ref do
      Process.cancel_timer(state.reconnect_ref)
    end

    if state.stability_timer_ref do
      Process.cancel_timer(state.stability_timer_ref)
    end

    # Notify of disconnection via typed events
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{state.profile}:#{state.chain_name}",
      {:ws_disconnected, state.endpoint.id,
       JError.new(-32_000, "terminated", provider_id: state.endpoint.id, retriable?: false)}
    )

    :ok
  end

  # WebSocket event handlers - these are now handled by WSHandler
  # and communicated back via messages

  # Private functions

  defp handle_response_success(id, resp, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from, timer: timer, sent_at: sent_at, method: method}, new_pending} ->
        Process.cancel_timer(timer)
        duration_ms = div(System.monotonic_time(:microsecond) - sent_at, 1000)

        emit_completion_telemetry(state.endpoint.id, method, id, :success, duration_ms)
        GenServer.reply(from, {:ok, resp})

        {:noreply, %{state | pending_requests: new_pending}}
    end
  end

  defp handle_response_error(id, jerr, state) do
    case Map.pop(state.pending_requests, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from, timer: timer, sent_at: sent_at, method: method}, new_pending} ->
        Process.cancel_timer(timer)
        duration_ms = div(System.monotonic_time(:microsecond) - sent_at, 1000)

        enriched = %{jerr | provider_id: state.endpoint.id, transport: :ws}

        emit_completion_telemetry(state.endpoint.id, method, id, :error, duration_ms)
        GenServer.reply(from, {:error, enriched})

        {:noreply, %{state | pending_requests: new_pending}}
    end
  end

  defp handle_non_response_message(raw_bytes, state) do
    case Jason.decode(raw_bytes) do
      {:ok, decoded} ->
        {:ok, new_state} = handle_websocket_message(decoded, state)
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to decode WebSocket message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp emit_completion_telemetry(provider_id, method, request_id, status, duration_ms) do
    :telemetry.execute(
      [:lasso, :websocket, :request, :completed],
      %{duration_ms: duration_ms},
      %{provider_id: provider_id, method: method, request_id: request_id, status: status}
    )

    :telemetry.execute(
      [:lasso, :ws, :request, :io],
      %{io_ms: duration_ms},
      %{provider_id: provider_id, method: method, request_id: request_id}
    )
  end

  defp connect_to_websocket(endpoint, parent_pid) do
    # Start a separate WebSocket handler process
    # Pass connection_id in opts for test-mode failure injection (MockWSClient)
    # WebSockex ignores unknown opts, so this is safe for production
    opts = [connection_id: endpoint.id]

    case ws_client().start_link(
           endpoint.ws_url,
           Lasso.RPC.Transport.WebSocket.Handler,
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

  defp schedule_stability_check(state) do
    state = cancel_stability_timer(state)
    ref = Process.send_after(self(), {:connection_stable}, state.endpoint.stability_ms)
    %{state | stability_timer_ref: ref}
  end

  defp cancel_stability_timer(state) do
    if state.stability_timer_ref do
      Process.cancel_timer(state.stability_timer_ref)
      %{state | stability_timer_ref: nil}
    else
      state
    end
  end

  defp schedule_reconnect_with_circuit_check(state) do
    case CircuitBreaker.get_state({state.profile, state.chain_name, state.endpoint.id, :ws}) do
      %{state: :open} ->
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
          "ws:conn:#{state.profile}:#{state.chain_name}",
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
          "ws:conn:#{state.profile}:#{state.chain_name}",
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
          "ws:conn:#{state.profile}:#{state.chain_name}",
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
      "ws:subs:#{state.profile}:#{state.chain_name}",
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
        "ws:conn:#{state.profile}:#{state.chain_name}",
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

  # WebSocket close codes that indicate graceful/expected disconnection
  # These should NOT trigger circuit breaker penalties:
  # - 1000: Normal closure (clean shutdown)
  # - 1001: Going away (server shutting down, browser navigating away)
  # - 1012: Service restart (server restarting, will be back soon)
  #
  # Close codes that SHOULD trigger penalties (not in this list):
  # - 1002: Protocol error
  # - 1003: Unsupported data (sometimes used for rate limits)
  # - 1006: Abnormal closure (no close frame received)
  # - 1008: Policy violation (often rate limit or connection limit exceeded)
  # - 1011: Server error
  # - 1013: Try again later (explicit rate limiting)
  defp graceful_close_code?(code) when code in [1000, 1001, 1012], do: true
  defp graceful_close_code?(_code), do: false

  # Generate unique connection ID for tracking connection instances
  # Used to detect stale subscriptions after reconnect
  defp generate_connection_id do
    "conn_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp via_name(profile, chain, provider_id) do
    {:via, Registry, {Lasso.Registry, {:ws_conn, profile, chain, provider_id}}}
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

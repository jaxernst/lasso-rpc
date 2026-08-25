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
  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.Core.Support.{ErrorClassifier, ErrorNormalizer}
  alias Lasso.Core.Transport.UpstreamResponse
  alias Lasso.Core.Transport.UpstreamResponse.Validated
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.{Catalog, InstanceState}
  alias Lasso.RPC.Response
  alias Lasso.RPC.Transport.WebSocket.{Client, Endpoint, Handler}

  @reconnect_log_threshold 5
  @shared_profile "__shared__"

  # Spread initial WS connection attempts across this window at boot to avoid a
  # thundering herd of simultaneous handshakes against the same upstream CDN
  # (Cloudflare in front of most providers will rate-limit a synchronized burst).
  # Configurable so tests can disable jitter; defaults to 3s in dev/prod.
  @default_startup_jitter_ms 3_000
  @default_transport_pending_limit 256
  @default_send_cleanup_ms 100
  @max_diagnostic_count 9_223_372_036_854_775_807

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
    instance_id = endpoint_instance_id(endpoint)

    GenServer.start_link(__MODULE__, endpoint, name: via_instance_name(instance_id))
  end

  @doc """
  Starts/returns the shared WebSocket connection for an instance_id.
  """
  @spec start_shared_link(String.t()) :: GenServer.on_start()
  def start_shared_link(instance_id) when is_binary(instance_id) do
    case catalog_get_with_retry(instance_id) do
      {:ok, instance} ->
        endpoint = %Endpoint{
          profile: @shared_profile,
          id: instance_id,
          name:
            get_in(instance, [:canonical_config, :name]) ||
              "Shared WebSocket #{instance_id}",
          ws_url: instance.ws_url,
          headers: Map.get(instance, :headers, []),
          chain_id: instance.chain_id
        }

        GenServer.start_link(__MODULE__, endpoint, name: via_instance_name(instance_id))

      {:error, reason} ->
        Logger.warning(
          "Cannot start shared WS connection for #{instance_id}: catalog lookup failed (#{inspect(reason)})"
        )

        {:error, reason}
    end
  end

  @doc """
  Gets the current connection status.

  ## Examples

      iex> Lasso.RPC.Transport.WebSocket.Connection.status("ethereum:ethereum_ws")
      %{connected: true, endpoint_id: "ethereum_ws", reconnect_attempts: 0}
  """
  @spec status(String.t()) :: map()
  def status(instance_id) when is_binary(instance_id) do
    GenServer.call(via_instance_name(instance_id), :status)
  end

  # Server Callbacks

  @impl true
  def init(%Endpoint{} = endpoint) do
    Process.flag(:trap_exit, true)

    instance_id = endpoint_instance_id(endpoint)

    state = %{
      endpoint: endpoint,
      profile: endpoint.profile,
      instance_id: instance_id,
      connection: nil,
      connected: false,
      reconnect_attempts: 0,
      pending_requests: %{},
      transport_pending: %{},
      control_sends: %{},
      transport_pending_limit: transport_pending_limit(),
      transport_diagnostics: %{},
      heartbeat_ref: nil,
      reconnect_ref: nil,
      stability_timer_ref: nil,
      connection_stable: false,
      connection_id: nil
    }

    write_ws_status(state.instance_id, :reconnecting, state.reconnect_attempts)

    # Stagger the initial connection attempt with a random delay so we don't
    # synchronize with sibling WS connections to the same CDN at boot. When the
    # jitter window is 0 (e.g. in tests) we connect immediately.
    case startup_jitter_ms() do
      0 ->
        {:ok, state, {:continue, :connect}}

      max ->
        Process.send_after(self(), :initial_connect, :rand.uniform(max))
        {:ok, state}
    end
  end

  @doc false
  @spec transport_snapshot(String.t(), timeout()) ::
          {:ok, {pid(), term()}} | {:error, :not_connected}
  def transport_snapshot(instance_id, timeout_ms) do
    GenServer.call(via_instance_name(instance_id), :transport_snapshot, timeout_ms)
  end

  @doc false
  @spec authorize_transport(
          String.t(),
          String.t(),
          pid(),
          integer(),
          binary(),
          timeout()
        ) ::
          {:ok, {pid(), term(), reference()}}
          | {:error,
             :authorization_unknown
             | :capacity
             | :cancelled
             | :deadline
             | :duplicate_transport_id
             | :invalid_transport_id
             | :not_connected}
  def authorize_transport(
        instance_id,
        transport_id,
        owner,
        deadline_us,
        encoded,
        timeout_ms
      ) do
    GenServer.call(
      via_instance_name(instance_id),
      {:authorize_transport, transport_id, owner, deadline_us, encoded},
      timeout_ms
    )
  catch
    :exit, _reason -> {:error, :authorization_unknown}
  end

  @doc false
  @spec register_transport(String.t(), {pid(), term()}, term(), pid(), integer(), timeout()) ::
          {:ok, reference()}
          | {:error,
             :capacity
             | :deadline
             | :duplicate_transport_id
             | :invalid_transport_id
             | :stale_connection}
  def register_transport(instance_id, snapshot, transport_id, owner, deadline_us, timeout_ms) do
    GenServer.call(
      via_instance_name(instance_id),
      {:register_transport, snapshot, transport_id, owner, deadline_us},
      timeout_ms
    )
  end

  @doc false
  @spec queue_transport(
          String.t(),
          term(),
          term(),
          reference(),
          binary(),
          timeout()
        ) :: :ok | {:error, :cancelled | :deadline | :queue_unknown | :stale_connection}
  def queue_transport(instance_id, transport_id, generation, token, encoded, timeout_ms) do
    GenServer.call(
      via_instance_name(instance_id),
      {:queue_transport, transport_id, generation, token, encoded},
      timeout_ms
    )
  catch
    :exit, _reason -> {:error, :queue_unknown}
  end

  @doc false
  @spec cancel_transport(String.t(), term(), term(), reference()) :: :ok
  def cancel_transport(instance_id, transport_id, generation, token) do
    GenServer.cast(
      via_instance_name(instance_id),
      {:cancel_transport, transport_id, generation, token}
    )
  end

  defp startup_jitter_ms do
    Application.get_env(:lasso, :ws_startup_jitter_ms, @default_startup_jitter_ms)
  end

  defp transport_pending_limit do
    case Application.get_env(
           :lasso,
           :ws_transport_pending_limit,
           @default_transport_pending_limit
         ) do
      limit when is_integer(limit) and limit > 0 -> limit
      _invalid -> @default_transport_pending_limit
    end
  end

  @doc """
  Performs a unary JSON-RPC request over the WebSocket connection with response correlation.

  The connection is identified by `instance_id`.

  Returns {:ok, result} | {:error, reason}.
  """
  @spec request(
          String.t(),
          String.t(),
          list() | map() | nil,
          non_neg_integer(),
          String.t() | nil
        ) ::
          {:ok, Response.Success.t()} | {:error, JError.t()}
  def request(target, method, params, timeout_ms \\ 30_000, request_id \\ nil)

  def request(instance_id, method, params, timeout_ms, request_id) when is_binary(instance_id) do
    GenServer.call(
      via_instance_name(instance_id),
      {:request, method, params, timeout_ms, request_id},
      timeout_ms + 2_000
    )
  catch
    :exit, {:noproc, _} ->
      {:error,
       JError.new(-32_000, "WebSocket connection not available",
         provider_id: instance_id,
         retriable?: true,
         breaker_penalty?: false,
         category: :local_capacity_rejection
       )}

    :exit, {:timeout, _} ->
      {:error,
       JError.new(-32_000, "WebSocket request timeout",
         provider_id: instance_id,
         retriable?: true,
         breaker_penalty?: true,
         category: :timeout
       )}

    :exit, _reason ->
      {:error,
       JError.new(-32_000, "WebSocket connection unavailable",
         provider_id: instance_id,
         retriable?: true,
         breaker_penalty?: false,
         category: :local_capacity_rejection
       )}
  end

  @impl true
  def handle_continue(:connect, state) do
    breaker_id = {state.instance_id, :ws}

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
            chain_id: state.endpoint.chain_id,
            error_code: jerr.code,
            error_message: jerr.message,
            retriable: true,
            will_reconnect: true
          }
        )

        broadcast_conn_event(state, fn provider_id ->
          {:connection_error, provider_id, jerr}
        end)

        state = schedule_reconnect(state)
        {:noreply, state}

      %{state: cb_state} when cb_state in [:closed, :half_open] ->
        maybe_connect_with_rate_limit_check(state, breaker_id)

      {:error, _reason} ->
        maybe_connect_with_rate_limit_check(state, breaker_id)
    end
  end

  @max_rate_limit_delay_ms 300_000

  defp maybe_connect_with_rate_limit_check(state, breaker_id) do
    case InstanceState.read_rate_limit(state.instance_id, :http) do
      %{rate_limited: true, remaining_ms: remaining} ->
        delay = remaining |> max(30_000) |> min(@max_rate_limit_delay_ms)

        Logger.info(
          "HTTP rate-limited for #{state.endpoint.id}, delaying WS reconnect by #{delay}ms"
        )

        state = schedule_reconnect_rate_limited(state, delay)
        {:noreply, state}

      _ ->
        do_connect(state, breaker_id)
    end
  end

  defp do_connect(state, breaker_id) do
    ws_connection_pid = self()
    connection_generation = generate_connection_id()

    case connect_to_websocket(state.endpoint, ws_connection_pid, connection_generation) do
      {:ok, connection} ->
        # Success - don't report to circuit breaker yet!
        # Recovery will be signaled when connection proves stable (5s)
        state = %{
          state
          | connection: connection,
            connection_id: connection_generation
        }

        {:noreply, state}

      {:error, error} ->
        jerr = normalize_connect_error(error, state.endpoint.id)

        Logger.warning(
          "Failed to connect to #{state.endpoint.name} (WebSocket): #{jerr.message} (code=#{inspect(jerr.code)})"
        )

        if jerr.breaker_penalty? do
          _ = CircuitBreaker.report_external_bounded(breaker_id, {:error, jerr})
        end

        :telemetry.execute(
          [:lasso, :websocket, :connection_failed],
          %{},
          %{
            provider_id: state.endpoint.id,
            chain_id: state.endpoint.chain_id,
            error_code: jerr.code,
            error_message: jerr.message,
            retriable: jerr.retriable?,
            will_reconnect: jerr.retriable?
          }
        )

        broadcast_conn_event(state, fn provider_id ->
          {:connection_error, provider_id, jerr}
        end)

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

    case Jason.encode(message) do
      {:ok, encoded_message} ->
        caller_pid = elem(from, 0)

        dispatch_result = if Process.alive?(caller_pid), do: :ok, else: {:error, :cancelled}

        handle_authorized_request(
          dispatch_result,
          encoded_message,
          from,
          method,
          request_id,
          timeout_ms,
          state
        )

      {:error, reason} ->
        jerr =
          ErrorNormalizer.normalize({:encode_error, Exception.message(reason)},
            provider_id: state.endpoint.id,
            transport: :ws
          )

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
    legacy_pending = map_size(state.pending_requests)
    transport_pending = map_size(state.transport_pending)
    control_sends = map_size(state.control_sends)

    status = %{
      connected: state.connected,
      connection_stable: state.connection_stable,
      endpoint_id: state.endpoint.id,
      reconnect_attempts: state.reconnect_attempts,
      pending_requests: legacy_pending + transport_pending + control_sends,
      legacy_pending_requests: legacy_pending,
      transport_pending_requests: transport_pending,
      transport_tombstones: count_send_state(state.transport_pending, :tombstone),
      queued_control_sends: control_sends,
      transport_pending_limit: state.transport_pending_limit,
      transport_diagnostics: state.transport_diagnostics
    }

    {:reply, status, state}
  end

  def handle_call(:transport_snapshot, _from, %{connected: true} = state) do
    {:reply, {:ok, {state.connection, state.connection_id}}, state}
  end

  def handle_call(:transport_snapshot, _from, state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call(
        {:authorize_transport, transport_id, owner, deadline_us, encoded},
        _from,
        %{connected: true, connection: connection, connection_id: generation} = state
      )
      when is_binary(encoded) and is_pid(owner) do
    now_us = System.monotonic_time(:microsecond)

    cond do
      now_us >= deadline_us ->
        {:reply, {:error, :deadline}, state}

      not Process.alive?(owner) ->
        {:reply, {:error, :cancelled}, state}

      not UpstreamResponse.transport_id?(transport_id) ->
        {:reply, {:error, :invalid_transport_id}, state}

      Map.has_key?(state.transport_pending, transport_id) ->
        {:reply, {:error, :duplicate_transport_id}, state}

      send_capacity_used(state) >= state.transport_pending_limit ->
        {:reply, {:error, :capacity}, state}

      true ->
        token = make_ref()
        cancel_latch = :atomics.new(1, signed: false)
        monitor = Process.monitor(owner)

        timer =
          Process.send_after(
            self(),
            {:transport_timeout, transport_id, generation, token},
            ceil_milliseconds(deadline_us - now_us)
          )

        pending = %{
          owner: owner,
          owner_monitor: monitor,
          token: token,
          timer: timer,
          generation: generation,
          deadline_us: deadline_us,
          connection: connection,
          cancel_latch: cancel_latch,
          send_state: :queued
        }

        next_state =
          %{state | transport_pending: Map.put(state.transport_pending, transport_id, pending)}

        case cast_send(
               next_state,
               {:transport, transport_id, token},
               deadline_us,
               cancel_latch,
               {:text, encoded}
             ) do
          :ok ->
            {:reply, {:ok, {connection, generation, token}}, next_state}

          {:error, _reason} ->
            cleanup_send_entry(pending)
            {:reply, {:error, :cancelled}, state}
        end
    end
  end

  def handle_call(
        {:authorize_transport, _transport_id, _owner, _deadline, _encoded},
        _from,
        state
      ),
      do: {:reply, {:error, :not_connected}, state}

  def handle_call(
        {:register_transport, {connection, generation}, transport_id, owner, deadline_us},
        _from,
        %{connected: true, connection: connection, connection_id: generation} = state
      ) do
    remaining_us = deadline_us - System.monotonic_time(:microsecond)

    cond do
      remaining_us <= 0 ->
        {:reply, {:error, :deadline}, state}

      not transport_id_for_generation?(transport_id, generation) ->
        {:reply, {:error, :invalid_transport_id}, state}

      Map.has_key?(state.transport_pending, transport_id) ->
        {:reply, {:error, :duplicate_transport_id}, state}

      send_capacity_used(state) >= state.transport_pending_limit ->
        {:reply, {:error, :capacity}, state}

      true ->
        token = make_ref()
        cancel_latch = :atomics.new(1, signed: false)
        monitor = Process.monitor(owner)
        timeout_ms = ceil_milliseconds(remaining_us)

        timer =
          Process.send_after(
            self(),
            {:transport_timeout, transport_id, generation, token},
            timeout_ms
          )

        pending = %{
          owner: owner,
          owner_monitor: monitor,
          token: token,
          timer: timer,
          generation: generation,
          deadline_us: deadline_us,
          connection: connection,
          cancel_latch: cancel_latch,
          send_state: :registered
        }

        {:reply, {:ok, token},
         %{state | transport_pending: Map.put(state.transport_pending, transport_id, pending)}}
    end
  end

  def handle_call({:register_transport, _snapshot, _id, _owner, _deadline}, _from, state),
    do: {:reply, {:error, :stale_connection}, state}

  def handle_call(
        {:queue_transport, transport_id, generation, token, encoded},
        _from,
        %{connected: true, connection_id: generation} = state
      ) do
    now_us = System.monotonic_time(:microsecond)

    case Map.get(state.transport_pending, transport_id) do
      %{generation: ^generation, token: ^token, send_state: :registered} = pending ->
        cond do
          now_us >= pending.deadline_us ->
            state = cancel_registered_transport(state, transport_id, pending)
            {:reply, {:error, :deadline}, state}

          not Process.alive?(pending.owner) ->
            state = cancel_registered_transport(state, transport_id, pending)
            {:reply, {:error, :cancelled}, state}

          true ->
            pending = %{pending | send_state: :queued}
            state = put_in(state, [:transport_pending, transport_id], pending)

            case cast_send(
                   state,
                   {:transport, transport_id, token},
                   pending.deadline_us,
                   pending.cancel_latch,
                   {:text, encoded}
                 ) do
              :ok ->
                {:reply, :ok, state}

              {:error, _reason} ->
                state = cancel_registered_transport(state, transport_id, pending)
                {:reply, {:error, :cancelled}, state}
            end
        end

      _missing_or_stale ->
        {:reply, {:error, :cancelled}, state}
    end
  end

  def handle_call({:queue_transport, _id, _generation, _token, _encoded}, _from, state),
    do: {:reply, {:error, :stale_connection}, state}

  @impl true
  def handle_cast({:cancel_transport, transport_id, generation, token}, state) do
    {:noreply, cancel_transport_by_key(state, transport_id, generation, token)}
  end

  defp handle_authorized_request(
         :ok,
         encoded_message,
         from,
         method,
         request_id,
         timeout_ms,
         state
       ) do
    caller_pid = elem(from, 0)

    cond do
      not Process.alive?(caller_pid) ->
        {:reply, {:error, cancelled_request_error(state)}, state}

      send_capacity_used(state) >= state.transport_pending_limit ->
        {:reply, {:error, capacity_error(state)}, state}

      Map.has_key?(state.pending_requests, request_id) ->
        {:reply, {:error, capacity_error(state)}, state}

      true ->
        sent_at = System.monotonic_time(:microsecond)
        deadline_us = sent_at + timeout_ms * 1_000
        token = make_ref()
        cancel_latch = :atomics.new(1, signed: false)
        owner_monitor = Process.monitor(caller_pid)

        timer =
          Process.send_after(
            self(),
            {:request_timeout, request_id, state.connection_id, token},
            timeout_ms
          )

        pending = %{
          from: from,
          owner: caller_pid,
          owner_monitor: owner_monitor,
          timer: timer,
          sent_at: sent_at,
          method: method,
          timeout_ms: timeout_ms,
          token: token,
          generation: state.connection_id,
          connection: state.connection,
          deadline_us: deadline_us,
          cancel_latch: cancel_latch,
          send_state: :queued
        }

        state = put_in(state, [:pending_requests, request_id], pending)

        case cast_send(
               state,
               {:legacy, request_id, token},
               deadline_us,
               cancel_latch,
               {:text, encoded_message}
             ) do
          :ok ->
            {:noreply, state}

          {:error, reason} ->
            state = remove_legacy_pending(state, request_id, pending)

            {:reply,
             {:error,
              ErrorNormalizer.normalize(reason,
                provider_id: state.endpoint.id,
                transport: :ws
              )}, state}
        end
    end
  end

  defp handle_authorized_request(
         {:error, :cancelled},
         _encoded_message,
         _from,
         _method,
         _request_id,
         _timeout_ms,
         state
       ) do
    jerr =
      JError.new(-32_008, "WebSocket request cancelled before dispatch",
        provider_id: state.endpoint.id,
        retriable?: true,
        breaker_penalty?: false,
        category: :local_capacity_rejection
      )

    {:reply, {:error, jerr}, state}
  end

  @impl true
  def handle_info(
        {:ws_send_decision, connection, generation, {:transport, transport_id, token}, decision,
         decided_at_us},
        %{connection: connection, connection_id: generation} = state
      ) do
    case Map.get(state.transport_pending, transport_id) do
      %{generation: ^generation, token: ^token, send_state: :queued} = pending ->
        case decision do
          :accepted ->
            send(pending.owner, {:ws_transport_send_accepted, token, generation, decided_at_us})

            {:noreply,
             put_in(state, [:transport_pending, transport_id], %{pending | send_state: :accepted})}

          {:rejected, reason} ->
            send(pending.owner, {:ws_transport_send_rejected, token, generation, reason})
            {:noreply, remove_transport_entry(state, transport_id, pending)}
        end

      %{generation: ^generation, token: ^token, send_state: :tombstone} = pending ->
        case decision do
          :accepted -> {:noreply, state}
          {:rejected, _reason} -> {:noreply, remove_transport_entry(state, transport_id, pending)}
        end

      _missing_or_stale ->
        {:noreply, increment_transport_diagnostic(state, :stale_send_decision)}
    end
  end

  def handle_info(
        {:ws_send_decision, connection, generation, {:legacy, request_id, token}, decision,
         _decided_at_us},
        %{connection: connection, connection_id: generation} = state
      ) do
    case Map.get(state.pending_requests, request_id) do
      %{generation: ^generation, token: ^token, send_state: :queued} = pending ->
        case decision do
          :accepted ->
            :telemetry.execute(
              [:lasso, :websocket, :request, :sent],
              %{},
              %{
                provider_id: state.endpoint.id,
                method: pending.method,
                request_id: request_id,
                timeout_ms: pending.timeout_ms
              }
            )

            {:noreply,
             put_in(state, [:pending_requests, request_id], %{pending | send_state: :accepted})}

          {:rejected, reason} ->
            GenServer.reply(
              pending.from,
              {:error,
               ErrorNormalizer.normalize(reason,
                 provider_id: state.endpoint.id,
                 transport: :ws
               )}
            )

            {:noreply, remove_legacy_pending(state, request_id, pending)}
        end

      %{generation: ^generation, token: ^token, send_state: :tombstone} = pending ->
        case decision do
          :accepted -> {:noreply, state}
          {:rejected, _reason} -> {:noreply, remove_legacy_pending(state, request_id, pending)}
        end

      _missing_or_stale ->
        {:noreply, increment_transport_diagnostic(state, :stale_send_decision)}
    end
  end

  def handle_info(
        {:ws_send_decision, connection, generation, {:control, token}, decision, _decided_at_us},
        %{connection: connection, connection_id: generation} = state
      ) do
    case Map.get(state.control_sends, token) do
      %{generation: ^generation} = control ->
        case {control.send_state, decision} do
          {:tombstone, :accepted} ->
            {:noreply, state}

          {:tombstone, {:rejected, _reason}} ->
            {:noreply, remove_control_send(state, token, control)}

          {_send_state, :accepted} ->
            {:noreply, put_in(state, [:control_sends, token], %{control | send_state: :accepted})}

          {_send_state, {:rejected, _reason}} ->
            state = remove_control_send(state, token, control)
            {:noreply, handle_control_decision(state, control, decision)}
        end

      _missing_or_stale ->
        {:noreply, increment_transport_diagnostic(state, :stale_send_decision)}
    end
  end

  def handle_info({:ws_send_decision, _connection, _generation, _key, _decision, _at}, state) do
    {:noreply, increment_transport_diagnostic(state, :stale_send_decision)}
  end

  def handle_info(
        {:ws_send_written, connection, generation, {:transport, transport_id, token},
         written_at_us},
        %{connection: connection, connection_id: generation} = state
      ) do
    case Map.get(state.transport_pending, transport_id) do
      %{generation: ^generation, token: ^token, send_state: :accepted} = pending ->
        send(pending.owner, {:ws_transport_send_confirmed, token, generation, written_at_us})

        {:noreply,
         put_in(state, [:transport_pending, transport_id], %{pending | send_state: :confirmed})}

      %{generation: ^generation, token: ^token, send_state: :tombstone} = pending ->
        {:noreply, remove_transport_entry(state, transport_id, pending)}

      _missing_or_stale ->
        {:noreply, increment_transport_diagnostic(state, :stale_send_confirmation)}
    end
  end

  def handle_info(
        {:ws_send_written, connection, generation, {:legacy, request_id, token}, _written_at_us},
        %{connection: connection, connection_id: generation} = state
      ) do
    case Map.get(state.pending_requests, request_id) do
      %{generation: ^generation, token: ^token, send_state: :accepted} = pending ->
        {:noreply,
         put_in(state, [:pending_requests, request_id], %{pending | send_state: :confirmed})}

      %{generation: ^generation, token: ^token, send_state: :tombstone} = pending ->
        {:noreply, remove_legacy_pending(state, request_id, pending)}

      _missing_or_stale ->
        {:noreply, increment_transport_diagnostic(state, :stale_send_confirmation)}
    end
  end

  def handle_info(
        {:ws_send_written, connection, generation, {:control, token}, _written_at_us},
        %{connection: connection, connection_id: generation} = state
      ) do
    case Map.get(state.control_sends, token) do
      %{generation: ^generation, send_state: :accepted} = control ->
        state = remove_control_send(state, token, control)
        {:noreply, handle_control_decision(state, control, :accepted)}

      %{generation: ^generation, send_state: :tombstone} = control ->
        {:noreply, remove_control_send(state, token, control)}

      _missing_or_stale ->
        {:noreply, increment_transport_diagnostic(state, :stale_send_confirmation)}
    end
  end

  def handle_info({:ws_send_written, _connection, _generation, _key, _at}, state) do
    {:noreply, increment_transport_diagnostic(state, :stale_send_confirmation)}
  end

  def handle_info(:initial_connect, state), do: handle_continue(:connect, state)

  def handle_info(
        {:ws_connected, connection, connection_generation},
        %{connection: connection, connection_id: connection_generation} = state
      ) do
    # NOTE: We intentionally do NOT call signal_recovery here.
    # Recovery is signaled only after the connection proves stable (see {:connection_stable}).
    # This allows circuit breaker failures to accumulate when providers accept connections
    # but immediately drop them (e.g., dRPC connection limits).

    connection_id = connection_generation

    :telemetry.execute(
      [:lasso, :websocket, :connected],
      %{},
      %{
        provider_id: state.endpoint.id,
        chain_id: state.endpoint.chain_id,
        reconnect_attempt: state.reconnect_attempts,
        connection_id: connection_id
      }
    )

    # Mark as connected but DON'T reset reconnect_attempts yet.
    # Schedule stability timer - only reset attempts after connection proves stable.
    # This prevents thrashing when providers drop connections immediately after connect.
    state = %{state | connected: true}

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
        broadcast_conn_event(state, fn provider_id ->
          {:ws_stable, provider_id}
        end)

        CircuitBreaker.signal_recovery_cast({state.instance_id, :ws})

        %{state | reconnect_attempts: 0, connection_stable: true}
      else
        schedule_stability_check(state)
      end

    broadcast_conn_event(state, fn provider_id ->
      {:ws_connected, provider_id, connection_id}
    end)

    write_ws_status(state.instance_id, :connected, state.reconnect_attempts)

    state = schedule_heartbeat(state)
    {:noreply, state}
  end

  def handle_info({:ws_connected, _connection, _connection_generation}, state) do
    {:noreply, increment_transport_diagnostic(state, :stale_generation)}
  end

  def handle_info(
        {:ws_message, connection, generation, parsed, raw_bytes, frame_received_at, validated_at},
        %{connection: connection, connection_id: generation} = state
      ) do
    {:noreply,
     route_ws_message(
       state,
       connection,
       generation,
       parsed,
       raw_bytes,
       frame_received_at,
       validated_at
     )}
  end

  def handle_info(
        {:ws_message, _connection, _generation, _parsed, _raw_bytes, _received_at, _validated_at},
        state
      ) do
    {:noreply, increment_transport_diagnostic(state, :stale_generation)}
  end

  def handle_info({:ws_message, _raw_bytes, _frame_received_at}, state) do
    {:noreply, increment_transport_diagnostic(state, :unstamped_frame)}
  end

  def handle_info({:transport_timeout, transport_id, generation, token}, state) do
    case Map.get(state.transport_pending, transport_id) do
      %{generation: ^generation, token: ^token, send_state: :tombstone} ->
        {:noreply, state}

      %{generation: ^generation, token: ^token} = pending ->
        now_us = System.monotonic_time(:microsecond)

        if now_us < pending.deadline_us do
          timer =
            Process.send_after(
              self(),
              {:transport_timeout, transport_id, generation, token},
              ceil_milliseconds(pending.deadline_us - now_us)
            )

          updated = %{pending | timer: timer}

          {:noreply,
           %{state | transport_pending: Map.put(state.transport_pending, transport_id, updated)}}
        else
          case take_eligible_transport_frame(pending, transport_id) do
            {:ok, parsed, raw_bytes, frame_received_at, validated_at} ->
              {:noreply,
               route_ws_message(
                 state,
                 pending.connection,
                 generation,
                 parsed,
                 raw_bytes,
                 frame_received_at,
                 validated_at
               )}

            :none ->
              send(pending.owner, {:ws_transport_timeout, token, generation})
              {:noreply, retire_transport_send(state, transport_id, pending)}
          end
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state) do
    state =
      Enum.reduce(state.transport_pending, state, fn {id, entry}, current_state ->
        if entry.owner_monitor == monitor and entry.owner == owner do
          retire_transport_send(current_state, id, entry)
        else
          current_state
        end
      end)

    state =
      Enum.reduce(state.pending_requests, state, fn {id, entry}, current_state ->
        if entry.owner_monitor == monitor and entry.owner == owner do
          retire_legacy_send(current_state, id, entry)
        else
          current_state
        end
      end)

    {:noreply, state}
  end

  def handle_info({:ws_error, error}, state) do
    Logger.error("WebSocket error: #{inspect(error)}")

    jerr =
      ErrorNormalizer.normalize(error,
        provider_id: state.endpoint.id,
        context: :transport,
        transport: :ws
      )

    broadcast_conn_event(state, fn provider_id ->
      {:connection_error, provider_id, jerr}
    end)

    {:noreply, state}
  end

  def handle_info(
        {:ws_disconnect_event, connection, generation, disconnect_info},
        %{connection: connection, connection_id: generation} = state
      ) do
    handle_info(disconnect_info, state)
  end

  def handle_info({:ws_disconnect_event, _connection, _generation, _disconnect_info}, state) do
    {:noreply, increment_transport_diagnostic(state, :stale_generation)}
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

    had_pending = active_pending?(state)

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
    pending_count = total_pending_count(state)
    state = cleanup_pending_requests(state, jerr)
    state = %{state | connected: false, connection: nil, connection_stable: false}

    # Emit telemetry event
    :telemetry.execute(
      [:lasso, :websocket, :disconnected],
      %{},
      %{
        provider_id: state.endpoint.id,
        chain_id: state.endpoint.chain_id,
        reason: reason,
        code: code,
        had_active_traffic: had_pending,
        was_stable: was_stable,
        unexpected: not is_graceful,
        pending_request_count: pending_count
      }
    )

    jerr_with_penalty = %{jerr | breaker_penalty?: should_penalize and jerr.breaker_penalty?}

    circuit_state =
      if should_penalize do
        breaker_id = {state.instance_id, :ws}

        CircuitBreaker.report_external_bounded(breaker_id, {:error, jerr_with_penalty})
      else
        :not_penalized
      end

    Logger.debug("Circuit breaker state after close frame",
      provider_id: state.endpoint.id,
      circuit_state: circuit_state,
      was_penalized: should_penalize
    )

    broadcast_conn_event(state, fn provider_id ->
      {:ws_closed, provider_id, code, jerr_with_penalty}
    end)

    state = if jerr.retriable?, do: schedule_reconnect_with_circuit_check(state), else: state
    write_ws_status(state.instance_id, :disconnected, state.reconnect_attempts)
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

      had_pending = active_pending?(state)

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
      pending_count = total_pending_count(state)
      state = cleanup_pending_requests(state, jerr)
      state = %{state | connected: false, connection: nil, connection_stable: false}

      # Emit telemetry event
      :telemetry.execute(
        [:lasso, :websocket, :disconnected],
        %{},
        %{
          provider_id: state.endpoint.id,
          chain_id: state.endpoint.chain_id,
          reason: reason,
          had_active_traffic: had_pending,
          was_stable: false,
          unexpected: true,
          pending_request_count: pending_count
        }
      )

      # Unexpected disconnects always warrant circuit breaker penalty
      jerr_with_penalty = %{jerr | breaker_penalty?: true}

      Logger.debug("Enqueuing circuit breaker failure",
        provider_id: state.endpoint.id,
        breaker_penalty: jerr_with_penalty.breaker_penalty?
      )

      breaker_id = {state.instance_id, :ws}

      circuit_state =
        CircuitBreaker.report_external_bounded(breaker_id, {:error, jerr_with_penalty})

      Logger.debug("Circuit breaker state after disconnect",
        provider_id: state.endpoint.id,
        circuit_state: circuit_state
      )

      broadcast_conn_event(state, fn provider_id ->
        {:ws_disconnected, provider_id, jerr_with_penalty}
      end)

      state = schedule_reconnect_with_circuit_check(state)
      write_ws_status(state.instance_id, :disconnected, state.reconnect_attempts)
      {:noreply, state}
    rescue
      e ->
        Logger.error("Error in ws_disconnect error handler: #{inspect(e)}")
        reraise e, __STACKTRACE__
    end
  end

  def handle_info(
        {:heartbeat},
        %{connected: true, endpoint: endpoint} = state
      ) do
    case enqueue_control_send(state, :heartbeat, :ping, control_send_timeout_ms()) do
      {:ok, state} ->
        {:noreply, %{state | heartbeat_ref: nil}}

      {:error, reason, state} ->
        :telemetry.execute(
          [:lasso, :websocket, :heartbeat, :failed],
          %{},
          %{provider_id: endpoint.id, reason: reason}
        )

        {:noreply, schedule_heartbeat(%{state | heartbeat_ref: nil})}
    end
  end

  def handle_info({:heartbeat}, %{connected: false} = state) do
    {:noreply, state}
  end

  def handle_info({:control_send_timeout, token, generation}, state) do
    case Map.get(state.control_sends, token) do
      %{generation: ^generation} = control ->
        _ = cancel_latch(control.cancel_latch)
        control = %{control | send_state: :tombstone}
        state = put_in(state, [:control_sends, token], control)

        if is_pid(state.connection) do
          Process.exit(state.connection, :kill)
        end

        {:noreply, state}

      _missing_or_stale ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:send_cleanup_expired, connection, generation, send_key, token, cleanup_expiry_us},
        state
      ) do
    {:noreply,
     expire_send_tombstone(
       state,
       connection,
       generation,
       send_key,
       token,
       cleanup_expiry_us
     )}
  end

  def handle_info({:request_timeout, request_id, generation, token}, state) do
    case Map.get(state.pending_requests, request_id) do
      nil ->
        {:noreply, state}

      %{generation: ^generation, token: ^token, send_state: :tombstone} ->
        {:noreply, state}

      %{generation: ^generation, token: ^token} = pending ->
        now_us = System.monotonic_time(:microsecond)

        if now_us < pending.deadline_us do
          timer =
            Process.send_after(
              self(),
              {:request_timeout, request_id, generation, token},
              ceil_milliseconds(pending.deadline_us - now_us)
            )

          {:noreply, put_in(state, [:pending_requests, request_id, :timer], timer)}
        else
          timeout_ms = div(now_us - pending.sent_at, 1000)

          :telemetry.execute(
            [:lasso, :websocket, :request, :timeout],
            %{timeout_ms: timeout_ms},
            %{
              provider_id: state.endpoint.id,
              method: pending.method,
              request_id: request_id
            }
          )

          GenServer.reply(
            pending.from,
            {:error,
             JError.new(-32_000, "WebSocket request timeout",
               category: :timeout,
               retriable?: true,
               provider_id: state.endpoint.id
             )}
          )

          {:noreply, retire_legacy_send(state, request_id, pending)}
        end

      _stale_timer ->
        {:noreply, state}
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
    Logger.log(
      reconnect_log_level(state.reconnect_attempts),
      "Reconnecting to #{state.endpoint.name} (attempt #{state.reconnect_attempts}, provider: #{state.endpoint.id})"
    )

    # Clear the reconnect timer ref since it's already fired
    state = %{state | reconnect_ref: nil}
    {:noreply, state, {:continue, :connect}}
  end

  # Connection has been stable for the grace period - now safe to reset reconnect_attempts
  # and signal WS circuit breaker recovery
  def handle_info({:connection_stable}, %{connected: true} = state) do
    Logger.debug(
      "Connection stable, resetting reconnect attempts (provider: #{state.endpoint.id})"
    )

    broadcast_conn_event(state, fn provider_id ->
      {:ws_stable, provider_id}
    end)

    CircuitBreaker.signal_recovery_cast({state.instance_id, :ws})

    {:noreply,
     %{state | reconnect_attempts: 0, stability_timer_ref: nil, connection_stable: true}}
  end

  # Connection was lost before stability timer fired - ignore
  def handle_info({:connection_stable}, state) do
    {:noreply, %{state | stability_timer_ref: nil}}
  end

  # Catch client exits which occur before or after the typed disconnect event.
  def handle_info({:EXIT, pid, reason}, %{connection: pid, connected: true} = state) do
    Logger.debug("WebSocket client process exited",
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

    had_pending = active_pending?(state)

    jerr =
      ErrorNormalizer.normalize({:ws_exit, reason},
        provider_id: state.endpoint.id,
        transport: :ws
      )

    Logger.warning(
      "WebSocket client exited unexpectedly (via :EXIT): #{inspect(reason)}, " <>
        "was_stable=#{was_stable}, had_active_traffic=#{had_pending} (provider: #{state.endpoint.id})"
    )

    # Clean up pending requests
    pending_count = total_pending_count(state)
    state = cleanup_pending_requests(state, jerr)
    state = %{state | connected: false, connection: nil, connection_stable: false}

    :telemetry.execute(
      [:lasso, :websocket, :disconnected],
      %{},
      %{
        provider_id: state.endpoint.id,
        chain_id: state.endpoint.chain_id,
        reason: {:exit, reason},
        had_active_traffic: had_pending,
        was_stable: was_stable,
        unexpected: true,
        pending_request_count: pending_count
      }
    )

    # Always penalize circuit breaker for unexpected exits
    jerr_with_penalty = %{jerr | breaker_penalty?: true}
    breaker_id = {state.instance_id, :ws}

    circuit_state =
      CircuitBreaker.report_external_bounded(breaker_id, {:error, jerr_with_penalty})

    Logger.debug("Circuit breaker state after WebSocket client exit",
      provider_id: state.endpoint.id,
      circuit_state: circuit_state
    )

    broadcast_conn_event(state, fn provider_id ->
      {:ws_disconnected, provider_id, jerr_with_penalty}
    end)

    state = schedule_reconnect_with_circuit_check(state)
    write_ws_status(state.instance_id, :disconnected, state.reconnect_attempts)
    {:noreply, state}
  end

  # The typed disconnect event can be processed before the linked-process exit.
  def handle_info({:EXIT, pid, reason}, %{connection: pid, connected: false} = state) do
    Logger.debug("WebSocket client process exited (already disconnected)",
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

  # Rapid reconnects can leave an exit signal from an older client generation.
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
    terminated_error =
      JError.new(-32_000, "terminated", provider_id: state.endpoint.id, retriable?: false)

    broadcast_conn_event(state, fn provider_id ->
      {:ws_disconnected, provider_id, terminated_error}
    end)

    write_ws_status(state.instance_id, :disconnected, state.reconnect_attempts)

    :ok
  end

  # WebSocket event handlers - these are now handled by WSHandler
  # and communicated back via messages

  # Private functions

  defp handle_response_success(id, resp, state) do
    case Map.get(state.pending_requests, id) do
      nil ->
        {:noreply, state}

      %{send_state: :tombstone} = pending ->
        {:noreply, remove_legacy_pending(state, id, pending)}

      pending ->
        duration_ms = div(System.monotonic_time(:microsecond) - pending.sent_at, 1000)

        emit_completion_telemetry(state.endpoint.id, pending.method, id, :success, duration_ms)
        GenServer.reply(pending.from, {:ok, resp})

        {:noreply, remove_legacy_pending(state, id, pending)}
    end
  end

  defp handle_response_error(id, jerr, state) do
    case Map.get(state.pending_requests, id) do
      nil ->
        {:noreply, state}

      %{send_state: :tombstone} = pending ->
        {:noreply, remove_legacy_pending(state, id, pending)}

      pending ->
        duration_ms = div(System.monotonic_time(:microsecond) - pending.sent_at, 1000)

        %{category: category, retriable?: retriable?, breaker_penalty?: breaker_penalty?} =
          ErrorClassifier.classify(jerr.code, jerr.message,
            data: jerr.data,
            provider_id: state.endpoint.id,
            profile: state.endpoint.profile,
            chain_id: state.endpoint.chain_id
          )

        enriched = %{
          jerr
          | provider_id: state.endpoint.id,
            transport: :ws,
            category: category,
            retriable?: retriable?,
            breaker_penalty?: breaker_penalty?
        }

        emit_completion_telemetry(state.endpoint.id, pending.method, id, :error, duration_ms)
        GenServer.reply(pending.from, {:error, enriched})

        {:noreply, remove_legacy_pending(state, id, pending)}
    end
  end

  defp handle_notification(
         %Response.Notification{method: "eth_subscription"} = notification,
         state
       ) do
    sub_id = Response.Notification.subscription_id(notification)
    payload = Response.Notification.result(notification)
    received_at = System.monotonic_time(:millisecond)

    broadcast_subscription_event(state, sub_id, payload, received_at)

    {:noreply, state}
  end

  defp handle_notification(%Response.Notification{method: method}, state) do
    Logger.debug("Received unhandled notification method: #{method}",
      provider_id: state.endpoint.id
    )

    {:noreply, state}
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

  defp normalize_connect_error(%JError{} = jerr, _endpoint_id), do: jerr

  defp normalize_connect_error(other, endpoint_id),
    do: JError.from(other, provider_id: endpoint_id)

  defp connect_to_websocket(endpoint, parent_pid, connection_generation) do
    opts = [
      connection_id: endpoint.id,
      connection_generation: connection_generation,
      extra_headers: endpoint.headers
    ]

    case ws_client().start_link(
           endpoint.ws_url,
           Handler,
           %{
             endpoint: endpoint,
             parent: parent_pid,
             connection_generation: connection_generation
           },
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
    case Snapshot.lookup({state.instance_id, :ws}) do
      {:ok, %Snapshot{state: :open}} ->
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

        new_state = %{
          state
          | reconnect_attempts: state.reconnect_attempts + 1,
            reconnect_ref: ref
        }

        write_ws_status(new_state.instance_id, :reconnecting, new_state.reconnect_attempts)
        new_state

      _ ->
        # Circuit closed or half-open - use normal reconnect logic
        schedule_reconnect(state)
    end
  end

  defp schedule_reconnect_rate_limited(state, delay) do
    state = cancel_pending_reconnect(state)

    :telemetry.execute(
      [:lasso, :websocket, :reconnect_scheduled],
      %{delay_ms: delay, jitter_ms: 0},
      %{
        provider_id: state.endpoint.id,
        attempt: state.reconnect_attempts,
        max_attempts: state.endpoint.max_reconnect_attempts,
        reason: :rate_limited
      }
    )

    ref = Process.send_after(self(), {:reconnect}, delay)
    write_ws_status(state.instance_id, :reconnecting, state.reconnect_attempts)
    %{state | reconnect_ref: ref}
  end

  defp schedule_reconnect(state) do
    state = cancel_pending_reconnect(state)
    max_attempts = state.endpoint.max_reconnect_attempts

    if max_attempts == :infinity or state.reconnect_attempts < max_attempts do
      delay = reconnect_delay(state)
      jitter = if delay > 0, do: :rand.uniform(1000), else: 0
      total_delay = delay + jitter
      max_label = if max_attempts == :infinity, do: "", else: "/#{max_attempts}"

      Logger.log(
        reconnect_log_level(state.reconnect_attempts),
        "Scheduling reconnect for #{state.endpoint.name} (attempt #{state.reconnect_attempts + 1}#{max_label}) in #{total_delay}ms"
      )

      :telemetry.execute(
        [:lasso, :websocket, :reconnect_scheduled],
        %{delay_ms: total_delay, jitter_ms: jitter},
        %{
          provider_id: state.endpoint.id,
          attempt: state.reconnect_attempts + 1,
          max_attempts: max_attempts
        }
      )

      broadcast_conn_event(state, fn provider_id ->
        {:ws_reconnecting, provider_id, state.reconnect_attempts + 1}
      end)

      ref = Process.send_after(self(), {:reconnect}, total_delay)

      new_state = %{
        state
        | reconnect_attempts: state.reconnect_attempts + 1,
          reconnect_ref: ref
      }

      write_ws_status(new_state.instance_id, :reconnecting, new_state.reconnect_attempts)
      new_state
    else
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

      # Broadcast reconnection attempt
      broadcast_conn_event(state, fn provider_id ->
        {:ws_reconnecting, provider_id, state.reconnect_attempts + 1}
      end)

      ref = Process.send_after(self(), {:reconnect}, extended_delay_ms + jitter)
      # Keep reconnect_attempts incrementing so we stay in extended backoff mode
      new_state = %{
        state
        | reconnect_attempts: state.reconnect_attempts + 1,
          reconnect_ref: ref
      }

      write_ws_status(new_state.instance_id, :reconnecting, new_state.reconnect_attempts)
      new_state
    end
  end

  defp cleanup_pending_requests(state, error) do
    pending_count = total_pending_count(state)

    if pending_count > 0 do
      # Emit telemetry for production visibility (metrics)
      :telemetry.execute(
        [:lasso, :websocket, :pending_cleanup],
        %{count: 1, pending_count: pending_count},
        %{provider_id: state.endpoint.id}
      )

      # Single aggregate log instead of per-request
      Logger.debug("Cleaning up #{pending_count} pending requests due to disconnect",
        provider: state.endpoint.id
      )

      Enum.each(state.pending_requests, fn {_id, req_info} ->
        _ = cancel_latch(req_info.cancel_latch)
        cleanup_send_entry(req_info)

        if req_info.send_state != :tombstone do
          GenServer.reply(req_info.from, {:error, error})
        end
      end)

      state
      |> Map.put(:pending_requests, %{})
      |> cleanup_transport_pending(error)
      |> cleanup_control_sends()
    else
      state
      |> cleanup_transport_pending(error)
      |> cleanup_control_sends()
    end
  end

  defp cleanup_transport_pending(state, error) do
    Enum.each(state.transport_pending, fn {_id, pending} ->
      _ = cancel_latch(pending.cancel_latch)
      cleanup_send_entry(pending)

      if pending.send_state != :tombstone do
        send(
          pending.owner,
          {:ws_transport_disconnected, pending.token, pending.generation, error}
        )
      end
    end)

    %{state | transport_pending: %{}}
  end

  defp route_ws_message(
         state,
         connection,
         generation,
         parsed,
         raw_bytes,
         frame_received_at,
         validated_at
       )
       when is_binary(raw_bytes) and is_integer(frame_received_at) and is_integer(validated_at) do
    case parsed do
      {:transport, %Validated{id: transport_id} = validated} ->
        route_transport_id(
          state,
          connection,
          generation,
          transport_id,
          {:ok, validated},
          raw_bytes,
          frame_received_at,
          validated_at
        )

      {:transport_invalid, transport_id, reason} ->
        route_transport_id(
          state,
          connection,
          generation,
          transport_id,
          {:invalid, reason},
          raw_bytes,
          frame_received_at,
          validated_at
        )

      :legacy ->
        legacy_ws_state(raw_bytes, state)

      {:unattributable, _reason} ->
        increment_transport_diagnostic(state, :unattributable_frame)
    end
  end

  defp route_ws_message(
         state,
         _connection,
         _generation,
         _parsed,
         _raw_bytes,
         _frame_received_at,
         _validated_at
       ),
       do: increment_transport_diagnostic(state, :invalid_frame_stamp)

  defp route_transport_id(
         state,
         connection,
         generation,
         transport_id,
         validation,
         raw_bytes,
         frame_received_at,
         validated_at
       ) do
    case Map.get(state.transport_pending, transport_id) do
      %{
        generation: ^generation,
        connection: ^connection,
        send_state: send_state
      } = pending
      when send_state != :tombstone ->
        cleanup_send_entry(pending)

        send(
          pending.owner,
          {:ws_transport_response, pending.token, generation, connection, validation, raw_bytes,
           frame_received_at, validated_at}
        )

        %{state | transport_pending: Map.delete(state.transport_pending, transport_id)}

      %{generation: ^generation, connection: ^connection} = pending ->
        state
        |> remove_transport_entry(transport_id, pending)
        |> increment_transport_diagnostic(:late_or_uncorrelated_response)

      _missing_or_stale ->
        increment_transport_diagnostic(state, :late_or_uncorrelated_response)
    end
  end

  defp legacy_ws_state(raw_bytes, state) do
    case handle_legacy_ws_message(raw_bytes, state) do
      {:noreply, new_state} -> new_state
    end
  end

  defp take_eligible_transport_frame(pending, transport_id) do
    connection = pending.connection
    generation = pending.generation
    deadline_us = pending.deadline_us

    receive do
      {:ws_message, ^connection, ^generation,
       {:transport, %Validated{id: ^transport_id}} = parsed, raw_bytes, frame_received_at,
       validated_at}
      when is_binary(raw_bytes) and is_integer(frame_received_at) and is_integer(validated_at) and
             validated_at < deadline_us ->
        {:ok, parsed, raw_bytes, frame_received_at, validated_at}

      {:ws_message, ^connection, ^generation,
       {:transport_invalid, ^transport_id, _reason} = parsed, raw_bytes, frame_received_at,
       validated_at}
      when is_binary(raw_bytes) and is_integer(frame_received_at) and is_integer(validated_at) and
             validated_at < deadline_us ->
        {:ok, parsed, raw_bytes, frame_received_at, validated_at}
    after
      0 -> :none
    end
  end

  defp increment_transport_diagnostic(state, reason) do
    diagnostics =
      Map.update(state.transport_diagnostics, reason, 1, fn count ->
        min(count + 1, @max_diagnostic_count)
      end)

    %{state | transport_diagnostics: diagnostics}
  end

  defp transport_id_for_generation?(transport_id, generation)
       when is_binary(transport_id) and is_binary(generation) do
    UpstreamResponse.transport_id?(transport_id) and
      String.starts_with?(transport_id, "lasso-#{generation}-")
  end

  defp transport_id_for_generation?(_transport_id, _generation), do: false

  defp ceil_milliseconds(remaining_us) when remaining_us > 0,
    do: div(remaining_us + 999, 1_000)

  defp ceil_milliseconds(_remaining_us), do: 0

  defp handle_legacy_ws_message(raw_bytes, state) do
    case Response.from_bytes(raw_bytes) do
      {:ok, %Response.Success{id: nil}} ->
        handle_non_response_message(raw_bytes, state)

      {:ok, %Response.Success{id: id} = resp} ->
        handle_response_success(id, resp, state)

      {:ok, %Response.Error{id: id, error: jerr}} ->
        handle_response_error(id, jerr, state)

      {:ok, %Response.Notification{} = notification} ->
        handle_notification(notification, state)

      {:error, _parse_reason} ->
        handle_non_response_message(raw_bytes, state)
    end
  end

  defp cancel_transport_by_key(state, transport_id, generation, token) do
    case Map.get(state.transport_pending, transport_id) do
      %{generation: ^generation, token: ^token} = pending ->
        retire_transport_send(state, transport_id, pending)

      _ ->
        state
    end
  end

  defp cancel_registered_transport(state, transport_id, pending) do
    _ = cancel_latch(pending.cancel_latch)
    remove_transport_entry(state, transport_id, pending)
  end

  defp retire_transport_send(state, transport_id, %{send_state: :registered} = pending),
    do: cancel_registered_transport(state, transport_id, pending)

  defp retire_transport_send(state, transport_id, %{send_state: :queued} = pending) do
    _ = cancel_latch(pending.cancel_latch)
    tombstone_transport_send(state, transport_id, pending)
  end

  defp retire_transport_send(state, transport_id, %{send_state: :accepted} = pending),
    do: tombstone_transport_send(state, transport_id, pending)

  defp retire_transport_send(state, transport_id, pending),
    do: remove_transport_entry(state, transport_id, pending)

  defp retire_legacy_send(state, request_id, %{send_state: :queued} = pending) do
    _ = cancel_latch(pending.cancel_latch)
    tombstone_legacy_send(state, request_id, pending)
  end

  defp retire_legacy_send(state, request_id, %{send_state: :accepted} = pending),
    do: tombstone_legacy_send(state, request_id, pending)

  defp retire_legacy_send(state, request_id, pending),
    do: remove_legacy_pending(state, request_id, pending)

  defp tombstone_transport_send(state, transport_id, pending) do
    cleanup_send_entry(pending)

    put_in(
      state,
      [:transport_pending, transport_id],
      tombstone(pending, {:transport, transport_id})
    )
  end

  defp tombstone_legacy_send(state, request_id, pending) do
    cleanup_send_entry(pending)

    put_in(
      state,
      [:pending_requests, request_id],
      tombstone(pending, {:legacy, request_id})
    )
  end

  defp tombstone(pending, send_key) do
    cleanup_expiry_us =
      System.monotonic_time(:microsecond) + send_cleanup_ms() * 1_000

    cleanup_timer =
      Process.send_after(
        self(),
        {:send_cleanup_expired, pending.connection, pending.generation, send_key, pending.token,
         cleanup_expiry_us},
        send_cleanup_ms()
      )

    Map.merge(pending, %{
      from: nil,
      owner: nil,
      owner_monitor: nil,
      timer: cleanup_timer,
      cleanup_expiry_us: cleanup_expiry_us,
      send_state: :tombstone
    })
  end

  defp expire_send_tombstone(
         state,
         connection,
         generation,
         send_key,
         token,
         cleanup_expiry_us
       ) do
    case tombstone_entry(state, send_key) do
      %{
        connection: ^connection,
        generation: ^generation,
        token: ^token,
        cleanup_expiry_us: ^cleanup_expiry_us,
        send_state: :tombstone
      } = pending ->
        now_us = System.monotonic_time(:microsecond)

        if now_us < cleanup_expiry_us do
          timer =
            Process.send_after(
              self(),
              {:send_cleanup_expired, connection, generation, send_key, token, cleanup_expiry_us},
              ceil_milliseconds(cleanup_expiry_us - now_us)
            )

          put_tombstone_entry(state, send_key, %{pending | timer: timer})
        else
          terminate_connection_generation(state, connection, generation)
        end

      _missing_or_stale ->
        state
    end
  end

  defp tombstone_entry(state, {:transport, transport_id}),
    do: Map.get(state.transport_pending, transport_id)

  defp tombstone_entry(state, {:legacy, request_id}),
    do: Map.get(state.pending_requests, request_id)

  defp put_tombstone_entry(state, {:transport, transport_id}, pending),
    do: put_in(state, [:transport_pending, transport_id], pending)

  defp put_tombstone_entry(state, {:legacy, request_id}, pending),
    do: put_in(state, [:pending_requests, request_id], pending)

  defp terminate_connection_generation(
         %{connection: connection, connection_id: generation} = state,
         connection,
         generation
       )
       when is_pid(connection) do
    Process.exit(connection, :kill)
    increment_transport_diagnostic(state, :send_cleanup_expired)
  end

  defp terminate_connection_generation(state, _connection, _generation), do: state

  defp remove_transport_entry(state, transport_id, pending) do
    cleanup_send_entry(pending)
    %{state | transport_pending: Map.delete(state.transport_pending, transport_id)}
  end

  defp remove_legacy_pending(state, request_id, pending) do
    cleanup_send_entry(pending)
    %{state | pending_requests: Map.delete(state.pending_requests, request_id)}
  end

  defp cleanup_send_entry(pending) do
    if is_reference(pending[:timer]), do: Process.cancel_timer(pending.timer)

    if is_reference(pending[:owner_monitor]),
      do: Process.demonitor(pending.owner_monitor, [:flush])
  end

  defp cancel_latch(latch) do
    case :atomics.compare_exchange(latch, 1, 0, 1) do
      value when value in [:ok, 0, 1] -> :cancelled
      2 -> :accepted
    end
  rescue
    ArgumentError -> :cancelled
  end

  defp cast_send(state, send_key, deadline_us, cancel_latch, frame) do
    ws_client().cast(
      state.connection,
      {:send_if_live, state.connection_id, send_key, deadline_us, cancel_latch, frame}
    )
  catch
    :exit, _reason -> {:error, :connection_down}
  end

  defp enqueue_control_send(state, kind, frame, timeout_ms) do
    cond do
      not state.connected or not is_pid(state.connection) ->
        {:error, :not_connected, state}

      send_capacity_used(state) >= state.transport_pending_limit ->
        {:error, :capacity, state}

      true ->
        token = make_ref()
        latch = :atomics.new(1, signed: false)
        deadline_us = System.monotonic_time(:microsecond) + timeout_ms * 1_000

        timer =
          Process.send_after(
            self(),
            {:control_send_timeout, token, state.connection_id},
            timeout_ms
          )

        control = %{
          kind: kind,
          generation: state.connection_id,
          cancel_latch: latch,
          timer: timer,
          send_state: :queued
        }

        state = put_in(state, [:control_sends, token], control)

        case cast_send(state, {:control, token}, deadline_us, latch, frame) do
          :ok -> {:ok, state}
          {:error, reason} -> {:error, reason, remove_control_send(state, token, control)}
        end
    end
  end

  defp remove_control_send(state, token, control) do
    if is_reference(control.timer), do: Process.cancel_timer(control.timer)
    %{state | control_sends: Map.delete(state.control_sends, token)}
  end

  defp cleanup_control_sends(state) do
    Enum.each(state.control_sends, fn {_token, control} ->
      _ = cancel_latch(control.cancel_latch)
      if is_reference(control.timer), do: Process.cancel_timer(control.timer)
    end)

    %{state | control_sends: %{}}
  end

  defp handle_control_decision(state, %{kind: :heartbeat}, :accepted) do
    :telemetry.execute(
      [:lasso, :websocket, :heartbeat, :sent],
      %{},
      %{provider_id: state.endpoint.id}
    )

    schedule_heartbeat(state)
  end

  defp handle_control_decision(state, %{kind: :heartbeat}, {:rejected, reason}) do
    :telemetry.execute(
      [:lasso, :websocket, :heartbeat, :failed],
      %{},
      %{provider_id: state.endpoint.id, reason: reason}
    )

    schedule_heartbeat(state)
  end

  defp handle_control_decision(state, _control, _decision), do: state

  defp count_send_state(pending, send_state) do
    Enum.count(pending, fn {_id, entry} -> entry.send_state == send_state end)
  end

  defp send_capacity_used(state) do
    map_size(state.pending_requests) + map_size(state.transport_pending) +
      map_size(state.control_sends)
  end

  defp control_send_timeout_ms do
    case Application.get_env(:lasso, :ws_control_send_timeout_ms, 5_000) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> 5_000
    end
  end

  defp send_cleanup_ms do
    case Application.get_env(:lasso, :ws_send_cleanup_ms, @default_send_cleanup_ms) do
      timeout when is_integer(timeout) and timeout >= 0 -> timeout
      _invalid -> @default_send_cleanup_ms
    end
  end

  defp capacity_error(state) do
    JError.new(-32_008, "WebSocket pending capacity exhausted",
      provider_id: state.endpoint.id,
      retriable?: true,
      breaker_penalty?: false,
      category: :local_capacity_rejection
    )
  end

  defp cancelled_request_error(state) do
    JError.new(-32_008, "WebSocket request cancelled before dispatch",
      provider_id: state.endpoint.id,
      retriable?: true,
      breaker_penalty?: false,
      category: :local_capacity_rejection
    )
  end

  defp active_pending?(state) do
    total_pending_count(state) > 0
  end

  defp total_pending_count(state), do: send_capacity_used(state)

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
          profile: state.endpoint.profile,
          chain_id: state.endpoint.chain_id,
          context: :jsonrpc,
          transport: :ws
        )

      broadcast_conn_event(state, fn provider_id ->
        {:connection_error, provider_id, jerr}
      end)

      # Proactively close on timeout-like provider errors to force clean reconnect
      state =
        if (is_integer(code) and code == -32_701) or
             (is_binary(msg) and String.contains?(String.downcase(msg), "timeout")) do
          case enqueue_control_send(
                 state,
                 :provider_timeout_close,
                 {:close, 1013, "connection timeout"},
                 control_send_timeout_ms()
               ) do
            {:ok, state} -> state
            {:error, _reason, state} -> state
          end
        else
          state
        end

      {:ok, state}
    end
  end

  defp handle_websocket_message(message, state) do
    Logger.debug("Received unexpected message from #{state.endpoint.id}: #{inspect(message)}")
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

  defp cancel_pending_reconnect(state) do
    if state.reconnect_ref do
      Process.cancel_timer(state.reconnect_ref)
      %{state | reconnect_ref: nil}
    else
      state
    end
  end

  defp reconnect_delay(state) do
    if state.reconnect_attempts == 0 do
      0
    else
      min(state.endpoint.reconnect_interval * state.reconnect_attempts, 30_000)
    end
  end

  defp reconnect_log_level(attempts) do
    if attempts < @reconnect_log_threshold, do: :info, else: :debug
  end

  @doc false
  @spec via_instance_name(String.t()) :: {:via, Registry, {Lasso.Registry, term()}}
  def via_instance_name(instance_id) when is_binary(instance_id) do
    {:via, Registry, {Lasso.Registry, {:ws_conn_instance, instance_id}}}
  end

  defp endpoint_instance_id(%Endpoint{profile: @shared_profile, id: instance_id}), do: instance_id

  defp endpoint_instance_id(%Endpoint{profile: profile, chain_id: chain_id, id: provider_id})
       when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and
              is_binary(provider_id) do
    Catalog.lookup_instance_id(profile, chain_id, provider_id) || "#{chain_id}:#{provider_id}"
  end

  defp broadcast_conn_event(state, event_builder) when is_function(event_builder, 1) do
    for {profile, provider_id} <- profile_provider_refs(state) do
      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.ws_connection(profile, state.endpoint.chain_id),
        event_builder.(provider_id)
      )
    end

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      Lasso.Topics.ws_conn_instance(state.instance_id),
      event_builder.(state.instance_id)
    )
  end

  defp broadcast_subscription_event(state, sub_id, payload, received_at) do
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      Lasso.Topics.ws_subs_instance(state.instance_id),
      {:subscription_event, state.instance_id, sub_id, payload, received_at}
    )
  end

  defp profile_provider_refs(%{
         profile: @shared_profile,
         endpoint: %Endpoint{chain_id: chain_id},
         instance_id: instance_id
       }) do
    case Catalog.get_instance_refs(instance_id) do
      refs when is_list(refs) and refs != [] ->
        Enum.map(refs, fn profile ->
          provider_id =
            Catalog.reverse_lookup_provider_id(profile, chain_id, instance_id) || instance_id

          {profile, provider_id}
        end)

      _ ->
        [{"public", instance_id}]
    end
  rescue
    _ -> [{"public", instance_id}]
  end

  defp profile_provider_refs(%{profile: profile, endpoint: endpoint})
       when is_binary(profile) and is_binary(endpoint.id) do
    [{profile, endpoint.id}]
  end

  @catalog_retry_attempts 3
  @catalog_retry_delay_ms 200

  defp catalog_get_with_retry(instance_id, attempt \\ 1) do
    case Catalog.get_instance(instance_id) do
      {:ok, _} = ok ->
        ok

      {:error, :not_found} when attempt < @catalog_retry_attempts ->
        Process.sleep(@catalog_retry_delay_ms * attempt)
        catalog_get_with_retry(instance_id, attempt + 1)

      {:error, _} = err ->
        err
    end
  end

  defp write_ws_status(instance_id, status, reconnect_attempts) do
    :ets.insert(:lasso_instance_state, {
      {:ws_status, instance_id},
      %{
        status: status,
        reconnect_attempts: reconnect_attempts,
        grace_until_ms: nil,
        last_event_ms: System.system_time(:millisecond)
      }
    })
  rescue
    ArgumentError -> :ok
  end

  defp ws_client do
    Application.get_env(:lasso, :ws_client_module, Client)
  end
end

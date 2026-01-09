defmodule Lasso.HealthProbe.Worker do
  @moduledoc """
  Per-provider health probe that informs circuit breaker state.

  This worker runs independently of the circuit breaker - it probes providers
  regardless of circuit state. Its purpose is to detect when providers recover
  so the circuit breaker can close.

  ## Responsibilities

  1. Probe provider at regular intervals using lightweight request (eth_chainId)
  2. Record success/failure to circuit breaker (both HTTP and WS)
  3. Continue probing even when circuit is open (that's the point)


  ## Separation from BlockSync

  - **HealthProbe**: "Is this provider alive?" → Informs circuit breaker
  - **BlockSync**: "What block is this provider at?" → Tracks sync status

  HealthProbe uses eth_chainId because:
  - Lightweight and fast
  - Cacheable by providers (low cost)
  - Validates basic connectivity
  """

  use GenServer
  require Logger

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.RPC.Transport.WebSocket.Connection, as: WSConnection
  alias Lasso.RPC.{Channel, Response, TransportRegistry}

  @default_probe_interval_ms 10_000
  @default_timeout_ms 5_000
  @max_consecutive_failures_before_warn 3

  @type t :: %__MODULE__{
          chain: String.t(),
          profile: String.t(),
          provider_id: String.t(),
          probe_interval_ms: pos_integer(),
          timeout_ms: pos_integer(),
          timer_ref: reference() | nil,
          consecutive_failures: non_neg_integer(),
          consecutive_successes: non_neg_integer(),
          last_probe_time: integer() | nil,
          last_latency_ms: non_neg_integer() | nil,
          has_http: boolean(),
          ws_consecutive_failures: non_neg_integer(),
          ws_consecutive_successes: non_neg_integer(),
          ws_last_probe_time: integer() | nil,
          ws_last_latency_ms: non_neg_integer() | nil,
          has_ws: boolean()
        }

  defstruct [
    :chain,
    :profile,
    :provider_id,
    :probe_interval_ms,
    :timeout_ms,
    :timer_ref,
    # HTTP probe state
    :consecutive_failures,
    :consecutive_successes,
    :last_probe_time,
    :last_latency_ms,
    :has_http,
    # WS probe state
    :ws_consecutive_failures,
    :ws_consecutive_successes,
    :ws_last_probe_time,
    :ws_last_latency_ms,
    :has_ws
  ]

  ## Client API

  def start_link({chain, profile, provider_id, opts}) when is_binary(profile) do
    GenServer.start_link(__MODULE__, {chain, profile, provider_id, opts},
      name: via(chain, profile, provider_id)
    )
  end

  def via(chain, profile, provider_id) when is_binary(profile) do
    {:via, Registry, {Lasso.Registry, {:health_probe_worker, chain, profile, provider_id}}}
  end

  @doc """
  Get the current status of a health probe worker.
  """
  def get_status(chain, profile, provider_id) when is_binary(profile) do
    GenServer.call(via(chain, profile, provider_id), :get_status)
  catch
    :exit, _ -> {:error, :not_running}
  end

  ## GenServer Callbacks

  @impl true
  @spec init({String.t(), String.t(), String.t(), keyword()}) :: {:ok, t()}
  def init({chain, profile, provider_id, opts}) when is_binary(profile) do
    probe_interval = Keyword.get(opts, :probe_interval_ms, @default_probe_interval_ms)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    # Check transport capabilities (profile-aware)
    has_http = has_http_capability?(profile, chain, provider_id)
    has_ws = has_ws_capability?(profile, chain, provider_id)

    state = %__MODULE__{
      chain: chain,
      profile: profile,
      provider_id: provider_id,
      probe_interval_ms: probe_interval,
      timeout_ms: timeout,
      timer_ref: nil,
      # HTTP probe state
      consecutive_failures: 0,
      consecutive_successes: 0,
      last_probe_time: nil,
      last_latency_ms: nil,
      has_http: has_http,
      # WS probe state
      ws_consecutive_failures: 0,
      ws_consecutive_successes: 0,
      ws_last_probe_time: nil,
      ws_last_latency_ms: nil,
      has_ws: has_ws
    }

    if has_http or has_ws do
      # Schedule first probe after a short delay to let connections establish
      state = schedule_probe(state, 2_000)

      Logger.debug("HealthProbe.Worker started",
        chain: chain,
        profile: profile,
        provider_id: provider_id,
        probe_interval_ms: probe_interval,
        has_http: has_http,
        has_ws: has_ws
      )

      {:ok, state}
    else
      # No transport capability, nothing to probe
      Logger.debug("HealthProbe.Worker skipped (no HTTP or WS)",
        chain: chain,
        profile: profile,
        provider_id: provider_id
      )

      {:ok, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      # HTTP probe status
      consecutive_failures: state.consecutive_failures,
      consecutive_successes: state.consecutive_successes,
      last_probe_time: state.last_probe_time,
      last_latency_ms: state.last_latency_ms,
      probe_interval_ms: state.probe_interval_ms,
      has_http: state.has_http,
      # WS probe status
      ws_consecutive_failures: state.ws_consecutive_failures,
      ws_consecutive_successes: state.ws_consecutive_successes,
      ws_last_probe_time: state.ws_last_probe_time,
      ws_last_latency_ms: state.ws_last_latency_ms,
      has_ws: state.has_ws
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def handle_info(:probe, state) do
    state = execute_probe(state)
    state = schedule_probe(state, state.probe_interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  defp broadcast_recovery(state, transport, old_consecutive_failures) do
    provider_key = {state.profile, state.provider_id}
    timestamp = System.system_time(:millisecond)

    old_state = %{
      consecutive_failures: old_consecutive_failures
    }

    new_state = %{
      consecutive_successes:
        if(transport == :http,
          do: state.consecutive_successes,
          else: state.ws_consecutive_successes
        ),
      status: :healthy
    }

    msg = {:health_probe_recovery, provider_key, transport, old_state, new_state, timestamp}

    Phoenix.PubSub.broadcast(Lasso.PubSub, "health_probe:#{state.profile}:#{state.chain}", msg)
  end

  defp schedule_probe(state, delay_ms) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :probe, delay_ms)
    %{state | timer_ref: ref}
  end

  # Execute probes for all available transports
  defp execute_probe(%__MODULE__{} = state) do
    state
    |> execute_http_probe()
    |> execute_ws_probe()
  end

  # HTTP probe execution
  defp execute_http_probe(%__MODULE__{has_http: false} = state), do: state

  defp execute_http_probe(%__MODULE__{} = state) do
    start_time = System.monotonic_time(:millisecond)

    result = do_http_probe(state.profile, state.chain, state.provider_id, state.timeout_ms)
    latency_ms = System.monotonic_time(:millisecond) - start_time
    now = System.system_time(:millisecond)

    case result do
      {:ok, _chain_id} ->
        handle_http_probe_success(state, latency_ms, now)

      {:error, reason} ->
        handle_http_probe_failure(state, reason, latency_ms, now)
    end
  end

  # WS probe execution
  defp execute_ws_probe(%__MODULE__{has_ws: false} = state), do: state

  defp execute_ws_probe(%__MODULE__{} = state) do
    # Re-check WS availability on each probe since connections can come and go
    if ws_connected?(state.chain, state.provider_id) do
      start_time = System.monotonic_time(:millisecond)

      result = do_ws_probe(state.chain, state.provider_id, state.timeout_ms)
      latency_ms = System.monotonic_time(:millisecond) - start_time
      now = System.system_time(:millisecond)

      case result do
        {:ok, _chain_id} ->
          handle_ws_probe_success(state, latency_ms, now)

        {:error, reason} ->
          handle_ws_probe_failure(state, reason, latency_ms, now)
      end
    else
      # WS not currently connected, skip probe but don't record failure
      # (the circuit breaker already knows about the disconnect)
      state
    end
  end

  # HTTP probe success/failure handlers

  defp handle_http_probe_success(state, latency_ms, now) do
    # Signal to HTTP circuit breaker that provider is reachable
    # Circuit breaker decides whether to use this signal based on its state
    cb_id = {state.profile, state.chain, state.provider_id, :http}
    CircuitBreaker.signal_recovery(cb_id)

    new_consecutive_successes = state.consecutive_successes + 1
    was_failing = state.consecutive_failures >= @max_consecutive_failures_before_warn

    # Log recovery if we were failing
    if was_failing do
      Logger.info("HealthProbe: HTTP recovered",
        chain: state.chain,
        provider_id: state.provider_id,
        latency_ms: latency_ms,
        after_failures: state.consecutive_failures
      )
    end

    new_state = %{
      state
      | consecutive_failures: 0,
        consecutive_successes: new_consecutive_successes,
        last_probe_time: now,
        last_latency_ms: latency_ms
    }

    # Broadcast recovery event after state update
    if was_failing do
      broadcast_recovery(new_state, :http, state.consecutive_failures)
    end

    new_state
  end

  defp handle_http_probe_failure(state, reason, latency_ms, now) do
    # Record failure to HTTP circuit breaker with actual error for proper classification
    cb_id = {state.profile, state.chain, state.provider_id, :http}
    CircuitBreaker.record_failure(cb_id, reason)

    new_consecutive_failures = state.consecutive_failures + 1

    # Log warning when failures accumulate
    if new_consecutive_failures == @max_consecutive_failures_before_warn do
      Logger.warning("HealthProbe: HTTP degraded",
        chain: state.chain,
        provider_id: state.provider_id,
        consecutive_failures: new_consecutive_failures,
        reason: inspect(reason)
      )
    end

    %{
      state
      | consecutive_failures: new_consecutive_failures,
        consecutive_successes: 0,
        last_probe_time: now,
        last_latency_ms: latency_ms
    }
  end

  # WS probe success/failure handlers

  defp handle_ws_probe_success(state, latency_ms, now) do
    # Signal to WS circuit breaker that provider is reachable
    # Circuit breaker decides whether to use this signal based on its state
    cb_id = {state.profile, state.chain, state.provider_id, :ws}
    CircuitBreaker.signal_recovery(cb_id)

    new_consecutive_successes = state.ws_consecutive_successes + 1
    was_failing = state.ws_consecutive_failures >= @max_consecutive_failures_before_warn

    # Log recovery if we were failing
    if was_failing do
      Logger.info("HealthProbe: WS recovered",
        chain: state.chain,
        provider_id: state.provider_id,
        latency_ms: latency_ms,
        after_failures: state.ws_consecutive_failures
      )
    end

    new_state = %{
      state
      | ws_consecutive_failures: 0,
        ws_consecutive_successes: new_consecutive_successes,
        ws_last_probe_time: now,
        ws_last_latency_ms: latency_ms
    }

    # Broadcast recovery event after state update
    if was_failing do
      broadcast_recovery(new_state, :ws, state.ws_consecutive_failures)
    end

    new_state
  end

  defp handle_ws_probe_failure(state, reason, latency_ms, now) do
    # Record failure to WS circuit breaker with actual error for proper classification
    cb_id = {state.profile, state.chain, state.provider_id, :ws}
    CircuitBreaker.record_failure(cb_id, reason)

    new_consecutive_failures = state.ws_consecutive_failures + 1

    # Log warning when failures accumulate
    if new_consecutive_failures == @max_consecutive_failures_before_warn do
      Logger.warning("HealthProbe: WS degraded",
        chain: state.chain,
        provider_id: state.provider_id,
        consecutive_failures: new_consecutive_failures,
        reason: inspect(reason)
      )
    end

    %{
      state
      | ws_consecutive_failures: new_consecutive_failures,
        ws_consecutive_successes: 0,
        ws_last_probe_time: now,
        ws_last_latency_ms: latency_ms
    }
  end

  # HTTP probe implementation

  defp do_http_probe(profile, chain, provider_id, timeout_ms) do
    # Get channel directly - NOT through circuit breaker
    case TransportRegistry.get_channel(profile, chain, provider_id, :http) do
      {:ok, channel} ->
        # Use eth_chainId - lightweight, cacheable, validates connectivity
        rpc_request = %{
          "jsonrpc" => "2.0",
          "method" => "eth_chainId",
          "params" => [],
          "id" => :rand.uniform(1_000_000)
        }

        case Channel.request(channel, rpc_request, timeout_ms) do
          {:ok, %Response.Success{} = response, _io_ms} ->
            case Response.Success.decode_result(response) do
              {:ok, "0x" <> hex} ->
                {:ok, String.to_integer(hex, 16)}

              {:ok, result} ->
                # Even if parsing fails, we got a response - provider is alive
                {:ok, result}

              {:error, reason} ->
                {:error, {:decode_failed, reason}}
            end

          {:ok, %Response.Error{error: jerror} = _error, _io_ms} ->
            # JSON-RPC error - provider responded, but method failed
            # This still counts as "reachable" for most error types
            # But rate limit errors should count as failures
            if jerror.category == :rate_limit do
              # Pass the actual JError for proper circuit breaker classification
              {:error, jerror}
            else
              # Provider is reachable, just returned an error
              {:ok, :error_response}
            end

          {:error, reason, _io_ms} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:channel_unavailable, reason}}
    end
  rescue
    e ->
      Logger.error("HealthProbe crashed",
        chain: chain,
        provider_id: provider_id,
        error: Exception.format(:error, e, __STACKTRACE__)
      )

      {:error, {:exception, Exception.message(e)}}
  end

  # WS probe implementation
  # Uses WSConnection.request directly (bypasses circuit breaker)

  defp do_ws_probe(chain, provider_id, timeout_ms) do
    # Use WSConnection.request directly - NOT through circuit breaker
    # The WSConnection uses the provider_id as the connection_id
    case WSConnection.request(provider_id, "eth_chainId", [], timeout_ms) do
      {:ok, %Response.Success{} = response} ->
        case Response.Success.decode_result(response) do
          {:ok, "0x" <> hex} ->
            {:ok, String.to_integer(hex, 16)}

          {:ok, result} ->
            # Even if parsing fails, we got a response - provider is alive
            {:ok, result}

          {:error, _} ->
            # Decode failed but we got a response - provider is alive
            {:ok, :parse_error}
        end

      {:error, %{category: :rate_limit} = jerr} ->
        # Rate limit errors should count as failures
        {:error, jerr}

      {:error, %{retriable?: true} = _jerr} ->
        # Other retriable errors but connection worked - provider is reachable
        {:ok, :error_response}

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, {:noproc, _} ->
      # WSConnection process not running
      {:error, {:ws_not_connected, chain, provider_id}}

    :exit, {:timeout, _} ->
      {:error, {:ws_request_timeout, timeout_ms}}

    kind, error ->
      Logger.error("WS HealthProbe crashed",
        chain: chain,
        provider_id: provider_id,
        error: Exception.format(kind, error, __STACKTRACE__)
      )

      {:error, {:exception, inspect({kind, error})}}
  end

  # Capability checks

  defp has_http_capability?(profile, chain, provider_id) do
    case TransportRegistry.get_channel(profile, chain, provider_id, :http) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp has_ws_capability?(profile, chain, provider_id) do
    # Check if provider has WS configured (not necessarily connected)
    # We check for the WS channel in the registry cache
    case TransportRegistry.get_channel(profile, chain, provider_id, :ws) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # Check if WS is currently connected (not just configured)
  defp ws_connected?(_chain, provider_id) do
    # Check if WSConnection process is alive and connected
    case WSConnection.status(provider_id) do
      %{connected: true} -> true
      _ -> false
    end
  catch
    :exit, _ -> false
  end
end

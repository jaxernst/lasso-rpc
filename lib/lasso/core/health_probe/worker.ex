defmodule Lasso.HealthProbe.Worker do
  @moduledoc """
  Per-provider health probe that informs circuit breaker state.

  This worker runs independently of the circuit breaker - it probes providers
  regardless of circuit state. Its purpose is to detect when providers recover
  so the circuit breaker can close.

  ## Responsibilities

  1. Probe provider at regular intervals using lightweight request (eth_chainId)
  2. Record success/failure to circuit breaker
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

  alias Lasso.RPC.{TransportRegistry, Channel, Response, CircuitBreaker}

  @default_probe_interval_ms 10_000
  @default_timeout_ms 5_000
  @max_consecutive_failures_before_warn 3

  defstruct [
    :chain,
    :provider_id,
    :probe_interval_ms,
    :timeout_ms,
    :timer_ref,
    :consecutive_failures,
    :consecutive_successes,
    :last_probe_time,
    :last_latency_ms,
    :has_http
  ]

  ## Client API

  def start_link({chain, provider_id, opts}) do
    GenServer.start_link(__MODULE__, {chain, provider_id, opts}, name: via(chain, provider_id))
  end

  def via(chain, provider_id) do
    {:via, Registry, {Lasso.Registry, {:health_probe_worker, chain, provider_id}}}
  end

  @doc """
  Get the current status of a health probe worker.
  """
  def get_status(chain, provider_id) do
    GenServer.call(via(chain, provider_id), :get_status)
  catch
    :exit, _ -> {:error, :not_running}
  end

  ## GenServer Callbacks

  @impl true
  def init({chain, provider_id, opts}) do
    probe_interval = Keyword.get(opts, :probe_interval_ms, @default_probe_interval_ms)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    # Check if provider has HTTP capability
    has_http = has_http_capability?(chain, provider_id)

    state = %__MODULE__{
      chain: chain,
      provider_id: provider_id,
      probe_interval_ms: probe_interval,
      timeout_ms: timeout,
      timer_ref: nil,
      consecutive_failures: 0,
      consecutive_successes: 0,
      last_probe_time: nil,
      last_latency_ms: nil,
      has_http: has_http
    }

    if has_http do
      # Schedule first probe after a short delay to let connections establish
      state = schedule_probe(state, 2_000)

      Logger.debug("HealthProbe.Worker started",
        chain: chain,
        provider_id: provider_id,
        probe_interval_ms: probe_interval
      )

      {:ok, state}
    else
      # No HTTP capability, nothing to probe
      Logger.debug("HealthProbe.Worker skipped (no HTTP)",
        chain: chain,
        provider_id: provider_id
      )

      {:ok, state}
    end
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      consecutive_failures: state.consecutive_failures,
      consecutive_successes: state.consecutive_successes,
      last_probe_time: state.last_probe_time,
      last_latency_ms: state.last_latency_ms,
      probe_interval_ms: state.probe_interval_ms,
      has_http: state.has_http
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

  defp schedule_probe(state, delay_ms) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    ref = Process.send_after(self(), :probe, delay_ms)
    %{state | timer_ref: ref}
  end

  defp execute_probe(%__MODULE__{has_http: false} = state), do: state

  defp execute_probe(%__MODULE__{} = state) do
    start_time = System.monotonic_time(:millisecond)

    result = do_probe(state.chain, state.provider_id, state.timeout_ms)
    latency_ms = System.monotonic_time(:millisecond) - start_time
    now = System.system_time(:millisecond)

    case result do
      {:ok, _chain_id} ->
        handle_probe_success(state, latency_ms, now)

      {:error, reason} ->
        handle_probe_failure(state, reason, latency_ms, now)
    end
  end

  defp handle_probe_success(state, latency_ms, now) do
    # Record success to HTTP circuit breaker
    cb_id = {state.chain, state.provider_id, :http}
    CircuitBreaker.record_success(cb_id)

    new_consecutive_successes = state.consecutive_successes + 1

    # Log recovery if we were failing
    if state.consecutive_failures >= @max_consecutive_failures_before_warn do
      Logger.info("HealthProbe: HTTP recovered",
        chain: state.chain,
        provider_id: state.provider_id,
        latency_ms: latency_ms,
        after_failures: state.consecutive_failures
      )
    end

    %{
      state
      | consecutive_failures: 0,
        consecutive_successes: new_consecutive_successes,
        last_probe_time: now,
        last_latency_ms: latency_ms
    }
  end

  defp handle_probe_failure(state, reason, latency_ms, now) do
    # Record failure to HTTP circuit breaker with actual error for proper classification
    cb_id = {state.chain, state.provider_id, :http}
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

  defp do_probe(chain, provider_id, timeout_ms) do
    # Get channel directly - NOT through circuit breaker
    case TransportRegistry.get_channel(chain, provider_id, :http) do
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

  defp has_http_capability?(chain, provider_id) do
    case TransportRegistry.get_channel(chain, provider_id, :http) do
      {:ok, _} -> true
      _ -> false
    end
  end
end

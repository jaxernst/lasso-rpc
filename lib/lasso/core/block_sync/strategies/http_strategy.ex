defmodule Lasso.BlockSync.Strategies.HttpStrategy do
  @moduledoc """
  HTTP polling strategy for block sync.

  Polls `eth_blockNumber` at a configurable interval and reports:
  - Block heights to the parent Worker

  ## Circuit Breaker Integration

  This strategy goes through the HTTP circuit breaker. When the circuit is open,
  polling is skipped. HealthProbe (which bypasses the circuit breaker) is responsible
  for detecting when the provider recovers and closing the circuit.

  ## Messages sent to parent

  - `{:block_height, height, %{latency_ms: ms}}`
  - `{:status, :healthy | :degraded}`
  """

  @behaviour Lasso.BlockSync.Strategy

  require Logger

  alias Lasso.RPC.{TransportRegistry, Channel, Response, CircuitBreaker}

  @default_poll_interval_ms 12_000
  @default_timeout_ms 3_000
  @max_consecutive_failures 3

  defstruct [
    :chain,
    :provider_id,
    :parent,
    :poll_interval_ms,
    :timer_ref,
    :consecutive_failures,
    :last_height,
    :last_poll_time
  ]

  ## Strategy Callbacks

  @impl true
  def start(chain, provider_id, opts) do
    parent = Keyword.get(opts, :parent, self())
    poll_interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)

    state = %__MODULE__{
      chain: chain,
      provider_id: provider_id,
      parent: parent,
      poll_interval_ms: poll_interval,
      consecutive_failures: 0,
      last_height: nil,
      last_poll_time: nil,
      timer_ref: nil
    }

    # Start the polling loop
    state = schedule_poll(state, 0)

    {:ok, state}
  end

  @impl true
  def stop(%__MODULE__{timer_ref: ref}) do
    if ref, do: Process.cancel_timer(ref)
    :ok
  end

  @impl true
  def healthy?(%__MODULE__{consecutive_failures: failures}) do
    failures < @max_consecutive_failures
  end

  @impl true
  def source, do: :http

  @impl true
  def get_status(%__MODULE__{} = state) do
    %{
      consecutive_failures: state.consecutive_failures,
      last_height: state.last_height,
      last_poll_time: state.last_poll_time,
      poll_interval_ms: state.poll_interval_ms,
      healthy: healthy?(state)
    }
  end

  @impl true
  def handle_message(:poll, state) do
    new_state = execute_poll(state)
    new_state = schedule_poll(new_state, new_state.poll_interval_ms)
    {:ok, new_state}
  end

  def handle_message(_other, state) do
    {:ok, state}
  end

  ## Public API (for use by Worker)

  @doc """
  Execute an immediate poll (for use during initialization).
  """
  def poll_now(%__MODULE__{} = state) do
    execute_poll(state)
  end

  ## Private Functions

  defp schedule_poll(state, delay_ms) do
    ref = Process.send_after(state.parent, {:http_strategy, :poll, state.provider_id}, delay_ms)
    %{state | timer_ref: ref}
  end

  defp execute_poll(%__MODULE__{} = state) do
    start_time = System.monotonic_time(:millisecond)

    result = do_poll(state.chain, state.provider_id)
    latency_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, height} ->
        # Report success (latency included in metadata)
        send(state.parent, {:block_height, state.provider_id, height, %{latency_ms: latency_ms}})

        new_state = %{
          state
          | consecutive_failures: 0,
            last_height: height,
            last_poll_time: System.system_time(:millisecond)
        }

        # Notify if recovering from failures
        if state.consecutive_failures >= @max_consecutive_failures do
          send(state.parent, {:status, state.provider_id, :http, :healthy})
        end

        new_state

      {:error, :circuit_open} ->
        # Circuit is open - skip this poll cycle without incrementing failures
        # HealthProbe handles recovery detection independently
        state

      {:error, reason} ->
        failures = state.consecutive_failures + 1

        # Log appropriately based on failure count
        if failures == @max_consecutive_failures do
          Logger.warning("HTTP polling degraded",
            chain: state.chain,
            provider_id: state.provider_id,
            consecutive_failures: failures,
            error: inspect(reason)
          )

          send(state.parent, {:status, state.provider_id, :http, :degraded})
        end

        %{state | consecutive_failures: failures, last_poll_time: System.system_time(:millisecond)}
    end
  end

  defp do_poll(chain, provider_id) do
    cb_id = {chain, provider_id, :http}

    # Go through circuit breaker - when open, HealthProbe handles recovery detection
    case CircuitBreaker.call(cb_id, fn -> do_poll_request(chain, provider_id) end) do
      # Function executed - examine what it returned
      {:executed, {:ok, height}} ->
        {:ok, height}

      {:executed, {:error, reason}} ->
        {:error, reason}

      {:executed, height} when is_integer(height) ->
        {:ok, height}

      {:executed, {:exception, _}} ->
        {:error, :exception}

      # Circuit breaker rejected execution
      {:rejected, :circuit_open} ->
        {:error, :circuit_open}

      {:rejected, :half_open_busy} ->
        {:error, :circuit_open}

      {:rejected, reason} ->
        {:error, reason}
    end
  end

  defp do_poll_request(chain, provider_id) do
    case TransportRegistry.get_channel(chain, provider_id, :http) do
      {:ok, channel} ->
        rpc_request = %{
          "jsonrpc" => "2.0",
          "method" => "eth_blockNumber",
          "params" => [],
          "id" => :rand.uniform(1_000_000)
        }

        case Channel.request(channel, rpc_request, @default_timeout_ms) do
          {:ok, %Response.Success{} = response, _io_ms} ->
            case Response.Success.decode_result(response) do
              {:ok, "0x" <> hex} ->
                {:ok, String.to_integer(hex, 16)}

              {:ok, other} ->
                {:error, {:unexpected_result, other}}

              {:error, reason} ->
                {:error, {:decode_failed, reason}}
            end

          {:error, reason, _io_ms} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:channel_unavailable, reason}}
    end
  rescue
    e ->
      Logger.error("HTTP polling crashed",
        chain: chain,
        provider_id: provider_id,
        error: Exception.format(:error, e, __STACKTRACE__)
      )

      {:error, {:exception, Exception.message(e)}}
  end
end

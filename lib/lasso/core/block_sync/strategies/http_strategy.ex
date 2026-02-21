defmodule Lasso.BlockSync.Strategies.HttpStrategy do
  @moduledoc """
  HTTP polling strategy for block sync.

  Polls `eth_blockNumber` at a configurable interval and reports block heights
  to the parent Worker. Uses a reference profile and Channel for auth injection.

  ## Circuit Breaker Integration

  Goes through the shared HTTP circuit breaker keyed by `{instance_id, :http}`.
  When the circuit is open, polling is skipped.
  """

  @behaviour Lasso.BlockSync.Strategy

  require Logger

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.{Channel, Response, TransportRegistry}

  @default_poll_interval_ms 15_000
  @default_timeout_ms 3_000
  @max_consecutive_failures 3

  defstruct [
    :instance_id,
    :chain,
    :parent,
    :poll_interval_ms,
    :timer_ref,
    :consecutive_failures,
    :last_height,
    :last_poll_time
  ]

  @type t :: %__MODULE__{
          instance_id: String.t(),
          chain: String.t(),
          parent: pid(),
          poll_interval_ms: non_neg_integer(),
          timer_ref: reference() | nil,
          consecutive_failures: non_neg_integer(),
          last_height: non_neg_integer() | nil,
          last_poll_time: integer() | nil
        }

  ## Strategy Callbacks

  @impl true
  def start(chain, instance_id, opts) do
    parent = Keyword.get(opts, :parent, self())
    poll_interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)

    state = %__MODULE__{
      instance_id: instance_id,
      chain: chain,
      parent: parent,
      poll_interval_ms: poll_interval,
      consecutive_failures: 0,
      last_height: nil,
      last_poll_time: nil,
      timer_ref: nil
    }

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

  @spec poll_now(t()) :: t()
  def poll_now(%__MODULE__{} = state) do
    execute_poll(state)
  end

  ## Private Functions

  defp schedule_poll(state, delay_ms) do
    ref = Process.send_after(state.parent, {:http_strategy, :poll, state.instance_id}, delay_ms)
    %{state | timer_ref: ref}
  end

  defp execute_poll(%__MODULE__{} = state) do
    start_time = System.monotonic_time(:millisecond)

    result = do_poll(state.instance_id, state.chain)
    latency_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, height} ->
        send(state.parent, {:block_height, state.instance_id, height, %{latency_ms: latency_ms}})

        new_state = %{
          state
          | consecutive_failures: 0,
            last_height: height,
            last_poll_time: System.system_time(:millisecond)
        }

        if state.consecutive_failures >= @max_consecutive_failures do
          send(state.parent, {:status, state.instance_id, :http, :healthy})
        end

        new_state

      {:error, :circuit_open} ->
        state

      {:error, reason} ->
        failures = state.consecutive_failures + 1

        if failures == @max_consecutive_failures do
          Logger.warning("HTTP polling degraded",
            chain: state.chain,
            instance_id: state.instance_id,
            consecutive_failures: failures,
            error: inspect(reason)
          )

          send(state.parent, {:status, state.instance_id, :http, :degraded})
        end

        %{
          state
          | consecutive_failures: failures,
            last_poll_time: System.system_time(:millisecond)
        }
    end
  end

  defp do_poll(instance_id, chain) do
    cb_id = {instance_id, :http}

    case CircuitBreaker.call(cb_id, fn -> do_poll_request(instance_id, chain) end) do
      {:executed, {:ok, height}} ->
        {:ok, height}

      {:executed, {:error, reason}} ->
        {:error, reason}

      {:executed, height} when is_integer(height) ->
        {:ok, height}

      {:executed, {:exception, _}} ->
        {:error, :exception}

      {:rejected, :circuit_open} ->
        {:error, :circuit_open}

      {:rejected, :half_open_busy} ->
        {:error, :circuit_open}

      {:rejected, reason} ->
        {:error, reason}
    end
  end

  # Use a reference profile + Channel for auth header injection
  defp do_poll_request(instance_id, chain) do
    case resolve_channel(instance_id, chain) do
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
        instance_id: instance_id,
        error: Exception.format(:error, e, __STACKTRACE__)
      )

      {:error, {:exception, Exception.message(e)}}
  end

  defp resolve_channel(instance_id, chain) do
    case Catalog.get_instance_refs(instance_id) do
      [ref_profile | _] ->
        provider_id = Catalog.reverse_lookup_provider_id(ref_profile, chain, instance_id)

        if provider_id do
          TransportRegistry.get_channel(ref_profile, chain, provider_id, :http)
        else
          {:error, :no_provider_id}
        end

      [] ->
        {:error, :no_refs}
    end
  end
end

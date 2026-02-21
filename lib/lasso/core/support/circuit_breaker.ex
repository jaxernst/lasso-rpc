defmodule Lasso.Core.Support.CircuitBreaker do
  @moduledoc """
  Circuit breaker implementation for RPC provider fault tolerance.

  Implements the circuit breaker pattern to prevent cascade failures
  when providers are experiencing issues. Provides automatic recovery
  and configurable failure thresholds.

  ## Key Scheme

  Circuit breakers are keyed by `{instance_id, transport}` where instance_id
  is a deterministic hash derived from the provider's chain + URL. This enables
  shared circuit breakers across profiles that use the same upstream provider.

  ## Recovery Mechanics

  When a circuit opens, a `recovery_deadline_ms` (monotonic timestamp) is set.
  Both proactive timer recovery and traffic-triggered recovery are gated by
  this deadline. The deadline is fixed for the duration of the open episode —
  additional failures while open do not extend it.

  On reopen (half_open → open), the deadline is computed with exponential
  backoff from the configured base recovery timeout. Rate-limit errors with
  retry-after headers use the retry-after value directly instead of backing off.

  Backoff schedule: base_recovery_timeout × 2^min(consecutive_reopens, 4),
  capped at `max_recovery_timeout` (default 10 minutes).

  ## ETS Write-Through

  On every state transition, writes to `:lasso_instance_state` at key
  `{:circuit, instance_id, transport}` with fields: state, error, recovery_deadline_ms.

  ## PubSub Fan-Out

  Broadcasts circuit events to `"circuit:events:{profile}:{chain}"` for ALL
  profiles referencing the instance (via `Catalog.get_instance_refs/1`).
  """

  use GenServer
  require Logger
  alias Lasso.Core.Support.ErrorNormalizer
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.Catalog

  defstruct [
    :instance_id,
    :transport,
    :failure_threshold,
    :base_recovery_timeout,
    :success_threshold,
    :category_thresholds,
    :state,
    :failure_count,
    :last_failure_time,
    :success_count,
    :config,
    inflight_count: 0,
    half_open_max_inflight: 3,
    opened_by_category: nil,
    recovery_timer_ref: nil,
    last_open_error: nil,
    consecutive_open_count: 0,
    max_recovery_timeout: 600_000,
    recovery_deadline_ms: nil,
    effective_recovery_delay: nil,
    recovery_timer_gen: 0,
    shared_mode: false
  ]

  @type transport :: :http | :ws
  @type breaker_id :: {String.t(), transport()}
  @type breaker_state :: :closed | :open | :half_open
  @type state_t :: %__MODULE__{
          instance_id: String.t(),
          transport: transport(),
          failure_threshold: non_neg_integer(),
          base_recovery_timeout: non_neg_integer(),
          success_threshold: non_neg_integer(),
          state: breaker_state(),
          failure_count: non_neg_integer(),
          last_failure_time: integer() | nil,
          success_count: non_neg_integer(),
          config: map(),
          recovery_deadline_ms: integer() | nil,
          effective_recovery_delay: non_neg_integer() | nil,
          recovery_timer_gen: non_neg_integer(),
          shared_mode: boolean()
        }

  @doc """
  Starts a circuit breaker for a provider instance.
  """
  @spec start_link({breaker_id(), map()}) :: GenServer.on_start()
  def start_link({id, config}) do
    GenServer.start_link(__MODULE__, {id, config}, name: via_name(id))
  end

  @doc """
  Attempts to execute a function guarded by the circuit breaker.

  Returns an explicit execution envelope that separates circuit breaker
  concerns from function results:

  - `{:executed, fun_result}` - Function was executed. `fun_result` is whatever
    the wrapped function returned (which could itself be an error tuple).

  - `{:rejected, reason}` - Circuit breaker prevented execution.

  ## Rejection Reasons

  - `:circuit_open` - Circuit is open due to failures
  - `:half_open_busy` - Circuit is half-open but at max inflight capacity
  - `:admission_timeout` - Admission check timed out
  - `:not_found` - Circuit breaker process not found
  """
  @admit_timeout 500

  @typedoc "Reasons why the circuit breaker rejected execution"
  @type rejection_reason :: :circuit_open | :half_open_busy | :admission_timeout | :not_found

  @typedoc "Result of a circuit breaker call - separates execution status from function result"
  @type call_result(result) :: {:executed, result} | {:rejected, rejection_reason()}

  @spec call(breaker_id(), (-> result), non_neg_integer()) :: call_result(result)
        when result: term()
  def call({instance_id, transport} = id, fun, timeout \\ 30_000) do
    now_ms = System.monotonic_time(:millisecond)
    admit_start_us = System.monotonic_time(:microsecond)

    decision =
      try do
        GenServer.call(via_name(id), {:admit, now_ms}, @admit_timeout)
      catch
        :exit, {:timeout, _} ->
          Logger.warning("Circuit breaker admission timeout",
            instance_id: instance_id,
            transport: transport
          )

          {:deny, :admission_timeout}

        :exit, {:noproc, _} ->
          Logger.warning("Circuit breaker not found",
            instance_id: instance_id,
            transport: transport
          )

          {:deny, :not_found}
      end

    admit_call_ms = div(System.monotonic_time(:microsecond) - admit_start_us, 1000)

    decision_tag =
      case decision do
        {:allow, _} -> :allow
        {:deny, reason} -> reason
        other -> other
      end

    :telemetry.execute(
      [:lasso, :circuit_breaker, :admit],
      %{admit_call_ms: admit_call_ms},
      %{
        instance_id: instance_id,
        transport: transport,
        decision: decision_tag
      }
    )

    case decision do
      {:allow, token} ->
        execute_with_token(id, token, fun, timeout, instance_id, transport)

      {:deny, :open} ->
        {:rejected, :circuit_open}

      {:deny, :half_open_busy} ->
        {:rejected, :half_open_busy}

      {:deny, :admission_timeout} ->
        {:rejected, :admission_timeout}

      {:deny, :not_found} ->
        {:rejected, :not_found}
    end
  end

  defp execute_with_token(id, token, fun, timeout, instance_id, transport) do
    task =
      Task.async(fn ->
        try do
          fun.()
        catch
          kind, error ->
            {:__exception__, {kind, error, __STACKTRACE__}}
        end
      end)

    result =
      case Task.yield(task, timeout) do
        {:ok, {:__exception__, exception_info}} ->
          {:exception, exception_info}

        {:ok, fun_result} ->
          fun_result

        nil ->
          Task.shutdown(task, :brutal_kill)

          Logger.error("Request timeout in circuit breaker",
            instance_id: instance_id,
            transport: transport,
            timeout_ms: timeout
          )

          :telemetry.execute(
            [:lasso, :circuit_breaker, :timeout],
            %{timeout_ms: timeout},
            %{instance_id: instance_id, transport: transport}
          )

          {:error,
           JError.new(-32_000, "Request timeout after #{timeout}ms",
             category: :timeout,
             retriable?: true,
             breaker_penalty?: true
           ), timeout}
      end

    report_result =
      case result do
        {:exception, {kind, error, _stacktrace}} -> {:error, {kind, error}}
        other -> other
      end

    GenServer.cast(via_name(id), {:report, token, report_result})

    {:executed, result}
  end

  @state_timeout 2_000

  @doc """
  Gets the current state of the circuit breaker.
  """
  @spec get_state(breaker_id()) ::
          %{
            instance_id: String.t(),
            transport: transport(),
            state: breaker_state(),
            failure_count: non_neg_integer(),
            success_count: non_neg_integer(),
            last_failure_time: integer() | nil
          }
          | {:error, term()}
  def get_state(id) do
    GenServer.call(via_name(id), :get_state, @state_timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("Timeout getting circuit breaker state for #{inspect(id)}")
      {:error, :timeout}

    :exit, {:noproc, _} ->
      {:error, :not_found}
  end

  @doc """
  Manually opens the circuit breaker.
  """
  @spec open(breaker_id()) :: :ok
  def open(breaker_id) do
    GenServer.cast(via_name(breaker_id), :open)
  end

  @doc """
  Manually closes the circuit breaker.
  """
  @spec close(breaker_id()) :: :ok
  def close(breaker_id) do
    GenServer.cast(via_name(breaker_id), :close)
  end

  @doc """
  Gets the time remaining until circuit recovery attempt (in milliseconds).
  Returns nil if circuit is not open or if recovery should be attempted immediately.
  """
  @spec get_recovery_time_remaining(breaker_id()) :: non_neg_integer() | nil
  def get_recovery_time_remaining(breaker_id) do
    case get_state(breaker_id) do
      %{state: :open} ->
        try do
          case GenServer.call(via_name(breaker_id), :get_recovery_timeout, @state_timeout) do
            {:ok, remaining} -> remaining
            _ -> nil
          end
        catch
          :exit, _ -> nil
        end

      {:error, _reason} ->
        nil

      _ ->
        nil
    end
  end

  @doc """
  Signals that external health monitoring has detected the provider is reachable.

  Used by health probes to indicate a provider appears to be responding. The
  circuit breaker uses this signal to attempt recovery when appropriate.

  ## Behavior by Circuit State

  - **Open**: Triggers transition to half-open state (recovery attempt)
  - **Half-open**: Counts toward success threshold for closing circuit
  - **Closed**: No-op (circuit doesn't need recovery signals)
  """
  @spec signal_recovery(breaker_id()) :: :ok | {:error, :not_found}
  def signal_recovery(id) do
    case GenServer.whereis(via_name(id)) do
      nil ->
        {:error, :not_found}

      _pid ->
        case get_state(id) do
          %{state: state} when state in [:open, :half_open] ->
            GenServer.cast(via_name(id), {:report_external, {:ok, :success}})
            :ok

          _ ->
            :ok
        end
    end
  end

  @doc """
  Fire-and-forget version of signal_recovery/1. Does not check current state.
  """
  @spec signal_recovery_cast(breaker_id()) :: :ok
  def signal_recovery_cast(cb_id) do
    GenServer.cast(via_name(cb_id), {:report_external, {:ok, :success}})
    :ok
  end

  @doc """
  Record a failed operation for the circuit breaker (async).
  """
  @spec record_failure(breaker_id(), term()) :: :ok | {:error, :not_found}
  def record_failure(id, reason \\ :failure) do
    case GenServer.whereis(via_name(id)) do
      nil ->
        {:error, :not_found}

      _pid ->
        GenServer.cast(via_name(id), {:report_external, {:error, reason}})
        :ok
    end
  end

  @doc """
  Record a failed operation for the circuit breaker (synchronous).
  Returns the circuit state after recording the failure.
  """
  @spec record_failure_sync(breaker_id(), term(), timeout()) ::
          {:ok, :closed | :open | :half_open} | {:error, :not_found | :timeout}
  def record_failure_sync(id, reason \\ :failure, timeout \\ 5_000) do
    case GenServer.whereis(via_name(id)) do
      nil ->
        {:error, :not_found}

      _pid ->
        try do
          state = GenServer.call(via_name(id), {:report_external_sync, {:error, reason}}, timeout)
          {:ok, state}
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, {:noproc, _} -> {:error, :not_found}
        end
    end
  end

  # GenServer callbacks

  @impl true
  def init({{instance_id, transport}, config}) when is_binary(instance_id) do
    do_init(instance_id, transport, config)
  end

  defp do_init(instance_id, transport, config) do
    default_category_thresholds = %{
      server_error: 5,
      network_error: 3,
      timeout: 2,
      auth_error: 2
    }

    category_thresholds =
      Map.get(config, :category_thresholds, %{})
      |> Map.merge(default_category_thresholds, fn _k, v1, _v2 -> v1 end)

    half_open_max_inflight = Map.get(config, :half_open_max_inflight, 3)

    state = %__MODULE__{
      instance_id: instance_id,
      transport: transport,
      failure_threshold: Map.get(config, :failure_threshold, 5),
      base_recovery_timeout: Map.get(config, :recovery_timeout, 60_000),
      success_threshold: Map.get(config, :success_threshold, 2),
      category_thresholds: category_thresholds,
      half_open_max_inflight: half_open_max_inflight,
      inflight_count: 0,
      state: :closed,
      failure_count: 0,
      last_failure_time: nil,
      success_count: 0,
      config: config,
      max_recovery_timeout: Map.get(config, :max_recovery_timeout, 600_000),
      shared_mode: Map.get(config, :shared_mode, false)
    }

    write_ets_state(state)

    {:ok, state}
  end

  @impl true
  def handle_call({:admit, now_ms}, _from, state) do
    case state.state do
      :closed ->
        {:reply, {:allow, :closed}, state}

      :open ->
        if should_attempt_recovery?(state) do
          cancel_recovery_timer(state.recovery_timer_ref)

          :telemetry.execute([:lasso, :circuit_breaker, :half_open], %{count: 1}, %{
            instance_id: state.instance_id,
            transport: state.transport,
            from_state: :open,
            to_state: :half_open,
            reason: :attempt_recovery,
            consecutive_open_count: state.consecutive_open_count
          })

          new_state = %{
            state
            | state: :half_open,
              last_failure_time: state.last_failure_time || now_ms,
              inflight_count: 1,
              recovery_timer_ref: nil,
              recovery_timer_gen: state.recovery_timer_gen + 1
          }

          publish_circuit_event(new_state, :open, :half_open, :attempt_recovery)
          write_ets_state(new_state)
          {:reply, {:allow, :half_open}, new_state}
        else
          {:reply, {:deny, :open}, state}
        end

      :half_open ->
        if state.inflight_count < state.half_open_max_inflight do
          {:reply, {:allow, :half_open}, %{state | inflight_count: state.inflight_count + 1}}
        else
          {:reply, {:deny, :half_open_busy}, state}
        end
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    status = %{
      instance_id: state.instance_id,
      transport: state.transport,
      state: state.state,
      failure_count: state.failure_count,
      success_count: state.success_count,
      last_failure_time: state.last_failure_time,
      last_open_error: state.last_open_error
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:get_recovery_timeout, _from, state) do
    remaining =
      case state.recovery_deadline_ms do
        nil -> 0
        deadline -> max(0, deadline - System.monotonic_time(:millisecond))
      end

    {:reply, {:ok, remaining}, state}
  end

  @impl true
  def handle_call({:report_external_sync, outcome}, _from, state) do
    new_state = classify_and_update_state_for_report(outcome, state)
    {:reply, new_state.state, new_state}
  end

  @impl true
  def handle_cast({:report, _token, result}, state) do
    normalized = normalize_transport_result(result)
    new_state = classify_and_update_state_for_report(normalized, state)

    final_state =
      case new_state.state do
        :half_open -> %{new_state | inflight_count: max(new_state.inflight_count - 1, 0)}
        _ -> new_state
      end

    {:noreply, final_state}
  end

  @impl true
  def handle_cast({:report_external, outcome}, state) do
    new_state = classify_and_update_state_for_report(outcome, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:open, state) do
    :telemetry.execute([:lasso, :circuit_breaker, :open], %{count: 1}, %{
      instance_id: state.instance_id,
      transport: state.transport,
      from_state: state.state,
      to_state: :open,
      reason: :manual_open
    })

    cancel_recovery_timer(state.recovery_timer_ref)
    delay = state.base_recovery_timeout
    delay_with_jitter = add_jitter(delay)
    new_gen = state.recovery_timer_gen + 1
    now = System.monotonic_time(:millisecond)
    timer_ref = schedule_recovery_timer(delay_with_jitter, new_gen)

    new_state = %{
      state
      | state: :open,
        last_failure_time: now,
        recovery_timer_ref: timer_ref,
        recovery_timer_gen: new_gen,
        recovery_deadline_ms: now + delay_with_jitter,
        effective_recovery_delay: delay
    }

    publish_circuit_event(new_state, state.state, :open, :manual_open)
    write_ets_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:close, state) do
    :telemetry.execute([:lasso, :circuit_breaker, :close], %{count: 1}, %{
      instance_id: state.instance_id,
      transport: state.transport,
      from_state: state.state,
      to_state: :closed,
      reason: :manual_close
    })

    cancel_recovery_timer(state.recovery_timer_ref)

    new_state = %{
      state
      | state: :closed,
        failure_count: 0,
        success_count: 0,
        last_failure_time: nil,
        opened_by_category: nil,
        recovery_timer_ref: nil,
        last_open_error: nil,
        consecutive_open_count: 0,
        recovery_deadline_ms: nil,
        effective_recovery_delay: nil
    }

    publish_circuit_event(new_state, state.state, :closed, :manual_close)
    write_ets_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:attempt_proactive_recovery, gen}, state)
      when gen == state.recovery_timer_gen do
    case state.state do
      :open ->
        :telemetry.execute([:lasso, :circuit_breaker, :proactive_recovery], %{count: 1}, %{
          instance_id: state.instance_id,
          transport: state.transport,
          from_state: :open,
          to_state: :half_open,
          reason: :proactive_recovery,
          consecutive_open_count: state.consecutive_open_count
        })

        new_state = %{
          state
          | state: :half_open,
            success_count: 0,
            inflight_count: 0,
            recovery_timer_ref: nil
        }

        publish_circuit_event(new_state, :open, :half_open, :proactive_recovery)
        write_ets_state(new_state)
        {:noreply, new_state}

      _other_state ->
        {:noreply, %{state | recovery_timer_ref: nil}}
    end
  end

  @impl true
  def handle_info({:attempt_proactive_recovery, _stale_gen}, state) do
    {:noreply, state}
  end

  defp normalize_transport_result({:ok, value, _io_ms}), do: {:ok, value}
  defp normalize_transport_result({:error, reason, _io_ms}), do: {:error, reason}
  defp normalize_transport_result({:ok, _value} = ok_tuple), do: ok_tuple
  defp normalize_transport_result({:error, _reason} = error_tuple), do: error_tuple
  defp normalize_transport_result(:ok), do: {:ok, :ok}
  defp normalize_transport_result(other), do: other

  defp classify_and_handle_result(result, state) do
    case result do
      {:ok, value} ->
        handle_success(value, state)

      {:error, %JError{retriable?: true} = reason} ->
        if shared_breaker_penalty?(reason, state) do
          handle_failure(reason, state)
        else
          handle_non_breaker_error({:error, reason}, state)
        end

      {:error, %JError{retriable?: false} = reason} ->
        handle_non_breaker_error({:error, reason}, state)

      {:error, reason} ->
        jerr =
          ErrorNormalizer.normalize(reason,
            instance_id: state.instance_id,
            transport: state.transport
          )

        if jerr.retriable? and shared_breaker_penalty?(jerr, state) do
          handle_failure(jerr, state)
        else
          handle_non_breaker_error({:error, jerr}, state)
        end

      other ->
        Logger.error("Circuit breaker received unexpected result shape after normalization",
          shape: inspect(other),
          instance_id: state.instance_id,
          transport: state.transport
        )

        jerr =
          JError.new(-32_000, "Internal error: unexpected circuit breaker result shape",
            category: :internal_error,
            retriable?: false
          )

        handle_failure(jerr, state)
    end
  end

  defp classify_and_update_state_for_report(result, state) do
    case classify_and_handle_result(result, state) do
      {:reply, _reply, new_state} -> new_state
    end
  end

  defp handle_non_breaker_error(error_result, state) do
    if state.state == :open do
      {:reply, {:error, :circuit_open}, state}
    else
      {:reply, error_result, state}
    end
  end

  defp handle_success(result, state) do
    effective_threshold = effective_success_threshold(state)

    case state.state do
      :closed ->
        new_state = %{state | failure_count: 0}
        {:reply, {:ok, result}, new_state}

      :open ->
        cancel_recovery_timer(state.recovery_timer_ref)

        :telemetry.execute([:lasso, :circuit_breaker, :half_open], %{count: 1}, %{
          instance_id: state.instance_id,
          transport: state.transport,
          from_state: :open,
          to_state: :half_open,
          reason: :recovery_attempt,
          consecutive_open_count: state.consecutive_open_count
        })

        if 1 >= effective_threshold do
          reset_to_closed(%{state | recovery_timer_ref: nil}, :open, result)
        else
          new_state = %{
            state
            | state: :half_open,
              success_count: 1,
              failure_count: 0,
              recovery_timer_ref: nil
          }

          publish_circuit_event(new_state, :open, :half_open, :recovery_attempt)
          write_ets_state(new_state)
          {:reply, {:ok, result}, new_state}
        end

      :half_open ->
        new_success_count = state.success_count + 1

        if new_success_count >= effective_threshold do
          reset_to_closed(state, :half_open, result)
        else
          new_state = %{state | success_count: new_success_count}
          {:reply, {:ok, result}, new_state}
        end
    end
  end

  defp reset_to_closed(state, from_state, result) do
    :telemetry.execute([:lasso, :circuit_breaker, :close], %{count: 1}, %{
      instance_id: state.instance_id,
      transport: state.transport,
      from_state: from_state,
      to_state: :closed,
      reason: :recovered
    })

    new_state = %{
      state
      | state: :closed,
        failure_count: 0,
        success_count: 0,
        last_failure_time: nil,
        opened_by_category: nil,
        recovery_timer_ref: nil,
        last_open_error: nil,
        consecutive_open_count: 0,
        recovery_deadline_ms: nil,
        effective_recovery_delay: nil
    }

    publish_circuit_event(new_state, from_state, :closed, :recovered)
    write_ets_state(new_state)
    {:reply, {:ok, result}, new_state}
  end

  defp effective_success_threshold(%{opened_by_category: :rate_limit}), do: 1
  defp effective_success_threshold(state), do: state.success_threshold

  defp handle_failure(error, state) do
    new_failure_count = state.failure_count + 1
    current_time = System.monotonic_time(:millisecond)

    error_category = if is_struct(error, JError), do: error.category, else: :unknown_error
    threshold = Map.get(state.category_thresholds, error_category, state.failure_threshold)

    adjusted_recovery_timeout =
      if error_category == :rate_limit and is_struct(error, JError) do
        extract_retry_after(error) || state.base_recovery_timeout
      else
        state.base_recovery_timeout
      end

    :telemetry.execute(
      [:lasso, :circuit_breaker, :failure],
      %{count: 1},
      %{
        instance_id: state.instance_id,
        transport: state.transport,
        error_category: error_category,
        circuit_state: state.state
      }
    )

    case state.state do
      :closed ->
        if new_failure_count >= threshold do
          :telemetry.execute([:lasso, :circuit_breaker, :open], %{count: 1}, %{
            instance_id: state.instance_id,
            transport: state.transport,
            from_state: :closed,
            to_state: :open,
            reason: :failure_threshold_exceeded,
            error_category: error_category,
            failure_count: new_failure_count,
            recovery_timeout_ms: adjusted_recovery_timeout
          })

          delay = adjusted_recovery_timeout
          delay_with_jitter = add_jitter(delay)
          new_gen = state.recovery_timer_gen + 1
          timer_ref = schedule_recovery_timer(delay_with_jitter, new_gen)

          new_state = %{
            state
            | state: :open,
              failure_count: new_failure_count,
              last_failure_time: current_time,
              opened_by_category: error_category,
              recovery_timer_ref: timer_ref,
              recovery_timer_gen: new_gen,
              recovery_deadline_ms: current_time + delay_with_jitter,
              effective_recovery_delay: delay,
              last_open_error: extract_error_info(error)
          }

          publish_circuit_event(new_state, :closed, :open, :failure_threshold_exceeded, error)
          write_ets_state(new_state)
          {:reply, {:error, :circuit_opening}, new_state}
        else
          new_state = %{state | failure_count: new_failure_count, last_failure_time: current_time}
          {:reply, {:error, error}, new_state}
        end

      :half_open ->
        new_consecutive_open_count = state.consecutive_open_count + 1

        new_state_for_backoff = %{state | consecutive_open_count: new_consecutive_open_count}
        delay = compute_reopen_delay(new_state_for_backoff, error, error_category)
        delay_with_jitter = add_jitter(delay)
        new_gen = state.recovery_timer_gen + 1
        now = System.monotonic_time(:millisecond)
        timer_ref = schedule_recovery_timer(delay_with_jitter, new_gen)

        :telemetry.execute([:lasso, :circuit_breaker, :open], %{count: 1}, %{
          instance_id: state.instance_id,
          transport: state.transport,
          from_state: :half_open,
          to_state: :open,
          reason: :reopen_due_to_failure,
          error_category: error_category,
          failure_count: new_failure_count,
          recovery_timeout_ms: delay,
          consecutive_open_count: new_consecutive_open_count
        })

        new_state = %{
          state
          | state: :open,
            failure_count: new_failure_count,
            last_failure_time: current_time,
            success_count: 0,
            recovery_timer_ref: timer_ref,
            recovery_timer_gen: new_gen,
            recovery_deadline_ms: now + delay_with_jitter,
            effective_recovery_delay: delay,
            last_open_error: extract_error_info(error),
            consecutive_open_count: new_consecutive_open_count,
            opened_by_category: error_category
        }

        publish_circuit_event(new_state, :half_open, :open, :reopen_due_to_failure, error)
        write_ets_state(new_state)
        {:reply, {:error, :circuit_reopening}, new_state}

      :open ->
        new_state = %{
          state
          | failure_count: new_failure_count,
            last_failure_time: current_time
        }

        {:reply, {:error, :circuit_open}, new_state}
    end
  end

  defp should_attempt_recovery?(state) do
    case state.recovery_deadline_ms do
      nil -> true
      deadline -> System.monotonic_time(:millisecond) >= deadline
    end
  end

  defp compute_reopen_delay(state, error, error_category) do
    explicit_retry_after =
      if error_category == :rate_limit and is_struct(error, JError) do
        extract_retry_after(error)
      end

    if explicit_retry_after do
      min(explicit_retry_after, state.max_recovery_timeout)
    else
      base = state.base_recovery_timeout
      multiplier = trunc(:math.pow(2, min(state.consecutive_open_count, 4)))
      min(base * multiplier, state.max_recovery_timeout)
    end
  end

  defp add_jitter(delay_ms) do
    jitter_ms = :rand.uniform(max(1, div(delay_ms, 20)))
    delay_ms + jitter_ms
  end

  defp schedule_recovery_timer(delay_ms, gen) do
    Process.send_after(self(), {:attempt_proactive_recovery, gen}, delay_ms)
  end

  defp cancel_recovery_timer(nil), do: :ok

  defp cancel_recovery_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp write_ets_state(state) do
    :ets.insert(:lasso_instance_state, {
      {:circuit, state.instance_id, state.transport},
      %{
        state: state.state,
        error: state.last_open_error,
        recovery_deadline_ms: state.recovery_deadline_ms
      }
    })
  rescue
    ArgumentError -> :ok
  end

  defp publish_circuit_event(state, from, to, reason, error \\ nil) do
    error_info =
      case error do
        %JError{code: code, category: category, message: msg} ->
          %{
            error_code: code,
            error_category: category,
            error_message: truncate_error_message(msg)
          }

        _ ->
          nil
      end

    {chain, refs} =
      try do
        chain =
          case Catalog.get_instance(state.instance_id) do
            {:ok, %{chain: c}} -> c
            _ -> nil
          end

        refs = Catalog.get_instance_refs(state.instance_id)
        {chain, refs}
      rescue
        ArgumentError ->
          Logger.debug(
            "Catalog unavailable for circuit event fan-out (instance: #{state.instance_id})"
          )

          {nil, []}
      end

    Enum.each(refs, fn profile ->
      provider_id = Catalog.reverse_lookup_provider_id(profile, chain, state.instance_id)

      event =
        {:circuit_breaker_event,
         %{
           ts: System.system_time(:millisecond),
           profile: profile,
           chain: chain,
           provider_id: provider_id || state.instance_id,
           instance_id: state.instance_id,
           transport: state.transport,
           from: from,
           to: to,
           reason: reason,
           error: error_info,
           source_node_id: Lasso.Cluster.Topology.get_self_node_id(),
           source_node: node()
         }}

      Phoenix.PubSub.broadcast(Lasso.PubSub, "circuit:events:#{profile}:#{chain}", event)
    end)
  end

  defp truncate_error_message(msg) when is_binary(msg) do
    if String.length(msg) > 100 do
      String.slice(msg, 0, 97) <> "..."
    else
      msg
    end
  end

  defp truncate_error_message(other), do: inspect(other) |> truncate_error_message()

  defp extract_retry_after(%JError{data: data}) when is_map(data) do
    Map.get(data, :retry_after_ms) || Map.get(data, "retry_after_ms")
  end

  defp extract_retry_after(_), do: nil

  defp extract_error_info(%JError{code: code, category: category, message: msg}) do
    %{
      code: code,
      category: category,
      message: truncate_error_message(msg)
    }
  end

  defp extract_error_info(_), do: nil

  # Shared circuit breakers should only trip on clearly provider-wide failures.
  # This avoids cross-profile coupling from workload-specific timeout patterns.
  defp shared_breaker_penalty?(%JError{category: :server_error}, %{shared_mode: true}), do: true
  defp shared_breaker_penalty?(%JError{category: :network_error}, %{shared_mode: true}), do: true
  defp shared_breaker_penalty?(%JError{category: :timeout}, %{shared_mode: true}), do: false
  defp shared_breaker_penalty?(%JError{category: :auth_error}, %{shared_mode: true}), do: false

  defp shared_breaker_penalty?(%JError{breaker_penalty?: penalty}, %{shared_mode: true}),
    do: penalty

  defp shared_breaker_penalty?(%JError{breaker_penalty?: penalty}, _state), do: penalty
  defp shared_breaker_penalty?(_, _state), do: false

  @doc false
  @spec via_name({String.t(), atom()}) :: {:via, Registry, {Lasso.Registry, term()}}
  def via_name({instance_id, transport}) when is_binary(instance_id) do
    {:via, Registry, {Lasso.Registry, {:circuit_breaker, "#{instance_id}:#{transport}"}}}
  end
end

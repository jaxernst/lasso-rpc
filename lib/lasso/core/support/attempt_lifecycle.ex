defmodule Lasso.Core.Support.AttemptLifecycle do
  @moduledoc false

  require Logger

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Core.Support.CircuitBreaker.AdmissionReceipt
  alias Lasso.Core.Transport.AttemptProtocol
  alias Lasso.JSONRPC.Error, as: JError

  @dispatch_context_key :lasso_attempt_dispatch_context
  @deadline_key :lasso_attempt_deadline_us
  @dispatch_receipt_key :lasso_attempt_dispatch_receipt
  @dispatch_timestamp_unset -9_223_372_036_854_775_808
  @open_unset 0
  @open_ambiguous 1
  @open_not_dispatched 2
  @open_dispatched 3
  @closed_offset 4

  @type terminal_callback :: CircuitBreaker.terminal_callback() | nil
  @type dispatch_callback :: (integer() -> term()) | nil
  @type dispatch_context :: AttemptProtocol.context()

  @spec run(
          pid(),
          AdmissionReceipt.t(),
          (-> term()),
          non_neg_integer(),
          terminal_callback()
        ) :: term()
  def run(caller_pid, receipt, fun, timeout, terminal_callback) do
    run(caller_pid, receipt, fun, timeout, terminal_callback, nil, :immediate)
  end

  @doc false
  @spec run(
          pid(),
          CircuitBreaker.breaker_id(),
          reference(),
          (-> term()),
          non_neg_integer(),
          terminal_callback()
        ) :: term()
  def run(caller_pid, breaker_id, token, fun, timeout, terminal_callback) do
    receipt = legacy_receipt(breaker_id, token)
    run(caller_pid, receipt, fun, timeout, terminal_callback, nil, :immediate)
  end

  @spec run(
          pid(),
          AdmissionReceipt.t(),
          (-> term()),
          non_neg_integer(),
          terminal_callback(),
          dispatch_callback(),
          :immediate | :deferred
        ) :: term()
  def run(
        caller_pid,
        %AdmissionReceipt{} = receipt,
        fun,
        timeout,
        terminal_callback,
        dispatch_callback,
        dispatch_mode
      ) do
    deadline_us = System.monotonic_time(:microsecond) + timeout * 1_000

    run(
      caller_pid,
      receipt,
      fun,
      timeout,
      terminal_callback,
      dispatch_callback,
      dispatch_mode,
      deadline_us
    )
  end

  @doc false
  def run(caller_pid, breaker_id, token, fun, timeout, terminal_callback, dispatch_mode) do
    receipt = legacy_receipt(breaker_id, token)
    run(caller_pid, receipt, fun, timeout, terminal_callback, nil, dispatch_mode)
  end

  @doc false
  @spec run(
          pid(),
          AdmissionReceipt.t(),
          (-> term()),
          non_neg_integer(),
          terminal_callback(),
          dispatch_callback(),
          :immediate | :deferred,
          integer()
        ) :: term()
  def run(
        caller_pid,
        %AdmissionReceipt{} = receipt,
        fun,
        timeout,
        terminal_callback,
        dispatch_callback,
        dispatch_mode,
        deadline_us
      ) do
    lifecycle_ref = make_ref()
    lifecycle_start_ref = make_ref()
    dispatch_latch = new_dispatch_latch()
    attempt_deadline_us = attempt_deadline_us(deadline_us, timeout)

    case claim_for_execution(receipt, caller_pid, dispatch_latch, attempt_deadline_us) do
      :ok ->
        context = %{
          caller_pid: caller_pid,
          lifecycle_ref: lifecycle_ref,
          lifecycle_start_ref: lifecycle_start_ref,
          receipt: receipt,
          fun: fun,
          timeout: timeout,
          legacy_terminal_callback: terminal_callback,
          dispatch_mode: dispatch_mode,
          attempt_deadline_us: attempt_deadline_us,
          lifecycle_deadline_us: attempt_deadline_us,
          dispatch_latch: dispatch_latch
        }

        {lifecycle_pid, monitor_ref} = spawn_monitor(fn -> execute(context) end)

        terminal_dispatch_callback =
          prepare_dispatch(
            dispatch_mode,
            dispatch_latch,
            dispatch_callback,
            attempt_deadline_us
          )

        send(lifecycle_pid, {:start_attempt_lifecycle, lifecycle_start_ref})

        terminal_candidate =
          receive do
            {^lifecycle_ref,
             {:attempt_terminal_candidate, result, elapsed_ms, accounting?, callback_eligible?}} ->
              {:candidate, result, elapsed_ms, accounting?, callback_eligible?}

            {:DOWN, ^monitor_ref, :process, ^lifecycle_pid, reason} ->
              {:owner_down, reason}
          after
            deadline_wait_ms(attempt_deadline_us) ->
              :client_timeout
          end

        {certainty, dispatched_at_us} = close_dispatch_latch(dispatch_latch)

        {result, elapsed_ms, accounting?} =
          outer_terminal_candidate(
            terminal_candidate,
            certainty,
            dispatched_at_us,
            timeout
          )

        if accounting? do
          finalize_receipt(dispatch_latch, receipt, result, certainty, terminal_callback)

          publish_owner_terminal(
            receipt.breaker_id,
            result,
            certainty,
            dispatched_at_us,
            terminal_dispatch_callback
          )
        end

        finish_compatibility_lifecycle(
          terminal_candidate,
          lifecycle_pid,
          monitor_ref,
          lifecycle_ref,
          result,
          terminal_elapsed_ms(elapsed_ms, dispatched_at_us),
          accounting?,
          certainty
        )

        result

      {:error, reason} ->
        {:__attempt_lifecycle_rejected__, reason}
    end
  end

  @doc false
  @spec run(
          pid(),
          CircuitBreaker.breaker_id(),
          reference(),
          (-> term()),
          non_neg_integer(),
          terminal_callback(),
          dispatch_callback(),
          :immediate | :deferred
        ) :: term()
  def run(
        caller_pid,
        breaker_id,
        token,
        fun,
        timeout,
        terminal_callback,
        dispatch_callback,
        dispatch_mode
      ) do
    receipt = legacy_receipt(breaker_id, token)
    run(caller_pid, receipt, fun, timeout, terminal_callback, dispatch_callback, dispatch_mode)
  end

  @doc false
  @spec dispatch_context() :: dispatch_context() | nil
  def dispatch_context, do: Process.get(@dispatch_context_key)

  @doc false
  @spec deadline_us() :: integer() | nil
  def deadline_us, do: Process.get(@deadline_key)

  @doc false
  @spec dispatch_owner_alive?() :: boolean()
  def dispatch_owner_alive? do
    case Process.get(@dispatch_receipt_key) do
      %{caller_pid: caller_pid} -> Process.alive?(caller_pid)
      _ -> true
    end
  end

  @doc false
  @spec record_dispatch_state(:ambiguous | :not_dispatched | :dispatched, integer()) ::
          :ok | {:error, :owner_down | :deadline_expired}
  def record_dispatch_state(certainty, event_us)
      when certainty in [:ambiguous, :not_dispatched, :dispatched] and is_integer(event_us) do
    case Process.get(@dispatch_receipt_key) do
      %{latch: latch, caller_pid: caller_pid} ->
        deadline_us = deadline_us()

        cond do
          not Process.alive?(caller_pid) -> {:error, :owner_down}
          is_integer(deadline_us) and event_us >= deadline_us -> {:error, :deadline_expired}
          true -> transition_dispatch_latch(latch, certainty, event_us)
        end

      %{latch: latch} ->
        transition_dispatch_latch(latch, certainty, event_us)

      _ ->
        :ok
    end
  end

  @doc false
  @spec authorize_dispatch(dispatch_context() | nil) :: :ok | {:error, :cancelled}
  def authorize_dispatch(nil), do: :ok

  def authorize_dispatch(%AttemptProtocol.Context{} = context) do
    if AttemptProtocol.authorized?(context, context.deadline_us),
      do: :ok,
      else: {:error, :cancelled}
  end

  def authorize_dispatch({lifecycle_pid, _dispatch_ref}),
    do: if(Process.alive?(lifecycle_pid), do: :ok, else: {:error, :cancelled})

  @doc false
  @spec confirm_dispatched(dispatch_context() | nil) :: :ok | {:error, :cancelled}
  def confirm_dispatched(nil), do: :ok

  def confirm_dispatched(%AttemptProtocol.Context{} = context) do
    case AttemptProtocol.send_started(context) do
      :ok -> AttemptProtocol.send_confirmed(context)
      {:error, _reason} -> {:error, :cancelled}
    end
  end

  def confirm_dispatched({lifecycle_pid, _dispatch_ref} = context) do
    if Process.alive?(lifecycle_pid) do
      case AttemptProtocol.send_started(context) do
        :ok -> AttemptProtocol.send_confirmed(context)
        {:error, _reason} -> {:error, :cancelled}
      end
    else
      {:error, :cancelled}
    end
  end

  @doc false
  @spec abort_dispatch(dispatch_context() | nil) :: :ok | {:error, :cancelled}
  def abort_dispatch(nil), do: :ok

  def abort_dispatch(%AttemptProtocol.Context{} = context) do
    if AttemptProtocol.authorized?(context, context.deadline_us) do
      AttemptProtocol.predispatch_failure(context, :local)
    else
      {:error, :cancelled}
    end
  end

  def abort_dispatch({lifecycle_pid, _dispatch_ref} = context) do
    if Process.alive?(lifecycle_pid) do
      AttemptProtocol.predispatch_failure(context, :local)
    else
      {:error, :cancelled}
    end
  end

  @doc false
  @spec mark_dispatched(dispatch_context() | nil) :: :ok | {:error, :cancelled}
  def mark_dispatched(context), do: confirm_dispatched(context)

  defp claim_for_execution(receipt, caller_pid, dispatch_latch, attempt_deadline_us) do
    case claim_receipt(receipt, caller_pid) do
      :ok ->
        mark_receipt_claimed(dispatch_latch)

        if Process.alive?(caller_pid) and
             System.monotonic_time(:microsecond) < attempt_deadline_us do
          :ok
        else
          release_receipt(receipt)
          mark_receipt_finalized(dispatch_latch)
          {:error, :timeout}
        end

      {:error, reason} ->
        abandon_unclaimed_receipt(receipt, caller_pid)
        mark_receipt_finalized(dispatch_latch)
        {:error, reason}
    end
  end

  defp prepare_dispatch(:deferred, _latch, dispatch_callback, _attempt_deadline_us),
    do: dispatch_callback

  defp prepare_dispatch(:immediate, latch, dispatch_callback, attempt_deadline_us) do
    dispatched_at_us = System.monotonic_time(:microsecond)

    if dispatched_at_us < attempt_deadline_us do
      :ok = transition_dispatch_latch(latch, :dispatched, dispatched_at_us)
      invoke_dispatch_callback(dispatch_callback, dispatched_at_us)
      nil
    else
      dispatch_callback
    end
  end

  defp execute(context) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(context.caller_pid)

    receive do
      {:start_attempt_lifecycle, start_ref} when start_ref == context.lifecycle_start_ref ->
        if Process.alive?(context.caller_pid) and
             System.monotonic_time(:microsecond) < context.attempt_deadline_us do
          start_attempt(Map.put(context, :caller_monitor, caller_monitor))
        else
          release_receipt(context.receipt)
          mark_receipt_finalized(context.dispatch_latch)

          send_terminal_candidate(
            context,
            {:__attempt_lifecycle_rejected__, :timeout},
            nil,
            false,
            false
          )
        end

      {:DOWN, ^caller_monitor, :process, caller_pid, _reason}
      when caller_pid == context.caller_pid ->
        :ok
    after
      deadline_wait_ms(context.attempt_deadline_us) ->
        release_receipt(context.receipt)
        mark_receipt_finalized(context.dispatch_latch)

        send_terminal_candidate(
          context,
          {:__attempt_lifecycle_rejected__, :timeout},
          nil,
          false,
          false
        )
    end
  end

  defp start_attempt(context) do
    dispatch_ref = make_ref()
    task_ref = make_ref()
    lifecycle_pid = self()

    {task_pid, task_monitor} =
      :erlang.spawn_opt(
        fn ->
          Process.put(@dispatch_context_key, {lifecycle_pid, dispatch_ref})
          Process.put(@deadline_key, context.attempt_deadline_us)

          Process.put(@dispatch_receipt_key, %{
            latch: context.dispatch_latch,
            caller_pid: context.caller_pid
          })

          receive do
            {:run_attempt, ^task_ref} ->
              result = execute_fun(context.fun)

              send(
                lifecycle_pid,
                {:attempt_task_result, task_ref, System.monotonic_time(:microsecond), result}
              )
          end
        end,
        [:link, :monitor]
      )

    phase = initial_phase(context)
    send(task_pid, {:run_attempt, task_ref})

    loop(
      Map.merge(context, %{
        dispatch_ref: dispatch_ref,
        task_ref: task_ref,
        task_pid: task_pid,
        task_monitor: task_monitor,
        phase: phase,
        started_at_us: System.monotonic_time(:microsecond),
        terminal_candidate_at_us: nil,
        completed_result: nil
      })
    )
  end

  defp loop(state) do
    receive do
      {:transport_observation, dispatch_ref, observation}
      when dispatch_ref == state.dispatch_ref and is_map(observation) ->
        loop(apply_transport_observation(state, observation))

      {:attempt_task_result, task_ref, completed_at_us, result} when task_ref == state.task_ref ->
        Process.demonitor(state.task_monitor, [:flush])

        if result_eligible?(state, completed_at_us),
          do: handle_task_result(state, unwrap_result(result)),
          else: handle_interruption(state, :timeout)

      {:DOWN, monitor_ref, :process, caller_pid, _reason}
      when monitor_ref == state.caller_monitor and caller_pid == state.caller_pid ->
        stop_task(state)

      {:DOWN, monitor_ref, :process, task_pid, reason}
      when monitor_ref == state.task_monitor and task_pid == state.task_pid ->
        handle_task_death(state, reason)

      {:EXIT, task_pid, reason} when task_pid == state.task_pid ->
        handle_task_death(state, reason)
    after
      remaining_timeout(state) ->
        handle_interruption(state, :timeout)
    end
  end

  defp initial_phase(%{dispatch_mode: :immediate} = context) do
    dispatched_at_us =
      dispatch_timestamp(context.dispatch_latch) || System.monotonic_time(:microsecond)

    transition_dispatch_latch(context.dispatch_latch, :dispatched, dispatched_at_us)
    {:dispatched, dispatched_at_us}
  end

  defp initial_phase(_context), do: :predispatch

  defp open_send_phase(phase, started_at_us) do
    case phase do
      {:ambiguous, _} -> {phase, :unchanged}
      {:dispatched, _} -> {phase, :unchanged}
      _ -> {{:ambiguous, started_at_us}, {:transitioned, started_at_us}}
    end
  end

  defp confirm_phase(phase, dispatched_at_us) do
    case phase do
      {:ambiguous, started_at_us} -> {{:dispatched, started_at_us}, :unchanged}
      {:dispatched, _} -> {phase, :unchanged}
      _ -> {{:dispatched, dispatched_at_us}, {:transitioned, dispatched_at_us}}
    end
  end

  defp abort_phase({:dispatched, _} = phase), do: phase
  defp abort_phase(_phase), do: :aborted

  defp apply_transport_observation(
         state,
         %{kind: :send_started, event_us: event_us}
       )
       when event_us < state.attempt_deadline_us do
    transition_dispatch_latch(state.dispatch_latch, :ambiguous, event_us)
    {phase, _transition} = open_send_phase(state.phase, event_us)
    %{state | phase: phase}
  end

  defp apply_transport_observation(
         state,
         %{kind: :send_confirmed, event_us: event_us}
       )
       when event_us < state.attempt_deadline_us do
    transition_dispatch_latch(state.dispatch_latch, :dispatched, event_us)
    {phase, _transition} = confirm_phase(state.phase, event_us)
    %{state | phase: phase}
  end

  defp apply_transport_observation(
         state,
         %{kind: :predispatch_failure, event_us: event_us}
       )
       when event_us < state.attempt_deadline_us do
    transition_dispatch_latch(state.dispatch_latch, :not_dispatched, event_us)
    %{state | phase: abort_phase(state.phase), terminal_candidate_at_us: event_us}
  end

  defp apply_transport_observation(
         state,
         %{kind: :transport_failure, event_us: event_us, certainty: :not_dispatched}
       )
       when event_us < state.attempt_deadline_us do
    transition_dispatch_latch(state.dispatch_latch, :not_dispatched, event_us)
    %{state | phase: abort_phase(state.phase), terminal_candidate_at_us: event_us}
  end

  defp apply_transport_observation(
         state,
         %{kind: :transport_failure, event_us: event_us, certainty: :indeterminate}
       )
       when event_us < state.attempt_deadline_us do
    transition_dispatch_latch(state.dispatch_latch, :ambiguous, event_us)
    {phase, _transition} = open_send_phase(state.phase, event_us)
    %{state | phase: phase, terminal_candidate_at_us: event_us}
  end

  defp apply_transport_observation(
         state,
         %{kind: :transport_failure, event_us: event_us, certainty: :dispatched}
       )
       when event_us < state.attempt_deadline_us do
    transition_dispatch_latch(state.dispatch_latch, :dispatched, event_us)
    {phase, _transition} = confirm_phase(state.phase, event_us)
    %{state | phase: phase, terminal_candidate_at_us: event_us}
  end

  defp apply_transport_observation(state, %{kind: kind, event_us: event_us})
       when event_us < state.attempt_deadline_us and kind in [:response, :invalid_response] do
    transition_dispatch_latch(state.dispatch_latch, :dispatched, event_us)
    {phase, _transition} = confirm_phase(state.phase, event_us)
    %{state | phase: phase, terminal_candidate_at_us: event_us}
  end

  defp apply_transport_observation(state, _observation), do: state

  defp handle_task_result(%{phase: {:dispatched, dispatched_at_us}} = state, result) do
    finalize_dispatched(state, result, elapsed_ms(dispatched_at_us))
  end

  defp handle_task_result(%{phase: {:ambiguous, started_at_us}} = state, result) do
    finalize_dispatched(state, result, elapsed_ms(started_at_us))
  end

  defp handle_task_result(%{phase: :predispatch} = state, result) do
    if predispatch_result?(result) do
      finalize_predispatch(state, result)
    else
      transition_dispatch_latch(state.dispatch_latch, :dispatched, state.started_at_us)
      finalize_dispatched(state, result, elapsed_ms(state.started_at_us))
    end
  end

  defp handle_task_result(%{phase: :aborted} = state, result) do
    finalize_predispatch(state, result)
  end

  defp handle_task_death(state, :normal) do
    case take_completed_result(state) do
      {:ok, result} -> handle_task_result(state, result)
      :none -> handle_task_death(state, :missing_result)
    end
  end

  defp handle_task_death(%{phase: {:dispatched, dispatched_at_us}} = state, reason) do
    finalize_dispatched(state, task_exit_result(reason), elapsed_ms(dispatched_at_us))
  end

  defp handle_task_death(%{phase: {:ambiguous, started_at_us}} = state, reason) do
    finalize_dispatched(state, task_exit_result(reason), elapsed_ms(started_at_us))
  end

  defp handle_task_death(%{phase: :predispatch} = state, reason) do
    finalize_predispatch(state, task_exit_result(reason))
  end

  defp handle_task_death(%{phase: :aborted} = state, reason) do
    finalize_predispatch(state, task_exit_result(reason))
  end

  defp handle_interruption(state, terminal) do
    state = drain_queued_closure_messages(state)

    case take_completed_result(state) do
      {:ok, result} ->
        Process.demonitor(state.task_monitor, [:flush])
        handle_task_result(state, result)

      :none ->
        finalize_interruption(state, terminal)
    end
  end

  defp finalize_interruption(%{phase: :predispatch} = state, :timeout) do
    stop_task(state)

    send_terminal_candidate(
      state,
      {:__attempt_lifecycle_rejected__, :timeout},
      nil,
      true,
      false
    )
  end

  defp finalize_interruption(%{phase: :aborted} = state, :timeout) do
    stop_task(state)

    send_terminal_candidate(
      state,
      {:__attempt_lifecycle_rejected__, :timeout},
      nil,
      true,
      false
    )
  end

  defp finalize_interruption(%{phase: {certainty, started_at_us}} = state, :timeout)
       when certainty in [:dispatched, :ambiguous] do
    stop_task(state)
    finalize_timeout(state, elapsed_ms(started_at_us))
  end

  defp drain_queued_closure_messages(state) do
    {observations, completed_result} =
      take_queued_closure_messages(state.dispatch_ref, state.task_ref, [], state.completed_result)

    state =
      observations
      |> Enum.reverse()
      |> Enum.reduce(state, &apply_transport_observation(&2, &1))

    %{state | completed_result: completed_result}
  end

  defp take_queued_closure_messages(dispatch_ref, task_ref, observations, completed_result) do
    receive do
      {:transport_observation, ^dispatch_ref, observation} when is_map(observation) ->
        take_queued_closure_messages(
          dispatch_ref,
          task_ref,
          [observation | observations],
          completed_result
        )

      {:attempt_task_result, ^task_ref, completed_at_us, result} ->
        take_queued_closure_messages(
          dispatch_ref,
          task_ref,
          observations,
          {completed_at_us, result}
        )
    after
      0 -> {observations, completed_result}
    end
  end

  defp take_completed_result(state) do
    case state.completed_result do
      {completed_at_us, result} ->
        if result_eligible?(state, completed_at_us),
          do: {:ok, unwrap_result(result)},
          else: :none

      nil ->
        receive do
          {:attempt_task_result, task_ref, completed_at_us, result}
          when task_ref == state.task_ref ->
            if result_eligible?(state, completed_at_us),
              do: {:ok, unwrap_result(result)},
              else: :none
        after
          0 -> :none
        end
    end
  end

  defp result_eligible?(state, completed_at_us),
    do: completed_at_us < state.attempt_deadline_us

  defp stop_task(state) do
    if Process.alive?(state.task_pid), do: Process.exit(state.task_pid, :kill)
    Process.demonitor(state.task_monitor, [:flush])
  end

  defp finalize_predispatch(state, result) do
    send_terminal_candidate(state, result, nil, true, true)
  end

  defp finalize_dispatched(state, result, elapsed_ms) do
    send_terminal_candidate(state, result, elapsed_ms, true, true)
  end

  defp finalize_timeout(state, elapsed_ms) do
    result =
      {:error,
       JError.new(-32_000, "Request timeout after #{state.timeout}ms",
         category: :timeout,
         retriable?: true,
         breaker_penalty?: true
       ), state.timeout}

    send_terminal_candidate(state, result, elapsed_ms, true, false)
  end

  defp execute_fun(fun) do
    {:__attempt_result__, fun.()}
  catch
    kind, error -> {:__attempt_exception__, {kind, error, __STACKTRACE__}}
  end

  defp unwrap_result({:__attempt_result__, result}), do: result
  defp unwrap_result({:__attempt_exception__, exception}), do: {:exception, exception}
  defp task_exit_result(reason), do: {:exception, {:exit, reason, []}}

  defp predispatch_result?({:error, :unsupported_method, _io_ms}), do: true

  defp predispatch_result?({:error, %JError{category: :local_capacity_rejection}, _io_ms}),
    do: true

  defp predispatch_result?(_result), do: false

  defp breaker_result({:exception, {_kind, _error, _stacktrace}}, terminal_callback)
       when is_function(terminal_callback, 2) do
    {:error,
     JError.new(-32_000, "Local attempt execution exception",
       category: :internal_error,
       retriable?: false,
       breaker_penalty?: false
     )}
  end

  defp breaker_result({:exception, {kind, error, _stacktrace}}, _terminal_callback),
    do: {:error, {kind, error}}

  defp breaker_result(result, _terminal_callback), do: result

  defp elapsed_ms(dispatched_at_us) do
    max(System.monotonic_time(:microsecond) - dispatched_at_us, 0) / 1000
  end

  defp remaining_timeout(state) do
    remaining_ms(state.lifecycle_deadline_us, 0)
  end

  defp send_terminal_candidate(state, result, elapsed_ms, accounting?, callback_eligible?) do
    send(
      state.caller_pid,
      {state.lifecycle_ref,
       {:attempt_terminal_candidate, result, elapsed_ms, accounting?, callback_eligible?}}
    )

    if accounting? and callback_eligible?, do: await_compatibility_callback(state)
  end

  # Compatibility boundary: this process may be lost or remain blocked in a legacy callback.
  # Owner cutover deletes this path in favor of the bounded projection dispatcher.
  defp await_compatibility_callback(state) do
    receive do
      {lifecycle_ref, {:authorize_legacy_terminal_callback, result, elapsed_ms}}
      when lifecycle_ref == state.lifecycle_ref ->
        Process.demonitor(state.caller_monitor, [:flush])
        invoke_terminal_callback(state.legacy_terminal_callback, result, elapsed_ms)

      {:DOWN, monitor_ref, :process, caller_pid, _reason}
      when monitor_ref == state.caller_monitor and caller_pid == state.caller_pid ->
        :ok
    end
  end

  defp remaining_ms(deadline_us, minimum) do
    remaining_us = max(deadline_us - System.monotonic_time(:microsecond), 0)
    max(div(remaining_us + 999, 1_000), minimum)
  end

  defp deadline_wait_ms(deadline_us), do: remaining_ms(deadline_us, 0)

  defp claim_receipt(%AdmissionReceipt{kind: :closed}, _caller_pid), do: :ok

  defp claim_receipt(
         %AdmissionReceipt{kind: :half_open, breaker_id: id, token: token} = receipt,
         caller_pid
       ) do
    CircuitBreaker.claim_attempt(id, token, caller_pid, receipt)
  end

  defp claim_receipt(%AdmissionReceipt{kind: :legacy, breaker_id: id, token: token}, caller_pid) do
    CircuitBreaker.claim_attempt(id, token, caller_pid)
  end

  defp report_receipt(%AdmissionReceipt{kind: :closed} = receipt, result) do
    CircuitBreaker.report_closed(receipt, result)
  end

  defp report_receipt(%AdmissionReceipt{kind: :half_open} = receipt, result) do
    CircuitBreaker.report_half_open(receipt, result)
  end

  defp report_receipt(%AdmissionReceipt{kind: :legacy, breaker_id: id, token: token}, result) do
    CircuitBreaker.report_attempt(id, token, result)
  end

  defp release_receipt(%AdmissionReceipt{kind: :closed}), do: :ok

  defp release_receipt(%AdmissionReceipt{kind: :half_open} = receipt) do
    CircuitBreaker.release_half_open(receipt)
  end

  defp release_receipt(%AdmissionReceipt{kind: :legacy, breaker_id: id, token: token}) do
    CircuitBreaker.release_attempt(id, token)
  end

  defp abandon_unclaimed_receipt(%AdmissionReceipt{kind: :half_open} = receipt, caller_pid) do
    CircuitBreaker.abandon_unclaimed(receipt, caller_pid)
  end

  defp abandon_unclaimed_receipt(_receipt, _caller_pid), do: :ok

  defp legacy_receipt(breaker_id, token) do
    %AdmissionReceipt{
      breaker_id: breaker_id,
      kind: :legacy,
      generation: 0,
      epoch: 1,
      owner_pid: self(),
      token: token
    }
  end

  defp invoke_terminal_callback(nil, _result, _elapsed_ms), do: :ok

  defp invoke_terminal_callback(callback, result, elapsed_ms) when is_function(callback, 2) do
    try do
      callback.(result, elapsed_ms)
    catch
      kind, error ->
        Logger.error("Attempt terminal callback failed", kind: kind, error: inspect(error))
    end

    :ok
  end

  defp invoke_dispatch_callback(nil, _dispatched_at_us), do: :ok

  defp invoke_dispatch_callback(callback, dispatched_at_us) when is_function(callback, 1) do
    try do
      callback.(dispatched_at_us)
    catch
      kind, error ->
        Logger.error("Attempt dispatch callback failed", kind: kind, error: inspect(error))
    end

    :ok
  end

  defp new_dispatch_latch do
    latch = :atomics.new(3, signed: true)
    :atomics.put(latch, 1, @open_unset)
    :atomics.put(latch, 2, @dispatch_timestamp_unset)
    :atomics.put(latch, 3, 0)
    latch
  end

  defp transition_dispatch_latch(latch, certainty, event_us) do
    if certainty in [:ambiguous, :dispatched], do: record_dispatch_timestamp(latch, event_us)

    current = :atomics.get(latch, 1)

    case next_open_dispatch_state(current, certainty) do
      :closed ->
        {:error, :owner_down}

      ^current ->
        :ok

      next ->
        case :atomics.compare_exchange(latch, 1, current, next) do
          :ok -> :ok
          _raced -> transition_dispatch_latch(latch, certainty, event_us)
        end
    end
  end

  defp next_open_dispatch_state(current, _certainty) when current >= @closed_offset,
    do: :closed

  defp next_open_dispatch_state(@open_dispatched, _certainty), do: @open_dispatched
  defp next_open_dispatch_state(@open_not_dispatched, :ambiguous), do: @open_not_dispatched
  defp next_open_dispatch_state(_current, :ambiguous), do: @open_ambiguous
  defp next_open_dispatch_state(_current, :not_dispatched), do: @open_not_dispatched
  defp next_open_dispatch_state(_current, :dispatched), do: @open_dispatched

  defp record_dispatch_timestamp(latch, event_us) do
    _result =
      :atomics.compare_exchange(latch, 2, @dispatch_timestamp_unset, event_us)

    :ok
  end

  defp dispatch_timestamp(latch) do
    case :atomics.get(latch, 2) do
      @dispatch_timestamp_unset -> nil
      event_us -> event_us
    end
  end

  defp close_dispatch_latch(latch) do
    current = :atomics.get(latch, 1)

    if current >= @closed_offset do
      closed_dispatch_state(latch, current)
    else
      case :atomics.compare_exchange(latch, 1, current, current + @closed_offset) do
        :ok -> closed_dispatch_state(latch, current + @closed_offset)
        _raced -> close_dispatch_latch(latch)
      end
    end
  end

  defp closed_dispatch_state(latch, closed_state) do
    certainty =
      case closed_state - @closed_offset do
        @open_unset -> :unset
        @open_ambiguous -> :ambiguous
        @open_not_dispatched -> :not_dispatched
        @open_dispatched -> :dispatched
      end

    dispatched_at_us =
      case :atomics.get(latch, 2) do
        @dispatch_timestamp_unset -> nil
        event_us -> event_us
      end

    {certainty, dispatched_at_us}
  end

  defp mark_receipt_claimed(latch) do
    _result = :atomics.compare_exchange(latch, 3, 0, 1)
    :ok
  end

  defp mark_receipt_finalized(latch) do
    case :atomics.get(latch, 3) do
      2 ->
        :ok

      current ->
        case :atomics.compare_exchange(latch, 3, current, 2) do
          :ok -> :ok
          _raced -> mark_receipt_finalized(latch)
        end
    end
  end

  defp outer_terminal_candidate(
         {:candidate, {:__attempt_lifecycle_rejected__, :timeout}, _elapsed_ms, true,
          _callback_eligible?},
         certainty,
         dispatched_at_us,
         timeout
       )
       when certainty in [:ambiguous, :dispatched] do
    {timeout_result(timeout), elapsed_from_dispatch(dispatched_at_us), true}
  end

  defp outer_terminal_candidate(
         {:candidate, result, elapsed_ms, accounting?, _callback_eligible?},
         _certainty,
         _dispatched_at_us,
         _timeout
       ),
       do: {result, elapsed_ms, accounting?}

  defp outer_terminal_candidate(
         {:owner_down, reason},
         _certainty,
         dispatched_at_us,
         _timeout
       ) do
    {{:exception, {:exit, reason, []}}, elapsed_from_dispatch(dispatched_at_us), true}
  end

  defp outer_terminal_candidate(:client_timeout, certainty, dispatched_at_us, timeout)
       when certainty in [:ambiguous, :dispatched],
       do: {timeout_result(timeout), elapsed_from_dispatch(dispatched_at_us), true}

  defp outer_terminal_candidate(:client_timeout, _certainty, _dispatched_at_us, _timeout),
    do: {{:__attempt_lifecycle_rejected__, :timeout}, nil, true}

  defp finish_compatibility_lifecycle(
         {:candidate, _result, _elapsed_ms, _accounting?, true},
         lifecycle_pid,
         monitor_ref,
         lifecycle_ref,
         result,
         elapsed_ms,
         true,
         certainty
       )
       when certainty in [:ambiguous, :dispatched] do
    Process.demonitor(monitor_ref, [:flush])

    send(
      lifecycle_pid,
      {lifecycle_ref, {:authorize_legacy_terminal_callback, result, elapsed_ms}}
    )

    :ok
  end

  defp finish_compatibility_lifecycle(
         _terminal_candidate,
         lifecycle_pid,
         monitor_ref,
         _lifecycle_ref,
         _result,
         _elapsed_ms,
         _accounting?,
         _certainty
       ) do
    terminate_lifecycle(lifecycle_pid, monitor_ref)
  end

  defp publish_owner_terminal(
         breaker_id,
         result,
         certainty,
         dispatched_at_us,
         dispatch_callback
       ) do
    if certainty in [:ambiguous, :dispatched] do
      dispatched_at_us = dispatched_at_us || System.monotonic_time(:microsecond)
      invoke_dispatch_callback(dispatch_callback, dispatched_at_us)
      maybe_emit_timeout(breaker_id, result)
    end

    :ok
  end

  defp finalize_receipt(latch, receipt, result, certainty, terminal_callback) do
    case :atomics.compare_exchange(latch, 3, 1, 2) do
      :ok ->
        if certainty in [:ambiguous, :dispatched],
          do: report_receipt(receipt, breaker_result(result, terminal_callback)),
          else: release_receipt(receipt)

      0 ->
        case :atomics.compare_exchange(latch, 3, 0, 2) do
          :ok -> abandon_unclaimed_receipt(receipt, self())
          _raced -> finalize_receipt(latch, receipt, result, certainty, terminal_callback)
        end

      2 ->
        :ok
    end
  end

  defp timeout_result(timeout) do
    {:error,
     JError.new(-32_000, "Request timeout after #{timeout}ms",
       category: :timeout,
       retriable?: true,
       breaker_penalty?: true
     ), timeout}
  end

  defp elapsed_from_dispatch(nil), do: 0.0
  defp elapsed_from_dispatch(dispatched_at_us), do: elapsed_ms(dispatched_at_us)

  defp terminal_elapsed_ms(elapsed_ms, nil), do: elapsed_ms || 0.0

  defp terminal_elapsed_ms(elapsed_ms, dispatched_at_us),
    do: elapsed_ms || elapsed_ms(dispatched_at_us)

  defp maybe_emit_timeout({instance_id, transport}, {:error, %JError{category: :timeout}, _}) do
    Logger.warning("Request timeout in circuit breaker",
      instance_id: instance_id,
      transport: transport
    )

    :telemetry.execute(
      [:lasso, :circuit_breaker, :timeout],
      %{count: 1},
      %{instance_id: instance_id, transport: transport}
    )
  end

  defp maybe_emit_timeout(_breaker_id, _result), do: :ok

  defp terminate_lifecycle(lifecycle_pid, monitor_ref) do
    if Process.alive?(lifecycle_pid), do: Process.exit(lifecycle_pid, :kill)
    Process.demonitor(monitor_ref, [:flush])
    :ok
  end

  defp attempt_deadline_us(deadline_us, timeout_ms) do
    min(
      deadline_us,
      System.monotonic_time(:microsecond) + timeout_ms * 1_000
    )
  end
end

defmodule Lasso.Core.Support.AttemptLifecycle do
  @moduledoc false

  require Logger

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Core.Support.CircuitBreaker.AdmissionReceipt
  alias Lasso.JSONRPC.Error, as: JError

  @dispatch_context_key :lasso_attempt_dispatch_context
  @dispatch_settle_timeout 1_000

  @type terminal_callback :: CircuitBreaker.terminal_callback() | nil
  @type dispatch_callback :: (integer() -> term()) | nil
  @type dispatch_context :: {pid(), reference()}

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

    {lifecycle_pid, monitor_ref} =
      spawn_monitor(fn ->
        execute(%{
          caller_pid: caller_pid,
          lifecycle_ref: lifecycle_ref,
          receipt: receipt,
          breaker_id: receipt.breaker_id,
          fun: fun,
          timeout: timeout,
          terminal_callback: terminal_callback,
          dispatch_callback: dispatch_callback,
          dispatch_mode: dispatch_mode,
          deadline_us: deadline_us
        })
      end)

    receive do
      {^lifecycle_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^lifecycle_pid, reason} ->
        {:exception, {:exit, reason, []}}
    after
      deadline_wait_ms(deadline_us) ->
        send(lifecycle_pid, {:attempt_caller_timeout, lifecycle_ref})
        Process.demonitor(monitor_ref, [:flush])
        {:__attempt_lifecycle_rejected__, :timeout}
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
  @spec authorize_dispatch(dispatch_context() | nil) :: :ok | {:error, :cancelled}
  def authorize_dispatch(nil), do: :ok

  def authorize_dispatch({lifecycle_pid, dispatch_ref}) do
    authorization_ref = make_ref()
    monitor_ref = Process.monitor(lifecycle_pid)

    send(
      lifecycle_pid,
      {:authorize_attempt_dispatch, dispatch_ref, self(), authorization_ref}
    )

    receive do
      {:attempt_dispatch_authorized, ^authorization_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        :ok

      {:attempt_dispatch_rejected, ^authorization_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :cancelled}

      {:DOWN, ^monitor_ref, :process, ^lifecycle_pid, _reason} ->
        {:error, :cancelled}
    after
      1_000 ->
        Process.demonitor(monitor_ref, [:flush])
        _abort_result = abort_dispatch({lifecycle_pid, dispatch_ref})
        {:error, :cancelled}
    end
  end

  @doc false
  @spec confirm_dispatched(dispatch_context() | nil) :: :ok | {:error, :cancelled}
  def confirm_dispatched(nil), do: :ok

  def confirm_dispatched({lifecycle_pid, dispatch_ref}) do
    confirmation_ref = make_ref()
    monitor_ref = Process.monitor(lifecycle_pid)

    send(lifecycle_pid, {:attempt_dispatched, dispatch_ref, self(), confirmation_ref})

    receive do
      {:attempt_dispatch_confirmed, ^confirmation_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        :ok

      {:attempt_dispatch_rejected, ^confirmation_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :cancelled}

      {:DOWN, ^monitor_ref, :process, ^lifecycle_pid, _reason} ->
        {:error, :cancelled}
    end
  end

  @doc false
  @spec abort_dispatch(dispatch_context() | nil) :: :ok | {:error, :cancelled}
  def abort_dispatch(nil), do: :ok

  def abort_dispatch({lifecycle_pid, dispatch_ref}) do
    abort_ref = make_ref()
    monitor_ref = Process.monitor(lifecycle_pid)
    send(lifecycle_pid, {:attempt_dispatch_aborted, dispatch_ref, self(), abort_ref})

    receive do
      {:attempt_dispatch_aborted, ^abort_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        :ok

      {:attempt_dispatch_rejected, ^abort_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :cancelled}

      {:DOWN, ^monitor_ref, :process, ^lifecycle_pid, _reason} ->
        {:error, :cancelled}
    end
  end

  @doc false
  @spec mark_dispatched(dispatch_context() | nil) :: :ok | {:error, :cancelled}
  def mark_dispatched(context) do
    with :ok <- authorize_dispatch(context), do: confirm_dispatched(context)
  end

  defp execute(context) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(context.caller_pid)

    case claim_receipt(context.receipt, context.caller_pid) do
      :ok ->
        if Process.alive?(context.caller_pid) do
          start_attempt(Map.put(context, :caller_monitor, caller_monitor))
        else
          release_receipt(context.receipt)
        end

      {:error, reason} ->
        Process.demonitor(caller_monitor, [:flush])

        send(context.caller_pid, {
          context.lifecycle_ref,
          {:__attempt_lifecycle_rejected__, reason}
        })
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

          receive do
            {:run_attempt, ^task_ref} ->
              send(lifecycle_pid, {:attempt_task_result, task_ref, execute_fun(context.fun)})
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
        pending_terminal: nil,
        pending_result: nil
      })
    )
  end

  defp loop(state) do
    receive do
      {:authorize_attempt_dispatch, dispatch_ref, requester, authorization_ref}
      when dispatch_ref == state.dispatch_ref ->
        authorize_or_reject_dispatch(state, requester, authorization_ref)

      {:attempt_dispatched, dispatch_ref, requester, confirmation_ref}
      when dispatch_ref == state.dispatch_ref ->
        case confirmation_rejection(state) do
          nil ->
            {phase, transition} = confirm_phase(state.phase)
            maybe_invoke_dispatch_callback(state.dispatch_callback, transition)
            send(requester, {:attempt_dispatch_confirmed, confirmation_ref})

            state
            |> Map.put(:phase, phase)
            |> resolve_pending_terminal()

          reason ->
            send(requester, {:attempt_dispatch_rejected, confirmation_ref})
            finalize_unconfirmed(state, reason)
        end

      {:attempt_dispatch_aborted, dispatch_ref, requester, abort_ref}
      when dispatch_ref == state.dispatch_ref ->
        if match?({:dispatched, _}, state.phase) do
          send(requester, {:attempt_dispatch_rejected, abort_ref})
          loop(state)
        else
          send(requester, {:attempt_dispatch_aborted, abort_ref})

          state
          |> Map.put(:phase, :aborted)
          |> resolve_pending_terminal()
        end

      {:attempt_task_result, task_ref, result} when task_ref == state.task_ref ->
        Process.demonitor(state.task_monitor, [:flush])
        handle_task_result(state, unwrap_result(result))

      {:DOWN, monitor_ref, :process, caller_pid, _reason}
      when monitor_ref == state.caller_monitor and caller_pid == state.caller_pid ->
        handle_interruption(state, :caller_down)

      {:DOWN, monitor_ref, :process, task_pid, reason}
      when monitor_ref == state.task_monitor and task_pid == state.task_pid ->
        handle_task_death(state, reason)

      {:EXIT, task_pid, reason} when task_pid == state.task_pid ->
        handle_task_death(state, reason)

      {:attempt_caller_timeout, lifecycle_ref} when lifecycle_ref == state.lifecycle_ref ->
        if is_nil(state.pending_terminal),
          do: handle_interruption(state, :timeout),
          else: loop(state)
    after
      remaining_timeout(state) ->
        handle_interruption(state, :timeout)
    end
  end

  defp authorize_phase(:predispatch),
    do: {:dispatching, System.monotonic_time(:microsecond)}

  defp authorize_phase(phase), do: phase

  defp authorize_or_reject_dispatch(state, requester, authorization_ref) do
    cond do
      state.phase == :aborted ->
        send(requester, {:attempt_dispatch_rejected, authorization_ref})
        loop(state)

      not Process.alive?(state.caller_pid) ->
        send(requester, {:attempt_dispatch_rejected, authorization_ref})
        handle_interruption(state, :caller_down)

      System.monotonic_time(:microsecond) >= state.deadline_us ->
        send(requester, {:attempt_dispatch_rejected, authorization_ref})
        handle_interruption(state, :timeout)

      true ->
        send(requester, {:attempt_dispatch_authorized, authorization_ref})
        loop(%{state | phase: authorize_phase(state.phase)})
    end
  end

  defp initial_phase(%{dispatch_mode: :immediate} = context) do
    dispatched_at_us = System.monotonic_time(:microsecond)
    invoke_dispatch_callback(context.dispatch_callback, dispatched_at_us)
    {:dispatched, dispatched_at_us}
  end

  defp initial_phase(_context), do: :predispatch

  defp confirm_phase({:dispatching, _authorized_at_us}) do
    dispatched_at_us = System.monotonic_time(:microsecond)
    {{:dispatched, dispatched_at_us}, {:transitioned, dispatched_at_us}}
  end

  defp confirm_phase({:dispatched, _dispatched_at_us} = phase), do: {phase, :unchanged}

  defp confirm_phase(:predispatch) do
    dispatched_at_us = System.monotonic_time(:microsecond)
    {{:dispatched, dispatched_at_us}, {:transitioned, dispatched_at_us}}
  end

  defp confirmation_rejection(%{phase: :aborted}), do: :aborted

  defp confirmation_rejection(%{pending_terminal: terminal}) when not is_nil(terminal),
    do: terminal

  defp confirmation_rejection(state) do
    cond do
      not Process.alive?(state.caller_pid) -> :caller_down
      System.monotonic_time(:microsecond) >= state.deadline_us -> :timeout
      true -> nil
    end
  end

  defp finalize_unconfirmed(state, :caller_down) do
    handle_interruption(%{state | phase: :predispatch, pending_terminal: nil}, :caller_down)
  end

  defp finalize_unconfirmed(state, :timeout) do
    handle_interruption(%{state | phase: :predispatch, pending_terminal: nil}, :timeout)
  end

  defp finalize_unconfirmed(state, :aborted) do
    handle_interruption(%{state | phase: :aborted, pending_terminal: nil}, :caller_down)
  end

  defp handle_task_result(%{phase: {:dispatching, _}} = state, result) do
    loop(%{state | pending_result: result})
  end

  defp handle_task_result(%{phase: {:dispatched, dispatched_at_us}} = state, result) do
    finalize_dispatched(state, result, elapsed_ms(dispatched_at_us))
  end

  defp handle_task_result(%{phase: :predispatch} = state, result) do
    if predispatch_result?(result) do
      finalize_predispatch(state, result)
    else
      finalize_dispatched(state, result, elapsed_ms(state.started_at_us))
    end
  end

  defp handle_task_result(%{phase: :aborted} = state, result) do
    finalize_predispatch(state, result)
  end

  defp handle_task_death(state, :normal) do
    case state.pending_result do
      nil -> handle_task_death(state, :missing_result)
      result -> handle_task_result(state, result)
    end
  end

  defp handle_task_death(%{phase: {:dispatching, _}} = state, reason) do
    loop(%{state | pending_result: task_exit_result(reason)})
  end

  defp handle_task_death(%{phase: {:dispatched, dispatched_at_us}} = state, reason) do
    finalize_dispatched(state, task_exit_result(reason), elapsed_ms(dispatched_at_us))
  end

  defp handle_task_death(%{phase: :predispatch} = state, reason) do
    finalize_predispatch(state, task_exit_result(reason))
  end

  defp handle_task_death(%{phase: :aborted} = state, reason) do
    finalize_predispatch(state, task_exit_result(reason))
  end

  defp handle_interruption(
         %{phase: {:dispatching, _dispatched_at_us}, pending_terminal: pending_terminal} = state,
         _terminal
       )
       when not is_nil(pending_terminal) do
    finalize_unconfirmed(state, pending_terminal)
  end

  defp handle_interruption(%{phase: {:dispatching, _}} = state, terminal) do
    loop(%{
      state
      | pending_terminal: terminal,
        settle_deadline_us: System.monotonic_time(:microsecond) + @dispatch_settle_timeout * 1_000
    })
  end

  defp handle_interruption(%{phase: :predispatch} = state, :caller_down) do
    stop_task(state)
    release_receipt(state.receipt)
  end

  defp handle_interruption(%{phase: :aborted} = state, :caller_down) do
    stop_task(state)
    release_receipt(state.receipt)
  end

  defp handle_interruption(%{phase: :predispatch} = state, :timeout) do
    stop_task(state)

    result =
      {:error,
       JError.new(-32_008, "Local transport admission timed out",
         category: :local_capacity_rejection,
         retriable?: true,
         breaker_penalty?: false
       ), state.timeout}

    finalize_predispatch(state, result)
  end

  defp handle_interruption(%{phase: :aborted} = state, :timeout) do
    stop_task(state)

    result =
      {:error,
       JError.new(-32_008, "Local transport admission timed out",
         category: :local_capacity_rejection,
         retriable?: true,
         breaker_penalty?: false
       ), state.timeout}

    finalize_predispatch(state, result)
  end

  defp handle_interruption(%{phase: {:dispatched, dispatched_at_us}} = state, terminal) do
    completed_result = take_completed_result(state)
    stop_task(state)

    case completed_result do
      {:ok, result} ->
        finalize_dispatched(state, result, elapsed_ms(dispatched_at_us))

      :none when terminal == :caller_down ->
        elapsed_ms = elapsed_ms(dispatched_at_us)

        cancellation =
          {:error,
           JError.new(-32_000, "Upstream attempt cancelled",
             category: :cancelled,
             retriable?: false,
             breaker_penalty?: false
           ), elapsed_ms}

        report_receipt(state.receipt, cancellation)
        invoke_terminal_callback(state.terminal_callback, cancellation, elapsed_ms)

      :none ->
        finalize_timeout(state, elapsed_ms(dispatched_at_us))
    end
  end

  defp resolve_pending_terminal(%{pending_terminal: nil, pending_result: nil} = state),
    do: loop(state)

  defp resolve_pending_terminal(%{pending_terminal: nil, pending_result: result} = state) do
    handle_task_result(%{state | pending_result: nil}, result)
  end

  defp resolve_pending_terminal(%{phase: :aborted, pending_terminal: terminal} = state) do
    handle_interruption(%{state | pending_terminal: nil}, terminal)
  end

  defp resolve_pending_terminal(%{phase: {:dispatched, _}, pending_terminal: terminal} = state) do
    handle_interruption(%{state | pending_terminal: nil}, terminal)
  end

  defp take_completed_result(state) do
    case state.pending_result do
      nil ->
        receive do
          {:attempt_task_result, task_ref, result} when task_ref == state.task_ref ->
            {:ok, unwrap_result(result)}
        after
          0 -> :none
        end

      result ->
        {:ok, result}
    end
  end

  defp stop_task(state) do
    if Process.alive?(state.task_pid), do: Process.exit(state.task_pid, :kill)
    Process.demonitor(state.task_monitor, [:flush])
  end

  defp finalize_predispatch(state, result) do
    release_receipt(state.receipt)
    Process.demonitor(state.caller_monitor, [:flush])
    send(state.caller_pid, {state.lifecycle_ref, result})
  end

  defp finalize_dispatched(state, result, elapsed_ms) do
    report_receipt(state.receipt, breaker_result(result, state.terminal_callback))

    Process.demonitor(state.caller_monitor, [:flush])
    invoke_terminal_callback(state.terminal_callback, result, elapsed_ms)
    send(state.caller_pid, {state.lifecycle_ref, result})
  end

  defp finalize_timeout(state, elapsed_ms) do
    {instance_id, transport} = state.breaker_id

    Logger.warning("Request timeout in circuit breaker",
      instance_id: instance_id,
      transport: transport,
      timeout_ms: state.timeout
    )

    :telemetry.execute(
      [:lasso, :circuit_breaker, :timeout],
      %{timeout_ms: state.timeout},
      %{instance_id: instance_id, transport: transport}
    )

    result =
      {:error,
       JError.new(-32_000, "Request timeout after #{state.timeout}ms",
         category: :timeout,
         retriable?: true,
         breaker_penalty?: true
       ), state.timeout}

    finalize_dispatched(state, result, elapsed_ms)
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

  defp remaining_timeout(%{pending_terminal: nil, deadline_us: deadline_us}) do
    remaining_ms(deadline_us, 0)
  end

  defp remaining_timeout(%{settle_deadline_us: settle_deadline_us})
       when is_integer(settle_deadline_us) do
    remaining_ms(settle_deadline_us, 1)
  end

  defp remaining_ms(deadline_us, minimum) do
    remaining_us = max(deadline_us - System.monotonic_time(:microsecond), 0)
    max(div(remaining_us + 999, 1_000), minimum)
  end

  defp deadline_wait_ms(deadline_us), do: remaining_ms(deadline_us, 0)

  defp claim_receipt(%AdmissionReceipt{kind: :closed}, _caller_pid), do: :ok

  defp claim_receipt(
         %AdmissionReceipt{kind: :half_open, breaker_id: id, token: token},
         caller_pid
       ) do
    CircuitBreaker.claim_attempt(id, token, caller_pid)
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

  defp maybe_invoke_dispatch_callback(callback, {:transitioned, dispatched_at_us}),
    do: invoke_dispatch_callback(callback, dispatched_at_us)

  defp maybe_invoke_dispatch_callback(_callback, :unchanged), do: :ok
end

defmodule Lasso.Core.Request.RequestOwner do
  @moduledoc false

  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.Core.Transport.AttemptProtocol
  alias Lasso.RPC.{AttemptIdentity, ExecutionProjector, ExecutionReducer}

  defmodule AttemptCompletion do
    @moduledoc false

    @enforce_keys [:result, :terminal_candidate, :completed_at_us]
    defstruct @enforce_keys
  end

  defmodule Outcome do
    @moduledoc false

    @enforce_keys [:result, :fact, :projection, :committed?]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            result: term(),
            fact: struct(),
            projection: ExecutionProjector.t(),
            committed?: true
          }
  end

  @type option ::
          {:caller_guard, ExecutionScope.CallerGuard.t()} | {:test_before_restore, (-> term())}

  @spec execute(AttemptIdentity.t(), integer(), (-> term()), [option()]) :: Outcome.t()
  def execute(%AttemptIdentity{} = identity, deadline_us, fun, opts \\ [])
      when is_integer(deadline_us) and is_function(fun, 0) do
    started_us = System.monotonic_time(:microsecond)

    if started_us >= deadline_us do
      deadline_outcome(ExecutionReducer.new(identity, started_us, started_us))
    else
      previous_trap_exit = Process.flag(:trap_exit, true)

      try do
        outcome = do_execute(identity, started_us, deadline_us, fun, opts, previous_trap_exit)
        invoke_test_before_restore(Keyword.get(opts, :test_before_restore))
        outcome
      after
        Process.flag(:trap_exit, previous_trap_exit)
        propagate_pending_exits(previous_trap_exit)
      end
    end
  end

  defp do_execute(identity, started_us, deadline_us, fun, opts, previous_trap_exit) do
    attempt_ref = make_ref()
    context = AttemptProtocol.new_context(self(), attempt_ref, deadline_us)
    caller_guard = Keyword.get(opts, :caller_guard)
    caller_state = caller_state(caller_guard)
    reducer = ExecutionReducer.new(identity, started_us, deadline_us)

    if caller_state.status == :down do
      context
      |> preflight_cancellation(reducer, started_us)
      |> build_outcome()
    else
      cutoff_token = make_ref()
      cutoff_timer = start_cutoff_timer(attempt_ref, cutoff_token, deadline_us)

      if now_us() >= deadline_us do
        cancel_cutoff(cutoff_timer, attempt_ref, cutoff_token)
        AttemptProtocol.close(context)
        deadline_outcome(reducer)
      else
        task = start_transport_task(context, fun)

        %{
          attempt_ref: attempt_ref,
          caller_monitor: caller_state.monitor,
          caller_pid: caller_state.pid,
          context: context,
          cutoff_timer: cutoff_timer,
          cutoff_token: cutoff_token,
          gate_snapshot: nil,
          previous_trap_exit: previous_trap_exit,
          reducer: reducer,
          task: task
        }
        |> await_terminal()
        |> finish()
      end
    end
  end

  defp start_transport_task(context, fun) do
    Task.async(fn ->
      :ok = AttemptProtocol.install_context(context)

      try do
        result = fun.()

        %AttemptCompletion{
          result: result,
          terminal_candidate: AttemptProtocol.take_terminal_candidate(context),
          completed_at_us: System.monotonic_time(:microsecond)
        }
      after
        AttemptProtocol.clear_context()
      end
    end)
  end

  defp await_terminal(state) do
    task_ref = state.task.ref
    task_pid = state.task.pid

    receive do
      {^task_ref, %AttemptCompletion{} = completion} ->
        handle_completion(state, completion)

      {:request_owner_cutoff, attempt_ref, cutoff_token}
      when attempt_ref == state.attempt_ref and cutoff_token == state.cutoff_token ->
        close_deadline(state)

      {:EXIT, ^task_pid, :normal} ->
        await_terminal(state)

      {:DOWN, ^task_ref, :process, ^task_pid, :normal} ->
        protocol_failure(state, :missing_completion, System.monotonic_time(:microsecond))

      {:EXIT, ^task_pid, reason} ->
        handle_task_down(state, reason)

      {:DOWN, ^task_ref, :process, ^task_pid, reason} ->
        handle_task_down(state, reason)

      {:DOWN, caller_ref, :process, caller_pid, _reason}
      when caller_ref == state.caller_monitor and caller_pid == state.caller_pid ->
        handle_caller_down(state)

      {:EXIT, _pid, :normal} when state.previous_trap_exit == false ->
        await_terminal(state)

      {:EXIT, _pid, reason} when state.previous_trap_exit == false ->
        exit(reason)
    end
  end

  defp handle_completion(state, %AttemptCompletion{completed_at_us: completed_at_us} = completion) do
    case completion.terminal_candidate do
      {:ok, %{event_us: event_us} = terminal} when event_us >= state.reducer.deadline_us ->
        close_deadline(state, terminal)

      _candidate ->
        if ExecutionReducer.eligible?(state.reducer, completed_at_us) do
          case validate_completion(completion) do
            {:ok, terminal} ->
              safely_commit_terminal(state, completion.result, completed_at_us, terminal)

            {:error, reason} ->
              protocol_failure(state, reason, completed_at_us)
          end
        else
          close_deadline(state)
        end
    end
  end

  defp validate_completion(%AttemptCompletion{
         result: result,
         terminal_candidate: {:ok, terminal},
         completed_at_us: completed_at_us
       }) do
    cond do
      terminal.event_us > completed_at_us -> {:error, :terminal_after_completion}
      not result_matches_terminal?(result, terminal) -> {:error, :terminal_result_mismatch}
      true -> {:ok, terminal}
    end
  end

  defp validate_completion(%AttemptCompletion{terminal_candidate: :missing}),
    do: {:error, :missing_terminal}

  defp validate_completion(%AttemptCompletion{terminal_candidate: {:conflict, _terminal}}),
    do: {:error, :conflicting_terminal}

  defp commit_terminal(state, result, completed_at_us, terminal) do
    if ExecutionReducer.eligible?(state.reducer, terminal.event_us) do
      state
      |> commit(result, completed_at_us, [terminal])
    else
      close_deadline(state)
    end
  end

  defp safely_commit_terminal(state, result, completed_at_us, terminal) do
    commit_terminal(state, result, completed_at_us, terminal)
  rescue
    ArgumentError -> protocol_failure(state, :invalid_terminal, completed_at_us)
  end

  defp protocol_failure(state, reason, event_us) do
    if ExecutionReducer.eligible?(state.reducer, event_us) do
      commit(
        state,
        {:error, {:attempt_protocol, bounded_protocol_reason(reason)}},
        event_us,
        [%{id: -3, kind: :task_exit, event_us: event_us}]
      )
    else
      close_deadline(state)
    end
  end

  defp handle_task_down(state, reason) do
    event_us = System.monotonic_time(:microsecond)

    if ExecutionReducer.eligible?(state.reducer, event_us) do
      commit(
        state,
        {:error, {:transport_task_exit, normalize_exit_reason(reason)}},
        event_us,
        [%{id: -4, kind: :task_exit, event_us: event_us}]
      )
    else
      close_deadline(state)
    end
  end

  defp handle_caller_down(state) do
    marker = make_ref()
    send(self(), {:request_owner_drain, state.attempt_ref, marker})
    state = close_authorization(state)
    state = drain_until_marker(state, marker)

    case Map.fetch(state, :committed) do
      {:ok, _committed} ->
        state

      :error ->
        event_us = System.monotonic_time(:microsecond)

        if ExecutionReducer.eligible?(state.reducer, event_us) do
          censoring_boundary_us =
            if state.gate_snapshot.certainty == :not_dispatched,
              do: 0,
              else: max(event_us - state.reducer.started_us, 1)

          commit(
            state,
            {:error, :caller_abandoned},
            event_us,
            [
              %{
                id: -5,
                kind: :cancelled,
                event_us: event_us,
                reason: :caller_abandoned,
                certainty: state.gate_snapshot.certainty,
                censoring_boundary_us: censoring_boundary_us
              }
            ]
          )
        else
          close_deadline(state)
        end
    end
  end

  defp drain_until_marker(state, marker) do
    task_ref = state.task.ref
    task_pid = state.task.pid

    receive do
      {:request_owner_drain, attempt_ref, ^marker} when attempt_ref == state.attempt_ref ->
        state

      {^task_ref, %AttemptCompletion{} = completion} ->
        case handle_completion(state, completion) do
          %{committed: _committed} = committed ->
            drain_committed_until_marker(committed, marker)

          next ->
            drain_until_marker(next, marker)
        end

      {:EXIT, ^task_pid, :normal} ->
        drain_until_marker(state, marker)

      {:DOWN, ^task_ref, :process, ^task_pid, :normal} ->
        state
        |> protocol_failure(:missing_completion, now_us())
        |> drain_committed_until_marker(marker)

      {:EXIT, ^task_pid, reason} ->
        state
        |> handle_task_down(reason)
        |> drain_committed_until_marker(marker)

      {:DOWN, ^task_ref, :process, ^task_pid, reason} ->
        state
        |> handle_task_down(reason)
        |> drain_committed_until_marker(marker)

      {:EXIT, _pid, :normal} when state.previous_trap_exit == false ->
        drain_until_marker(state, marker)

      {:EXIT, _pid, reason} when state.previous_trap_exit == false ->
        exit(reason)
    end
  end

  defp drain_committed_until_marker(state, marker) do
    task_ref = state.task.ref
    task_pid = state.task.pid

    receive do
      {:request_owner_drain, attempt_ref, ^marker} when attempt_ref == state.attempt_ref ->
        state

      {^task_ref, _reply} ->
        drain_committed_until_marker(state, marker)

      {:EXIT, ^task_pid, _reason} ->
        drain_committed_until_marker(state, marker)

      {:DOWN, ^task_ref, :process, ^task_pid, _reason} ->
        drain_committed_until_marker(state, marker)
    end
  end

  defp close_deadline(state, terminal_candidate \\ nil) do
    state = close_authorization(state)
    certainty = deadline_certainty(state.gate_snapshot.certainty, terminal_candidate)
    reducer = ExecutionReducer.close_deadline(state.reducer, certainty)

    fact = ExecutionReducer.terminal_fact(reducer)

    Map.merge(state, %{
      committed: true,
      completed_at_us: state.reducer.deadline_us,
      fact: fact,
      result: {:error, :deadline_expired},
      reducer: reducer
    })
  end

  defp commit(state, result, completed_at_us, terminal_events) do
    state = close_authorization(state)

    observations = terminal_observations(terminal_events, state.gate_snapshot)

    reducer =
      state.reducer
      |> ExecutionReducer.observe_many(observations)
      |> ensure_terminal(completed_at_us)
      |> ExecutionReducer.commit()

    fact = ExecutionReducer.terminal_fact(reducer)

    Map.merge(state, %{
      committed: true,
      completed_at_us: completed_at_us,
      fact: fact,
      result: result,
      reducer: reducer
    })
  end

  defp ensure_terminal(%ExecutionReducer{terminal: nil} = reducer, event_us) do
    ExecutionReducer.observe(reducer, %{id: -6, kind: :task_exit, event_us: event_us})
  end

  defp ensure_terminal(reducer, _event_us), do: reducer

  defp deadline_certainty(snapshot_certainty, terminal_candidate) do
    case terminal_dispatch_certainty(terminal_candidate) do
      :dispatched -> :dispatched
      :indeterminate when snapshot_certainty == :not_dispatched -> :indeterminate
      _certainty -> snapshot_certainty
    end
  end

  defp terminal_dispatch_certainty(%{kind: kind})
       when kind in [:response, :invalid_response],
       do: :dispatched

  defp terminal_dispatch_certainty(%{kind: :transport_failure, certainty: certainty})
       when certainty in [:indeterminate, :dispatched],
       do: certainty

  defp terminal_dispatch_certainty(_terminal), do: nil

  defp terminal_observations([%{kind: kind} = terminal], _gate_snapshot)
       when kind in [:response, :invalid_response],
       do: [terminal]

  defp terminal_observations(
         [%{kind: :predispatch_failure} = terminal],
         %{certainty: :not_dispatched}
       ),
       do: [terminal]

  defp terminal_observations(
         [%{kind: :predispatch_failure, event_us: event_us}],
         %{certainty: certainty}
       )
       when certainty in [:indeterminate, :dispatched] do
    [
      %{
        id: -13,
        kind: :transport_failure,
        event_us: event_us,
        reason: :unknown,
        certainty: certainty
      }
    ]
  end

  defp terminal_observations(terminal_events, gate_snapshot),
    do: AttemptProtocol.gate_observations(terminal_events, gate_snapshot)

  defp preflight_cancellation(context, reducer, event_us) do
    snapshot = AttemptProtocol.close(context)

    reducer =
      reducer
      |> ExecutionReducer.observe_many([
        %{
          id: -7,
          kind: :cancelled,
          event_us: event_us,
          reason: :caller_abandoned,
          certainty: snapshot.certainty,
          censoring_boundary_us: 0
        }
      ])
      |> ExecutionReducer.commit()

    %{
      fact: ExecutionReducer.terminal_fact(reducer),
      result: {:error, :caller_abandoned},
      reducer: reducer
    }
  end

  defp close_authorization(%{gate_snapshot: nil} = state),
    do: %{state | gate_snapshot: AttemptProtocol.close(state.context)}

  defp close_authorization(state), do: state

  defp finish(state) do
    cancel_cutoff(state)
    cleanup_task(state.task)
    drain_retired_attempt(state)
    build_outcome(state)
  end

  defp build_outcome(%{
         fact: fact,
         result: result,
         reducer: %ExecutionReducer{committed: true}
       }) do
    %Outcome{
      result: result,
      fact: fact,
      projection: ExecutionProjector.project(fact),
      committed?: true
    }
  end

  defp deadline_outcome(reducer) do
    reducer = ExecutionReducer.close_deadline(reducer)

    build_outcome(%{
      fact: ExecutionReducer.terminal_fact(reducer),
      result: {:error, :deadline_expired},
      reducer: reducer
    })
  end

  defp result_matches_terminal?(result, %{kind: :response, response_kind: :success}),
    do: result_kind(result) == :success

  defp result_matches_terminal?(result, %{kind: :response, response_kind: :application_error}),
    do: result_kind(result) == :error

  defp result_matches_terminal?(result, %{kind: kind})
       when kind in [:predispatch_failure, :invalid_response, :transport_failure],
       do: result_kind(result) == :error

  defp result_matches_terminal?(_result, _terminal), do: false

  defp result_kind({:ok, _value}), do: :success
  defp result_kind({:ok, _value, _elapsed}), do: :success
  defp result_kind({:error, _reason}), do: :error
  defp result_kind({:error, _reason, _elapsed}), do: :error
  defp result_kind(_result), do: :unknown

  defp bounded_protocol_reason(reason)
       when reason in [
              :conflicting_terminal,
              :missing_completion,
              :missing_terminal,
              :invalid_terminal,
              :terminal_after_completion,
              :terminal_result_mismatch
            ],
       do: reason

  defp bounded_protocol_reason(_reason), do: :invalid_completion

  defp normalize_exit_reason(reason)
       when reason in [:killed, :normal, :noproc, :shutdown],
       do: reason

  defp normalize_exit_reason({:shutdown, _detail}), do: :shutdown
  defp normalize_exit_reason(_reason), do: :transport_crashed

  defp start_cutoff_timer(attempt_ref, cutoff_token, deadline_us) do
    deadline_ms = -Integer.floor_div(-deadline_us, 1_000)

    Process.send_after(
      self(),
      {:request_owner_cutoff, attempt_ref, cutoff_token},
      deadline_ms,
      abs: true
    )
  end

  defp cancel_cutoff(state),
    do: cancel_cutoff(state.cutoff_timer, state.attempt_ref, state.cutoff_token)

  defp cancel_cutoff(timer, attempt_ref, cutoff_token) do
    Process.cancel_timer(timer)

    receive do
      {:request_owner_cutoff, ^attempt_ref, ^cutoff_token} ->
        :ok
    after
      0 -> :ok
    end
  end

  defp cleanup_task(task) do
    task_pid = task.pid
    Process.unlink(task.pid)
    Process.demonitor(task.ref, [:flush])
    if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)

    receive do
      {:EXIT, ^task_pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp drain_retired_attempt(state) do
    task_ref = state.task.ref
    task_pid = state.task.pid

    receive do
      {^task_ref, _reply} ->
        drain_retired_attempt(state)

      {:DOWN, ^task_ref, :process, ^task_pid, _reason} ->
        drain_retired_attempt(state)

      {:EXIT, ^task_pid, _reason} ->
        drain_retired_attempt(state)
    after
      0 -> :ok
    end
  end

  defp caller_state(nil), do: %{monitor: nil, pid: nil, status: :alive}

  defp caller_state(%ExecutionScope.CallerGuard{} = caller_guard) do
    %{
      monitor: ExecutionScope.caller_monitor(caller_guard),
      pid: ExecutionScope.caller_pid(caller_guard),
      status: if(ExecutionScope.caller_alive?(caller_guard), do: :alive, else: :down)
    }
  end

  defp propagate_pending_exits(true), do: :ok

  defp propagate_pending_exits(false) do
    receive do
      {:EXIT, _pid, :normal} -> propagate_pending_exits(false)
      {:EXIT, _pid, reason} -> exit(reason)
    after
      0 -> :ok
    end
  end

  defp invoke_test_before_restore(nil), do: :ok
  defp invoke_test_before_restore(hook) when is_function(hook, 0), do: hook.()

  defp now_us, do: System.monotonic_time(:microsecond)
end

defmodule Lasso.RPC.ExecutionReducerTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.{AttemptIdentity, ExecutionReducer}

  defp state(deadline_us \\ 100) do
    identity =
      AttemptIdentity.new(
        request_id: "request",
        attempt_id: "attempt",
        profile: "public",
        chain_id: 1,
        upstream_instance_id: "instance",
        transport: :http,
        route_generation: 1,
        circuit_scope: :broad,
        circuit_epoch: 1,
        execution_safety: :replay_safe,
        routing_intent: "default",
        workload_key: "read",
        request_budget_ms: 1,
        candidate_admission_count: 1,
        dispatch_count: 1
      )

    ExecutionReducer.new(identity, 0, deadline_us)
  end

  defp response(id, event_us, extra \\ %{}) do
    Map.merge(
      %{id: id, kind: :response, event_us: event_us, response_kind: :success, io_duration_us: 1},
      extra
    )
  end

  defp predispatch(id, event_us),
    do: %{id: id, kind: :predispatch_failure, event_us: event_us, reason: :local, elapsed_us: 1}

  test "D-1 is eligible while D and D+1 are late" do
    eligible = ExecutionReducer.observe(state(), response(1, 99))
    assert eligible.terminal == :response
    assert eligible.dispatch_certainty == :dispatched

    for stamp <- [100, 101] do
      reduced = ExecutionReducer.observe(state(), response(stamp, stamp))
      assert reduced.terminal == nil
      assert [%{event_us: ^stamp}] = reduced.late_observations
      assert ExecutionReducer.close_deadline(reduced).terminal == :deadline
    end
  end

  test "deadline fact stores elapsed censoring duration, not absolute monotonic time" do
    origin = -576_460_751_234_567

    reduced =
      ExecutionReducer.new(state().identity, origin, origin + 50_000)
      |> ExecutionReducer.observe(%{id: 1, kind: :send_started, event_us: origin + 1})

    assert reduced.dispatch_certainty == :not_dispatched

    reduced = ExecutionReducer.close_deadline(reduced)

    assert reduced.dispatch_certainty == :indeterminate

    assert %Lasso.RPC.AttemptTerminal.Deadline{censoring_boundary_us: 50_000} =
             ExecutionReducer.terminal_fact(reduced)
  end

  test "deadline closure retains an authoritative external dispatch snapshot" do
    reduced = ExecutionReducer.close_deadline(state(), :dispatched)

    assert reduced.dispatch_certainty == :dispatched

    assert %Lasso.RPC.AttemptTerminal.Deadline{dispatch_certainty: :dispatched} =
             ExecutionReducer.terminal_fact(reduced)
  end

  test "certainty only increases" do
    reduced =
      state()
      |> ExecutionReducer.observe(%{id: 1, kind: :send_started, event_us: 10})
      |> ExecutionReducer.observe(%{id: 2, kind: :send_confirmed, event_us: 20})
      |> ExecutionReducer.observe(%{id: 3, kind: :not_dispatched, event_us: 30})

    assert reduced.dispatch_certainty == :dispatched
    assert [%{reason: :certainty_regression}] = reduced.protocol_violations
  end

  test "send start remains open until authoritative predispatch proof" do
    event = %{id: 1, kind: :send_started, event_us: 10}
    once = ExecutionReducer.observe(state(), event)
    assert ExecutionReducer.observe(once, event) == once

    resolved =
      once
      |> ExecutionReducer.observe(predispatch(2, 20))

    assert resolved.terminal == :predispatch_failure
    assert resolved.dispatch_certainty == :not_dispatched
    assert resolved.protocol_violations == []

    reused = ExecutionReducer.observe(once, response(1, 10))
    assert [%{reason: :observation_id_reused}] = reused.protocol_violations

    persisted =
      ExecutionReducer.observe(reused, %{id: 3, kind: :send_confirmed, event_us: 30})

    assert Enum.any?(persisted.protocol_violations, &(&1.reason == :observation_id_reused))
  end

  test "protocol-normalized no-send transport failure constructs a predispatch terminal" do
    context =
      Lasso.Core.Transport.AttemptProtocol.new_context(
        self(),
        make_ref(),
        System.monotonic_time(:microsecond) + 1_000_000
      )

    :ok = Lasso.Core.Transport.AttemptProtocol.install_context(context)

    assert :ok =
             Lasso.Core.Transport.AttemptProtocol.terminal_at(
               context,
               :transport_failure,
               %{reason: :network_error, certainty: :not_dispatched, elapsed_us: 7},
               20
             )

    assert {:ok, observation} =
             Lasso.Core.Transport.AttemptProtocol.take_terminal_candidate(context)

    reduced = ExecutionReducer.observe(state(), observation)

    assert reduced.terminal == :predispatch_failure
    assert reduced.dispatch_certainty == :not_dispatched

    assert %Lasso.RPC.AttemptTerminal.PredispatchFailure{
             reason: :not_connected,
             elapsed_us: 7
           } = ExecutionReducer.terminal_fact(reduced)
  end

  test "hostile observation payloads are never retained" do
    secret = String.duplicate("credential", 1_000)

    reduced =
      state()
      |> ExecutionReducer.observe(response("event", 99, %{body: secret}))
      |> ExecutionReducer.commit()
      |> ExecutionReducer.observe(response("late", 98, %{context: secret}))

    serialized = inspect(reduced)
    refute serialized =~ secret
    refute Map.has_key?(hd(reduced.late_observations), :context)
  end

  test "long observation IDs deduplicate after bounded normalization" do
    id = String.duplicate("event-id", 100)
    event = %{id: id, kind: :send_started, event_us: 10}
    once = ExecutionReducer.observe(state(), event)
    assert ExecutionReducer.observe(once, event) == once

    reused = ExecutionReducer.observe(once, response(id, 10))
    assert [%{reason: :observation_id_reused}] = reused.protocol_violations
  end

  test "certainty and terminal contradictions are independent of mailbox order" do
    events = [
      %{id: 1, kind: :send_confirmed, event_us: 90},
      predispatch(2, 80)
    ]

    forward = Enum.reduce(events, state(), &ExecutionReducer.observe(&2, &1))
    reverse = Enum.reduce(Enum.reverse(events), state(), &ExecutionReducer.observe(&2, &1))

    assert forward.dispatch_certainty == reverse.dispatch_certainty
    assert forward.terminal == reverse.terminal
    assert forward.terminal_at_us == reverse.terminal_at_us
    assert forward.protocol_violations == reverse.protocol_violations
  end

  test "a correlated response conservatively proves dispatch after a predispatch claim" do
    reduced =
      state()
      |> ExecutionReducer.observe(predispatch(1, 10))
      |> ExecutionReducer.observe(response(2, 20))

    assert reduced.dispatch_certainty == :dispatched
    assert reduced.terminal == :response
    assert %Lasso.RPC.AttemptTerminal.Response{} = ExecutionReducer.terminal_fact(reduced)
    assert Enum.any?(reduced.protocol_violations, &(&1.reason == :observation_after_terminal))
  end

  test "observation state is hard bounded without suppressing decisive events" do
    reduced =
      Enum.reduce(1..100, state(1_000), fn id, acc ->
        ExecutionReducer.observe(acc, %{id: id, kind: :send_started, event_us: id})
      end)

    assert map_size(reduced.seen) == 16
    assert map_size(reduced.observations) == 1
    assert length(reduced.protocol_violations) <= 16

    decided =
      ExecutionReducer.observe(reduced, %{
        id: 101,
        kind: :response,
        event_us: 999,
        response_kind: :success,
        io_duration_us: 42
      })

    assert decided.terminal == :response
    assert decided.terminal_event.response_kind == :success
    assert decided.terminal_event.io_duration_us == 42
  end

  test "bounded ID tracking preserves earlier derived protocol violations" do
    contradicted =
      state(1_000)
      |> ExecutionReducer.observe(%{id: 1, kind: :send_confirmed, event_us: 1})
      |> ExecutionReducer.observe(%{id: 2, kind: :not_dispatched, event_us: 2})

    filled =
      Enum.reduce(3..16, contradicted, fn id, acc ->
        ExecutionReducer.observe(acc, %{id: id, kind: :send_started, event_us: id})
      end)

    overflowed = ExecutionReducer.observe(filled, %{id: 17, kind: :send_started, event_us: 17})

    reasons = Enum.map(overflowed.protocol_violations, & &1.reason)
    assert :certainty_regression in reasons
    assert map_size(overflowed.seen) == 16
    assert map_size(overflowed.observations) == 3
  end

  test "terminal linearization is unaffected by mailbox order" do
    reduced =
      state()
      |> ExecutionReducer.observe(%{
        id: 1,
        kind: :transport_failure,
        event_us: 90,
        reason: :connection,
        certainty: :indeterminate
      })
      |> ExecutionReducer.observe(response(2, 80))

    assert reduced.terminal == :response
    assert reduced.terminal_at_us == 80

    committed = ExecutionReducer.commit(reduced)
    late = ExecutionReducer.observe(committed, %{id: 3, kind: :send_confirmed, event_us: 70})
    assert late.terminal == :response
    assert [%{kind: :send_confirmed}] = late.late_observations
  end

  test "generic task loss never proves non-dispatch" do
    reduced = ExecutionReducer.observe(state(), %{id: 1, kind: :task_exit, event_us: 50})
    assert reduced.terminal == :transport_failure
    assert reduced.dispatch_certainty == :indeterminate

    assert %Lasso.RPC.AttemptTerminal.TransportFailure{reason: :unknown} =
             ExecutionReducer.terminal_fact(reduced)
  end

  test "task loss preserves prior positive dispatch proof" do
    reduced =
      state()
      |> ExecutionReducer.observe(%{id: 1, kind: :send_confirmed, event_us: 40})
      |> ExecutionReducer.observe(%{id: 2, kind: :task_exit, event_us: 50})

    assert reduced.terminal == :transport_failure
    assert reduced.dispatch_certainty == :dispatched

    assert %Lasso.RPC.AttemptTerminal.TransportFailure{
             reason: :unknown,
             dispatch_certainty: :dispatched
           } = ExecutionReducer.terminal_fact(reduced)
  end

  test "a weaker terminal failure materializes the strongest dispatch proof in either order" do
    failure = %{
      id: 2,
      kind: :transport_failure,
      event_us: 50,
      reason: :closed,
      certainty: :indeterminate
    }

    for events <- [
          [%{id: 1, kind: :send_confirmed, event_us: 40}, failure],
          [failure, %{id: 1, kind: :send_confirmed, event_us: 40}]
        ] do
      reduced = ExecutionReducer.observe_many(state(), events)

      assert reduced.terminal == :transport_failure
      assert reduced.dispatch_certainty == :dispatched

      assert %Lasso.RPC.AttemptTerminal.TransportFailure{
               dispatch_certainty: :dispatched
             } = ExecutionReducer.terminal_fact(reduced)

      assert Enum.any?(reduced.protocol_violations, &(&1.reason == :certainty_regression))
    end
  end

  test "bounded batch reduction agrees with sequential logical reduction" do
    events = [
      %{id: 1, kind: :send_started, event_us: 10},
      %{id: 2, kind: :send_confirmed, event_us: 20},
      %{
        id: 3,
        kind: :transport_failure,
        event_us: 30,
        reason: :closed,
        certainty: :dispatched,
        io_duration_us: 20
      }
    ]

    batched = ExecutionReducer.observe_many(state(), events)
    sequential = Enum.reduce(events, state(), &ExecutionReducer.observe(&2, &1))

    assert batched.dispatch_certainty == sequential.dispatch_certainty
    assert batched.terminal == sequential.terminal
    assert batched.terminal_event == sequential.terminal_event
    assert batched.protocol_violations == sequential.protocol_violations
    assert ExecutionReducer.terminal_fact(batched) == ExecutionReducer.terminal_fact(sequential)
  end

  test "cancellation during unresolved send is indeterminate" do
    reduced =
      state()
      |> ExecutionReducer.observe(%{id: 1, kind: :send_started, event_us: 10})
      |> ExecutionReducer.observe(%{
        id: 2,
        kind: :cancelled,
        event_us: 20,
        reason: :caller_abandoned,
        certainty: :not_dispatched,
        censoring_boundary_us: 20
      })

    assert reduced.terminal == :cancelled
    assert reduced.dispatch_certainty == :indeterminate

    assert %Lasso.RPC.AttemptTerminal.Cancelled{
             dispatch_certainty: :indeterminate,
             censoring_boundary_us: 20
           } =
             ExecutionReducer.terminal_fact(reduced)
  end

  test "cancellation upgraded by positive dispatch proof receives a positive censor" do
    reduced =
      state()
      |> ExecutionReducer.observe(%{id: 1, kind: :send_confirmed, event_us: 10})
      |> ExecutionReducer.observe(%{
        id: 2,
        kind: :cancelled,
        event_us: 20,
        reason: :caller_abandoned,
        certainty: :not_dispatched,
        censoring_boundary_us: 0
      })

    assert %Lasso.RPC.AttemptTerminal.Cancelled{
             dispatch_certainty: :dispatched,
             censoring_boundary_us: 20
           } = ExecutionReducer.terminal_fact(reduced)
  end

  test "authoritative not-dispatched proof closes ambiguity before cancellation" do
    reduced =
      state()
      |> ExecutionReducer.observe(%{id: 1, kind: :send_started, event_us: 10})
      |> ExecutionReducer.observe(%{id: 2, kind: :not_dispatched, event_us: 15})
      |> ExecutionReducer.observe(%{
        id: 3,
        kind: :cancelled,
        event_us: 20,
        reason: :caller_abandoned,
        certainty: :not_dispatched,
        censoring_boundary_us: 0
      })

    assert reduced.dispatch_certainty == :not_dispatched
    assert reduced.protocol_violations == []
  end
end

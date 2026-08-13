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

    ExecutionReducer.new(identity, deadline_us)
  end

  test "D-1 is eligible while D and D+1 are late" do
    eligible = ExecutionReducer.observe(state(), %{id: 1, kind: :response, event_us: 99})
    assert eligible.terminal == :response
    assert eligible.dispatch_certainty == :dispatched

    for stamp <- [100, 101] do
      reduced = ExecutionReducer.observe(state(), %{id: stamp, kind: :response, event_us: stamp})
      assert reduced.terminal == nil
      assert [%{event_us: ^stamp}] = reduced.late_observations
      assert ExecutionReducer.close_deadline(reduced).terminal == :deadline
    end
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

  test "duplicates are idempotent and contradictions are diagnostic" do
    event = %{id: 1, kind: :send_started, event_us: 10}
    once = ExecutionReducer.observe(state(), event)
    assert ExecutionReducer.observe(once, event) == once

    contradicted =
      once
      |> ExecutionReducer.observe(%{id: 2, kind: :predispatch_failure, event_us: 20})

    assert contradicted.terminal == nil
    assert [%{reason: :predispatch_after_send}] = contradicted.protocol_violations

    reused = ExecutionReducer.observe(once, %{id: 1, kind: :response, event_us: 10})
    assert [%{reason: :observation_id_reused}] = reused.protocol_violations

    persisted =
      ExecutionReducer.observe(reused, %{id: 3, kind: :send_confirmed, event_us: 30})

    assert Enum.any?(persisted.protocol_violations, &(&1.reason == :observation_id_reused))
  end

  test "hostile observation payloads are never retained" do
    secret = String.duplicate("credential", 1_000)

    reduced =
      state()
      |> ExecutionReducer.observe(%{id: "event", kind: :response, event_us: 99, body: secret})
      |> ExecutionReducer.commit()
      |> ExecutionReducer.observe(%{id: "late", kind: :response, event_us: 98, context: secret})

    serialized = inspect(reduced)
    refute serialized =~ secret
    refute Map.has_key?(hd(reduced.late_observations), :context)
  end

  test "long observation IDs deduplicate after bounded normalization" do
    id = String.duplicate("event-id", 100)
    event = %{id: id, kind: :send_started, event_us: 10}
    once = ExecutionReducer.observe(state(), event)
    assert ExecutionReducer.observe(once, event) == once

    reused = ExecutionReducer.observe(once, %{id: id, kind: :response, event_us: 10})
    assert [%{reason: :observation_id_reused}] = reused.protocol_violations
  end

  test "certainty and terminal contradictions are independent of mailbox order" do
    events = [
      %{id: 1, kind: :send_confirmed, event_us: 90},
      %{id: 2, kind: :predispatch_failure, event_us: 80}
    ]

    forward = Enum.reduce(events, state(), &ExecutionReducer.observe(&2, &1))
    reverse = Enum.reduce(Enum.reverse(events), state(), &ExecutionReducer.observe(&2, &1))

    assert forward.dispatch_certainty == reverse.dispatch_certainty
    assert forward.terminal == reverse.terminal
    assert forward.terminal_at_us == reverse.terminal_at_us
    assert forward.protocol_violations == reverse.protocol_violations
  end

  test "observation state is hard bounded" do
    reduced =
      Enum.reduce(1..100, state(1_000), fn id, acc ->
        ExecutionReducer.observe(acc, %{id: id, kind: :send_started, event_us: id})
      end)

    assert map_size(reduced.seen) == 16
    assert length(reduced.observations) == 16
    assert length(reduced.protocol_violations) <= 16
    assert Enum.any?(reduced.protocol_violations, &(&1.reason == :observation_limit_exceeded))
  end

  test "overflow preserves earlier derived protocol violations" do
    contradicted =
      state(1_000)
      |> ExecutionReducer.observe(%{id: 1, kind: :send_started, event_us: 1})
      |> ExecutionReducer.observe(%{id: 2, kind: :not_dispatched, event_us: 2})

    filled =
      Enum.reduce(3..16, contradicted, fn id, acc ->
        ExecutionReducer.observe(acc, %{id: id, kind: :send_started, event_us: id})
      end)

    overflowed =
      ExecutionReducer.observe(filled, %{id: 17, kind: :send_started, event_us: 17})

    reasons = Enum.map(overflowed.protocol_violations, & &1.reason)
    assert :certainty_regression in reasons
    assert :observation_limit_exceeded in reasons
  end

  test "terminal linearization is unaffected by mailbox order" do
    reduced =
      state()
      |> ExecutionReducer.observe(%{
        id: 1,
        kind: :transport_failure,
        event_us: 90,
        certainty: :indeterminate
      })
      |> ExecutionReducer.observe(%{id: 2, kind: :response, event_us: 80})

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
  end
end

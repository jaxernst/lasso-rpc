defmodule Lasso.RPC.ExecutionOutcomeTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.ExecutionOutcome

  test "constructs the accepted versioned attempt facts" do
    outcome =
      ExecutionOutcome.new(
        stage: :attempt,
        cause: :provider_health,
        completion: :possibly_applied,
        disposition: :failover,
        evidence_effect: :reliability_failure,
        request_id: "request-1",
        attempt_id: "attempt-1",
        upstream_instance_id: "instance-1",
        chain_id: 1,
        transport: :http,
        routing_intent: :default,
        route_generation: 7,
        circuit_scope: :broad,
        circuit_epoch: 3,
        deadline_us: 200,
        dispatched_at_us: 100,
        terminal_at_us: 150,
        censoring_boundary_ms: 50
      )

    assert outcome.schema_version == 1
    assert outcome.stage == :attempt
    assert outcome.completion == :possibly_applied
  end

  test "admission outcomes cannot claim a dispatch completion" do
    assert_raise ArgumentError, ~r/admission outcomes must be not_dispatched/, fn ->
      ExecutionOutcome.new(
        stage: :admission,
        cause: :capacity,
        completion: :responded,
        disposition: :exhausted,
        evidence_effect: :capacity_signal,
        request_id: "request-1",
        deadline_us: 200,
        terminal_at_us: 150
      )
    end
  end

  test "attempt outcomes require a unique attempt id" do
    assert_raise ArgumentError, ~r/attempt outcomes require attempt_id/, fn ->
      ExecutionOutcome.new(
        stage: :attempt,
        cause: :success,
        completion: :responded,
        disposition: :returned,
        evidence_effect: :usable_success,
        request_id: "request-1",
        deadline_us: 200,
        terminal_at_us: 150
      )
    end
  end

  test "shared version-one fixtures validate without reinterpretation" do
    fixture_path = Path.join(:code.priv_dir(:lasso), "fixtures/execution_outcomes_v1.json")
    fixtures = fixture_path |> File.read!() |> Jason.decode!()

    assert Enum.map(fixtures, & &1["stage"]) == ["admission", "attempt", "request"]

    for fixture <- fixtures do
      attrs =
        fixture
        |> Map.drop(["schema_version"])
        |> Map.new(fn
          {key, value}
          when key in [
                 "stage",
                 "cause",
                 "completion",
                 "disposition",
                 "evidence_effect",
                 "transport",
                 "routing_intent",
                 "circuit_scope"
               ] ->
            {String.to_existing_atom(key), String.to_existing_atom(value)}

          {key, value} ->
            {String.to_existing_atom(key), value}
        end)

      assert %ExecutionOutcome{schema_version: 1} = ExecutionOutcome.new(Map.to_list(attrs))
    end
  end

  test "fixtures declare the supported schema version" do
    fixture_path = Path.join(:code.priv_dir(:lasso), "fixtures/execution_outcomes_v1.json")
    fixtures = fixture_path |> File.read!() |> Jason.decode!()
    assert Enum.all?(fixtures, &(&1["schema_version"] == 1))
  end
end

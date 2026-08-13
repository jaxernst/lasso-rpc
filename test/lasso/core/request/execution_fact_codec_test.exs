defmodule Lasso.RPC.ExecutionFact.CodecTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.{AdmissionTerminal, AttemptIdentity, AttemptTerminal, LateObservation}
  alias Lasso.RPC.{RequestTerminal, ExecutionFact.Codec}

  defp identity do
    AttemptIdentity.new(
      request_id: "request-1",
      attempt_id: "attempt-1",
      profile: "public",
      subject_token: "account-token",
      chain_id: 1,
      upstream_instance_id: "instance-1",
      transport: :http,
      route_generation: 7,
      circuit_scope: :broad,
      circuit_epoch: 3,
      execution_safety: :replay_safe,
      routing_intent: "default",
      workload_key: "read",
      request_budget_ms: 100,
      candidate_admission_count: 2,
      dispatch_count: 1
    )
  end

  defp request_attrs(safety \\ :replay_safe) do
    [
      request_id: "request-1",
      profile: "public",
      subject_token: "account-token",
      chain_id: 1,
      execution_safety: safety,
      routing_intent: "default",
      workload_key: "read",
      elapsed_us: 50_000,
      candidate_admission_count: 2,
      dispatch_count: 1,
      observed_at: "2026-08-13T20:00:00Z"
    ]
  end

  test "round trips every tagged fact variant" do
    id = identity()
    response = AttemptTerminal.Response.new(id, :success, 12)

    facts = [
      AdmissionTerminal.new(
        request_id: "request-1",
        profile: "public",
        chain_id: 1,
        routing_intent: "default",
        workload_key: "read",
        reason: :local_capacity,
        candidate_admission_count: 1,
        dispatch_count: 0,
        elapsed_us: 2,
        retry_after_ms: 5
      ),
      AttemptTerminal.PredispatchFailure.new(id, :encode, 2),
      response,
      AttemptTerminal.Response.new(id, :application_error, 12,
        error_code: -32_000,
        error_category: :quota,
        retry_after_ms: 250
      ),
      AttemptTerminal.InvalidResponse.new(id, :invalid_json, 12),
      AttemptTerminal.TransportFailure.new(id, :connection, :indeterminate, io_duration_us: 12),
      AttemptTerminal.Deadline.new(id, :dispatched, 30),
      AttemptTerminal.Cancelled.new(id, :caller_abandoned, :not_dispatched, 0),
      RequestTerminal.UpstreamResponse.new(request_attrs(), response),
      RequestTerminal.LocalFailure.new(request_attrs(), :configuration),
      RequestTerminal.Deadline.new(request_attrs(), :indeterminate),
      RequestTerminal.CallerAbandonment.new(
        Keyword.put(request_attrs(), :dispatch_count, 0),
        :not_dispatched
      ),
      RequestTerminal.UnsafeIndeterminateExhaustion.new(
        request_attrs(:raw_transaction_broadcast)
      ),
      RequestTerminal.OrdinaryExhaustion.new(request_attrs(), :providers_exhausted),
      LateObservation.new(
        request_id: "request-1",
        attempt_id: "attempt-1",
        kind: :send_confirmed,
        elapsed_us: 55
      )
    ]

    for fact <- facts do
      assert {:ok, json} = Codec.encode(fact)
      assert byte_size(json) <= Codec.max_bytes()
      assert {:ok, ^fact} = Codec.decode(json)
    end
  end

  test "version requires non-negative integer major and minor fields" do
    encoded = Codec.encode!(AttemptTerminal.Response.new(identity(), :success, 1))
    envelope = Jason.decode!(encoded)

    for version <- [
          %{"major" => 1},
          %{"major" => 1, "minor" => "garbage"},
          %{"major" => 1, "minor" => -1}
        ] do
      assert {:error, :invalid_envelope} =
               envelope
               |> Map.put("version", version)
               |> Jason.encode!()
               |> Codec.decode()
    end

    assert {:ok, _} =
             envelope
             |> Map.put("version", %{"major" => 1, "minor" => 0, "future" => true})
             |> Jason.encode!()
             |> Codec.decode()
  end

  test "rejects malformed and unsupported major versions" do
    assert Codec.decode("not-json") == {:error, :malformed_json}

    assert Codec.decode(
             ~s({"schema":"lasso.execution-fact","version":{"major":2},"stage":"request"})
           ) ==
             {:error, :invalid_envelope}

    assert Codec.decode(~s({"schema":"other","version":{"major":1}})) ==
             {:error, :invalid_envelope}
  end

  test "unknown minor fields are ignored without atom growth" do
    {:ok, json} = Codec.encode(AttemptTerminal.Deadline.new(identity(), :dispatched, 30))
    decoded = Jason.decode!(json)

    decorated =
      Enum.reduce(1..10, decoded, fn index, acc ->
        Map.put(acc, "never_atomized_external_field_#{index}", String.duplicate("x", 8))
      end)

    before_count = :erlang.system_info(:atom_count)
    assert {:ok, %AttemptTerminal.Deadline{}} = Codec.decode(Jason.encode!(decorated))
    assert :erlang.system_info(:atom_count) == before_count
  end

  test "oversized external facts are rejected before decoding" do
    assert Codec.decode(String.duplicate("x", Codec.max_bytes() + 1)) ==
             {:error, :fact_too_large}
  end

  test "wire facts contain no absolute monotonic timestamp or retained payload" do
    secret_request = String.duplicate("request-payload-secret", 1_000)
    secret_response = String.duplicate("response-payload-secret", 1_000)
    fact = AttemptTerminal.Response.new(identity(), :success, 12)
    json = Codec.encode!(fact)

    refute json =~ secret_request
    refute json =~ secret_response
    refute json =~ "deadline_us"
    refute json =~ "started_at_us"
    refute json =~ "terminal_at_us"
    refute json =~ "request_body"
    refute json =~ "response_value"
  end

  test "shared version-one fixtures decode through the public boundary" do
    fixture_path = Path.join(:code.priv_dir(:lasso), "fixtures/execution_facts_v1.json")
    fixtures = fixture_path |> File.read!() |> Jason.decode!()

    assert Enum.map(fixtures, & &1["stage"]) == ["admission", "attempt", "request"]

    for fixture <- fixtures do
      json = Jason.encode!(fixture)
      assert byte_size(json) <= Codec.max_bytes()
      assert {:ok, _fact} = Codec.decode(json)
    end
  end

  test "maximum legal fact remains within the fixed four-kibibyte boundary" do
    max = String.duplicate("x", 128)

    identity =
      AttemptIdentity.new(
        request_id: max,
        attempt_id: max,
        profile: max,
        subject_token: max,
        chain_id: 9_999_999_999,
        upstream_instance_id: max,
        transport: :http,
        route_generation: 9_999_999_999,
        circuit_scope: :broad,
        circuit_epoch: 9_999_999_999,
        execution_safety: :raw_transaction_broadcast,
        routing_intent: max,
        workload_key: max,
        request_budget_ms: 9_999_999_999,
        candidate_admission_count: 16,
        dispatch_count: 3
      )

    fact =
      AttemptTerminal.Response.new(identity, :application_error, 9_999_999_999,
        error_code: -32_000,
        error_category: :provider_failure,
        retry_after_ms: 9_999_999_999
      )

    assert {:ok, json} = Codec.encode(fact)
    assert byte_size(json) <= 4_096
    assert {:ok, ^fact} = Codec.decode(json)
  end
end

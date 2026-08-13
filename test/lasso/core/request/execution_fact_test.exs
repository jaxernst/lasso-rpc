defmodule Lasso.RPC.ExecutionFactTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.{AdmissionTerminal, AttemptIdentity, AttemptTerminal, LateObservation}
  alias Lasso.RPC.{RequestTerminal, ExecutionPlan, AdmissionLease}

  def identity(safety \\ :replay_safe) do
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
      execution_safety: safety,
      routing_intent: "default",
      workload_key: "read",
      request_budget_ms: 100,
      candidate_admission_count: 2,
      dispatch_count: 1
    )
  end

  def request_attrs(safety \\ :replay_safe) do
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

  test "constructs every legal attempt terminal variant" do
    id = identity()

    assert %AttemptTerminal.PredispatchFailure{} =
             AttemptTerminal.PredispatchFailure.new(id, :encode, 10)

    assert %AttemptTerminal.Response{} = AttemptTerminal.Response.new(id, :success, 20)

    assert %AttemptTerminal.Response{} =
             AttemptTerminal.Response.new(id, :application_error, 20,
               error_code: -32_000,
               error_category: "application"
             )

    assert %AttemptTerminal.InvalidResponse{} =
             AttemptTerminal.InvalidResponse.new(id, :id_mismatch, 20)

    assert %AttemptTerminal.TransportFailure{} =
             AttemptTerminal.TransportFailure.new(id, :connection, :indeterminate)

    assert %AttemptTerminal.Deadline{} = AttemptTerminal.Deadline.new(id, :dispatched, 30)

    assert %AttemptTerminal.Cancelled{} =
             AttemptTerminal.Cancelled.new(id, :caller_abandoned, :not_dispatched, 0)
  end

  test "constructs every legal request terminal variant" do
    response = AttemptTerminal.Response.new(identity(), :success, 20)

    assert %RequestTerminal.UpstreamResponse{} =
             RequestTerminal.UpstreamResponse.new(request_attrs(), response)

    assert %RequestTerminal.LocalFailure{} =
             RequestTerminal.LocalFailure.new(request_attrs(), :configuration)

    assert %RequestTerminal.Deadline{} =
             RequestTerminal.Deadline.new(request_attrs(), :indeterminate)

    assert %RequestTerminal.CallerAbandonment{} =
             RequestTerminal.CallerAbandonment.new(request_attrs(), :not_dispatched)

    assert %RequestTerminal.UnsafeIndeterminateExhaustion{} =
             RequestTerminal.UnsafeIndeterminateExhaustion.new(
               request_attrs(:raw_transaction_broadcast)
             )

    assert %RequestTerminal.OrdinaryExhaustion{} =
             RequestTerminal.OrdinaryExhaustion.new(request_attrs(), :providers_exhausted)
  end

  test "illegal combinations are rejected by tagged constructors" do
    assert_raise ArgumentError, ~r/successful responses/, fn ->
      AttemptTerminal.Response.new(identity(), :success, 20, error_code: -1)
    end

    assert_raise ArgumentError, ~r/zero censoring/, fn ->
      AttemptTerminal.Deadline.new(identity(), :not_dispatched, 1)
    end

    assert_raise ArgumentError, ~r/replay-safe/, fn ->
      RequestTerminal.UnsafeIndeterminateExhaustion.new(request_attrs())
    end

    assert_raise ArgumentError, ~r/identity disagree/, fn ->
      RequestTerminal.UpstreamResponse.new(
        Keyword.put(request_attrs(), :profile, "other-tenant"),
        AttemptTerminal.Response.new(identity(), :success, 20)
      )
    end
  end

  test "admission and late facts have no attempt timing or payload fields" do
    admission =
      AdmissionTerminal.new(
        request_id: "request-1",
        profile: "public",
        chain_id: 1,
        routing_intent: "default",
        workload_key: "read",
        reason: :local_capacity,
        candidate_admission_count: 1,
        dispatch_count: 0,
        elapsed_us: 20
      )

    late =
      LateObservation.new(
        request_id: "request-1",
        attempt_id: "attempt-1",
        kind: :send_confirmed,
        elapsed_us: 30
      )

    refute Map.has_key?(admission, :attempt_id)
    refute Map.has_key?(admission, :dispatch_certainty)
    refute Map.has_key?(late, :request_body)
    refute Map.has_key?(late, :response_value)
  end

  test "identifiers are bounded without retaining long external values" do
    source = String.duplicate("sensitive/", 1_000)
    id = AttemptIdentity.new(Keyword.merge(Map.to_list(identity()), request_id: source))

    assert byte_size(id.request_id) <= 128
    assert String.starts_with?(id.request_id, "sha256:")
    refute id.request_id =~ "sensitive"
  end

  test "execution plans and composite leases remain narrow and ordered" do
    plan =
      ExecutionPlan.new(
        profile: "public",
        workload_key: "read",
        route_generation: 2,
        candidate: %{upstream_instance_id: "i", transport: :http},
        policy: %{strategy: "fastest"}
      )

    assert plan.route_generation == 2

    lease =
      AdmissionLease.new("lease", self())
      |> AdmissionLease.add(:breaker, "breaker")
      |> AdmissionLease.add(:node_bulkhead, "node")

    assert Enum.map(AdmissionLease.rollback_order(lease), & &1.kind) == [:node_bulkhead, :breaker]

    assert_raise ArgumentError, ~r/fixed order/, fn ->
      AdmissionLease.new("lease", self()) |> AdmissionLease.add(:upstream_bulkhead, "bad")
    end
  end
end

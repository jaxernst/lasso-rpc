defmodule Lasso.RPC.ExecutionProjectorTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.{AdmissionTerminal, AttemptIdentity, AttemptTerminal, ExecutionProjector}
  alias Lasso.RPC.RequestTerminal

  defp identity(safety) do
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
      execution_safety: safety,
      routing_intent: "default",
      workload_key: "read",
      request_budget_ms: 100,
      candidate_admission_count: 1,
      dispatch_count: 1
    )
  end

  test "fallback matrix is derived from safety and dispatch certainty" do
    for safety <- [:replay_safe, :raw_transaction_broadcast, :unknown],
        certainty <- [:indeterminate, :dispatched] do
      fact = AttemptTerminal.TransportFailure.new(identity(safety), :connection, certainty)
      projection = ExecutionProjector.project(fact)
      expected = safety == :replay_safe
      assert projection.fallback_eligible == expected

      assert projection.recommended_action ==
               if(expected, do: :try_next_candidate, else: :finish_unsafe_indeterminate)
    end
  end

  test "projector covers every attempt variant without storing future disposition" do
    id = identity(:replay_safe)

    facts = [
      AttemptTerminal.PredispatchFailure.new(id, :encode, 0),
      AttemptTerminal.Response.new(id, :success, 1),
      AttemptTerminal.Response.new(id, :application_error, 1,
        error_code: -1,
        error_category: :deterministic
      ),
      AttemptTerminal.InvalidResponse.new(id, :invalid_json, 1),
      AttemptTerminal.TransportFailure.new(id, :closed, :dispatched),
      AttemptTerminal.Deadline.new(id, :indeterminate, 10),
      AttemptTerminal.Cancelled.new(id, :caller_abandoned, :dispatched, 10)
    ]

    for fact <- facts do
      assert %ExecutionProjector{version: 1} = ExecutionProjector.project(fact)
      refute Map.has_key?(fact, :failover)
      refute Map.has_key?(fact, :exhausted)
    end
  end

  test "an indeterminate transport failure alone does not penalize provider health" do
    projection =
      identity(:unknown)
      |> AttemptTerminal.TransportFailure.new(:connection, :indeterminate)
      |> ExecutionProjector.project()

    assert projection.breaker_effect == :none
    assert projection.evidence_qualification == :neutral
  end

  test "application error category and safety matrix is exhaustive" do
    categories = [:deterministic, :quota, :capability, :provider_failure]

    safeties = [
      :replay_safe,
      :raw_transaction_broadcast,
      :upstream_signed,
      :filter_create,
      :filter_affine_read,
      :filter_affine_consume,
      :filter_affine_uninstall,
      :subscription,
      :unknown
    ]

    for category <- categories, safety <- safeties do
      projection =
        identity(safety)
        |> AttemptTerminal.Response.new(:application_error, 1,
          error_code: -32_000,
          error_category: category,
          retry_after_ms: if(category == :quota, do: 250)
        )
        |> ExecutionProjector.project()

      expected_fallback =
        category in [:quota, :capability] or
          (category == :provider_failure and safety == :replay_safe)

      assert projection.fallback_eligible == expected_fallback

      assert projection.breaker_effect ==
               if(category == :provider_failure, do: :failure, else: :none)
    end
  end

  test "unsupported projector versions fail explicitly" do
    assert_raise ArgumentError, ~r/unsupported projector version/, fn ->
      ExecutionProjector.project(
        AttemptTerminal.Response.new(identity(:replay_safe), :success, 1),
        2
      )
    end
  end

  test "projector covers admission and request terminal variants" do
    admission =
      AdmissionTerminal.new(
        request_id: "request",
        profile: "public",
        chain_id: 1,
        routing_intent: "default",
        workload_key: "read",
        reason: :local_capacity,
        candidate_admission_count: 1,
        dispatch_count: 0,
        elapsed_us: 1
      )

    attrs = [
      request_id: "request",
      profile: "public",
      chain_id: 1,
      execution_safety: :raw_transaction_broadcast,
      routing_intent: "transaction",
      workload_key: "send",
      elapsed_us: 10,
      candidate_admission_count: 1,
      dispatch_count: 1
    ]

    response = AttemptTerminal.Response.new(identity(:replay_safe), :success, 1)

    response_attrs = [
      request_id: "request",
      profile: "public",
      chain_id: 1,
      execution_safety: :replay_safe,
      routing_intent: "default",
      workload_key: "read",
      elapsed_us: 10,
      candidate_admission_count: 1,
      dispatch_count: 1
    ]

    facts = [
      admission,
      RequestTerminal.UpstreamResponse.new(response_attrs, response),
      RequestTerminal.LocalFailure.new(attrs, :configuration),
      RequestTerminal.Deadline.new(attrs, :indeterminate),
      RequestTerminal.CallerAbandonment.new(attrs, :indeterminate),
      RequestTerminal.UnsafeIndeterminateExhaustion.new(attrs),
      RequestTerminal.OrdinaryExhaustion.new(attrs, :providers_exhausted)
    ]

    assert Enum.all?(
             facts,
             &match?(%ExecutionProjector{version: 1}, ExecutionProjector.project(&1))
           )
  end

  test "admission reason matrix never continues after hard ceilings or invariant breaches" do
    retryable = [:circuit_open, :admission_unavailable, :local_capacity, :unsupported_transport]

    reasons = [
      :deadline,
      :candidate_budget_exhausted,
      :dispatch_budget_exhausted,
      :duplicate_dispatch,
      :circuit_open,
      :admission_unavailable,
      :local_capacity,
      :policy,
      :unsupported_transport,
      :invalid_request,
      :caller_abandoned
    ]

    for reason <- reasons do
      fact =
        AdmissionTerminal.new(
          request_id: "request",
          profile: "public",
          chain_id: 1,
          routing_intent: "default",
          workload_key: "read",
          reason: reason,
          candidate_admission_count: 1,
          dispatch_count: 0,
          elapsed_us: 1
        )

      projection = ExecutionProjector.project(fact)
      assert projection.fallback_eligible == reason in retryable
    end
  end

  test "attempt deadline fallback follows safety and certainty while cancellation finishes" do
    for safety <- [
          :replay_safe,
          :raw_transaction_broadcast,
          :upstream_signed,
          :filter_create,
          :filter_affine_read,
          :filter_affine_consume,
          :filter_affine_uninstall,
          :subscription,
          :unknown
        ],
        certainty <- [:not_dispatched, :indeterminate, :dispatched] do
      boundary = if certainty == :not_dispatched, do: 0, else: 10

      deadline = AttemptTerminal.Deadline.new(identity(safety), certainty, boundary)

      cancelled =
        AttemptTerminal.Cancelled.new(
          identity(safety),
          :caller_abandoned,
          certainty,
          boundary
        )

      deadline_projection = ExecutionProjector.project(deadline)
      expected_fallback = certainty == :not_dispatched or safety == :replay_safe
      assert deadline_projection.fallback_eligible == expected_fallback

      assert deadline_projection.recommended_action ==
               if(expected_fallback, do: :try_next_candidate, else: :finish_unsafe_indeterminate)

      cancellation_projection = ExecutionProjector.project(cancelled)
      refute cancellation_projection.fallback_eligible
      assert cancellation_projection.recommended_action == :finish_request
    end
  end
end

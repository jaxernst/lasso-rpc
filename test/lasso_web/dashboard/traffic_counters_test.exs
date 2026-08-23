defmodule LassoWeb.Dashboard.TrafficCountersTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.{
    AttemptIdentity,
    AttemptTerminal,
    RequestProjection,
    RequestTerminal
  }

  alias LassoWeb.Dashboard.TrafficCounters

  setup do
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  test "counts exact client outcomes by profile while excluding system work" do
    unique = System.unique_integer([:positive])
    profile = "traffic-profile-#{unique}"
    now_second = System.system_time(:second)

    assert :ok = TrafficCounters.record(success_event(profile, 2, :client))
    assert :ok = TrafficCounters.record(error_event(profile, 1))
    assert :ok = TrafficCounters.record(success_event(profile, 0, :client))
    assert :ignored = TrafficCounters.record(success_event(profile, 0, :system))

    windows = TrafficCounters.windows(profile, [:profile], 60, now_second)

    assert windows[:profile] == %{
             count: 3,
             successes: 2,
             errors: 1,
             elapsed_us: 30_000,
             failovers: 3
           }
  end

  test "does not include outcomes outside the requested window" do
    unique = System.unique_integer([:positive])
    profile = "traffic-window-#{unique}"
    now_second = System.system_time(:second)

    old = %{
      success_event(profile, 0, :client)
      | emitted_at_ms: (now_second - 60) * 1_000
    }

    current = %{success_event(profile, 0, :client) | emitted_at_ms: now_second * 1_000}

    assert :ok = TrafficCounters.record(old)
    assert :ok = TrafficCounters.record(current)

    assert %{count: 1, successes: 1, errors: 0} =
             TrafficCounters.windows(profile, [:profile], 60, now_second)[:profile]
  end

  defp success_event(profile, failovers, origin) do
    identity =
      AttemptIdentity.new(
        request_id: "request-#{System.unique_integer([:positive])}",
        attempt_id: "attempt-#{System.unique_integer([:positive])}",
        profile: profile,
        chain_id: 1,
        upstream_instance_id: "instance-a",
        transport: :http,
        route_generation: 1,
        circuit_scope: :broad,
        circuit_epoch: 1,
        execution_safety: :replay_safe,
        routing_intent: "fastest",
        workload_key: "default",
        request_budget_ms: 100,
        candidate_admission_count: 1,
        dispatch_count: 1
      )

    attempt = AttemptTerminal.Response.new(identity, :success, 7_000)

    terminal =
      RequestTerminal.UpstreamResponse.new(
        [
          request_id: identity.request_id,
          profile: profile,
          subject_token: nil,
          chain_id: 1,
          execution_safety: :replay_safe,
          routing_intent: "fastest",
          workload_key: "default",
          elapsed_us: 10_000,
          candidate_admission_count: 1,
          dispatch_count: 1,
          observed_at: nil
        ],
        attempt
      )

    RequestProjection.new(
      terminal,
      "eth_blockNumber",
      %{provider_id: "provider-a", instance_id: "instance-a", transport: :http},
      failovers,
      origin
    )
  end

  defp error_event(profile, failovers) do
    terminal =
      RequestTerminal.LocalFailure.new(
        [
          request_id: "request-#{System.unique_integer([:positive])}",
          profile: profile,
          subject_token: nil,
          chain_id: 1,
          execution_safety: :replay_safe,
          routing_intent: "fastest",
          workload_key: "default",
          elapsed_us: 10_000,
          candidate_admission_count: 0,
          dispatch_count: 0,
          observed_at: nil
        ],
        :capacity
      )

    RequestProjection.new(
      terminal,
      "eth_blockNumber",
      nil,
      failovers,
      :client
    )
  end
end

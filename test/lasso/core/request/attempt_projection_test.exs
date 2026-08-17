defmodule Lasso.RPC.AttemptProjectionTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.{ProjectionDispatcher, ProjectionLane}
  alias Lasso.Providers.Catalog

  alias Lasso.RPC.{
    AttemptIdentity,
    AttemptProjection,
    AttemptTerminal,
    RequestTerminal
  }

  @profile "projection-test"
  @chain_id 1
  @healthy_dispatcher Lasso.TestHealthyProjectionDispatcher
  @predispatch_dispatcher Lasso.TestPredispatchProjectionDispatcher

  setup do
    Application.ensure_all_started(:lasso)
    clear_control_rows()

    on_exit(fn ->
      clear_control_rows()

      AttemptProjection.reconcile_routes(
        ConfigStore.route_generation(),
        Catalog.routing_control_routes()
      )
    end)

    :ok
  end

  test "only canonical diagnostics use the bounded asynchronous dispatcher" do
    lanes = AttemptProjection.lane_configs()

    assert Keyword.keys(lanes) == [:diagnostics]
    assert lanes[:diagnostics][:capacity] == 2_048
    assert lanes[:diagnostics][:scope_capacity] == 64
  end

  test "projection payload round trips as one bounded canonical fact" do
    event = success_event(1)

    assert {:ok, payload} = AttemptProjection.encode(event)
    assert byte_size(payload) <= 4_096
    assert {:ok, ^event} = AttemptProjection.decode(payload)

    refute inspect(payload) =~ "request body"
    refute inspect(payload) =~ "response body"
  end

  test "healthy one-attempt completion submits only its request terminal diagnostic" do
    parent = self()

    start_supervised!({
      ProjectionDispatcher,
      name: @healthy_dispatcher,
      lanes: [
        diagnostics:
          diagnostic_lane(fn _scope, payload -> send(parent, {:diagnostic, payload}) end)
      ]
    })

    generation = ConfigStore.route_generation()

    attempt =
      AttemptTerminal.Response.new(identity("projection-instance", generation), :success, 10)

    event = AttemptProjection.new(attempt, "provider", "eth_call")

    assert :not_required = AttemptProjection.enqueue_diagnostic(event, @healthy_dispatcher)

    terminal =
      RequestTerminal.UpstreamResponse.new(
        [
          request_id: attempt.identity.request_id,
          profile: attempt.identity.profile,
          subject_token: nil,
          chain_id: attempt.identity.chain_id,
          execution_safety: attempt.identity.execution_safety,
          routing_intent: attempt.identity.routing_intent,
          workload_key: attempt.identity.workload_key,
          elapsed_us: 10,
          candidate_admission_count: attempt.identity.candidate_admission_count,
          dispatch_count: attempt.identity.dispatch_count,
          observed_at: nil
        ],
        attempt
      )

    assert {:ok, _token} =
             AttemptProjection.enqueue_request_terminal(terminal, @healthy_dispatcher)

    assert_receive {:diagnostic, _payload}
    refute_receive {:diagnostic, _payload}, 10
  end

  test "predispatch failures remain independently diagnosable" do
    parent = self()

    start_supervised!({
      ProjectionDispatcher,
      name: @predispatch_dispatcher,
      lanes: [
        diagnostics:
          diagnostic_lane(fn _scope, payload -> send(parent, {:diagnostic, payload}) end)
      ]
    })

    generation = ConfigStore.route_generation()

    fact =
      AttemptTerminal.PredispatchFailure.new(
        identity("projection-instance", generation),
        :encode,
        3
      )

    event = AttemptProjection.new(fact, "provider", "eth_call")

    assert {:ok, _token} =
             AttemptProjection.enqueue_diagnostic(event, @predispatch_dispatcher)

    assert_receive {:diagnostic, payload}
    assert {:ok, ^event} = AttemptProjection.decode(payload)
  end

  test "saturated diagnostics reject before encoding an attempt event" do
    dispatcher =
      Module.concat(__MODULE__, "Saturated#{System.unique_integer([:positive])}")

    start_supervised!({
      ProjectionDispatcher,
      name: dispatcher,
      lanes: [
        diagnostics:
          Keyword.merge(diagnostic_lane(fn _scope, _payload -> :ok end),
            capacity: 1,
            scope_capacity: 1
          )
      ]
    })

    {:ok, lane} = ProjectionDispatcher.lane(dispatcher, :diagnostics)
    {worker, _generation} = ProjectionLane.workers(lane)[0]
    :erlang.suspend_process(worker)
    on_exit(fn -> if Process.alive?(worker), do: :erlang.resume_process(worker) end)

    generation = ConfigStore.route_generation()

    fact =
      AttemptTerminal.PredispatchFailure.new(
        identity("projection-instance", generation),
        :encode,
        3
      )

    event = AttemptProjection.new(fact, "provider", "eth_call")
    assert {:ok, occupied} = AttemptProjection.enqueue_diagnostic(event, dispatcher)

    oversized = %{event | provider_id: :binary.copy("x", 5_000)}
    assert {:error, :event_too_large} = AttemptProjection.encode(oversized)

    assert {:drop, :bucket_contended, %ProjectionLane.Degradation{}} =
             AttemptProjection.enqueue_diagnostic(oversized, dispatcher)

    assert :cancelled = ProjectionDispatcher.cancel(dispatcher, :diagnostics, occupied)

    assert {:drop, :invalid_payload, :untracked} =
             AttemptProjection.enqueue_diagnostic(oversized, dispatcher)

    assert ProjectionLane.stats(lane).retained_items == 0
  end

  test "request completion never recreates a route removed after publication" do
    generation = publish_routes(["projection-instance"])
    route_key = route_key("projection-instance")
    :ets.delete(:lasso_instance_state, route_key)

    assert :stale =
             AttemptProjection.apply_control(success_event(10, "projection-instance", generation))

    assert [] = :ets.lookup(:lasso_instance_state, route_key)

    scope = AttemptProjection.scope_state(@profile, @chain_id)
    assert scope.degraded?
    assert scope.missing_drops == 1
  end

  test "reversed event stamps preserve aggregates while the newer status wins" do
    generation = publish_routes(["projection-instance"])

    assert :ok =
             AttemptProjection.apply_control(
               success_event(200, "projection-instance", generation)
             )

    assert :ok =
             AttemptProjection.apply_control(
               failure_event(100, "projection-instance", generation)
             )

    scope = AttemptProjection.scope_state(@profile, @chain_id)
    row = AttemptProjection.route_state(scope, "projection-instance", :http)

    assert row.revision == 2
    assert row.comparable_attempts == 2
    assert row.usable_successes == 1
    assert row.total_failures == 1
    assert row.observed_at_us == 200
    assert row.oldest_observed_at_us == 100
    assert row.state_observed_at_us == 200
    assert row.status == :healthy
    assert row.consecutive_failures == 0
  end

  test "rate-limit observations never regress and every delta is counted" do
    generation = publish_routes(["projection-instance"])

    assert :ok =
             AttemptProjection.apply_control(
               quota_event(2_000_000, 100, "projection-instance", generation)
             )

    assert :ok =
             AttemptProjection.apply_control(
               quota_event(1_000_000, 500, "projection-instance", generation)
             )

    scope = AttemptProjection.scope_state(@profile, @chain_id)
    row = AttemptProjection.route_state(scope, "projection-instance", :http)

    assert row.comparable_attempts == 2
    assert row.total_rate_limits == 2
    assert row.rate_limit_observed_at_us == 2_000_000
    assert row.rate_limit_expiry_ms == 2_100
    assert row.rate_limit_retry_after_ms == 100
  end

  test "probation cannot resurrect another provider's pre-degradation state" do
    generation = publish_routes(["projection-instance-a", "projection-instance-b"])

    assert :ok =
             AttemptProjection.apply_control(
               success_event(10, "projection-instance-b", generation)
             )

    assert :stale =
             AttemptProjection.apply_control(
               success_event(20, "unpublished-instance", generation)
             )

    assert AttemptProjection.learned_feedback_degraded?(@profile, @chain_id)

    for stamp <- 21..52 do
      assert :ok =
               AttemptProjection.apply_control(
                 success_event(stamp, "projection-instance-a", generation)
               )
    end

    scope = AttemptProjection.scope_state(@profile, @chain_id)
    refute scope.degraded?
    assert scope.recovery_floor_us == 20
    assert AttemptProjection.route_state(scope, "projection-instance-a", :http)
    refute AttemptProjection.route_state(scope, "projection-instance-b", :http)
  end

  test "only thirty-two applied successes complete degraded-scope probation" do
    generation = publish_routes(["projection-instance"])

    assert :stale =
             AttemptProjection.apply_control(
               success_event(20, "unpublished-instance", generation)
             )

    initial = AttemptProjection.scope_state(@profile, @chain_id)
    assert initial.degraded?
    assert initial.probation_remaining == 32

    for stamp <- 21..52 do
      event =
        case rem(stamp, 3) do
          0 -> failure_event(stamp, "projection-instance", generation)
          1 -> quota_event(stamp, 100, "projection-instance", generation)
          2 -> neutral_event(stamp, "projection-instance", generation)
        end

      assert :ok = AttemptProjection.apply_control(event)
    end

    unchanged = AttemptProjection.scope_state(@profile, @chain_id)
    assert unchanged.degraded?
    assert unchanged.probation_remaining == 32

    for stamp <- 53..83 do
      assert :ok =
               AttemptProjection.apply_control(
                 success_event(stamp, "projection-instance", generation)
               )
    end

    almost_recovered = AttemptProjection.scope_state(@profile, @chain_id)
    assert almost_recovered.degraded?
    assert almost_recovered.probation_remaining == 1

    assert :ok =
             AttemptProjection.apply_control(success_event(84, "projection-instance", generation))

    recovered = AttemptProjection.scope_state(@profile, @chain_id)
    refute recovered.degraded?
    assert recovered.probation_remaining == 0
  end

  test "success summaries do not mislabel a lifetime maximum as p95" do
    generation = publish_routes(["projection-instance"])

    assert :ok =
             AttemptProjection.apply_control(
               success_event_with_latency(100, 10_000, "projection-instance", generation)
             )

    assert :ok =
             AttemptProjection.apply_control(
               success_event_with_latency(101, 1_000_000, "projection-instance", generation)
             )

    scope = AttemptProjection.scope_state(@profile, @chain_id)
    row = AttemptProjection.route_state(scope, "projection-instance", :http)

    assert row.successful_mean_latency_ms == 505.0
    assert row.successful_p95_latency_ms == nil
  end

  test "client and system evidence stay isolated while system latency seeds a client prior" do
    generation = publish_routes(["projection-instance"])
    scope = AttemptProjection.scope_state(@profile, @chain_id)

    key = route_key("projection-instance")
    assert [{^key, _row}] = :ets.lookup(:lasso_instance_state, key)

    for stamp <- 100..102 do
      assert :ok =
               AttemptProjection.apply_control(
                 success_event_for(stamp, 20_000, "projection-instance", generation, "system")
               )
    end

    client = AttemptProjection.route_state(scope, "projection-instance", :http, "client")
    system = AttemptProjection.route_state(scope, "projection-instance", :http, "system")

    assert is_nil(client)
    assert system.usable_successes == 3

    row = AttemptProjection.route_record(scope, "projection-instance", :http)

    prior =
      AttemptProjection.summarize_route(row, "projection-instance", :http, @chain_id, :client)

    assert prior.state == :unqualified
    assert prior.support_source == :system_prior
    assert prior.comparable_attempts == 0
    assert prior.successful_mean_latency_ms == 20.0

    for stamp <- 200..202 do
      assert :ok =
               AttemptProjection.apply_control(
                 success_event_for(stamp, 80_000, "projection-instance", generation, "client")
               )
    end

    client = AttemptProjection.route_state(scope, "projection-instance", :http, "client")
    system = AttemptProjection.route_state(scope, "projection-instance", :http, "system")

    row = AttemptProjection.route_record(scope, "projection-instance", :http)

    authoritative =
      AttemptProjection.summarize_route(row, "projection-instance", :http, @chain_id, :client)

    assert authoritative.state == :qualified
    assert authoritative.support_source == :client_attempt
    assert authoritative.successful_mean_latency_ms == 80.0
    assert client.usable_successes == 3
    assert system.usable_successes == 3
    assert system.successful_mean_latency_ms == 20.0
  end

  test "unknown workload keys cannot grow the fixed routing table" do
    generation = publish_routes(["projection-instance"])
    before_size = :ets.info(:lasso_instance_state, :size)

    assert :stale =
             AttemptProjection.apply_control(
               success_event_for(100, 10_000, "projection-instance", generation, "unknown")
             )

    assert :ets.info(:lasso_instance_state, :size) == before_size
  end

  test "system quota updates shared admission without becoming client reliability evidence" do
    generation = publish_routes(["projection-instance"])

    fact =
      AttemptTerminal.Response.new(
        identity("projection-instance", generation, "system"),
        :application_error,
        10,
        error_code: -32_005,
        error_category: :quota,
        retry_after_ms: 500
      )

    event = %{AttemptProjection.new(fact, "provider", "eth_call") | emitted_at_us: 2_000_000}
    assert :ok = AttemptProjection.apply_control(event)

    scope = AttemptProjection.scope_state(@profile, @chain_id)
    row = AttemptProjection.route_record(scope, "projection-instance", :http)
    system = AttemptProjection.route_state(scope, "projection-instance", :http, "system")

    assert row.total_rate_limits == 0
    assert row.comparable_attempts == 0
    assert row.rate_limit_expiry_ms == 2_500
    assert system.total_rate_limits == 1
    assert system.comparable_attempts == 1
  end

  test "stale system evidence cannot seed client ordering" do
    generation = publish_routes(["projection-instance"])
    stale_us = System.monotonic_time(:microsecond) - 300_000_010

    for offset <- 0..2 do
      assert :ok =
               AttemptProjection.apply_control(
                 success_event_for(
                   stale_us + offset,
                   10_000,
                   "projection-instance",
                   generation,
                   "system"
                 )
               )
    end

    scope = AttemptProjection.scope_state(@profile, @chain_id)
    row = AttemptProjection.route_record(scope, "projection-instance", :http)

    refute AttemptProjection.summarize_route(
             row,
             "projection-instance",
             :http,
             @chain_id,
             :client
           )
  end

  test "qualified routing evidence becomes stale after five minutes without an observation" do
    generation = publish_routes(["stale-instance", "fresh-instance"])
    now_us = System.monotonic_time(:microsecond)
    stale_us = now_us - 300_000_001

    for offset <- 0..2 do
      assert :ok =
               AttemptProjection.apply_control(
                 success_event(stale_us + offset, "stale-instance", generation)
               )

      assert :ok =
               AttemptProjection.apply_control(
                 success_event(now_us - 2 + offset, "fresh-instance", generation)
               )
    end

    summaries =
      AttemptProjection.batch_summaries(
        @profile,
        [
          %{instance_id: "stale-instance", transport: :http},
          %{instance_id: "fresh-instance", transport: :http}
        ],
        @chain_id,
        :default
      )

    assert summaries[{"stale-instance", :http}].state == :stale
    assert summaries[{"fresh-instance", :http}].state == :qualified
  end

  test "availability degradation counters are fixed, generation scoped, and profile isolated" do
    generation = ConfigStore.route_generation()

    routes = [
      %{
        profile: @profile,
        chain_id: @chain_id,
        instance_id: "projection-instance",
        transport: :http
      },
      %{
        profile: "projection-other",
        chain_id: @chain_id,
        instance_id: "other-instance",
        transport: :http
      }
    ]

    assert :ok = AttemptProjection.reconcile_routes(generation, routes)
    before_size = :ets.info(:lasso_instance_state, :size)

    for _index <- 1..100 do
      assert :ok =
               AttemptProjection.record_availability_degradation(
                 @profile,
                 @chain_id,
                 :fastest,
                 :default
               )
    end

    assert :ets.info(:lasso_instance_state, :size) == before_size

    assert AttemptProjection.availability_degradation_count(
             @profile,
             @chain_id,
             :fastest,
             :default
           ) == 100

    assert AttemptProjection.availability_degradation_count(
             "projection-other",
             @chain_id,
             :fastest,
             :default
           ) == 0

    assert :not_tracked =
             AttemptProjection.record_availability_degradation(
               @profile,
               @chain_id,
               :unknown,
               :default
             )
  end

  test "a stale route generation is diagnostic-only and cannot mutate current aggregates" do
    generation = publish_routes(["projection-instance"])
    stale_generation = generation + 1

    assert :stale =
             AttemptProjection.apply_control(
               success_event(100, "projection-instance", stale_generation)
             )

    scope = AttemptProjection.scope_state(@profile, @chain_id)
    [{_, row}] = :ets.lookup(:lasso_instance_state, route_key("projection-instance"))

    assert scope.stale_drops == 1
    assert row.stale_drops == 1
    assert row.comparable_attempts == 0
    assert is_nil(row.observed_at_us)
  end

  test "a missing scope is conservatively degraded and neutral" do
    scope = AttemptProjection.scope_state(@profile, @chain_id)

    assert scope.degraded?
    assert scope.missing_drops == 1
    refute AttemptProjection.route_state(scope, "projection-instance", :http)
  end

  defp publish_routes(instance_ids) do
    generation = ConfigStore.route_generation()

    routes =
      Enum.map(instance_ids, fn instance_id ->
        %{profile: @profile, chain_id: @chain_id, instance_id: instance_id, transport: :http}
      end)

    assert :ok = AttemptProjection.reconcile_routes(generation, routes)
    generation
  end

  defp success_event(emitted_at_us, instance_id \\ "projection-instance", generation \\ nil) do
    generation = generation || ConfigStore.route_generation()
    fact = AttemptTerminal.Response.new(identity(instance_id, generation), :success, 10)
    %{AttemptProjection.new(fact, "provider", "eth_call") | emitted_at_us: emitted_at_us}
  end

  defp failure_event(emitted_at_us, instance_id, generation) do
    fact =
      AttemptTerminal.InvalidResponse.new(identity(instance_id, generation), :invalid_json, 10)

    %{AttemptProjection.new(fact, "provider", "eth_call") | emitted_at_us: emitted_at_us}
  end

  defp quota_event(emitted_at_us, retry_after_ms, instance_id, generation) do
    fact =
      AttemptTerminal.Response.new(
        identity(instance_id, generation),
        :application_error,
        10,
        error_code: -32_005,
        error_category: :quota,
        retry_after_ms: retry_after_ms
      )

    %{AttemptProjection.new(fact, "provider", "eth_call") | emitted_at_us: emitted_at_us}
  end

  defp neutral_event(emitted_at_us, instance_id, generation) do
    fact =
      AttemptTerminal.Cancelled.new(
        identity(instance_id, generation),
        :superseded,
        :dispatched,
        10
      )

    %{AttemptProjection.new(fact, "provider", "eth_call") | emitted_at_us: emitted_at_us}
  end

  defp success_event_with_latency(emitted_at_us, io_duration_us, instance_id, generation) do
    fact =
      AttemptTerminal.Response.new(identity(instance_id, generation), :success, io_duration_us)

    %{AttemptProjection.new(fact, "provider", "eth_call") | emitted_at_us: emitted_at_us}
  end

  defp success_event_for(emitted_at_us, io_duration_us, instance_id, generation, workload_key) do
    fact =
      AttemptTerminal.Response.new(
        identity(instance_id, generation, workload_key),
        :success,
        io_duration_us
      )

    %{AttemptProjection.new(fact, "provider", "eth_call") | emitted_at_us: emitted_at_us}
  end

  defp identity(instance_id, generation), do: identity(instance_id, generation, "client")

  defp identity(instance_id, generation, workload_key) do
    AttemptIdentity.new(
      request_id: "projection-request",
      attempt_id: "projection-attempt-#{instance_id}",
      profile: @profile,
      chain_id: @chain_id,
      upstream_instance_id: instance_id,
      transport: :http,
      route_generation: generation,
      circuit_scope: :broad,
      circuit_epoch: 1,
      execution_safety: :replay_safe,
      routing_intent: "default",
      workload_key: workload_key,
      request_budget_ms: 100,
      candidate_admission_count: 1,
      dispatch_count: 1
    )
  end

  defp route_key(instance_id),
    do: {:routing_control, @profile, @chain_id, instance_id, :http, "client"}

  defp clear_control_rows do
    :ets.match_delete(:lasso_instance_state, {{:routing_control_scope, @profile, :_}, :_})
    :ets.match_delete(:lasso_instance_state, {{:routing_control, @profile, :_, :_, :_, :_}, :_})
  rescue
    ArgumentError -> :ok
  end

  defp diagnostic_lane(sink) do
    [
      capacity: 8,
      byte_capacity: 32_768,
      scope_capacity: 8,
      scope_byte_capacity: 32_768,
      shards: 1,
      max_age_ms: 1_000,
      audit_interval_ms: 1_000,
      sink: sink
    ]
  end
end

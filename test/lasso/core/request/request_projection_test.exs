defmodule Lasso.RPC.RequestProjectionTest do
  use ExUnit.Case, async: false

  alias Lasso.Benchmarking.BenchmarkStore
  alias Lasso.Core.ProjectionDispatcher
  alias Lasso.Events.RoutingDecision

  alias Lasso.RPC.{
    AttemptIdentity,
    AttemptTerminal,
    BoundedIdentifier,
    RequestProjection,
    RequestTerminal
  }

  alias Lasso.RPC.ExecutionFact.Codec
  alias LassoWeb.Dashboard.TrafficCounters

  @fast_dispatcher Lasso.TestRequestProjectionFastDispatcher

  setup do
    Application.ensure_all_started(:lasso)
    :ok
  end

  test "bounded request projection round trips without request or response payloads" do
    oversized = String.duplicate("identifier", 100)

    event =
      RequestProjection.new(
        terminal(),
        oversized,
        %{
          provider_id: oversized,
          instance_id: oversized,
          transport: :http
        },
        2
      )

    assert event.method == BoundedIdentifier.encode(oversized)
    assert event.provider_id == BoundedIdentifier.encode(oversized)
    assert event.instance_id == BoundedIdentifier.encode(oversized)

    assert {:ok, payload} = RequestProjection.encode(event)
    assert byte_size(payload) <= 4_096
    assert {:ok, ^event} = RequestProjection.decode(payload)
    refute inspect(payload) =~ "request body"
    refute inspect(payload) =~ "response body"
  end

  test "maximum route metadata remains inside the projection envelope budget" do
    max_identifier = String.duplicate("i", 128)

    event =
      RequestProjection.new(
        terminal(),
        max_identifier,
        %{
          provider_id: max_identifier,
          instance_id: max_identifier,
          transport: :ws
        },
        16
      )

    assert event.method == max_identifier
    assert event.provider_id == max_identifier
    assert event.instance_id == max_identifier
    assert {:ok, payload} = RequestProjection.encode(event)
    assert byte_size(payload) <= 4_096
    assert {:ok, ^event} = RequestProjection.decode(payload)
  end

  test "successful facts use the compact envelope while legacy facts remain compatible" do
    event = request_projection()

    assert {:ok, native_payload} = RequestProjection.encode(event)

    assert {:lasso_request_projection, 1, compact_fact, _method, _provider_id, _instance_id,
            _transport, _origin, _failovers,
            _emitted_at_ms} =
             :erlang.binary_to_term(native_payload, [:safe])

    assert elem(compact_fact, 0) == :compact_success_v1
    assert tuple_size(compact_fact) == 20
    assert byte_size(native_payload) <= 384

    native_fact_payload =
      :erlang.term_to_binary(
        {
          :lasso_request_projection,
          1,
          event.fact,
          event.method,
          event.provider_id,
          event.instance_id,
          event.transport,
          event.request_origin,
          event.failover_count,
          event.emitted_at_ms
        },
        [:deterministic]
      )

    assert {:ok, ^event} = RequestProjection.decode(native_fact_payload)

    legacy_payload =
      :erlang.term_to_binary(
        {
          :lasso_request_projection,
          1,
          Codec.encode!(event.fact),
          event.method,
          event.provider_id,
          event.instance_id,
          event.transport,
          event.request_origin,
          event.failover_count,
          event.emitted_at_ms
        },
        [:deterministic]
      )

    assert {:ok, ^event} = RequestProjection.decode(legacy_payload)
  end

  test "successful routing detail is bounded without sampling terminal telemetry" do
    topic = Lasso.Topics.routing_decision("public")
    :ok = Phoenix.PubSub.subscribe(Lasso.PubSub, topic)

    handler_id = "routing-sampled-out-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:lasso, :rpc, :routing_decision, :sampled_out],
          [:lasso, :rpc, :request, :terminal]
        ],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    event = request_projection()

    for _index <- 1..258 do
      assert :ok = RequestProjection.deliver(event)
    end

    decisions =
      for _index <- 1..256 do
        assert_receive %RoutingDecision{}
      end

    assert length(decisions) == 256
    refute_receive %RoutingDecision{}

    for _index <- 1..258 do
      assert_receive {[:lasso, :rpc, :request, :terminal], %{count: 1, elapsed_us: _}, _}
    end

    for _index <- 1..2 do
      assert_receive {
        [:lasso, :rpc, :routing_decision, :sampled_out],
        %{count: 1},
        %{profile: "public", chain_id: 1, request_origin: :client}
      }
    end
  end

  test "exact traffic counts are independent of diagnostic sampling" do
    suffix = System.unique_integer([:positive])
    profile = "projection-exact-#{suffix}"
    chain_id = 80_000 + rem(suffix, 9_000)
    fact = terminal(profile, chain_id)
    route = %{provider_id: "provider-a", instance_id: "instance-a", transport: :http}

    for _index <- 1..258 do
      _result =
        RequestProjection.record_and_enqueue(
          fact,
          "eth_blockNumber",
          route,
          0,
          :client
        )
    end

    assert %{count: 258, successes: 258, errors: 0} =
             TrafficCounters.windows(profile, [:profile], 60, System.system_time(:second))[
               :profile
             ]

    _result =
      RequestProjection.record_and_enqueue(
        fact,
        "eth_blockNumber",
        route,
        0,
        :system
      )

    assert TrafficCounters.windows(profile, [:profile], 60, System.system_time(:second))[
             :profile
           ].count == 258
  end

  test "application errors retain their complete native classification" do
    attempt =
      AttemptTerminal.Response.new(identity(), :application_error, 7_000,
        error_code: -32_005,
        error_category: :provider_failure,
        retry_after_ms: 250
      )

    fact =
      RequestTerminal.UpstreamResponse.new(
        [
          request_id: attempt.identity.request_id,
          profile: attempt.identity.profile,
          subject_token: nil,
          chain_id: attempt.identity.chain_id,
          execution_safety: attempt.identity.execution_safety,
          routing_intent: attempt.identity.routing_intent,
          workload_key: attempt.identity.workload_key,
          elapsed_us: 12_345,
          candidate_admission_count: attempt.identity.candidate_admission_count,
          dispatch_count: attempt.identity.dispatch_count,
          observed_at: nil
        ],
        attempt
      )

    event =
      RequestProjection.new(
        fact,
        "eth_blockNumber",
        %{provider_id: "provider-a", instance_id: "instance-a", transport: :http},
        2
      )

    assert {:ok, payload} = RequestProjection.encode(event)

    assert {:lasso_request_projection, 1, %RequestTerminal.UpstreamResponse{}, _, _, _, _, _, _,
            _} =
             :erlang.binary_to_term(payload, [:safe])

    assert {:ok, ^event} = RequestProjection.decode(payload)
  end

  test "malformed compact success facts fail closed" do
    event = request_projection()
    assert {:ok, payload} = RequestProjection.encode(event)

    {:lasso_request_projection, 1, compact_fact, method, provider_id, instance_id, transport,
     origin, failovers, emitted_at_ms} = :erlang.binary_to_term(payload, [:safe])

    payload =
      :erlang.term_to_binary(
        {
          :lasso_request_projection,
          1,
          put_elem(compact_fact, 5, 0),
          method,
          provider_id,
          instance_id,
          transport,
          origin,
          failovers,
          emitted_at_ms
        },
        [:deterministic]
      )

    assert {:error, :invalid_fact} = RequestProjection.decode(payload)
  end

  test "routing decision preserves canonical request and final route identity" do
    event = request_projection()

    assert {:ok,
            %RoutingDecision{
              request_id: "projection-request",
              profile: "public",
              chain_id: 1,
              method: "eth_blockNumber",
              strategy: "fastest",
              provider_id: "provider-a",
              instance_id: "instance-a",
              transport: :http,
              request_origin: :client,
              duration_ms: 12,
              result: :success,
              failover_count: 2
            }} = RequestProjection.routing_decision(event)
  end

  test "system request origin survives the bounded projection" do
    event =
      RequestProjection.new(
        terminal(),
        "eth_blockNumber",
        %{provider_id: "provider-a", instance_id: "instance-a", transport: :http},
        0,
        :system
      )

    assert {:ok, payload} = RequestProjection.encode(event)
    assert {:ok, %{request_origin: :system} = decoded} = RequestProjection.decode(payload)

    assert {:ok, %RoutingDecision{request_origin: :system}} =
             RequestProjection.routing_decision(decoded)
  end

  test "delivery emits canonical and compatibility request telemetry from one envelope" do
    event = request_projection()
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}
    terminal_event = [:lasso, :rpc, :request, :terminal]
    stop_event = [:lasso, :rpc, :request, :stop]

    :ok =
      :telemetry.attach_many(
        handler_id,
        [terminal_event, stop_event],
        fn name, measurements, metadata, _config ->
          send(test_pid, {name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    assert :ok = RequestProjection.deliver(event)

    assert_receive {
      ^terminal_event,
      %{count: 1, elapsed_us: 12_345},
      %{
        request_id: "projection-request",
        method: "eth_blockNumber",
        provider_id: "provider-a",
        transport: :http,
        result: :success,
        failovers: 2,
        diagnostic: :request_returned
      }
    }

    assert_receive {
      ^stop_event,
      %{duration: 12},
      %{
        method: "eth_blockNumber",
        provider_id: "provider-a",
        transport: :http,
        result: :success,
        status: :success,
        failovers: 2
      }
    }
  end

  test "client delivery records provider dashboard metrics without recording system traffic" do
    suffix = System.unique_integer([:positive])
    profile = "projection-metrics-#{suffix}"
    chain_id = 90_000 + rem(suffix, 9_000)
    method = "eth_blockNumber"

    on_exit(fn -> BenchmarkStore.clear_chain_metrics(profile, chain_id) end)

    route = %{provider_id: "client-provider", instance_id: "client-instance", transport: :http}
    client_event = RequestProjection.new(terminal(profile, chain_id), method, route, 0)

    assert :ok = RequestProjection.deliver(client_event)

    assert %{
             total_calls: 1,
             success_calls: 1,
             success_rate: 1.0,
             avg_latency: 12
           } =
             BenchmarkStore.get_rpc_performance(
               profile,
               chain_id,
               "client-provider",
               "#{method}@http"
             )

    system_route = %{
      provider_id: "system-provider",
      instance_id: "system-instance",
      transport: :http
    }

    system_event =
      RequestProjection.new(terminal(profile, chain_id), method, system_route, 0, :system)

    assert :ok = RequestProjection.deliver(system_event)

    assert %{total_calls: 0} =
             BenchmarkStore.get_rpc_performance(
               profile,
               chain_id,
               "system-provider",
               "#{method}@http"
             )
  end

  test "routing publication precedes potentially blocking telemetry consumers" do
    event = request_projection()
    topic = Lasso.Topics.routing_decision("public")
    :ok = Phoenix.PubSub.subscribe(Lasso.PubSub, topic)
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:lasso, :rpc, :request, :terminal],
        fn _event, _measurements, _metadata, _config ->
          send(test_pid, {:terminal_handler_entered, self()})
          receive do: (:release_terminal_handler -> :ok)
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler_id)

      receive do
        {:terminal_handler_entered, delivery_pid} ->
          send(delivery_pid, :release_terminal_handler)
      after
        0 -> :ok
      end
    end)

    delivery = Task.async(fn -> RequestProjection.deliver(event) end)

    assert_receive %RoutingDecision{request_id: "projection-request"}, 1_000
    assert_receive {:terminal_handler_entered, delivery_pid}, 1_000
    refute Task.yield(delivery, 0)
    send(delivery_pid, :release_terminal_handler)
    assert :ok = Task.await(delivery)
  end

  test "a terminal without an upstream route remains telemetry-only" do
    event = RequestProjection.new(local_failure(), "eth_call", nil, 0)
    assert :not_routed = RequestProjection.routing_decision(event)
  end

  test "constructing and enqueueing preserves the bounded event" do
    parent = self()

    start_supervised!({
      ProjectionDispatcher,
      name: @fast_dispatcher,
      lanes: [
        diagnostics: [
          capacity: 8,
          byte_capacity: 32_768,
          scope_capacity: 8,
          scope_byte_capacity: 32_768,
          shards: 1,
          max_age_ms: 1_000,
          audit_interval_ms: 1_000,
          sink: fn _scope, payload -> send(parent, {:diagnostic, payload}) end
        ]
      ]
    })

    assert {:ok, _token} =
             RequestProjection.new_and_enqueue(
               terminal(),
               "eth_blockNumber",
               %{provider_id: "provider-a", instance_id: "instance-a", transport: :http},
               2,
               :client,
               @fast_dispatcher
             )

    assert_receive {:diagnostic, payload}

    assert {:ok, %{method: "eth_blockNumber", provider_id: "provider-a"}} =
             RequestProjection.decode(payload)
  end

  defp request_projection do
    RequestProjection.new(
      terminal(),
      "eth_blockNumber",
      %{provider_id: "provider-a", instance_id: "instance-a", transport: :http},
      2
    )
  end

  defp terminal(profile \\ "public", chain_id \\ 1) do
    attempt = AttemptTerminal.Response.new(identity(profile, chain_id), :success, 7_000)

    RequestTerminal.UpstreamResponse.new(
      [
        request_id: attempt.identity.request_id,
        profile: attempt.identity.profile,
        subject_token: nil,
        chain_id: attempt.identity.chain_id,
        execution_safety: attempt.identity.execution_safety,
        routing_intent: attempt.identity.routing_intent,
        workload_key: attempt.identity.workload_key,
        elapsed_us: 12_345,
        candidate_admission_count: attempt.identity.candidate_admission_count,
        dispatch_count: attempt.identity.dispatch_count,
        observed_at: nil
      ],
      attempt
    )
  end

  defp local_failure do
    RequestTerminal.LocalFailure.new(
      [
        request_id: "local-request",
        profile: "public",
        subject_token: nil,
        chain_id: 1,
        execution_safety: :replay_safe,
        routing_intent: "fastest",
        workload_key: "default",
        elapsed_us: 10,
        candidate_admission_count: 0,
        dispatch_count: 0,
        observed_at: nil
      ],
      :invalid_request
    )
  end

  defp identity(profile \\ "public", chain_id \\ 1) do
    AttemptIdentity.new(
      request_id: "projection-request",
      attempt_id: "projection-attempt",
      profile: profile,
      chain_id: chain_id,
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
  end
end

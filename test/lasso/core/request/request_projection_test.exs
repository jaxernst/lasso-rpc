defmodule Lasso.RPC.RequestProjectionTest do
  use ExUnit.Case, async: false

  alias Lasso.Events.RoutingDecision

  alias Lasso.RPC.{
    AttemptIdentity,
    AttemptTerminal,
    BoundedIdentifier,
    RequestProjection,
    RequestTerminal
  }

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

  defp request_projection do
    RequestProjection.new(
      terminal(),
      "eth_blockNumber",
      %{provider_id: "provider-a", instance_id: "instance-a", transport: :http},
      2
    )
  end

  defp terminal do
    attempt = AttemptTerminal.Response.new(identity(), :success, 7_000)

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

  defp identity do
    AttemptIdentity.new(
      request_id: "projection-request",
      attempt_id: "projection-attempt",
      profile: "public",
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
  end
end

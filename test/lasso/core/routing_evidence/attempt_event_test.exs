defmodule Lasso.RPC.RoutingEvidence.AttemptEventTest do
  use ExUnit.Case, async: false

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{Channel, RequestContext, RequestOptions}
  alias Lasso.RPC.RequestPipeline.Observability
  alias Lasso.RPC.RoutingEvidence.AttemptEvent

  setup do
    ctx = RequestContext.new(1, "eth_getBalance", [])

    channel = %Channel{
      profile: "public",
      chain_id: 1,
      provider_id: "provider",
      instance_id: "instance",
      transport: :http
    }

    {:ok, ctx: ctx, channel: channel}
  end

  test "uses exact attempt I/O for usable success", %{ctx: ctx, channel: channel} do
    assert {:ok, event} = AttemptEvent.from_result(ctx, channel, "instance", {:ok, :result, 17})
    assert event.outcome == :usable_success
    assert event.elapsed_io_ms == 17
    assert event.censoring_boundary_ms == nil
    assert event.workload_key == :default
  end

  test "separates service failures, timeouts, capacity, neutral errors, and cancellation", %{
    ctx: ctx,
    channel: channel
  } do
    cases = [
      {JError.new(-32_002, "service", category: :server_error), 9, :service_failure, 9, nil},
      {JError.new(-32_000, "timeout", category: :timeout), 50, :timeout, nil, 50},
      {JError.new(429, "limited", category: :rate_limit), 3, :capacity_rejection, 3, nil},
      {JError.new(-32_602, "invalid", category: :invalid_params), 2, :neutral_error, 2, nil},
      {JError.new(-32_000, "cancelled", category: :cancelled), 7, :cancelled, nil, 7}
    ]

    Enum.each(cases, fn {reason, io_ms, outcome, elapsed, censoring} ->
      assert {:ok, event} =
               AttemptEvent.from_result(ctx, channel, "instance", {:error, reason, io_ms})

      assert event.outcome == outcome
      assert event.elapsed_io_ms == elapsed
      assert event.censoring_boundary_ms == censoring
    end)
  end

  test "preflight rejection is not an upstream attempt", %{ctx: ctx, channel: channel} do
    assert :not_dispatched =
             AttemptEvent.from_result(ctx, channel, "instance", {
               :error,
               :unsupported_method,
               0
             })
  end

  test "recorder emits exactly one terminal event for every outcome class", %{
    ctx: ctx,
    channel: channel
  } do
    ref = :telemetry_test.attach_event_handlers(self(), [[:lasso, :rpc, :attempt, :stop]])
    on_exit(fn -> :telemetry.detach(ref) end)

    ctx =
      Map.put(ctx, :opts, %RequestOptions{
        profile: "public",
        strategy: :priority,
        timeout_ms: 100
      })

    results = [
      {:ok, :result, 1},
      {:error, JError.new(-32_002, "service", category: :server_error), 2},
      {:error, JError.new(-32_000, "timeout", category: :timeout), 3},
      {:error, JError.new(429, "limited", category: :rate_limit), 4},
      {:error, JError.new(-32_602, "invalid", category: :invalid_params), 5},
      {:error, JError.new(-32_000, "cancelled", category: :cancelled), 6}
    ]

    Enum.each(results, fn result ->
      assert :ok = Observability.record_attempt(ctx, channel, "instance", result)
    end)

    outcomes =
      Enum.map(1..length(results), fn _ ->
        assert_receive {[:lasso, :rpc, :attempt, :stop], ^ref, %{count: 1}, metadata}
        metadata.outcome
      end)

    assert outcomes == [
             :usable_success,
             :service_failure,
             :timeout,
             :capacity_rejection,
             :neutral_error,
             :cancelled
           ]

    refute_receive {[:lasso, :rpc, :attempt, :stop], ^ref, _, _}, 50
  end
end

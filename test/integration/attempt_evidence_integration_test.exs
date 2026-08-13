defmodule Lasso.RPC.AttemptEvidenceIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration
  @moduletag timeout: 10_000

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{RequestOptions, RequestPipeline}
  alias Lasso.Test.CircuitBreakerHelper
  alias Lasso.Testing.MockProviderBehavior

  setup do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:lasso, :rpc, :attempt, :stop], [:lasso, :rpc, :admission, :rejected]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "successful request emits one attempt with its upstream I/O latency", %{chain: chain} do
    setup_providers([%{id: "success", priority: 10, behavior: :healthy, profile: "public"}])

    {:ok, _result, ctx} = execute(chain, "success", false, "success-request", 1_000)
    [event] = attempt_events("success-request", 1)

    assert event.metadata.outcome == :usable_success
    assert event.metadata.provider_id == "success"
    assert event.measurements.duration_ms == ctx.upstream_latency_ms
  end

  test "recovered failover attributes failure and success to their own upstreams", %{chain: chain} do
    delayed_failure =
      MockProviderBehavior.parameter_sensitive(fn _method, _params, _state ->
        Process.sleep(40)

        {:error,
         JError.new(-32_002, "service unavailable",
           category: :server_error,
           retriable?: true,
           breaker_penalty?: true
         )}
      end)

    setup_providers([
      %{id: "primary", priority: 10, behavior: delayed_failure, profile: "public"},
      %{id: "backup", priority: 20, behavior: :healthy, profile: "public"}
    ])

    {:ok, _result, ctx} =
      RequestPipeline.execute_via_channels(
        chain,
        "eth_blockNumber",
        [],
        %RequestOptions{
          profile: "public",
          strategy: :priority,
          timeout_ms: 1_000,
          request_id: "failover-request"
        }
      )

    events = attempt_events("failover-request", 2)
    :sys.get_state(Lasso.Benchmarking.BenchmarkStore)

    assert Enum.map(events, &{&1.metadata.provider_id, &1.metadata.outcome}) == [
             {"primary", :service_failure},
             {"backup", :usable_success}
           ]

    successful = Enum.find(events, &(&1.metadata.outcome == :usable_success))
    failed = Enum.find(events, &(&1.metadata.outcome == :service_failure))

    assert failed.measurements.duration_ms >= 35
    assert successful.measurements.duration_ms < ctx.upstream_latency_ms

    assert %{total_calls: 1, success_calls: 0, error_calls: 1} =
             Lasso.Benchmarking.BenchmarkStore.get_rpc_performance(
               "public",
               chain,
               "primary",
               "eth_blockNumber@http"
             )

    assert %{total_calls: 1, success_calls: 1, avg_latency: successful_latency} =
             Lasso.Benchmarking.BenchmarkStore.get_rpc_performance(
               "public",
               chain,
               "backup",
               "eth_blockNumber@http"
             )

    assert successful_latency == successful.measurements.duration_ms
  end

  test "terminal provider failure emits exactly one failed attempt", %{chain: chain} do
    setup_providers([%{id: "failure", priority: 10, behavior: :always_fail, profile: "public"}])

    {:error, _error, _ctx} = execute(chain, "failure", false, "failure-request", 1_000)
    [event] = attempt_events("failure-request", 1)

    assert event.metadata.outcome == :service_failure
    refute_receive {[:lasso, :rpc, :attempt, :stop], _, %{request_id: "failure-request"}}, 50
  end

  test "attempt timeout is right-censored once", %{chain: chain} do
    setup_providers([
      %{id: "timeout", priority: 10, behavior: :always_timeout, profile: "public"}
    ])

    {:error, _error, _ctx} = execute(chain, "timeout", false, "timeout-request", 50)
    [event] = attempt_events("timeout-request", 1)

    assert event.metadata.outcome == :timeout
    assert event.metadata.censored
    assert event.measurements.duration_ms == 50
  end

  test "circuit rejection emits admission evidence and no attempt", %{chain: chain} do
    setup_providers([%{id: "open", priority: 10, behavior: :healthy, profile: "public"}])
    instance_id = Lasso.Providers.Catalog.lookup_instance_id("public", chain, "open")
    CircuitBreakerHelper.force_open({instance_id, :http})
    Process.sleep(50)

    {:error, _error, _ctx} = execute(chain, "open", false, "rejected-request", 1_000)

    assert_receive {[:lasso, :rpc, :admission, :rejected], %{count: 1},
                    %{request_id: "rejected-request", reason: :circuit_open}}

    refute_receive {[:lasso, :rpc, :attempt, :stop], _, %{request_id: "rejected-request"}}, 100
  end

  defp execute(chain, provider_id, failover?, request_id, timeout_ms) do
    RequestPipeline.execute_via_channels(
      chain,
      "eth_blockNumber",
      [],
      %RequestOptions{
        profile: "public",
        provider_override: provider_id,
        failover_on_override: failover?,
        strategy: :priority,
        timeout_ms: timeout_ms,
        request_id: request_id
      }
    )
  end

  defp attempt_events(request_id, count) do
    Enum.map(1..count, fn _ ->
      assert_receive {[:lasso, :rpc, :attempt, :stop], measurements,
                      %{request_id: ^request_id} = metadata},
                     2_000

      %{measurements: measurements, metadata: metadata}
    end)
  end
end

defmodule Lasso.RPC.AttemptEvidenceIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration
  @moduletag timeout: 10_000

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{RequestOptions, RequestPipeline}
  alias Lasso.Test.CircuitBreakerHelper
  alias Lasso.Testing.MockProviderBehavior

  defmodule RaisingRecorder do
    def record(_event), do: raise("recorder unavailable")
  end

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

    {:ok, _result, _ctx} = execute(chain, "success", false, "success-request", 1_000)
    [event] = attempt_events("success-request", 1)

    assert event.metadata.outcome == :usable_success
    assert event.metadata.provider_id == "success"
    assert is_number(event.measurements.duration_ms)
    assert event.measurements.duration_ms >= 0
    assert event.measurements.duration_ms < 1_000
  end

  test "recorder failure does not suppress analytics or live health", %{chain: chain} do
    previous = Application.get_env(:lasso, :attempt_evidence_recorder)
    Application.put_env(:lasso, :attempt_evidence_recorder, RaisingRecorder)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lasso, :attempt_evidence_recorder, previous),
        else: Application.delete_env(:lasso, :attempt_evidence_recorder)
    end)

    setup_providers([%{id: "sink-isolation", priority: 10, behavior: :healthy}])
    instance_id = Lasso.Providers.Catalog.lookup_instance_id("public", chain, "sink-isolation")
    :ets.delete(:lasso_instance_state, {:health_routing, instance_id})

    assert {:ok, _result, _ctx} =
             execute(chain, "sink-isolation", false, "sink-isolation-request", 1_000)

    eventually(fn ->
      match?(
        [{_, %{status: :healthy}}],
        :ets.lookup(:lasso_instance_state, {:health_routing, instance_id})
      )
    end)

    eventually(fn ->
      match?(
        %{total_calls: 1, success_calls: 1},
        Lasso.Benchmarking.BenchmarkStore.get_rpc_performance(
          "public",
          chain,
          "sink-isolation",
          "eth_blockNumber@http"
        )
      )
    end)
  end

  test "dynamic channels retain the endpoint-derived instance identity", %{chain: chain} do
    setup_providers([%{id: "dynamic", priority: 10, behavior: :healthy, profile: "public"}])

    expected = Lasso.Providers.Catalog.lookup_instance_id("public", chain, "dynamic")

    assert {:ok, channel} =
             Lasso.RPC.TransportRegistry.get_channel("public", chain, "dynamic", :http)

    assert is_binary(expected)
    assert channel.instance_id == expected
  end

  test "recreated channels derive identity from full configured authentication scope", %{
    chain: chain
  } do
    setup_providers([%{id: "identity-seed", priority: 100, behavior: :healthy}])
    provider_id = "authenticated-dynamic"

    provider_config = %{
      id: provider_id,
      name: "Authenticated Dynamic",
      url: "http://authenticated-dynamic.test",
      priority: 10,
      archival: true,
      api_key: "secret-scope",
      sharing_mode: :isolated,
      __mock__: true
    }

    :ok =
      Lasso.Config.ConfigStore.register_provider_runtime("public", chain, provider_config)

    :ok = Lasso.RPC.ChainSupervisor.ensure_provider("public", chain, provider_config)

    on_exit(fn ->
      Lasso.RPC.TransportRegistry.close_channel_sync(
        "public",
        chain,
        provider_id,
        :http
      )

      Lasso.Config.ConfigStore.unregister_provider_runtime("public", chain, provider_id)
      Lasso.Providers.Catalog.build_from_config()
    end)

    expected = Lasso.Providers.Catalog.lookup_instance_id("public", chain, provider_id)

    :ok =
      Lasso.RPC.TransportRegistry.close_channel_sync("public", chain, provider_id, :http)

    reduced_candidate = %{id: provider_id, url: provider_config.url}

    assert {:ok, recreated} =
             Lasso.RPC.TransportRegistry.get_channel(
               "public",
               chain,
               provider_id,
               :http,
               provider_config: reduced_candidate
             )

    assert recreated.instance_id == expected
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

    assert Map.new(events, &{&1.metadata.provider_id, &1.metadata.outcome}) == %{
             "primary" => :service_failure,
             "backup" => :usable_success
           }

    successful = Enum.find(events, &(&1.metadata.outcome == :usable_success))
    failed = Enum.find(events, &(&1.metadata.outcome == :service_failure))

    assert failed.measurements.duration_ms >= 35
    assert successful.measurements.duration_ms < ctx.upstream_latency_ms

    eventually(fn ->
      match?(
        %{total_calls: 1, success_calls: 0, error_calls: 1},
        Lasso.Benchmarking.BenchmarkStore.get_rpc_performance(
          "public",
          chain,
          "primary",
          "eth_blockNumber@http"
        )
      )
    end)

    eventually(fn ->
      match?(
        %{total_calls: 1, success_calls: 1},
        Lasso.Benchmarking.BenchmarkStore.get_rpc_performance(
          "public",
          chain,
          "backup",
          "eth_blockNumber@http"
        )
      )
    end)

    %{avg_latency: successful_latency} =
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

  test "attempt timeout authorizes no late compatibility evidence", %{chain: chain} do
    setup_providers([
      %{id: "timeout", priority: 10, behavior: :always_timeout, profile: "public"}
    ])

    {:error, _error, _ctx} = execute(chain, "timeout", false, "timeout-request", 50)

    refute_receive {[:lasso, :rpc, :attempt, :stop], _, %{request_id: "timeout-request"}},
                   250
  end

  test "killing the request owner may lose its owner-local terminal fact", %{chain: chain} do
    test_pid = self()

    blocking =
      MockProviderBehavior.parameter_sensitive(fn _method, _params, _state ->
        send(test_pid, :upstream_attempt_started)
        Process.sleep(:infinity)
      end)

    setup_providers([
      %{id: "cancelled", priority: 10, behavior: blocking, profile: "public"}
    ])

    request_pid =
      spawn(fn -> execute(chain, "cancelled", false, "cancelled-request", 5_000) end)

    assert_receive :upstream_attempt_started, 2_000
    Process.exit(request_pid, :kill)

    refute_receive {[:lasso, :rpc, :attempt, :stop], _, %{request_id: "cancelled-request"}},
                   250
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

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end

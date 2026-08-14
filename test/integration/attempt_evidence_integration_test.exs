defmodule Lasso.RPC.AttemptEvidenceIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration
  @moduletag timeout: 10_000

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{AttemptProjection, RequestOptions, RequestPipeline}
  alias Lasso.Test.CircuitBreakerHelper
  alias Lasso.Testing.MockProviderBehavior

  defmodule DummyWebSocketConnection do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
    @impl true
    def init(nil), do: {:ok, nil}
  end

  setup do
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:lasso, :rpc, :attempt, :terminal], [:lasso, :rpc, :request, :terminal]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "successful request emits one bounded request terminal", %{chain: chain} do
    setup_providers([%{id: "success", priority: 10, behavior: :healthy, profile: "public"}])

    {:ok, _result, _ctx} = execute(chain, "success", false, "success-request", 1_000)
    event = request_event("success-request")

    assert event.metadata.diagnostic == :request_returned
    assert event.metadata.candidate_admission_count == 1
    assert event.metadata.dispatch_count == 1
    assert event.measurements.elapsed_us >= 0

    refute_receive {[:lasso, :rpc, :attempt, :terminal], _, %{request_id: "success-request"}},
                   50
  end

  test "diagnostic delivery is independent of direct learned control", %{chain: chain} do
    setup_providers([%{id: "sink-isolation", priority: 10, behavior: :healthy}])
    instance_id = Lasso.Providers.Catalog.lookup_instance_id("public", chain, "sink-isolation")

    assert {:ok, _result, _ctx} =
             execute(chain, "sink-isolation", false, "sink-isolation-request", 1_000)

    scope = AttemptProjection.scope_state("public", chain)
    row = AttemptProjection.route_state(scope, instance_id, :http, "default")

    assert row.status == :healthy
    assert row.usable_successes == 1
    assert request_event("sink-isolation-request").metadata.diagnostic == :request_returned
  end

  test "dynamic channels retain the endpoint-derived instance identity", %{chain: chain} do
    setup_providers([%{id: "dynamic", priority: 10, behavior: :healthy, profile: "public"}])

    expected = Lasso.Providers.Catalog.lookup_instance_id("public", chain, "dynamic")

    assert {:ok, channel} =
             Lasso.RPC.TransportRegistry.get_channel("public", chain, "dynamic", :http)

    assert is_binary(expected)
    assert channel.instance_id == expected
  end

  test "snapshot-scoped channel recreation preserves authentication and exact identity", %{
    chain: chain
  } do
    setup_providers([%{id: "identity-seed", priority: 100, behavior: :healthy}])
    provider_id = "authenticated-dynamic"

    provider_config = %{
      id: provider_id,
      name: "Authenticated Dynamic",
      url: "http://authenticated-dynamic.test",
      ws_url: "ws://authenticated-dynamic.test/ws",
      priority: 10,
      archival: true,
      api_key: "secret-scope",
      headers: %{"x-tenant" => "tenant-a"},
      sharing_mode: :isolated,
      __mock__: true
    }

    :ok =
      Lasso.Config.ConfigStore.register_provider_runtime("public", chain, provider_config)

    :ok = Lasso.RPC.ChainSupervisor.ensure_provider("public", chain, provider_config)

    snapshot = Lasso.Providers.Catalog.snapshot()
    expected = Lasso.Providers.Catalog.lookup_instance_id("public", chain, provider_id)
    assert is_binary(expected)
    assert {:ok, snapshot_config} = Lasso.Providers.Catalog.get_instance(snapshot, expected)

    {:ok, ws_pid} =
      DummyWebSocketConnection.start_link(
        Lasso.RPC.Transport.WebSocket.Connection.via_instance_name(expected)
      )

    on_exit(fn ->
      Lasso.RPC.TransportRegistry.close_channel_sync(
        "public",
        chain,
        provider_id,
        :http
      )

      Lasso.RPC.TransportRegistry.close_channel_sync(
        "public",
        chain,
        provider_id,
        :ws
      )

      if Process.alive?(ws_pid), do: GenServer.stop(ws_pid)

      Lasso.Config.ConfigStore.unregister_provider_runtime("public", chain, provider_id)
      Lasso.Providers.Catalog.build_from_config()
    end)

    :ok =
      Lasso.RPC.TransportRegistry.close_channel_sync("public", chain, provider_id, :http)

    assert {:ok, recreated} =
             Lasso.RPC.TransportRegistry.get_channel(
               "public",
               chain,
               provider_id,
               :http,
               provider_config: snapshot_config,
               instance_id: expected,
               route_generation: snapshot.generation
             )

    assert recreated.instance_id == expected
    assert recreated.route_generation == snapshot.generation

    headers = Map.new(recreated.raw_channel.config.headers)

    assert Map.take(headers, ["authorization", "x-tenant"]) == %{
             "authorization" => "Bearer secret-scope",
             "x-tenant" => "tenant-a"
           }

    assert {:ok, rebound} =
             Lasso.RPC.TransportRegistry.get_channel(
               "public",
               chain,
               provider_id,
               :http,
               provider_config: snapshot_config,
               instance_id: expected,
               route_generation: snapshot.generation
             )

    assert rebound.instance_id == expected
    assert Map.new(rebound.raw_channel.config.headers) == headers

    assert {:ok, websocket} =
             Lasso.RPC.TransportRegistry.get_channel(
               "public",
               chain,
               provider_id,
               :ws,
               provider_config: snapshot_config,
               instance_id: expected,
               route_generation: snapshot.generation
             )

    assert websocket.instance_id == expected
    assert websocket.raw_channel.instance_id == expected
    assert websocket.raw_channel.connection_pid == ws_pid
    assert Map.new(websocket.raw_channel.config.headers) == headers
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

    [failed] = attempt_events("failover-request", 1)
    request = request_event("failover-request")

    assert failed.metadata.provider_id == "primary"
    assert failed.metadata.outcome == :neutral_error
    assert failed.metadata.error_category == :provider_failure
    assert failed.measurements.duration_ms >= 35
    assert failed.measurements.duration_ms < ctx.upstream_latency_ms
    assert request.metadata.diagnostic == :request_returned
    assert request.metadata.candidate_admission_count == 2
    assert request.metadata.dispatch_count == 2
  end

  test "terminal provider failure emits exactly one failed attempt", %{chain: chain} do
    setup_providers([%{id: "failure", priority: 10, behavior: :always_fail, profile: "public"}])

    {:error, _error, _ctx} = execute(chain, "failure", false, "failure-request", 1_000)
    [event] = attempt_events("failure-request", 1)
    request = request_event("failure-request")

    assert event.metadata.outcome == :neutral_error
    assert event.metadata.error_category == :provider_failure
    assert request.metadata.diagnostic == :request_returned

    refute_receive {[:lasso, :rpc, :attempt, :terminal], _, %{request_id: "failure-request"}},
                   50
  end

  test "attempt timeout emits bounded deadline diagnostics", %{chain: chain} do
    setup_providers([
      %{id: "timeout", priority: 10, behavior: :always_timeout, profile: "public"}
    ])

    {:error, _error, _ctx} = execute(chain, "timeout", false, "timeout-request", 50)

    [attempt] = attempt_events("timeout-request", 1)
    request = request_event("timeout-request")

    assert attempt.metadata.outcome == :timeout
    assert request.metadata.diagnostic == :request_deadline
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

    refute_receive {[:lasso, :rpc, :attempt, :terminal], _, %{request_id: "cancelled-request"}},
                   250

    refute_receive {[:lasso, :rpc, :request, :terminal], _, %{request_id: "cancelled-request"}},
                   50
  end

  test "circuit rejection emits one request terminal and no attempt", %{chain: chain} do
    setup_providers([%{id: "open", priority: 10, behavior: :healthy, profile: "public"}])
    instance_id = Lasso.Providers.Catalog.lookup_instance_id("public", chain, "open")
    CircuitBreakerHelper.force_open({instance_id, :http})
    Process.sleep(50)

    {:error, _error, _ctx} = execute(chain, "open", false, "rejected-request", 1_000)

    request = request_event("rejected-request")

    assert request.metadata.diagnostic == :ordinary_exhaustion
    assert request.metadata.dispatch_count == 0

    refute_receive {[:lasso, :rpc, :attempt, :terminal], _, %{request_id: "rejected-request"}},
                   100
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
      assert_receive {[:lasso, :rpc, :attempt, :terminal], measurements,
                      %{request_id: ^request_id} = metadata},
                     2_000

      %{measurements: measurements, metadata: metadata}
    end)
  end

  defp request_event(request_id) do
    assert_receive {[:lasso, :rpc, :request, :terminal], measurements,
                    %{request_id: ^request_id} = metadata},
                   2_000

    %{measurements: measurements, metadata: metadata}
  end
end

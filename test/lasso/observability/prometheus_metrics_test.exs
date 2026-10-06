defmodule Lasso.Observability.PrometheusMetricsTest do
  use ExUnit.Case, async: false

  alias Lasso.Observability.{Prometheus, PrometheusMetrics, PrometheusRuntime}

  setup do
    tables = [:lasso_prometheus_observations, :lasso_prometheus_observation_stats]
    saved = Enum.map(tables, &{&1, :ets.tab2list(&1)})
    Enum.each(tables, &:ets.delete_all_objects/1)
    :ets.insert(:lasso_prometheus_observation_stats, [{:dropped, 0}, {:invalid, 0}])

    on_exit(fn ->
      Enum.each(saved, fn {table, rows} ->
        :ets.delete_all_objects(table)
        :ets.insert(table, rows)
      end)
    end)

    :ok
  end

  defp request(ms, overrides \\ %{}) do
    meta =
      Map.merge(
        %{
          profile: "public",
          chain_id: 1,
          provider_id: "alchemy",
          method: "eth_getLogs",
          transport: :http,
          request_origin: :client,
          result: :success,
          failovers: 0
        },
        overrides
      )

    :telemetry.execute([:lasso, :rpc, :request, :stop], %{duration: ms}, meta)
  end

  defp output, do: PrometheusMetrics.scrape() |> Enum.join("\n")

  defp value(body, name, match \\ "") do
    line =
      body
      |> String.split("\n")
      |> Enum.find(&(String.starts_with?(&1, name <> "{") and String.contains?(&1, match)))

    line |> String.split(" ") |> List.last() |> String.to_float()
  end

  defmodule TenantScope do
    @behaviour Lasso.Observability.MetricsScope

    @impl true
    def bound(%{profile: "tenant-" <> _} = meta),
      do: %{meta | profile: "custom", provider_id: "custom"}

    def bound(meta), do: meta

    @impl true
    def export_route?(profile), do: not String.starts_with?(profile, "tenant-")
  end

  test "a host metrics scope bounds labels before series are created" do
    :persistent_term.put(Lasso.Observability.MetricsScope, TenantScope)
    on_exit(fn -> :persistent_term.erase(Lasso.Observability.MetricsScope) end)

    for tenant <- ["tenant-a", "tenant-b"] do
      request(10, %{profile: tenant, provider_id: "#{tenant}-node"})

      :telemetry.execute([:lasso, :rpc, :attempt, :terminal], %{}, %{
        profile: tenant,
        chain_id: 1,
        provider_id: "#{tenant}-node",
        transport: :http,
        request_origin: :client,
        outcome: :service_failure,
        error_category: :rate_limit
      })
    end

    body = output()
    refute body =~ "tenant-"

    assert body =~
             ~s(lasso_rpc_request_duration_seconds_count{profile="custom",chain="1",provider="custom",method="eth_getLogs",transport="http",origin="client",outcome="success"} 2)

    assert body =~
             ~s(lasso_upstream_attempts_total{profile="custom",chain="1",provider="custom",transport="http",origin="client",outcome="service_failure",category="rate_limit"} 2)
  end

  test "millisecond observations produce cumulative second buckets and an exact sum" do
    request(5)
    request(100)
    request(31_000)
    body = output()
    assert body =~ ~s(origin="client",outcome="success")
    assert body =~ ~s(le="0.005"} 1)
    assert body =~ ~s(le="0.1"} 2)
    assert body =~ ~s(le="30"} 2)
    assert body =~ ~s(le="+Inf"} 3)
    assert value(body, "lasso_rpc_request_duration_seconds_sum") == 31.105
    assert body =~ "lasso_rpc_request_duration_seconds_count{"
    refute body =~ "lasso_rpc_requests_total"
  end

  test "failed requests and health probes have separate latency series" do
    request(12, %{result: :error})
    request(25, %{request_origin: :system})
    body = output()
    assert body =~ ~s(origin="client",outcome="error",le="+Inf"} 1)
    assert body =~ ~s(origin="system",outcome="success",le="+Inf"} 1)
  end

  test "invalid durations do not invent a zero latency observation" do
    for duration <- [nil, -1, "slow"], do: request(duration)
    body = output()
    refute body =~ "lasso_rpc_request_duration_seconds_count{"
    assert PrometheusMetrics.stats().invalid == 3
  end

  test "concurrent updates retain every observation in one consistent histogram row" do
    1..1000 |> Task.async_stream(fn _ -> request(10) end, max_concurrency: 32) |> Stream.run()
    body = output()
    assert body =~ ~s(le="+Inf"} 1000)
    assert body =~ ~s(le="0.01"} 1000)
    assert value(body, "lasso_rpc_request_duration_seconds_sum") == 10.0
    assert PrometheusMetrics.stats().series == 1
  end

  test "unknown methods and reason strings fold into bounded labels without raw identifiers" do
    request(10, %{
      method: "private_wallet_0xdead",
      request_id: "secret-request",
      url: "https://secret/key"
    })

    :telemetry.execute([:lasso, :circuit_breaker, :failure], %{count: 1}, %{
      chain_id: 1,
      error_category: "private-secret-error"
    })

    body = output()
    assert body =~ ~s(method="other")
    assert body =~ ~s(category="other")

    for secret <- [
          "private_wallet",
          "secret-request",
          "https://secret/key",
          "private-secret-error"
        ],
        do: refute(body =~ secret)
  end

  test "series admission is bounded and overflow remains visible" do
    for id <- 1..8000 do
      PrometheusMetrics.handle_event(
        [:lasso, :rpc, :attempt, :terminal],
        %{},
        %{chain_id: id},
        nil
      )
    end

    stats = PrometheusMetrics.stats()
    assert stats.series <= stats.capacity
    assert stats.dropped > 0
    body = output()
    assert body =~ "lasso_observer_dropped_total #{stats.dropped}"
    assert byte_size(body) < 2_000_000
  end

  test "removed event sources do not create misleading series" do
    refute [:lasso, :rpc, :attempt, :stop] in PrometheusMetrics.events()
    refute [:lasso, :rpc, :admission, :rejected] in PrometheusMetrics.events()
    refute [:lasso, :failover, :exhaustion] in PrometheusMetrics.events()
    refute [:phoenix, :endpoint, :stop] in PrometheusMetrics.events()
    refute [:lasso, :circuit_breaker, :timeout] in PrometheusMetrics.events()
    body = output()
    refute body =~ "lasso_upstream_attempt_duration_seconds"
    refute body =~ "lasso_http_"
    refute body =~ "lasso_admission_rejections_total"
    refute body =~ "lasso_failover_events_total"
    refute body =~ "lasso_circuit_timeouts_total"
  end

  test "stream reservations expose latest gauges and cumulative admission losses" do
    :telemetry.execute(
      [:lasso, :stream, :memory, :snapshot],
      %{used_bytes: 100, limit_bytes: 1000},
      %{}
    )

    :telemetry.execute(
      [:lasso, :stream, :memory, :snapshot],
      %{used_bytes: 200, limit_bytes: 1000},
      %{}
    )

    body = output()
    assert body =~ ~s(lasso_stream_memory_bytes{kind="used"} 200)
    assert body =~ ~s(lasso_stream_memory_bytes{kind="limit"} 1000)
  end

  test "shared WebSocket events expose physical instance identity" do
    :telemetry.execute([:lasso, :websocket, :connected], %{count: 1}, %{
      chain_id: 1,
      provider_id: "1:drpc:7ce04b4c2a3f"
    })

    assert output() =~
             ~s(lasso_websocket_connections_total{chain="1",instance_id="1:drpc:7ce04b4c2a3f",event="connected"} 1)

    refute output() =~ ~s(provider="1:drpc:7ce04b4c2a3f")
  end

  test "long credential-distinct instances retain full identity in counters and mappings" do
    alias Lasso.Config.ChainConfig.Provider
    alias Lasso.Providers.InstanceId

    provider = %Provider{id: "drpc", url: "https://#{String.duplicate("a", 63)}.com"}

    ids =
      for credential <- ["first", "second"] do
        InstanceId.derive(1, %{provider | api_key: credential})
      end

    assert Enum.all?(ids, &(String.length(&1) == 78))
    assert Enum.uniq(Enum.map(ids, &String.slice(&1, 0, 64))) |> length() == 1

    for id <- ids do
      :telemetry.execute([:lasso, :websocket, :connected], %{count: 1}, %{
        chain_id: 1,
        provider_id: id
      })

      for event <- [:open, :failure, :proactive_recovery] do
        :telemetry.execute([:lasso, :circuit_breaker, event], %{count: 1}, %{
          instance_id: id,
          transport: :ws,
          reason: :failure_threshold,
          error_category: :network_error,
          circuit_state: :open
        })
      end

      mapping =
        PrometheusRuntime.route_samples("public", 1, "drpc", id, false)
        |> Enum.join("\n")

      assert mapping =~ ~s(instance_id="#{id}")

      for family <- [
            "lasso_websocket_connections_total",
            "lasso_circuit_transitions_total",
            "lasso_circuit_failures_total",
            "lasso_circuit_recovery_attempts_total"
          ] do
        samples =
          output()
          |> String.split("\n")
          |> Enum.filter(&String.starts_with?(&1, family <> "{"))

        assert Enum.any?(
                 samples,
                 &(String.contains?(&1, ~s(instance_id="#{id}")) and
                     String.ends_with?(&1, " 1"))
               )
      end
    end

    assert PrometheusMetrics.stats().series == 8
  end

  test "long configured route labels match gauges and stay separate in both exporters" do
    profile = String.duplicate("p", 64) <> "public"
    providers = for suffix <- ["first", "second"], do: String.duplicate("a", 64) <> suffix

    for provider <- providers do
      request(10, %{profile: profile, provider_id: provider})

      :telemetry.execute([:lasso, :rpc, :attempt, :terminal], %{}, %{
        chain_id: 1,
        provider_id: provider,
        transport: :http,
        outcome: :service_failure,
        error_category: :network_error
      })

      body = output()
      assert body =~ ~s(profile="#{profile}",chain="1",provider="#{provider}")

      assert body =~
               ~s(lasso_upstream_attempts_total{profile="unknown",chain="1",provider="#{provider}")

      legacy =
        Prometheus.scrape()
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "lasso_rpc_requests_total{"))

      assert Enum.any?(
               legacy,
               &(String.contains?(&1, ~s(provider="#{provider}")) and
                   String.ends_with?(&1, " 1"))
             )

      mapping =
        PrometheusRuntime.route_samples(profile, 1, provider, nil, false)
        |> Enum.join("\n")

      assert mapping =~ ~s(profile="#{profile}",chain="1",provider="#{provider}")
    end

    assert PrometheusMetrics.stats().series == 4
  end

  test "over-128-byte route IDs match canonical hashed telemetry and all route gauges" do
    alias Lasso.RPC.BoundedIdentifier
    profile = String.duplicate("p", 129)
    providers = for suffix <- ["first", "second"], do: String.duplicate("a", 129) <> suffix
    encoded_profile = BoundedIdentifier.encode(profile)

    for provider <- providers do
      encoded_provider = BoundedIdentifier.encode(provider)
      request(10, %{profile: encoded_profile, provider_id: encoded_provider})
      request(10, %{profile: profile, provider_id: provider})

      :telemetry.execute([:lasso, :rpc, :attempt, :terminal], %{}, %{
        chain_id: 1,
        provider_id: encoded_provider,
        transport: :http,
        outcome: :service_failure,
        error_category: :network_error
      })

      body = output()
      assert body =~ ~s(profile="#{encoded_profile}",chain="1",provider="#{encoded_provider}")

      assert body =~
               ~s(lasso_upstream_attempts_total{profile="unknown",chain="1",provider="#{encoded_provider}")

      legacy =
        Prometheus.scrape()
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "lasso_rpc_requests_total{"))

      assert Enum.any?(
               legacy,
               &(String.contains?(&1, ~s(provider="#{encoded_provider}")) and
                   String.ends_with?(&1, " 2"))
             )

      mapping =
        PrometheusRuntime.route_samples(profile, 1, provider, nil, false)
        |> Enum.join("\n")

      assert mapping =~ ~s(profile="#{encoded_profile}",chain="1",provider="#{encoded_provider}")
      readiness = PrometheusRuntime.readiness_samples([{profile, 1}]) |> Enum.join("\n")
      assert readiness =~ ~s(profile="#{encoded_profile}")

      state =
        PrometheusMetrics.sample("lasso_circuit_state", 1,
          profile: profile,
          chain: 1,
          provider: provider,
          state: "closed"
        )

      assert state =~ ~s(profile="#{encoded_profile}",chain="1",provider="#{encoded_provider}")
      refute body =~ ~s(provider="#{provider}")
      refute mapping =~ ~s(profile="#{profile}")
    end

    assert PrometheusMetrics.stats().series == 4
  end

  test "real continuity admissions retain rejection kinds and reasons" do
    alias Lasso.Core.Streaming.ContinuityBudget

    budget =
      start_supervised!(
        {ContinuityBudget,
         name: nil, node_limit: 100, stream_limit: 50, client_limit: 50, delivery_message_limit: 1}
      )

    assert {:error, :stream_limit} = ContinuityBudget.set_stream_bytes(budget, self(), 51)
    assert {:error, :client_limit} = ContinuityBudget.reserve_delivery(budget, self(), 51)
    assert :ok = ContinuityBudget.reserve_delivery(budget, self(), 1)
    assert {:error, :client_message_limit} = ContinuityBudget.reserve_delivery(budget, self(), 1)
    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, _}
    assert {:error, :budget_unavailable} = ContinuityBudget.reserve_delivery(budget, dead, 1)

    body = output()

    for {kind, reason} <- [
          {"stream_bytes", "stream_limit"},
          {"delivery_bytes", "client_limit"},
          {"delivery_messages", "client_message_limit"},
          {"delivery_bytes", "budget_unavailable"}
        ] do
      assert body =~ ~s(lasso_stream_budget_rejections_total{kind="#{kind}",reason="#{reason}"} 1)
    end
  end

  test "real coordinator drops and exhaustion keep actionable reasons" do
    alias Lasso.Core.Streaming.StreamCoordinator

    pid =
      start_supervised!(
        {StreamCoordinator,
         {"public", 1, {:newHeads}, [primary_provider_id: "drpc", max_event_bytes: 1]}}
      )

    GenServer.cast(pid, {:upstream_event, "old", "sub", %{}, 0})
    :sys.get_state(pid)
    assert output() =~ ~s(reason="stale_provider")

    GenServer.cast(
      pid,
      {:upstream_event, "drpc", "sub",
       %{"number" => "0x1", "hash" => "0x1", "parentHash" => "0x0"}, 0}
    )

    :sys.get_state(pid)
    assert output() =~ ~s(reason="event_too_large")

    logs =
      start_supervised!(
        Supervisor.child_spec(
          {StreamCoordinator, {"public", 1, {:logs, %{}}, [primary_provider_id: "drpc"]}},
          id: :metrics_invalid_log
        )
      )

    GenServer.cast(logs, {:upstream_event, "drpc", "sub", %{}, 0})
    :sys.get_state(logs)
    assert output() =~ ~s(reason="invalid_log")

    heads =
      start_supervised!(
        Supervisor.child_spec(
          {StreamCoordinator, {"public", 2, {:newHeads}, [primary_provider_id: "drpc"]}},
          id: :metrics_invalid_header
        )
      )

    GenServer.cast(heads, {:upstream_event, "drpc", "sub", %{}, 0})
    :sys.get_state(heads)
    assert output() =~ ~s(reason="invalid_header")

    for reason <- [:event_buffer_overflow, :client_message_limit] do
      :telemetry.execute([:lasso, :stream, :continuity_resource_exhausted], %{count: 1}, %{
        profile: "public",
        chain_id: 1,
        reason: reason
      })

      assert output() =~ ~s(reason="#{reason}")
    end
  end

  test "coordinator dispatch reports real ingress rejection reasons" do
    alias Lasso.Core.Streaming.{ClientSubscriptionRegistry, Ingress, StreamCoordinator}

    registry = start_supervised!({ClientSubscriptionRegistry, {"public", 42_424}})

    pid =
      start_supervised!(
        {StreamCoordinator, {"public", 42_424, {:newHeads}, [primary_provider_id: "drpc"]}}
      )

    tokens =
      for _ <- 1..Ingress.stats().owner_messages do
        {:ok, token} = Ingress.reserve(:lasso_stream_ingress, registry, 256)
        token
      end

    try do
      GenServer.cast(
        pid,
        {:upstream_event, "drpc", "sub",
         %{"number" => "0x1", "hash" => "0x1", "parentHash" => "0x0"}, 0}
      )

      :sys.get_state(pid)
      assert output() =~ ~s(reason="owner_messages")
    after
      Enum.each(tokens, &Ingress.release/1)
    end

    missing =
      start_supervised!(
        Supervisor.child_spec(
          {StreamCoordinator, {"public", 42_425, {:newHeads}, [primary_provider_id: "drpc"]}},
          id: :metrics_missing_registry
        )
      )

    GenServer.cast(
      missing,
      {:upstream_event, "drpc", "sub",
       %{"number" => "0x1", "hash" => "0x1", "parentHash" => "0x0"}, 0}
    )

    :sys.get_state(missing)
    assert output() =~ ~s(reason="recipient_down")

    for reason <- [:owner_bytes, :node_capacity, :contention, :mailbox_limit] do
      :telemetry.execute([:lasso, :stream, :continuity_resource_exhausted], %{count: 1}, %{
        profile: "public",
        chain_id: 1,
        reason: reason
      })

      assert output() =~ ~s(reason="#{reason}")
    end
  end

  test "zero failovers retain completed request evidence without inventing a counter" do
    request(10)
    body = output()
    assert body =~ "lasso_rpc_request_duration_seconds_count{"
    refute body =~ "lasso_rpc_failovers_total{"
  end

  test "canonical projection emits failure diagnostics but not successful attempts" do
    alias Lasso.Config.ConfigStore
    alias Lasso.RPC.{AttemptIdentity, AttemptProjection, AttemptTerminal}

    parent = self()
    handler = "prometheus-canonical-attempt-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:lasso, :rpc, :attempt, :terminal],
      fn _, _, meta, _ ->
        send(parent, {:terminal, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    identity =
      AttemptIdentity.new(
        request_id: "metrics-canonical-request",
        attempt_id: "metrics-canonical-attempt",
        profile: "public",
        chain_id: 1,
        upstream_instance_id: "physical",
        transport: :http,
        route_generation: ConfigStore.route_generation(),
        circuit_scope: :broad,
        circuit_epoch: 1,
        execution_safety: :replay_safe,
        routing_intent: "default",
        workload_key: "client",
        request_budget_ms: 100,
        candidate_admission_count: 1,
        dispatch_count: 1
      )

    success = AttemptTerminal.Response.new(identity, :success, 17_000)

    assert {_, :not_required} =
             AttemptProjection.process(AttemptProjection.new(success, "recorder", "eth_call"))

    refute_receive {:terminal, _}, 20

    failure = AttemptTerminal.InvalidResponse.new(identity, :invalid_json, 17_000)
    AttemptProjection.process(AttemptProjection.new(failure, "recorder", "eth_call"))
    assert_receive {:terminal, %{provider_id: "recorder"}}, 1000
    body = output()

    assert body =~
             ~s(lasso_upstream_attempts_total{profile="public",chain="1",provider="recorder",transport="http",origin="client")

    assert body =~ ~s(outcome="service_failure",category="protocol_error")
    refute body =~ "lasso_upstream_attempt_duration_seconds"
    refute body =~ "outcome=\"usable_success\""

    for category <- [
          :deterministic,
          :ambiguous,
          :quota,
          :capability,
          :provider_failure,
          :local_safety
        ] do
      response =
        AttemptTerminal.Response.new(identity, :application_error, 17_000,
          error_code: -32_000,
          error_category: category
        )

      AttemptProjection.process(AttemptProjection.new(response, "recorder", "eth_call"))
      expected = if category == :quota, do: :rate_limit, else: category
      assert_receive {:terminal, %{error_category: ^expected}}, 1000
      assert output() =~ ~s(category="#{expected}")
    end
  end

  test "scrape contains one TYPE per family and VM metrics do not require a dashboard" do
    assert PrometheusRuntime.scrape() |> Enum.join("\n") =~ "lasso_vm_processes "
    body = Prometheus.scrape()
    types = body |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "# TYPE"))
    assert Enum.uniq(types) == types
    assert body =~ "lasso_vm_memory_bytes{kind=\"total\"}"
    assert body =~ "lasso_vm_run_queue "
  end
end

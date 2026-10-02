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

    :telemetry.execute([:lasso, :rpc, :admission, :rejected], %{count: 1}, %{
      chain_id: 1,
      reason: "private-secret-error"
    })

    body = output()
    assert body =~ ~s(method="other")
    assert body =~ ~s(reason="other")

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
      PrometheusMetrics.handle_event([:lasso, :failover, :exhaustion], %{}, %{chain_id: id}, nil)
    end

    stats = PrometheusMetrics.stats()
    assert stats.series <= stats.capacity
    assert stats.dropped > 0
    body = output()
    assert body =~ "lasso_observer_dropped_total #{stats.dropped}"
    assert byte_size(body) < 2_000_000
  end

  test "canonical attempt outcomes include neutral and censored observations" do
    for outcome <- [:usable_success, :service_failure, :timeout, :capacity_rejection, :cancelled] do
      :telemetry.execute([:lasso, :rpc, :attempt, :stop], %{duration_ms: 250}, %{
        chain_id: 1,
        provider_id: "alchemy",
        outcome: outcome,
        transport: :http,
        request_origin: :client
      })
    end

    body = output()
    assert body =~ "lasso_upstream_attempts_total{"
    assert body =~ ~s(outcome="timeout",category="unknown",le="0.25"} 1)
    assert body =~ ~s(outcome="cancelled")
  end

  test "Phoenix native time is converted and dynamic HTTP paths are never labels" do
    conn = Plug.Test.conn(:get, "/rpc/fastest/private-wallet") |> Plug.Conn.put_status(503)

    :telemetry.execute(
      [:phoenix, :endpoint, :stop],
      %{duration: System.convert_time_unit(100_000, :microsecond, :native)},
      %{conn: conn}
    )

    body = output()
    assert body =~ ~s(route="/rpc/*",status="5xx")
    assert value(body, "lasso_http_request_duration_seconds_sum") == 0.1
    refute body =~ "private-wallet"
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

  test "canonical dispatched recorder produces one observation with route context" do
    alias Lasso.RPC.{Channel, RequestContext, RequestOptions}

    ctx = %{
      RequestContext.new(1, "eth_getBalance", [])
      | opts: %RequestOptions{profile: "public", request_origin: :system, timeout_ms: 1000}
    }

    channel = %Channel{
      profile: "public",
      chain_id: 1,
      provider_id: "recorder",
      instance_id: "physical",
      transport: :http
    }

    assert :ok =
             Lasso.RPC.RequestPipeline.Observability.record_attempt(
               ctx,
               channel,
               "physical",
               {:ok, :value, 17}
             )

    body = output()

    assert body =~
             ~s(lasso_upstream_attempts_total{profile="public",chain="1",provider="recorder",method="eth_getBalance",transport="http",origin="system",outcome="usable_success",category="unknown"} 1)

    assert value(body, "lasso_upstream_attempt_duration_seconds_sum") == 0.017
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

defmodule Lasso.TracingIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration
  require Record
  alias Lasso.RPC.{RequestOptions, RequestPipeline}

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  setup do
    previous = Application.get_env(:lasso, :otel_enabled, false)
    Application.put_env(:lasso, :otel_enabled, true)
    :ok = :otel_batch_processor.set_exporter(:otel_exporter_pid, self())

    on_exit(fn ->
      Application.put_env(:lasso, :otel_enabled, previous)
      :otel_batch_processor.set_exporter(:none)
    end)

    :ok
  end

  defp completed(count), do: collect(count, [], System.monotonic_time(:millisecond) + 2_000)

  defp collect(0, records, _deadline), do: Enum.reverse(records)

  defp collect(count, records, deadline) do
    :otel_tracer_provider.force_flush()

    receive do
      {:span, record} -> collect(count - 1, [record | records], deadline)
    after
      25 ->
        # HTTP response receipt precedes the router span's finalizer. Re-flush
        # until that span arrives instead of depending on the SDK's 5s timer.
        assert System.monotonic_time(:millisecond) < deadline, "missing completed tracing spans"
        collect(count, records, deadline)
    end
  end

  test "real routing retains a successful parent and both failed and fallback attempts", %{
    chain: chain
  } do
    setup_providers([
      %{
        id: "failed",
        priority: 10,
        profile: "public",
        behavior: {:error, Lasso.JSONRPC.Error.new(-32_000, "archive node required")}
      },
      %{id: "fallback", priority: 20, profile: "public", behavior: :healthy}
    ])

    assert {:ok, _value, ctx} =
             RequestPipeline.execute_via_channels(chain, "eth_getLogs", [], %RequestOptions{
               profile: "public",
               strategy: :priority,
               timeout_ms: 1_000
             })

    assert ctx.retries == 1
    :otel_tracer_provider.force_flush()

    records = completed(3)

    request = Enum.find(records, &(span(&1, :name) == "lasso.rpc"))
    attempts = Enum.filter(records, &(span(&1, :name) == "lasso.upstream"))
    assert length(attempts) == 2
    assert Enum.all?(attempts, &(span(&1, :parent_span_id) == span(request, :span_id)))
    assert Enum.all?(records, &(span(&1, :trace_id) == span(request, :trace_id)))
    assert :otel_attributes.map(span(request, :attributes))["lasso.outcome"] == "success"
    assert :otel_attributes.map(span(request, :attributes))["lasso.attempts"] == 2
    providers = Enum.map(attempts, &:otel_attributes.map(span(&1, :attributes))["lasso.provider"])
    assert Enum.sort(providers) == ["failed", "fallback"]
  end

  test "HTTP ingress keeps incoming trace context through actual routing", %{chain: chain} do
    setup_providers([%{id: "healthy", profile: "public", behavior: :healthy}])
    {:ok, _} = Application.ensure_all_started(:inets)
    port = LassoWeb.Endpoint.config(:http)[:port]
    url = String.to_charlist("http://127.0.0.1:#{port}/rpc/#{chain}")
    trace_id = String.duplicate("a", 32)
    headers = [{~c"traceparent", String.to_charlist("00-#{trace_id}-bbbbbbbbbbbbbbbb-01")}]
    body = Jason.encode!(%{jsonrpc: "2.0", method: "eth_getLogs", params: [], id: 1})

    assert {:ok, {{_, 200, _}, _, response}} =
             :httpc.request(:post, {url, headers, ~c"application/json", body}, [], [])

    assert Jason.decode!(to_string(response))["result"]
    :otel_tracer_provider.force_flush()

    records = completed(3)

    assert Enum.sort(Enum.map(records, &span(&1, :name))) == [
             "lasso.http",
             "lasso.rpc",
             "lasso.upstream"
           ]

    assert Enum.all?(records, &(span(&1, :trace_id) == String.to_integer(trace_id, 16)))

    Application.put_env(:lasso, :otel_enabled, false)

    assert {:ok, {{_, 200, _}, _, untraced_response}} =
             :httpc.request(:post, {url, headers, ~c"application/json", body}, [], [])

    assert untraced_response == response
    :otel_tracer_provider.force_flush()
    refute_receive {:span, _}, 100
  end

  test "metrics, readiness, health and dashboard ingress do not trace their own monitoring" do
    {:ok, _} = Application.ensure_all_started(:inets)
    port = LassoWeb.Endpoint.config(:http)[:port]

    for path <- ["/metrics", "/api/ready", "/api/health", "/", "/dashboard", "/dashboard/public"] do
      url = String.to_charlist("http://127.0.0.1:#{port}#{path}")

      assert {:ok, {{_, status, _}, _, _}} =
               :httpc.request(:get, {url, []}, [autoredirect: false], [])

      assert status in [200, 302, 503]
    end

    :otel_tracer_provider.force_flush()
    refute_receive {:span, _}, 100
  end

  test "ordinary WebSocket item ownership creates an independent RPC root", %{chain: chain} do
    alias LassoWeb.RPCSocket.ItemOwner
    setup_providers([%{id: "socket_upstream", profile: "public", behavior: :healthy}])
    now = System.monotonic_time(:microsecond)
    ref = make_ref()

    work = %ItemOwner.Work{
      chain_id: chain,
      method: "eth_getLogs",
      params: [],
      profile: "public",
      strategy: :priority,
      jsonrpc_id_present?: true,
      jsonrpc_id: 1,
      started_at_us: now,
      deadline_us: now + 1_000_000,
      timeout_ms: 1_000
    }

    assert {:ok, pid} = ItemOwner.start(self(), ref, work)
    assert_receive {:rpc_item_result, ^ref, ^pid, {:ok, _, _}}, 2_000
    :otel_tracer_provider.force_flush()
    records = completed(2)

    request = Enum.find(records, &(span(&1, :name) == "lasso.rpc"))
    attempt = Enum.find(records, &(span(&1, :name) == "lasso.upstream"))
    assert span(request, :parent_span_id) in [0, :undefined]
    assert span(attempt, :parent_span_id) == span(request, :span_id)
    assert span(attempt, :trace_id) == span(request, :trace_id)
    refute Enum.any?(records, &(span(&1, :name) == "lasso.http"))
  end
end

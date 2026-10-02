defmodule Lasso.Observability.TracingTest do
  use ExUnit.Case, async: false

  require Record
  require OpenTelemetry.Tracer, as: Tracer

  alias Lasso.Observability.Tracing
  alias Lasso.RPC.RequestOptions
  alias LassoWeb.RPCController.BatchExecutor
  alias OpenTelemetry.Ctx

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  defmodule Collector do
    @behaviour Plug
    def init(pid), do: pid

    def call(conn, pid) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(pid, {:otlp, conn.request_path, Plug.Conn.get_req_header(conn, "content-type"), body})
      Plug.Conn.send_resp(conn, 200, "")
    end
  end

  setup do
    previous = Application.get_env(:lasso, :otel_enabled, false)
    Application.put_env(:lasso, :otel_enabled, true)
    :ok = :otel_batch_processor.set_exporter(:otel_exporter_pid, self())
    metadata = Logger.metadata()
    context = Ctx.get_current()

    on_exit(fn ->
      Application.put_env(:lasso, :otel_enabled, previous)
      :otel_batch_processor.set_exporter(:none)
    end)

    %{metadata: metadata, context: context}
  end

  defp completed(n) do
    :otel_tracer_provider.force_flush()

    for _ <- 1..n do
      assert_receive {:span, record}, 2_000
      record
    end
  end

  defp attributes(record), do: :otel_attributes.map(span(record, :attributes))
  defp opts, do: %RequestOptions{profile: "public", timeout_ms: 1_000}
  defp result, do: {:ok, :value, %{execution_envelope: %{dispatch_count: 2}}}

  test "disabled tracing preserves results, headers, context and logger metadata", state do
    Application.put_env(:lasso, :otel_enabled, false)
    conn = Plug.Test.conn(:post, "/rpc/1")
    headers = [{"authorization", "secret"}]
    fun = fn -> result() end

    assert Tracing.request(1, "eth_call", opts(), fun) == result()
    assert Tracing.wrap(fun) == fun
    assert Tracing.inject(headers) == headers
    assert Tracing.http(conn, & &1) == conn
    assert Ctx.get_current() == state.context
    assert Logger.metadata() == state.metadata
    :otel_tracer_provider.force_flush()
    refute_receive {:span, _}, 50
  end

  test "runtime tracing opt-in reads the existing dotenv bootstrap" do
    path = Path.join(System.tmp_dir!(), "lasso-tracing-env-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    File.write!(Path.join(path, ".env"), "LASSO_OTEL_ENABLED=true\n")
    config_path = Path.expand("config/runtime.exs")
    previous = System.get_env("LASSO_OTEL_ENABLED")
    System.delete_env("LASSO_OTEL_ENABLED")

    try do
      config = File.cd!(path, fn -> Config.Reader.read!(config_path, env: :test) end)
      assert config[:lasso][:otel_enabled]
      refute config[:opentelemetry][:sdk_disabled]
    after
      if previous,
        do: System.put_env("LASSO_OTEL_ENABLED", previous),
        else: System.delete_env("LASSO_OTEL_ENABLED")

      File.rm_rf!(path)
    end
  end

  test "production config stays disabled without opt-in and accepts the existing numeric flag convention" do
    path =
      Path.join(System.tmp_dir!(), "lasso-tracing-default-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    config_path = Path.expand("config/runtime.exs")

    keys =
      ~w(LASSO_OTEL_ENABLED LASSO_NODE_ID SECRET_KEY_BASE LASSO_BLOCK_PUBLICATION_MEMBERS LASSO_BLOCK_PUBLICATION_DATABASE_URL)

    previous = Map.new(keys, &{&1, System.get_env(&1)})
    System.delete_env("LASSO_OTEL_ENABLED")
    System.put_env("LASSO_NODE_ID", "tracing-config-test")
    System.put_env("SECRET_KEY_BASE", String.duplicate("0", 64))
    System.delete_env("LASSO_BLOCK_PUBLICATION_MEMBERS")
    System.delete_env("LASSO_BLOCK_PUBLICATION_DATABASE_URL")

    try do
      File.cd!(path, fn ->
        config = Config.Reader.read!(config_path, env: :prod)
        refute config[:lasso][:otel_enabled]
        assert config[:opentelemetry][:sdk_disabled]
        assert config[:opentelemetry][:traces_exporter] == :none

        for {value, enabled} <- [{"1", true}, {"0", false}] do
          System.put_env("LASSO_OTEL_ENABLED", value)
          config = Config.Reader.read!(config_path, env: :prod)
          assert config[:lasso][:otel_enabled] == enabled
          assert config[:opentelemetry][:sdk_disabled] == not enabled
          assert config[:opentelemetry][:traces_exporter] == if(enabled, do: :otlp, else: :none)
        end
      end)
    after
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      File.rm_rf!(path)
    end
  end

  test "remote parent, batch items and retry attempts form one tree", state do
    remote_trace = String.duplicate("a", 32)
    remote_parent = String.duplicate("b", 16)

    conn =
      Plug.Test.conn(:post, "/rpc/1?secret=caller")
      |> Plug.Conn.put_req_header("traceparent", "00-#{remote_trace}-#{remote_parent}-01")
      |> Plug.Conn.put_req_header("baggage", "wallet=secret-wallet")
      |> Plug.Conn.put_req_header("tracestate", "vendor=secret-state")

    Tracing.http(conn, fn conn ->
      deadline = System.monotonic_time(:microsecond) + 1_000_000

      BatchExecutor.run([%{index: 0, deadline_us: deadline}], fn _item, _scope ->
        Tracing.request(1, "eth_getLogs", opts(), fn ->
          ctx = %{chain_id: 1, method: "eth_getLogs", opts: opts()}

          for diagnostic <- [:transport_failure, :upstream_success] do
            Tracing.attempt(%{provider_id: "provider", transport: :http}, ctx, fn ->
              Task.async(
                Tracing.wrap(fn ->
                  injected = Tracing.inject([{"authorization", "secret-auth"}])
                  assert {"authorization", "secret-auth"} in injected

                  assert [{"traceparent", parent}] =
                           Enum.filter(injected, &(elem(&1, 0) == "traceparent"))

                  assert String.contains?(parent, remote_trace)
                  refute List.keymember?(injected, "baggage", 0)
                  refute List.keymember?(injected, "tracestate", 0)
                  assert Logger.metadata()[:trace_id] == remote_trace
                  %{projection: %{diagnostic: diagnostic}}
                end)
              )
              |> Task.await()
            end)
          end

          result()
        end)
      end)

      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    records = completed(4)
    server = Enum.find(records, &(span(&1, :name) == "lasso.http"))
    request = Enum.find(records, &(span(&1, :name) == "lasso.rpc"))
    attempts = Enum.filter(records, &(span(&1, :name) == "lasso.upstream"))
    assert span(server, :parent_span_id) == String.to_integer(remote_parent, 16)
    assert span(server, :parent_span_is_remote)
    assert span(request, :parent_span_id) == span(server, :span_id)
    assert Enum.all?(attempts, &(span(&1, :parent_span_id) == span(request, :span_id)))
    assert Enum.all?(records, &(span(&1, :trace_id) == String.to_integer(remote_trace, 16)))
    assert attributes(request)["lasso.attempts"] == 2
    assert Ctx.get_current() == state.context
    assert Logger.metadata() == state.metadata

    for secret <- ["secret-wallet", "secret-state", "secret-auth", "secret=caller"] do
      refute inspect(records) =~ secret
    end
  end

  test "exceptions end spans without exporting exception text or leaking context", state do
    assert_raise RuntimeError, "secret-url-and-payload", fn ->
      Tracing.request(1, "private-wallet-method", opts(), fn ->
        raise "secret-url-and-payload"
      end)
    end

    [record] = completed(1)
    assert attributes(record)["rpc.method"] == "other"
    assert span(record, :end_time) >= span(record, :start_time)
    refute inspect(record) =~ "secret-url-and-payload"
    refute inspect(record) =~ "private-wallet-method"
    assert Ctx.get_current() == state.context
    assert Logger.metadata() == state.metadata
  end

  test "invalid and duplicate incoming traceparents safely start new roots" do
    for values <- [["invalid"], [String.duplicate("a", 129)], ["invalid", "another"]] do
      conn = %{
        Plug.Test.conn(:post, "/rpc/1")
        | req_headers: Enum.map(values, &{"traceparent", &1})
      }

      Tracing.http(conn, &Plug.Conn.send_resp(&1, 200, "ok"))
      [record] = completed(1)
      assert span(record, :parent_span_id) in [0, :undefined]
    end
  end

  test "outgoing propagation preserves an unsampled parent flag" do
    ctx = :otel_tracer.from_remote_span(1, 2, 0)
    token = Ctx.attach(Tracer.set_current_span(Ctx.new(), ctx))

    try do
      assert [{"traceparent", value}] = Tracing.inject([])
      assert String.ends_with?(value, "-00")
    after
      Ctx.detach(token)
    end
  end

  test "JSON formatter exposes bounded trace and span correlation fields" do
    Tracing.request(1, "eth_call", opts(), fn ->
      metadata = Logger.metadata()
      assert byte_size(metadata[:trace_id]) == 32
      assert byte_size(metadata[:span_id]) == 16
      line = Lasso.Logger.JSONFormatter.format(:info, "test", nil, metadata)
      assert Jason.decode!(line)["metadata"]["trace_id"] == metadata[:trace_id]
      result()
    end)

    completed(1)
  end

  test "standard exporter sends real protobuf OTLP to a local receiver" do
    ref = make_ref()

    start_supervised!(
      {Plug.Cowboy, scheme: :http, plug: {Collector, self()}, options: [port: 0, ref: ref]}
    )

    port = :ranch.get_port(ref)

    :ok =
      :otel_batch_processor.set_exporter(:opentelemetry_exporter, %{
        protocol: :http_protobuf,
        endpoints: ["http://127.0.0.1:#{port}"]
      })

    assert Tracing.request(1, "eth_getLogs", opts(), fn -> result() end) == result()
    :otel_tracer_provider.force_flush()
    assert_receive {:otlp, "/v1/traces", ["application/x-protobuf"], body}, 2_000

    decoded =
      :opentelemetry_exporter_trace_service_pb.decode_msg(body, :export_trace_service_request)

    spans =
      for resource <- decoded.resource_spans,
          scope <- resource.scope_spans,
          record <- scope.spans,
          do: record

    assert [%{name: "lasso.rpc", trace_id: trace_id}] = spans
    assert byte_size(trace_id) == 16
  end

  test "an unreachable collector never blocks or changes routing results" do
    :ok =
      :otel_batch_processor.set_exporter(:opentelemetry_exporter, %{
        protocol: :http_protobuf,
        endpoints: ["http://127.0.0.1:1"]
      })

    started = System.monotonic_time(:millisecond)

    for _ <- 1..100 do
      assert Tracing.request(1, "eth_getLogs", opts(), fn -> result() end) == result()
    end

    assert System.monotonic_time(:millisecond) - started < 1_000
    :otel_tracer_provider.force_flush()
    assert Tracing.request(1, "eth_getLogs", opts(), fn -> result() end) == result()
  end

  test "Finch encoded and prepared paths propagate context without mutating provider templates" do
    alias Lasso.RPC.Transport.HTTP.Client.Finch, as: FinchClient

    provider =
      FinchClient.prepare_provider(%{url: "http://example.invalid/rpc", api_key: "secret-key"})

    template = provider.lasso_finch_template

    {:ok, prepared} =
      Lasso.RPC.PreparedRequest.new(
        %{"jsonrpc" => "2.0", "method" => "eth_getLogs", "params" => [], "id" => 1},
        "lasso-wire"
      )

    Tracing.request(1, "eth_getLogs", opts(), fn ->
      request_fun = fn request, _name, _opts ->
        assert {"authorization", "Bearer secret-key"} in request.headers

        assert [{"traceparent", parent}] =
                 Enum.filter(request.headers, &(elem(&1, 0) == "traceparent"))

        assert String.contains?(parent, Logger.metadata()[:trace_id])
        {:ok, %Finch.Response{status: 200, body: ~s({"jsonrpc":"2.0","id":1,"result":[]})}}
      end

      assert {:ok, _} = FinchClient.request(provider, "eth_getLogs", [], request_fun: request_fun)
      assert {:ok, _} = FinchClient.request_prepared(provider, prepared, request_fun: request_fun)
      assert provider.lasso_finch_template == template
      refute List.keymember?(template.headers, "traceparent", 0)
      result()
    end)

    [record] = completed(1)
    refute inspect(record) =~ "secret-key"
  end
end

defmodule Lasso.Observability.Tracing do
  @moduledoc """
  Opt-in traces for routed RPC requests and their owned upstream attempts.

  Only routing identity and bounded outcomes are recorded. RPC payloads,
  URLs, caller IDs, error messages, baggage and tracestate are never copied.
  """

  require OpenTelemetry.Tracer, as: Tracer

  alias OpenTelemetry.{Ctx, Span}

  @methods ~w(eth_blockNumber eth_call eth_chainId eth_estimateGas eth_feeHistory
    eth_getBalance eth_getBlockByHash eth_getBlockByNumber eth_getCode eth_getLogs
    eth_getStorageAt eth_getTransactionByHash eth_getTransactionCount
    eth_getTransactionReceipt eth_sendRawTransaction eth_subscribe eth_unsubscribe
    net_version web3_clientVersion)

  def enabled?, do: Application.get_env(:lasso, :otel_enabled, false)

  def request(chain_id, method, opts, fun) do
    if enabled?() do
      attributes = %{
        "rpc.system" => "jsonrpc",
        "rpc.method" => method_name(method),
        "lasso.chain_id" => chain_id,
        "lasso.profile" => identity(opts.profile),
        "lasso.origin" => to_string(opts.request_origin)
      }

      span("lasso.rpc", :internal, attributes, fn ->
        result = fun.()
        request_result(result)
        result
      end)
    else
      fun.()
    end
  end

  def attempt(channel, ctx, fun) do
    if enabled?() do
      attributes = %{
        "rpc.system" => "jsonrpc",
        "rpc.method" => method_name(ctx.method),
        "lasso.chain_id" => ctx.chain_id,
        "lasso.profile" => identity(ctx.opts.profile),
        "lasso.provider" => identity(channel.provider_id),
        "lasso.transport" => to_string(channel.transport),
        "lasso.origin" => to_string(ctx.opts.request_origin)
      }

      span("lasso.upstream", :client, attributes, fn ->
        outcome = fun.()
        diagnostic = Atom.to_string(outcome.projection.diagnostic)
        Tracer.set_attribute("lasso.outcome", diagnostic)
        if diagnostic != "upstream_success", do: Tracer.set_status(:error, diagnostic)
        outcome
      end)
    else
      fun.()
    end
  end

  @doc "Captures context before spawning; restores both context and log metadata afterward."
  def wrap(fun) when is_function(fun, 0) do
    if enabled?() do
      ctx = Ctx.get_current()
      fn -> with_context(ctx, fun) end
    else
      fun
    end
  end

  def http(conn, fun) do
    if enabled?() do
      # Accept only a single bounded W3C traceparent. Never propagate baggage.
      headers =
        case Plug.Conn.get_req_header(conn, "traceparent") do
          [value] when byte_size(value) <= 128 -> [{"traceparent", value}]
          _ -> []
        end

      ctx =
        :otel_propagator_text_map.extract_to(Ctx.new(), :otel_propagator_trace_context, headers)

      with_context(ctx, fn ->
        span("lasso.http", :server, %{"http.request.method" => http_method(conn.method)}, fn ->
          response = fun.(conn)

          if response.status,
            do: Tracer.set_attribute("http.response.status_code", response.status)

          if response.status && response.status >= 500,
            do: Tracer.set_status(:error, "http_error")

          response
        end)
      end)
    else
      fun.(conn)
    end
  end

  @doc "Injects only W3C traceparent; leaves credentials and provider headers intact."
  def inject(headers) do
    if enabled?() do
      injected =
        :otel_propagator_text_map.inject_from(
          Ctx.get_current(),
          :otel_propagator_trace_context,
          []
        )

      case List.keyfind(injected, "traceparent", 0) do
        nil ->
          headers

        parent ->
          [parent | Enum.reject(headers, &(String.downcase(elem(&1, 0)) == "traceparent"))]
      end
    else
      headers
    end
  end

  defp span(name, kind, attributes, fun) do
    metadata = Logger.metadata()

    try do
      Tracer.with_span name, %{kind: kind, attributes: attributes} do
        with_log_context(fun)
      end
    after
      Logger.reset_metadata(metadata)
    end
  end

  defp with_context(ctx, fun) do
    metadata = Logger.metadata()
    token = Ctx.attach(ctx)

    try do
      with_log_context(fun)
    after
      Ctx.detach(token)
      Logger.reset_metadata(metadata)
    end
  end

  defp with_log_context(fun) do
    previous = Logger.metadata()
    context = Span.hex_span_ctx(Tracer.current_span_ctx())
    Logger.metadata(trace_id: context[:otel_trace_id], span_id: context[:otel_span_id])

    try do
      fun.()
    catch
      kind, reason ->
        # Do not record exception messages/stacktraces, which may contain URLs or payloads.
        Tracer.set_status(:error, "internal_error")
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      Logger.reset_metadata(previous)
    end
  end

  defp request_result({:ok, _result, ctx}) do
    Tracer.set_attribute("lasso.outcome", "success")
    Tracer.set_attribute("lasso.attempts", ctx.execution_envelope.dispatch_count)
  end

  defp request_result({:error, _error, ctx}) do
    Tracer.set_attribute("lasso.outcome", "error")
    Tracer.set_attribute("lasso.attempts", ctx.execution_envelope.dispatch_count)
    Tracer.set_status(:error, "rpc_error")
  end

  defp identity(value) when is_binary(value), do: String.slice(value, 0, 64)
  defp identity(_), do: "unknown"
  defp method_name(value) when value in @methods, do: value
  defp method_name(_), do: "other"
  defp http_method(value) when value in ~w(GET POST PUT DELETE HEAD OPTIONS PATCH), do: value
  defp http_method(_), do: "_OTHER"
end

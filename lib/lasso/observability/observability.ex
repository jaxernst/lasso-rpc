defmodule Lasso.RPC.Observability do
  @moduledoc """
  Structured request observability for RPC operations.

  Emits `rpc.request.completed` events with detailed metadata including:
  - Provider selection details and latency breakdown
  - Request/response shapes (redacted)
  - Routing decisions and circuit breaker states

  Configuration:
      config :lasso, :observability,
        log_level: :info,
        max_error_message_chars: 256,
        max_meta_header_bytes: 4096,
        sampling: [rate: 1.0]
  """

  require Logger
  alias Lasso.RPC.RequestContext

  @default_config [
    log_level: :info,
    max_error_message_chars: 256,
    max_meta_header_bytes: 4096,
    sampling: [rate: 1.0]
  ]

  @doc """
  Emits a structured log event for a completed request.

  Options:
    - batch_size: If provided, indicates this is a batch request log entry
  """
  def log_request_completed(%RequestContext{} = ctx, opts \\ []) do
    # Always log errors regardless of sampling rate
    should_log = ctx.status == :error or should_sample?()

    if should_log do
      batch_size = Keyword.get(opts, :batch_size)
      event = build_log_event(ctx, batch_size)

      # Use appropriate log level: warning for errors, info for success
      log_level =
        case ctx.status do
          :error -> :warning
          _ -> get_config(:log_level, :info)
        end

      # Human-readable log line
      Logger.log(log_level, fn ->
        format_readable_log(ctx, event, batch_size)
      end)

      # Also emit telemetry for external consumption
      :telemetry.execute(
        [:lasso, :observability, :request_completed],
        %{count: batch_size || 1},
        event
      )
    end
  end

  @doc """
  Builds client-visible metadata (subset of log event).

  Returns a map suitable for inclusion in HTTP headers or JSON-RPC response body.
  Respects size limits and redaction rules.
  """
  def build_client_metadata(%RequestContext{} = ctx) do
    metadata = %{
      version: "1.0",
      request_id: ctx.request_id,
      strategy: to_string(ctx.strategy),
      chain: ctx.chain,
      transport: to_string(ctx.transport),
      candidate_providers: format_candidate_providers(ctx.candidate_providers),
      selected_provider: ctx.selected_provider,
      selection_latency_ms: ctx.selection_latency_ms,
      upstream_latency_ms: ctx.upstream_latency_ms,
      end_to_end_latency_ms: ctx.end_to_end_latency_ms,
      lasso_overhead_ms: ctx.lasso_overhead_ms,
      retries: ctx.retries,
      circuit_breaker_state: to_string(ctx.circuit_breaker_state || :unknown)
    }

    # Filter out nil values
    metadata
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Encodes client metadata as base64url for header transmission.
  Returns {:ok, encoded_string} or {:error, :too_large}.
  """
  def encode_metadata_for_header(metadata) when is_map(metadata) do
    json = Jason.encode!(metadata)
    encoded = Base.url_encode64(json, padding: false)
    max_bytes = get_config(:max_meta_header_bytes, 4096)

    if byte_size(encoded) > max_bytes do
      {:error, :too_large}
    else
      {:ok, encoded}
    end
  end

  # Private implementation

  defp build_log_event(%RequestContext{} = ctx, batch_size) do
    base_event = %{
      event: "rpc.request.completed",
      request_id: ctx.request_id,
      strategy: to_string(ctx.strategy),
      chain: ctx.chain,
      transport: to_string(ctx.transport),
      jsonrpc_method: ctx.method,
      params_present: ctx.params != [] and not is_nil(ctx.params)
    }

    # Add optional fields
    base_event
    |> maybe_put(:path, ctx.path)
    |> maybe_put(:client_ip, ctx.client_ip)
    |> maybe_put(:user_agent, ctx.user_agent)
    |> maybe_put(:batch_size, batch_size)
    |> Map.put(:routing, build_routing_section(ctx))
    |> Map.put(:timing, build_timing_section(ctx))
    |> Map.put(:response, build_response_section(ctx))
  end

  defp build_routing_section(ctx) do
    %{
      selected_provider: ctx.selected_provider,
      retries: ctx.retries
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_timing_section(ctx) do
    %{
      upstream_latency_ms: ctx.upstream_latency_ms,
      end_to_end_latency_ms: ctx.end_to_end_latency_ms,
      lasso_overhead_ms: ctx.lasso_overhead_ms
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp build_response_section(ctx) do
    base = %{status: to_string(ctx.status || :unknown)}

    case ctx.status do
      :success ->
        base
        |> maybe_put(:result_type, ctx.result_type)
        |> maybe_put(:result_size_bytes, ctx.result_size_bytes)

      :error ->
        base
        |> maybe_put(:error, ctx.error)

      _ ->
        base
    end
  end

  defp format_readable_log(ctx, _event, batch_size) do
    provider =
      case ctx.selected_provider do
        %{id: id, protocol: protocol} -> "#{id}:#{protocol}"
        _ -> "unknown"
      end

    # Compact timing format: (e2e: 45ms, io: 40ms)
    # e2e = end-to-end latency (from plug entry to response)
    # io = upstream provider I/O time
    latency_str = format_compact_timing(ctx)

    retry_str = if ctx.retries > 0, do: " retries=#{ctx.retries}", else: ""
    batch_str = if batch_size, do: " batch=#{batch_size}", else: ""

    case ctx.status do
      :success ->
        result_info =
          if ctx.result_type && ctx.result_size_bytes do
            " #{ctx.result_type} #{ctx.result_size_bytes}b"
          else
            ""
          end

        "RPC [#{ctx.chain}] #{ctx.method} -> #{provider}#{latency_str}#{retry_str}#{batch_str} OK#{result_info}"

      :error ->
        error_msg =
          case ctx.error do
            %{code: code, message: msg} -> " #{code}: #{msg}"
            _ -> ""
          end

        "RPC [#{ctx.chain}] #{ctx.method} -> #{provider}#{latency_str}#{retry_str}#{batch_str} ERR#{error_msg}"

      _ ->
        "RPC [#{ctx.chain}] #{ctx.method} -> #{provider}#{retry_str}#{batch_str}"
    end
  end

  # Format timing in compact notation: (e2e: 45ms, io: 40ms)
  defp format_compact_timing(ctx) do
    cond do
      # Full timing available: show both e2e and io
      ctx.end_to_end_latency_ms && ctx.upstream_latency_ms ->
        " (e2e: #{round_num(ctx.end_to_end_latency_ms, 0)}ms, io: #{round_num(ctx.upstream_latency_ms, 0)}ms)"

      # Only e2e timing available
      ctx.end_to_end_latency_ms ->
        " (e2e: #{round_num(ctx.end_to_end_latency_ms, 0)}ms)"

      # Only io timing available
      ctx.upstream_latency_ms ->
        " (io: #{round_num(ctx.upstream_latency_ms, 0)}ms)"

      true ->
        ""
    end
  end

  defp format_candidate_providers(providers) when is_list(providers) do
    providers
  end

  defp format_candidate_providers(_), do: []

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp should_sample? do
    sampling_config = get_config(:sampling, rate: 1.0)
    rate = Keyword.get(sampling_config, :rate, 1.0)
    :rand.uniform() <= rate
  end

  defp get_config(key, default) do
    config = Application.get_env(:lasso, :observability, @default_config)
    Keyword.get(config, key, default)
  end

  defp round_num(val, _precision) when is_integer(val), do: val
  defp round_num(val, precision) when is_float(val), do: Float.round(val, precision)
  defp round_num(_, _), do: 0
end

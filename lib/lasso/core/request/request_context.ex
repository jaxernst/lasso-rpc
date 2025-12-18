defmodule Lasso.RPC.RequestContext do
  @moduledoc """
  Tracks request lifecycle data for rpc request pipeline observability and client-visible metadata.

  This struct threads through the request pipeline to collect:
  - Request identification and timing
  - Provider selection details
  - Routing decisions and circuit breaker states
  - Channel execution history
  - Result or error shapes
  """

  alias Lasso.RPC.{Channel, RequestOptions, Response}

  @type channel_attempt :: {Channel.t(), :success | {:error, term()}}

  @type t :: %__MODULE__{
          # Request identification
          request_id: String.t(),
          chain: String.t(),
          method: String.t(),
          params_present: boolean(),
          transport: :http | :ws,
          strategy: atom(),
          path: String.t() | nil,
          client_ip: String.t() | nil,
          user_agent: String.t() | nil,

          # Routing
          candidate_providers: [String.t()],
          selected_provider: %{id: String.t(), protocol: :http | :ws} | nil,
          selection_reason: String.t() | nil,
          selection_latency_ms: float() | nil,
          retries: non_neg_integer(),
          circuit_breaker_state: :open | :half_open | :closed | nil,
          # Track repeated error categories to detect universal failures
          repeated_error_categories: %{atom() => non_neg_integer()},

          # Channel execution tracking (for observability without polluting return types)
          executed_channel: Channel.t() | nil,
          attempted_channels: [channel_attempt()],

          # Timing
          # Plug-level start time for true E2E measurement (from RequestTimingPlug)
          plug_start_time: integer() | nil,

          # Pipeline-level start time (fallback if plug timing not available)
          start_time: integer(),
          request_start_ms: integer() | nil,
          selection_start: integer() | nil,
          selection_end: integer() | nil,
          upstream_start: integer() | nil,
          upstream_end: integer() | nil,

          # TRUE upstream provider I/O time (HTTP/WS send→receive at transport boundary)
          upstream_latency_ms: float() | nil,
          end_to_end_latency_ms: float() | nil,

          # Computed: end_to_end - upstream = Lasso internal overhead
          lasso_overhead_ms: float() | nil,

          # Response
          status: :success | :error | nil,
          result_type: String.t() | nil,
          result_size_bytes: non_neg_integer() | nil,
          error: map() | nil,

          # Execution parameters (immutable throughout pipeline)
          rpc_request: map() | nil,
          timeout_ms: timeout() | nil,
          opts: RequestOptions.t() | nil
        }

  defstruct request_id: nil,
            chain: nil,
            method: nil,
            params_present: false,
            transport: :http,
            strategy: nil,
            path: nil,
            client_ip: nil,
            user_agent: nil,
            candidate_providers: [],
            selected_provider: nil,
            selection_reason: nil,
            selection_latency_ms: nil,
            retries: 0,
            circuit_breaker_state: nil,
            repeated_error_categories: %{},
            executed_channel: nil,
            attempted_channels: [],
            plug_start_time: nil,
            start_time: nil,
            request_start_ms: nil,
            selection_start: nil,
            selection_end: nil,
            upstream_start: nil,
            upstream_end: nil,
            upstream_latency_ms: nil,
            end_to_end_latency_ms: nil,
            lasso_overhead_ms: nil,
            status: nil,
            result_type: nil,
            result_size_bytes: nil,
            error: nil,
            rpc_request: nil,
            timeout_ms: nil,
            opts: nil

  @doc """
  Creates a new request context with request_id and start_time.

  If :request_id is provided in opts, it will be used (typically from Phoenix's Plug.RequestId).
  Otherwise, a new request_id will be generated.
  """
  def new(chain, method, opts \\ []) do
    request_id = Keyword.get(opts, :request_id) || generate_request_id()

    # Use plug_start_time if available for accurate E2E, otherwise use current time
    plug_start = Keyword.get(opts, :plug_start_time)
    start_time = plug_start || System.monotonic_time(:microsecond)

    %__MODULE__{
      request_id: request_id,
      chain: chain,
      method: method,
      params_present: Keyword.get(opts, :params_present, false),
      transport: Keyword.get(opts, :transport, :http),
      strategy: Keyword.get(opts, :strategy),
      path: Keyword.get(opts, :path),
      client_ip: Keyword.get(opts, :client_ip),
      user_agent: Keyword.get(opts, :user_agent),
      plug_start_time: plug_start,
      start_time: start_time
    }
  end

  @doc """
  Sets the execution parameters for pipeline processing.

  These are immutable throughout the pipeline execution:
  - rpc_request: The JSON-RPC request map being executed
  - timeout_ms: Per-attempt timeout in milliseconds
  - opts: The RequestOptions struct with routing configuration
  """
  def set_execution_params(%__MODULE__{} = ctx, rpc_request, timeout_ms, %RequestOptions{} = opts)
      when is_map(rpc_request) and is_integer(timeout_ms) do
    %{ctx | rpc_request: rpc_request, timeout_ms: timeout_ms, opts: opts}
  end

  @doc """
  Records the start of provider selection phase.
  """
  def mark_selection_start(%__MODULE__{} = ctx) do
    %{ctx | selection_start: System.monotonic_time(:microsecond)}
  end

  @doc """
  Records provider selection completion with metadata.
  """
  def mark_selection_end(%__MODULE__{} = ctx, opts \\ []) do
    now = System.monotonic_time(:microsecond)

    selection_latency_ms =
      if ctx.selection_start do
        (now - ctx.selection_start) / 1000.0
      else
        nil
      end

    %{
      ctx
      | selection_end: now,
        selection_latency_ms: selection_latency_ms,
        candidate_providers: Keyword.get(opts, :candidates, ctx.candidate_providers),
        selected_provider: Keyword.get(opts, :selected, ctx.selected_provider),
        selection_reason: Keyword.get(opts, :reason, ctx.selection_reason),
        circuit_breaker_state: Keyword.get(opts, :cb_state, ctx.circuit_breaker_state)
    }
  end

  @doc """
  Records the start of upstream request.
  """
  def mark_upstream_start(%__MODULE__{} = ctx) do
    %{ctx | upstream_start: System.monotonic_time(:microsecond)}
  end

  @doc """
  Records upstream request completion.

  Note: This calculates timing from mark_upstream_start to now, but the actual
  upstream_latency_ms should be set via set_upstream_latency/2 with the measured
  I/O time from the transport layer for accuracy.
  """
  def mark_upstream_end(%__MODULE__{} = ctx) do
    now = System.monotonic_time(:microsecond)
    %{ctx | upstream_end: now}
  end

  @doc """
  Adds upstream I/O latency measured at the transport boundary (HTTP/WS send→receive).

  On failover, this sums the I/O time from all attempts so that:
  - `upstream_latency_ms` = total time waiting on providers
  - `lasso_overhead_ms` = e2e - upstream = actual Lasso processing time

  Without accumulation, failover would inflate apparent Lasso overhead since
  failed provider I/O time would be attributed to Lasso instead of upstream.
  """
  def add_upstream_latency(%__MODULE__{} = ctx, io_ms) when is_number(io_ms) do
    current = ctx.upstream_latency_ms || 0
    %{ctx | upstream_latency_ms: current + io_ms}
  end

  @doc """
  Marks the start of request execution for duration tracking.
  Stores current monotonic time in milliseconds for later duration calculation.
  """
  def mark_request_start(%__MODULE__{} = ctx) do
    %{ctx | request_start_ms: System.monotonic_time(:millisecond)}
  end

  @doc """
  Calculates request duration from marked start time.
  Returns duration in milliseconds, or 0 if start was never marked.
  """
  def get_duration(%__MODULE__{request_start_ms: nil}), do: 0

  def get_duration(%__MODULE__{request_start_ms: start_ms}) do
    System.monotonic_time(:millisecond) - start_ms
  end

  @doc """
  Records successful result shape and calculates Lasso overhead.
  """
  def record_success(%__MODULE__{} = ctx, result) do
    now = System.monotonic_time(:microsecond)
    end_to_end_ms = (now - ctx.start_time) / 1000.0

    {result_type, result_size} = analyze_result(result)

    # Calculate Lasso internal overhead (everything except upstream I/O)
    lasso_overhead_ms =
      if ctx.upstream_latency_ms do
        end_to_end_ms - ctx.upstream_latency_ms
      else
        nil
      end

    %{
      ctx
      | status: :success,
        result_type: result_type,
        result_size_bytes: result_size,
        end_to_end_latency_ms: end_to_end_ms,
        lasso_overhead_ms: lasso_overhead_ms
    }
  end

  @doc """
  Records error shape and calculates Lasso overhead.
  """
  def record_error(%__MODULE__{} = ctx, error) do
    now = System.monotonic_time(:microsecond)
    end_to_end_ms = (now - ctx.start_time) / 1000.0

    error_map =
      case error do
        %{code: code, message: message} = e ->
          %{
            code: code,
            message: truncate_string(message, 256),
            data_present: Map.has_key?(e, :data) and not is_nil(Map.get(e, :data))
          }

        _ ->
          %{
            code: -32_000,
            message: truncate_string(inspect(error), 256),
            data_present: false
          }
      end

    # Calculate Lasso internal overhead (everything except upstream I/O)
    lasso_overhead_ms =
      if ctx.upstream_latency_ms do
        end_to_end_ms - ctx.upstream_latency_ms
      else
        nil
      end

    %{
      ctx
      | status: :error,
        error: error_map,
        end_to_end_latency_ms: end_to_end_ms,
        lasso_overhead_ms: lasso_overhead_ms
    }
  end

  @doc """
  Increment retry counter.
  """
  def increment_retries(%__MODULE__{} = ctx) do
    %{ctx | retries: ctx.retries + 1}
  end

  @doc """
  Track an error category to detect repeated failures across providers.

  Used for detecting when the same error (e.g., result size violation) occurs
  across multiple providers, indicating a universal limitation rather than
  provider-specific issue.
  """
  def track_error_category(%__MODULE__{} = ctx, category) when is_atom(category) do
    count = Map.get(ctx.repeated_error_categories, category, 0) + 1
    %{ctx | repeated_error_categories: Map.put(ctx.repeated_error_categories, category, count)}
  end

  @doc """
  Get the count for a specific error category.
  """
  def get_error_category_count(%__MODULE__{} = ctx, category) when is_atom(category) do
    Map.get(ctx.repeated_error_categories, category, 0)
  end

  @doc """
  Records the channel that successfully executed the request.
  Also updates selected_provider for backwards compatibility.
  """
  def set_executed_channel(%__MODULE__{} = ctx, %Channel{} = channel) do
    %{
      ctx
      | executed_channel: channel,
        selected_provider: %{id: channel.provider_id, protocol: channel.transport}
    }
  end

  @doc """
  Records a failed channel attempt for observability/debugging.
  Appends to the attempted_channels list to maintain audit trail.
  """
  def record_channel_attempt(%__MODULE__{} = ctx, %Channel{} = channel, error) do
    attempt = {channel, {:error, error}}
    %{ctx | attempted_channels: ctx.attempted_channels ++ [attempt]}
  end

  @doc """
  Records a successful channel attempt. Called before set_executed_channel
  to capture the full attempt history.
  """
  def record_channel_success(%__MODULE__{} = ctx, %Channel{} = channel) do
    attempt = {channel, :success}
    %{ctx | attempted_channels: ctx.attempted_channels ++ [attempt]}
  end

  # Private helpers

  defp generate_request_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end

  defp analyze_result(%Response.Success{raw_bytes: raw_bytes}) do
    # For passthrough responses, use raw bytes size directly (no re-encoding)
    {"passthrough", byte_size(raw_bytes)}
  end

  defp analyze_result(result) do
    result_type =
      cond do
        is_nil(result) -> "null"
        is_boolean(result) -> "boolean"
        is_number(result) -> "number"
        is_binary(result) -> "string"
        is_list(result) -> "array"
        is_map(result) -> "object"
        true -> "unknown"
      end

    # Estimate serialized size
    result_size =
      try do
        result |> Jason.encode!() |> byte_size()
      rescue
        _ -> 0
      end

    {result_type, result_size}
  end

  defp truncate_string(str, max_length) when is_binary(str) do
    if String.length(str) > max_length do
      String.slice(str, 0, max_length) <> "..."
    else
      str
    end
  end

  defp truncate_string(other, _max_length), do: inspect(other)
end

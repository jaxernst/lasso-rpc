defmodule Livechain.RPC.RequestContext do
  @moduledoc """
  Tracks request lifecycle data for observability and client-visible metadata.

  This struct threads through the entire request pipeline to collect:
  - Request identification and timing
  - Provider selection details
  - Routing decisions and circuit breaker states
  - Result or error shapes

  Used by both server-side logging and optional client-side metadata.
  """

  @type t :: %__MODULE__{
          # Request identification
          request_id: String.t(),
          chain: String.t(),
          method: String.t(),
          params_present: boolean(),
          params_digest: String.t() | nil,
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

          # Timing
          start_time: integer(),
          selection_start: integer() | nil,
          selection_end: integer() | nil,
          upstream_start: integer() | nil,
          upstream_end: integer() | nil,
          upstream_latency_ms: float() | nil,
          end_to_end_latency_ms: float() | nil,

          # Response
          status: :success | :error | nil,
          result_type: String.t() | nil,
          result_size_bytes: non_neg_integer() | nil,
          error: map() | nil
        }

  defstruct request_id: nil,
            chain: nil,
            method: nil,
            params_present: false,
            params_digest: nil,
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
            start_time: nil,
            selection_start: nil,
            selection_end: nil,
            upstream_start: nil,
            upstream_end: nil,
            upstream_latency_ms: nil,
            end_to_end_latency_ms: nil,
            status: nil,
            result_type: nil,
            result_size_bytes: nil,
            error: nil

  @doc """
  Creates a new request context with generated request_id and start_time.
  """
  def new(chain, method, opts \\ []) do
    request_id = generate_request_id()
    start_time = System.monotonic_time(:millisecond)

    %__MODULE__{
      request_id: request_id,
      chain: chain,
      method: method,
      params_present: Keyword.get(opts, :params_present, false),
      params_digest: Keyword.get(opts, :params_digest),
      transport: Keyword.get(opts, :transport, :http),
      strategy: Keyword.get(opts, :strategy),
      path: Keyword.get(opts, :path),
      client_ip: Keyword.get(opts, :client_ip),
      user_agent: Keyword.get(opts, :user_agent),
      start_time: start_time
    }
  end

  @doc """
  Records the start of provider selection phase.
  """
  def mark_selection_start(%__MODULE__{} = ctx) do
    %{ctx | selection_start: System.monotonic_time(:millisecond)}
  end

  @doc """
  Records provider selection completion with metadata.
  """
  def mark_selection_end(%__MODULE__{} = ctx, opts \\ []) do
    now = System.monotonic_time(:millisecond)

    selection_latency_ms =
      if ctx.selection_start do
        (now - ctx.selection_start) * 1.0
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
    %{ctx | upstream_start: System.monotonic_time(:millisecond)}
  end

  @doc """
  Records upstream request completion.
  """
  def mark_upstream_end(%__MODULE__{} = ctx) do
    now = System.monotonic_time(:millisecond)

    upstream_latency_ms =
      if ctx.upstream_start do
        now - ctx.upstream_start
      else
        nil
      end

    %{ctx | upstream_end: now, upstream_latency_ms: upstream_latency_ms}
  end

  @doc """
  Records successful result shape.
  """
  def record_success(%__MODULE__{} = ctx, result) do
    now = System.monotonic_time(:millisecond)
    end_to_end_ms = now - ctx.start_time

    {result_type, result_size} = analyze_result(result)

    %{
      ctx
      | status: :success,
        result_type: result_type,
        result_size_bytes: result_size,
        end_to_end_latency_ms: end_to_end_ms
    }
  end

  @doc """
  Records error shape.
  """
  def record_error(%__MODULE__{} = ctx, error) do
    now = System.monotonic_time(:millisecond)
    end_to_end_ms = now - ctx.start_time

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
            code: -32000,
            message: truncate_string(inspect(error), 256),
            data_present: false
          }
      end

    %{
      ctx
      | status: :error,
        error: error_map,
        end_to_end_latency_ms: end_to_end_ms
    }
  end

  @doc """
  Increment retry counter.
  """
  def increment_retries(%__MODULE__{} = ctx) do
    %{ctx | retries: ctx.retries + 1}
  end

  @doc """
  Generates a params digest for logging (SHA-256 hex).
  """
  def compute_params_digest(params) when is_list(params) or is_map(params) do
    json = Jason.encode!(params)
    hash = :crypto.hash(:sha256, json)
    "sha256:" <> Base.encode16(hash, case: :lower) |> String.slice(0..15)
  end

  def compute_params_digest(_), do: nil

  # Private helpers

  defp generate_request_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
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

defmodule Lasso.RPC.RequestPipeline do
  @moduledoc """
  Orchestrates RPC request execution with provider selection, retries, and failover.

  This module provides a unified pipeline for executing JSON-RPC requests across
  multiple providers and transports (HTTP/WebSocket). Key features:

  - Single execution path for both normal routing and provider overrides
  - Automatic failover on retriable errors
  - Circuit breaker integration per provider/transport
  - Full observability via RequestContext

  ## Return Type Contract

  All functions return 3-tuples:
  - `{:ok, result, ctx}` - Success with result and updated context
  - `{:error, %JError{}, ctx}` - Failure with typed error and updated context

  The executed channel is stored in `ctx.executed_channel` for observability,
  """

  require Logger

  alias Lasso.JSONRPC.Error, as: JError

  alias Lasso.RPC.{
    Channel,
    CircuitBreaker,
    ProviderPool,
    RequestContext,
    Selection,
    TransportRegistry
  }

  alias Lasso.RPC.Providers.AdapterFilter
  alias Lasso.RPC.RequestOptions
  alias Lasso.RPC.RequestPipeline.{FailoverStrategy, Observability}

  # Type definitions
  @type chain :: String.t()
  @type method :: String.t()
  @type params :: list()
  @type result :: {:ok, any(), RequestContext.t()} | {:error, JError.t(), RequestContext.t()}

  # A channel source is a function that returns channels to try
  @type channel_source :: (RequestContext.t() -> [Channel.t()])

  # Configuration
  @max_channel_candidates 10

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Execute an RPC request using transport-agnostic channels.

  This is the main entry point for request execution. It handles:
  - Provider selection (or override)
  - Automatic failover on retriable errors
  - Circuit breaker integration
  - Full observability tracking

  ## Options

  Takes a `RequestOptions` struct with:
  - `strategy` - Routing strategy (:fastest, :cheapest, etc.)
  - `provider_override` - Force specific provider (optional)
  - `transport` - Transport preference (:http, :ws, :both)
  - `failover_on_override` - Retry on other providers if override fails
  - `timeout_ms` - Per-attempt timeout in milliseconds
  - `request_id` - Request tracing ID (optional)
  - `request_context` - Pre-created RequestContext (optional)

  ## Examples

      {:ok, result, ctx} = execute_via_channels(
        "ethereum",
        "eth_blockNumber",
        [],
        %RequestOptions{strategy: :fastest}
      )
      # ctx.executed_channel contains the channel that succeeded

      {:error, %JError{}, ctx} = execute_via_channels(
        "ethereum",
        "eth_call",
        [],
        %RequestOptions{provider_override: "failing_provider"}
      )
  """
  @spec execute_via_channels(chain(), method(), params(), RequestOptions.t()) :: result()
  def execute_via_channels(chain, method, params, %RequestOptions{} = opts) do
    # Initialize context
    ctx = initialize_context(chain, method, params, opts)

    # Build RPC request and set execution params on context
    rpc_request = build_rpc_request(method, params, ctx)
    ctx = RequestContext.set_execution_params(ctx, rpc_request, opts.timeout_ms, opts)

    # Build channel source based on options (unifies override vs normal selection)
    channel_source = build_channel_source(chain, method, opts)

    # Execute the pipeline
    execute_pipeline(channel_source, ctx)
  end

  # ============================================================================
  # Pipeline Execution
  # ============================================================================

  @spec execute_pipeline(channel_source(), RequestContext.t()) :: result()
  defp execute_pipeline(channel_source, ctx) do
    ctx = RequestContext.mark_request_start(ctx)

    Observability.record_request_start(
      ctx.chain,
      ctx.method,
      ctx.opts.strategy,
      ctx.opts.provider_override
    )

    # Get channels from the source
    ctx = RequestContext.mark_selection_start(ctx)
    channels = channel_source.(ctx)

    ctx =
      RequestContext.mark_selection_end(ctx,
        candidates: Enum.map(channels, &"#{&1.provider_id}:#{&1.transport}"),
        selected: List.first(channels)
      )

    case channels do
      [] ->
        handle_no_channels(ctx)

      _ ->
        ctx = RequestContext.mark_upstream_start(ctx)
        attempt_channels(channels, ctx)
    end
  end

  # ============================================================================
  # Channel Source Builders
  # ============================================================================

  # Builds a function that returns channels to try, unifying override vs normal selection
  @spec build_channel_source(chain(), method(), RequestOptions.t()) :: channel_source()
  defp build_channel_source(chain, method, %RequestOptions{provider_override: nil} = opts) do
    profile = opts.profile || "default"

    # Normal selection: get best channels via Selection module
    fn _ctx ->
      Selection.select_channels(profile, chain, method,
        strategy: opts.strategy,
        transport: opts.transport || :both,
        limit: @max_channel_candidates
      )
    end
  end

  defp build_channel_source(chain, method, %RequestOptions{provider_override: provider_id} = opts) do
    profile = opts.profile || "default"

    # Provider override: get channels for specific provider, optionally with failover
    fn _ctx ->
      primary_channels = get_provider_channels(profile, chain, provider_id, opts.transport)

      if opts.failover_on_override do
        # Append alternative channels for failover
        failover_channels =
          Selection.select_channels(profile, chain, method,
            strategy: opts.strategy,
            transport: :both,
            exclude: [provider_id],
            limit: @max_channel_candidates
          )

        primary_channels ++ failover_channels
      else
        primary_channels
      end
    end
  end

  # ============================================================================
  # Channel Attempts (Tail-Recursive)
  # ============================================================================

  @spec attempt_channels([Channel.t()], RequestContext.t()) :: result()
  defp attempt_channels([], ctx) do
    # All channels exhausted
    Logger.warning("All channels exhausted",
      chain: ctx.chain,
      method: ctx.method,
      request_id: ctx.request_id,
      attempts: length(ctx.attempted_channels)
    )

    jerr =
      JError.new(-32_000, "No channels available",
        category: :provider_error,
        retriable?: true
      )

    finalize_error(jerr, ctx)
  end

  defp attempt_channels([channel | rest], ctx) do
    %{"method" => method, "params" => params} = ctx.rpc_request

    # Validate params for this channel first
    case AdapterFilter.validate_params(channel, method, params) do
      :ok ->
        execute_on_channel(channel, rest, ctx)

      {:error, reason} ->
        Logger.debug("Parameters invalid for channel, skipping",
          channel: Channel.to_string(channel),
          method: method,
          reason: inspect(reason)
        )

        ctx = RequestContext.increment_retries(ctx)
        attempt_channels(rest, ctx)
    end
  end

  # ============================================================================
  # Single Channel Execution
  # ============================================================================

  @spec execute_on_channel(Channel.t(), [Channel.t()], RequestContext.t()) :: result()
  defp execute_on_channel(channel, rest_channels, ctx) do
    # Update context with current channel selection
    ctx = %{
      ctx
      | selected_provider: %{id: channel.provider_id, protocol: channel.transport},
        circuit_breaker_state: :unknown
    }

    case execute_with_circuit_breaker(channel, ctx.rpc_request, ctx.timeout_ms) do
      # Function executed - examine what it returned
      {:executed, {:ok, result, io_ms}} ->
        handle_success(result, io_ms, channel, ctx)

      {:executed, {:error, :unsupported_method, _io_ms}} ->
        Logger.debug("Method not supported on channel, skipping",
          channel: Channel.to_string(channel),
          method: ctx.rpc_request["method"]
        )
        attempt_channels(rest_channels, ctx)

      {:executed, {:error, reason, io_ms}} ->
        handle_channel_error(reason, io_ms, channel, rest_channels, ctx)

      {:executed, {:exception, {kind, error, _stacktrace}}} ->
        Logger.error("Exception during request execution",
          channel: Channel.to_string(channel),
          kind: kind,
          error: inspect(error)
        )
        exception_error = JError.new(-32_000, "Internal error: #{kind}", category: :server_error, retriable?: true)
        handle_channel_error(exception_error, nil, channel, rest_channels, ctx)

      # Circuit breaker rejected execution
      {:rejected, :circuit_open} ->
        handle_circuit_open(channel, rest_channels, ctx)

      {:rejected, :half_open_busy} ->
        handle_circuit_open(channel, rest_channels, ctx)

      {:rejected, :admission_timeout} ->
        Logger.warning("Circuit breaker admission timeout",
          channel: Channel.to_string(channel),
          request_id: ctx.request_id
        )
        # Treat as retriable - try next channel
        ctx = RequestContext.increment_retries(ctx)
        attempt_channels(rest_channels, ctx)

      {:rejected, :not_found} ->
        Logger.error("Circuit breaker not found",
          channel: Channel.to_string(channel),
          request_id: ctx.request_id
        )
        # Treat as retriable - try next channel
        ctx = RequestContext.increment_retries(ctx)
        attempt_channels(rest_channels, ctx)
    end
  end

  # ============================================================================
  # Result Handlers
  # ============================================================================

  @spec handle_success(any(), number(), Channel.t(), RequestContext.t()) :: result()
  defp handle_success(result, io_ms, channel, ctx) do
    Logger.debug("Request succeeded",
      channel: Channel.to_string(channel),
      request_id: ctx.request_id,
      io_latency_ms: io_ms
    )

    log_slow_request_if_needed(io_ms, ctx.method, channel, ctx)

    # Update context with success info
    ctx =
      ctx
      |> RequestContext.add_upstream_latency(io_ms)
      |> RequestContext.record_channel_success(channel)
      |> RequestContext.set_executed_channel(channel)
      |> RequestContext.mark_upstream_end()
      |> RequestContext.record_success(result)

    duration_ms = RequestContext.get_duration(ctx)
    Observability.record_success(ctx, channel, ctx.method, ctx.opts.strategy, duration_ms)

    {:ok, result, ctx}
  end

  @spec handle_channel_error(any(), number() | nil, Channel.t(), [Channel.t()], RequestContext.t()) ::
          result()
  defp handle_channel_error(reason, io_ms, channel, rest_channels, ctx) do
    # Record the failed attempt
    ctx =
      ctx
      |> RequestContext.add_upstream_latency(io_ms || 0)
      |> RequestContext.record_channel_attempt(channel, reason)

    # Use FailoverStrategy to decide next action
    case FailoverStrategy.decide(reason, rest_channels, ctx) do
      {:failover, failover_reason} ->
        Logger.debug("Failing over to next channel",
          channel: Channel.to_string(channel),
          reason: failover_reason,
          remaining: length(rest_channels)
        )

        error_category = extract_error_category(reason)

        ctx =
          ctx
          |> RequestContext.increment_retries()
          |> RequestContext.track_error_category(error_category)

        Observability.record_fast_fail(ctx, channel, failover_reason, reason)

        attempt_channels(rest_channels, ctx)

      {:terminal_error, terminal_reason} ->
        Logger.warning("Terminal error, not retrying",
          channel: Channel.to_string(channel),
          reason: terminal_reason,
          error: inspect(reason)
        )

        jerr = JError.from(reason, provider_id: channel.provider_id)

        ctx = RequestContext.set_executed_channel(ctx, channel)

        finalize_error(jerr, ctx)
    end
  end

  @spec handle_circuit_open(Channel.t(), [Channel.t()], RequestContext.t()) :: result()
  defp handle_circuit_open(channel, rest_channels, ctx) do
    Logger.info("Circuit breaker open, skipping",
      channel: Channel.to_string(channel),
      request_id: ctx.request_id
    )

    ctx =
      ctx
      |> RequestContext.add_upstream_latency(0)
      |> RequestContext.increment_retries()

    Observability.record_circuit_open(ctx, channel)

    attempt_channels(rest_channels, ctx)
  end

  @spec handle_no_channels(RequestContext.t()) :: result()
  defp handle_no_channels(ctx) do
    retry_after_ms = calculate_min_recovery_time(ctx.chain, ctx.opts.transport)
    {message, data} = build_exhaustion_error_message(ctx.method, retry_after_ms, ctx.chain)

    jerr =
      JError.new(-32_000, message,
        category: :provider_error,
        retriable?: true,
        data: data
      )

    Logger.warning("No channels available",
      chain: ctx.chain,
      method: ctx.method,
      retry_after_ms: retry_after_ms
    )

    Observability.record_exhaustion(ctx.chain, ctx.method, ctx.opts.transport, retry_after_ms)

    finalize_error(jerr, ctx)
  end

  # ============================================================================
  # Finalization
  # ============================================================================

  @spec finalize_error(JError.t(), RequestContext.t()) :: result()
  defp finalize_error(jerr, ctx) do
    ctx =
      ctx
      |> RequestContext.mark_upstream_end()
      |> RequestContext.record_error(jerr)

    duration_ms = RequestContext.get_duration(ctx)

    # Record observability if we have an executed channel
    if ctx.executed_channel do
      Observability.record_failure(
        ctx,
        ctx.executed_channel,
        ctx.method,
        ctx.opts.strategy,
        jerr,
        duration_ms
      )
    else
      Observability.record_failure(
        ctx,
        "no_channel",
        ctx.method,
        ctx.opts.strategy,
        jerr,
        duration_ms
      )
    end

    {:error, jerr, ctx}
  end

  # ============================================================================
  # Circuit Breaker Execution
  # ============================================================================

  # CircuitBreaker.call returns:
  # - {:executed, fun_result} - Function executed, fun_result is what Channel.request returned
  # - {:rejected, reason} - Circuit breaker prevented execution
  #
  # Channel.request returns: {:ok, result, io_ms} | {:error, reason, io_ms}
  #
  # The CB handles all exit cases internally (timeout, noproc, etc.) and returns
  # {:rejected, :admission_timeout} or {:rejected, :not_found} instead.
  @spec execute_with_circuit_breaker(Channel.t(), map(), timeout()) ::
          CircuitBreaker.call_result({:ok, any(), number()} | {:error, any(), number()})
  defp execute_with_circuit_breaker(channel, rpc_request, timeout) do
    attempt_fun = fn -> Channel.request(channel, rpc_request, timeout) end
    cb_id = {channel.chain, channel.provider_id, channel.transport}
    CircuitBreaker.call(cb_id, attempt_fun, timeout)
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  @spec initialize_context(chain(), method(), params(), RequestOptions.t()) :: RequestContext.t()
  defp initialize_context(chain, method, params, opts) do
    opts.request_context ||
      RequestContext.new(chain, method,
        params_present: params != [] and not is_nil(params),
        transport: opts.transport || :http,
        strategy: opts.strategy,
        request_id: opts.request_id,
        plug_start_time: opts.plug_start_time
      )
  end

  @spec build_rpc_request(method(), params(), RequestContext.t()) :: map()
  defp build_rpc_request(method, params, ctx) do
    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => ctx.request_id
    }
  end

  @spec get_provider_channels(String.t(), chain(), String.t(), atom() | nil) :: [Channel.t()]
  defp get_provider_channels(profile, chain, provider_id, transport_override) do
    transports = if transport_override, do: [transport_override], else: [:http, :ws]

    for transport <- transports,
        channel = fetch_channel_safe(profile, chain, provider_id, transport),
        not is_nil(channel),
        do: channel
  end

  @spec fetch_channel_safe(String.t(), chain(), String.t(), atom()) :: Channel.t() | nil
  defp fetch_channel_safe(profile, chain, provider_id, transport) do
    case TransportRegistry.get_channel(profile, chain, provider_id, transport) do
      {:ok, channel} -> channel
      {:error, _} -> nil
    end
  catch
    :exit, _ -> nil
  end

  @spec build_exhaustion_error_message(method(), non_neg_integer() | nil, chain()) ::
          {String.t(), map()}
  defp build_exhaustion_error_message(method, nil, _chain) do
    {"No available channels for method: #{method}. All circuit breakers are open.", %{}}
  end

  defp build_exhaustion_error_message(method, ms, _chain) when is_integer(ms) and ms > 0 do
    seconds = div(ms, 1000)
    message = "No available channels for method: #{method}. All circuits open, retry after #{seconds}s"
    {message, %{retry_after_ms: ms}}
  end

  defp build_exhaustion_error_message(method, retry_after_ms, chain) do
    Logger.warning("Invalid recovery time: #{inspect(retry_after_ms)}", chain: chain)
    {"No available channels for method: #{method}. All circuit breakers are open.", %{}}
  end

  @spec calculate_min_recovery_time(chain(), atom() | nil) :: non_neg_integer() | nil
  defp calculate_min_recovery_time(chain, transport_filter) do
    transport = transport_filter || :both

    case ProviderPool.get_min_recovery_time(chain, transport: transport, timeout: 2000) do
      {:ok, min_time} -> min_time
      {:error, :timeout} ->
        Logger.warning("Timeout getting recovery time", chain: chain)
        60_000
      {:error, _reason} -> nil
    end
  end

  @spec extract_error_category(any()) :: atom()
  defp extract_error_category(%JError{category: category}), do: category || :unknown
  defp extract_error_category(:circuit_open), do: :circuit_open
  defp extract_error_category(_), do: :unknown

  # ============================================================================
  # Slow Request Logging
  # ============================================================================

  @spec log_slow_request_if_needed(number(), method(), Channel.t(), RequestContext.t()) :: :ok
  defp log_slow_request_if_needed(latency_ms, method, channel, ctx) when latency_ms > 4000 do
    Logger.error("VERY SLOW request (may timeout clients)",
      request_id: ctx.request_id,
      method: method,
      provider: channel.provider_id,
      latency_ms: latency_ms
    )

    Observability.record_very_slow_request(
      ctx.chain,
      method,
      channel.provider_id,
      channel.transport,
      latency_ms
    )
  end

  defp log_slow_request_if_needed(latency_ms, method, channel, ctx) when latency_ms > 2000 do
    Logger.warning("Slow request",
      request_id: ctx.request_id,
      method: method,
      provider: channel.provider_id,
      latency_ms: latency_ms
    )

    Observability.record_slow_request(
      ctx.chain,
      method,
      channel.provider_id,
      channel.transport,
      latency_ms
    )
  end

  defp log_slow_request_if_needed(latency_ms, method, channel, ctx) when latency_ms > 1000 do
    Logger.info("Elevated latency",
      request_id: ctx.request_id,
      method: method,
      provider: channel.provider_id,
      latency_ms: latency_ms
    )
  end

  defp log_slow_request_if_needed(_latency_ms, _method, _channel, _ctx), do: :ok
end
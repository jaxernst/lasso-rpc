defmodule Lasso.RPC.RequestPipeline do
  @moduledoc """
  Orchestrates provider selection, optional override short-circuit,
  and resilient retries/failover for RPC requests across transports.

  Responsibilities:
  - Select provider using strategy and protocol constraints
  - Support provider override (attempt first; optional failover on retriable errors)
  - Execute single attempts wrapped in per-provider circuit breakers
  - Publish telemetry and update provider metrics for successes/failures
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

  @type chain :: String.t()
  @type method :: String.t()
  @type params :: list()

  # Configuration constants
  @max_channel_candidates 10

  @doc """
  Execute an RPC request using transport-agnostic channels.

  This is a channel-based API that supports mixed HTTP and WebSocket routing.
  It automatically selects the best channels across different transports based on
  strategy, health, and capabilities.

  Returns the final RequestContext alongside the result, providing observability
  metadata including provider selection details, latency measurements, retry history,
  and error chains.

  Takes a `RequestOptions` struct containing all execution parameters:
  - `strategy` - Routing strategy (:fastest, :cheapest, etc.)
  - `provider_override` - Force specific provider (optional)
  - `transport` - Transport preference (:http, :ws, :both)
  - `failover_on_override` - Retry on other providers if override fails
  - `timeout_ms` - Per-attempt timeout in milliseconds
  - `request_id` - Request tracing ID (optional)
  - `request_context` - Pre-created RequestContext for observability (optional)

  ## Examples

      {:ok, result, ctx} = execute_via_channels(
        "ethereum",
        "eth_blockNumber",
        [],
        %RequestOptions{strategy: :fastest}
      )
      # ctx contains: selected_provider, upstream_latency_ms, retries, etc.

      {:error, error, ctx} = execute_via_channels(
        "ethereum",
        "eth_call",
        [],
        %RequestOptions{provider_override: "failing_provider"}
      )
      # ctx.errors contains the error chain
  """
  @spec execute_via_channels(chain, method, params, RequestOptions.t()) ::
          {:ok, any(), RequestContext.t()} | {:error, any(), RequestContext.t()}
  def execute_via_channels(chain, method, params, %RequestOptions{} = opts) do
    # Get or create request context
    ctx =
      opts.request_context ||
        RequestContext.new(chain, method,
          params_present: params != [] and not is_nil(params),
          params_digest: compute_params_digest(params),
          transport: opts.transport || :http,
          strategy: opts.strategy,
          request_id: opts.request_id
        )

    # Build JSON-RPC request
    rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => ctx.request_id
    }

    # Route based on provider override
    case opts.provider_override do
      provider_id when is_binary(provider_id) ->
        execute_with_provider_override(chain, rpc_request, opts, ctx)

      nil ->
        execute_with_channel_selection(chain, rpc_request, opts, ctx)
    end
  end

  # Completes a request with final logging (telemetry already emitted by Observability module)
  @spec complete_request(
          atom(),
          RequestContext.t(),
          non_neg_integer(),
          String.t(),
          String.t(),
          keyword()
        ) :: RequestContext.t()
  defp complete_request(_status, ctx, _duration_ms, _chain, _method, _opts) do
    # Telemetry is already emitted by Observability.record_success/record_failure
    # This function now just returns the context for future extensibility
    ctx
  end

  # Provider override execution path
  @spec execute_with_provider_override(chain(), map(), RequestOptions.t(), RequestContext.t()) ::
          {:ok, any(), RequestContext.t()} | {:error, any(), RequestContext.t()}
  defp execute_with_provider_override(
         chain,
         %{"method" => method} = rpc_request,
         %RequestOptions{} = opts,
         ctx
       ) do
    provider_id = opts.provider_override
    ctx = RequestContext.mark_request_start(ctx)

    Logger.info("RPC request started (provider override)",
      request_id: ctx.request_id,
      chain: chain,
      method: method,
      provider_id: provider_id,
      timeout_ms: opts.timeout_ms,
      strategy: opts.strategy
    )

    Observability.record_request_start(chain, method, opts.strategy, provider_id)

    # Get channels for the specific provider
    channels = get_provider_channels(chain, provider_id, opts.transport)

    case attempt_request_on_channels(channels, rpc_request, opts.timeout_ms, ctx) do
      {:ok, result, channel, updated_ctx} ->
        handle_override_success(chain, method, opts, result, channel, updated_ctx)

      {:error, :no_channels_available, updated_ctx} ->
        handle_override_no_channels(chain, method, opts, provider_id, updated_ctx)

      {:error, reason, channel, ctx1} ->
        handle_override_failure(chain, rpc_request, opts, provider_id, reason, channel, ctx1)
    end
  end

  # Handles successful provider override request
  @spec handle_override_success(
          chain(),
          String.t(),
          RequestOptions.t(),
          any(),
          Channel.t(),
          RequestContext.t()
        ) :: {:ok, any(), RequestContext.t()}
  defp handle_override_success(chain, method, opts, result, channel, updated_ctx) do
    duration_ms = RequestContext.get_duration(updated_ctx)

    Observability.record_success(updated_ctx, channel, method, opts.strategy, duration_ms)

    final_ctx =
      complete_request(:success, updated_ctx, duration_ms, chain, method, result: result)

    {:ok, result, final_ctx}
  end

  # Handles no channels available for provider override
  @spec handle_override_no_channels(
          chain(),
          String.t(),
          RequestOptions.t(),
          String.t(),
          RequestContext.t()
        ) :: {:error, JError.t(), RequestContext.t()}
  defp handle_override_no_channels(chain, method, opts, provider_id, updated_ctx) do
    duration_ms = RequestContext.get_duration(updated_ctx)

    jerr =
      JError.new(-32_000, "Provider not found or no channels available",
        category: :provider_error
      )

    Observability.record_failure(
      updated_ctx,
      provider_id,
      method,
      opts.strategy,
      jerr,
      duration_ms
    )

    final_ctx = complete_request(:error, updated_ctx, duration_ms, chain, method, error: jerr)
    {:error, jerr, final_ctx}
  end

  # Handles failure of provider override with optional failover
  @spec handle_override_failure(
          chain(),
          map(),
          RequestOptions.t(),
          String.t(),
          any(),
          Channel.t(),
          RequestContext.t()
        ) :: {:ok, any(), RequestContext.t()} | {:error, JError.t(), RequestContext.t()}
  defp handle_override_failure(
         chain,
         %{"method" => method} = rpc_request,
         opts,
         provider_id,
         reason,
         channel,
         ctx1
       ) do
    duration_ms = RequestContext.get_duration(ctx1)
    jerr = normalize_channel_error(reason, provider_id)

    Observability.record_failure(ctx1, channel, method, opts.strategy, jerr, duration_ms)

    should_failover = opts.failover_on_override and retriable_error?(jerr)

    if should_failover do
      attempt_override_failover(chain, rpc_request, opts, provider_id, ctx1, jerr, method)
    else
      final_ctx = complete_request(:error, ctx1, duration_ms, chain, method, error: jerr)
      {:error, jerr, final_ctx}
    end
  end

  # Attempts failover after provider override failure
  @spec attempt_override_failover(
          chain(),
          map(),
          RequestOptions.t(),
          String.t(),
          RequestContext.t(),
          JError.t(),
          String.t()
        ) :: {:ok, any(), RequestContext.t()} | {:error, JError.t(), RequestContext.t()}
  defp attempt_override_failover(chain, rpc_request, opts, provider_id, ctx1, jerr, method) do
    # Select alternative channels excluding the failed provider
    failover_channels =
      Selection.select_channels(chain, method,
        strategy: opts.strategy,
        transport: :both,
        exclude: [provider_id],
        limit: @max_channel_candidates
      )

    case failover_channels do
      [] ->
        # No alternative providers available
        final_duration_ms = RequestContext.get_duration(ctx1)
        final_ctx = complete_request(:error, ctx1, final_duration_ms, chain, method, error: jerr)
        {:error, jerr, final_ctx}

      _ ->
        # Try failover channels using standard pipeline
        case attempt_request_on_channels(failover_channels, rpc_request, opts.timeout_ms, ctx1) do
          {:ok, result, channel, updated_ctx} ->
            # Failover succeeded
            duration_ms = RequestContext.get_duration(updated_ctx)
            Observability.record_success(updated_ctx, channel, method, opts.strategy, duration_ms)

            final_ctx =
              complete_request(:success, updated_ctx, duration_ms, chain, method, result: result)

            {:ok, result, final_ctx}

          {:error, _reason, _channel, failed_ctx} ->
            # Failover failed - return original error
            final_duration_ms = RequestContext.get_duration(failed_ctx)

            final_ctx =
              complete_request(:error, failed_ctx, final_duration_ms, chain, method, error: jerr)

            {:error, jerr, final_ctx}

          {:error, :no_channels_available, failed_ctx} ->
            # All failover channels exhausted - return original error
            final_duration_ms = RequestContext.get_duration(failed_ctx)

            final_ctx =
              complete_request(:error, failed_ctx, final_duration_ms, chain, method, error: jerr)

            {:error, jerr, final_ctx}
        end
    end
  end

  # Normal selection execution path
  @spec execute_with_channel_selection(chain(), map(), RequestOptions.t(), RequestContext.t()) ::
          {:ok, any(), RequestContext.t()} | {:error, any(), RequestContext.t()}
  defp execute_with_channel_selection(
         chain,
         %{"method" => method} = rpc_request,
         %RequestOptions{} = opts,
         ctx
       ) do
    ctx = RequestContext.mark_request_start(ctx)

    Logger.info("RPC request started",
      request_id: ctx.request_id,
      chain: chain,
      method: method,
      timeout_ms: opts.timeout_ms,
      strategy: opts.strategy
    )

    Observability.record_request_start(chain, method, opts.strategy)

    # Mark selection start and get candidate channels
    ctx = RequestContext.mark_selection_start(ctx)

    channels =
      Selection.select_channels(chain, method,
        strategy: opts.strategy,
        transport: opts.transport || :both,
        limit: @max_channel_candidates
      )

    # Update context with selection metadata
    ctx =
      RequestContext.mark_selection_end(ctx,
        candidates: Enum.map(channels, &"#{&1.provider_id}:#{&1.transport}"),
        selected: if(length(channels) > 0, do: List.first(channels), else: nil)
      )

    case channels do
      [] ->
        handle_no_channels_available(chain, rpc_request, method, opts, ctx)

      _ ->
        execute_request_with_channels(chain, rpc_request, method, opts, ctx, channels, :normal)
    end
  end

  # Handles the case when no channels are available with closed circuits
  @spec handle_no_channels_available(
          chain(),
          map(),
          String.t(),
          RequestOptions.t(),
          RequestContext.t()
        ) :: {:ok, any(), RequestContext.t()} | {:error, any(), RequestContext.t()}
  defp handle_no_channels_available(
         chain,
         rpc_request,
         method,
         %RequestOptions{} = opts,
         ctx
       ) do
    Logger.info(
      "No closed circuit channels available, attempting degraded mode with half-open circuits",
      chain: chain,
      method: method
    )

    Observability.record_degraded_mode(chain, method)

    degraded_channels =
      Selection.select_channels(chain, method,
        strategy: opts.strategy,
        transport: opts.transport || :both,
        limit: @max_channel_candidates,
        include_half_open: true
      )

    case degraded_channels do
      [] ->
        handle_channel_exhaustion(chain, method, opts, ctx)

      _ ->
        execute_request_with_channels(
          chain,
          rpc_request,
          method,
          opts,
          ctx,
          degraded_channels,
          :degraded
        )
    end
  end

  # Handles request execution when all circuits are open
  @spec handle_channel_exhaustion(
          chain(),
          String.t(),
          RequestOptions.t(),
          RequestContext.t()
        ) :: {:error, JError.t(), RequestContext.t()}
  defp handle_channel_exhaustion(chain, method, %RequestOptions{} = opts, ctx) do
    duration_ms = RequestContext.get_duration(ctx)
    retry_after_ms = calculate_min_recovery_time(chain, opts.transport)
    {error_message, error_data} = build_exhaustion_error_message(method, retry_after_ms, chain)

    jerr =
      JError.new(-32_000, error_message,
        category: :provider_error,
        retriable?: true,
        data: error_data
      )

    updated_ctx = RequestContext.record_error(ctx, jerr)

    Logger.warning("Channel exhaustion: all circuits open",
      chain: chain,
      method: method,
      retry_after_ms: retry_after_ms
    )

    Observability.record_exhaustion(chain, method, opts.transport, retry_after_ms)

    final_ctx = complete_request(:error, updated_ctx, duration_ms, chain, method, error: jerr)
    {:error, jerr, final_ctx}
  end

  # Builds error message with retry-after hint for channel exhaustion
  @spec build_exhaustion_error_message(String.t(), non_neg_integer() | nil, String.t()) ::
          {String.t(), map()}
  defp build_exhaustion_error_message(method, nil, _chain) do
    {"No available channels for method: #{method}. All circuit breakers are open.", %{}}
  end

  defp build_exhaustion_error_message(method, ms, _chain) when is_integer(ms) and ms > 0 do
    seconds = div(ms, 1000)

    message =
      "No available channels for method: #{method}. All circuits open, retry after #{seconds}s"

    {message, %{retry_after_ms: ms}}
  end

  defp build_exhaustion_error_message(method, retry_after_ms, chain) do
    Logger.warning("Invalid recovery time returned: #{inspect(retry_after_ms)}",
      chain: chain,
      method: method
    )

    {"No available channels for method: #{method}. All circuit breakers are open.", %{}}
  end

  # Unified request execution with channels (works for both normal and degraded modes)
  @spec execute_request_with_channels(
          chain(),
          map(),
          String.t(),
          RequestOptions.t(),
          RequestContext.t(),
          [Channel.t()],
          atom()
        ) :: {:ok, any(), RequestContext.t()} | {:error, any(), RequestContext.t()}
  defp execute_request_with_channels(
         chain,
         rpc_request,
         method,
         %RequestOptions{} = opts,
         ctx,
         channels,
         mode
       ) do
    # Log and update context for degraded mode
    ctx =
      if mode == :degraded do
        Logger.info("Degraded mode: attempting #{length(channels)} half-open channels",
          chain: chain,
          method: method,
          channels: Enum.map(channels, &"#{&1.provider_id}:#{&1.transport}")
        )

        # Update context to reflect degraded mode selection
        RequestContext.mark_selection_end(ctx,
          candidates: Enum.map(channels, &"#{&1.provider_id}:#{&1.transport}"),
          selected: if(length(channels) > 0, do: List.first(channels), else: nil)
        )
      else
        ctx
      end

    # Mark upstream start and attempt request
    ctx = RequestContext.mark_upstream_start(ctx)

    case attempt_request_on_channels(channels, rpc_request, opts.timeout_ms, ctx) do
      {:ok, result, channel, updated_ctx} ->
        handle_success(chain, method, opts, ctx, result, channel, updated_ctx, mode)

      {:error, reason, channel, _ctx1} ->
        handle_failure(chain, method, opts, ctx, reason, channel, mode)

      {:error, :no_channels_available, _updated_ctx} ->
        # No channels available - return error
        duration_ms = RequestContext.get_duration(ctx)
        updated_ctx = RequestContext.mark_upstream_end(ctx)
        final_ctx = RequestContext.record_error(updated_ctx, :no_channels_available)
        jerr = normalize_channel_error(:no_channels_available, "no_channels")

        final_ctx =
          complete_request(:error, final_ctx, duration_ms, ctx.chain, ctx.method, error: jerr)

        {:error, jerr, final_ctx}
    end
  end

  # Unified success handler for all execution modes
  @spec handle_success(
          chain(),
          String.t(),
          RequestOptions.t(),
          RequestContext.t(),
          any(),
          Channel.t(),
          RequestContext.t(),
          atom()
        ) :: {:ok, any(), RequestContext.t()}
  defp handle_success(
         chain,
         method,
         %RequestOptions{} = opts,
         _original_ctx,
         result,
         channel,
         updated_ctx,
         mode
       ) do
    duration_ms = RequestContext.get_duration(updated_ctx)
    updated_ctx = RequestContext.mark_upstream_end(updated_ctx)
    updated_ctx = RequestContext.record_success(updated_ctx, result)

    Observability.record_success(updated_ctx, channel, method, opts.strategy, duration_ms)

    # Additional logging and observability for degraded mode
    if mode == :degraded do
      Logger.info("Degraded mode success via half-open channel",
        chain: chain,
        method: method,
        channel: "#{channel.provider_id}:#{channel.transport}"
      )

      Observability.record_degraded_success(chain, method, channel)
    end

    final_ctx =
      complete_request(:success, updated_ctx, duration_ms, chain, method, result: result)

    {:ok, result, final_ctx}
  end

  # Unified failure handler for all execution modes
  @spec handle_failure(
          chain(),
          String.t(),
          RequestOptions.t(),
          RequestContext.t(),
          any(),
          Channel.t(),
          atom()
        ) :: {:error, JError.t(), RequestContext.t()}
  defp handle_failure(
         chain,
         method,
         %RequestOptions{} = opts,
         ctx,
         reason,
         channel,
         _mode
       ) do
    duration_ms = RequestContext.get_duration(ctx)
    updated_ctx = RequestContext.mark_upstream_end(ctx)
    final_ctx = RequestContext.record_error(updated_ctx, reason)
    jerr = normalize_channel_error(reason, "no_channels")
    duration = final_ctx.upstream_latency_ms || 0

    Observability.record_failure(final_ctx, channel, method, opts.strategy, jerr, duration)

    final_ctx = complete_request(:error, final_ctx, duration_ms, chain, method, error: jerr)
    {:error, jerr, final_ctx}
  end

  @spec get_provider_channels(chain(), String.t(), atom() | nil) :: [Channel.t()]
  defp get_provider_channels(chain, provider_id, transport_override) do
    transports = if transport_override, do: [transport_override], else: [:http, :ws]

    for transport <- transports,
        channel = fetch_channel_safe(chain, provider_id, transport),
        not is_nil(channel),
        do: channel
  end

  @spec fetch_channel_safe(chain(), String.t(), atom()) :: Channel.t() | nil
  defp fetch_channel_safe(chain, provider_id, transport) do
    case TransportRegistry.get_channel(chain, provider_id, transport) do
      {:ok, channel} -> channel
      {:error, _} -> nil
    end
  catch
    :exit, _ -> nil
  end

  @spec attempt_request_on_channels([Channel.t()], map(), timeout(), RequestContext.t()) ::
          {:ok, any(), Channel.t(), RequestContext.t()}
          | {:error, atom(), Channel.t(), RequestContext.t()}
          | {:error, atom(), RequestContext.t()}
  defp attempt_request_on_channels([], _rpc_request, _timeout, ctx) do
    Logger.warning("No channels available for request",
      chain: ctx.chain,
      method: ctx.method,
      request_id: ctx.request_id,
      transport: ctx.transport
    )

    {:error, :no_channels_available, ctx}
  end

  defp attempt_request_on_channels(
         [channel | rest_channels],
         %{"method" => method, "params" => params} = rpc_request,
         timeout,
         ctx
       ) do
    # Validate parameters for this specific channel before attempting request
    case AdapterFilter.validate_params(channel, method, params) do
      :ok ->
        # Params valid, proceed with request
        execute_channel_request(channel, rpc_request, timeout, ctx, rest_channels)

      {:error, reason} ->
        # Params invalid for this provider, skip to next channel
        Logger.debug(
          "Parameters invalid for channel, trying next: #{inspect(reason)}",
          channel: Channel.to_string(channel),
          method: method,
          reason: reason
        )

        # Increment retries and try next channel
        ctx = RequestContext.increment_retries(ctx)
        attempt_request_on_channels(rest_channels, rpc_request, timeout, ctx)
    end
  end

  # Executes a circuit breaker call with error handling for exits
  @spec execute_with_circuit_breaker(Channel.t(), map(), timeout(), RequestContext.t()) ::
          {:ok, {:ok, any(), number()} | {:error, any(), number()}} | {:error, any()}
  defp execute_with_circuit_breaker(channel, rpc_request, timeout, ctx) do
    attempt_fun = fn -> Channel.request(channel, rpc_request, timeout) end
    cb_id = {channel.chain, channel.provider_id, channel.transport}

    try do
      CircuitBreaker.call(cb_id, attempt_fun, timeout)
    catch
      :exit, {:timeout, _} ->
        Logger.error("Request timeout on channel (GenServer.call)",
          request_id: ctx.request_id,
          channel: Channel.to_string(channel),
          method: Map.get(rpc_request, "method"),
          timeout: timeout
        )

        {:error, JError.new(-32_000, "Request timeout", category: :timeout, retriable?: true)}

      :exit, {:noproc, _} ->
        Logger.error("Circuit breaker not found for channel - provider may not be initialized",
          request_id: ctx.request_id,
          channel: Channel.to_string(channel),
          method: Map.get(rpc_request, "method"),
          circuit_breaker_id: inspect(cb_id)
        )

        {:error,
         JError.new(-32_000, "Provider not available",
           category: :provider_error,
           retriable?: true
         )}

      :exit, reason ->
        Logger.error("Circuit breaker unexpected exit",
          request_id: ctx.request_id,
          channel: Channel.to_string(channel),
          method: Map.get(rpc_request, "method"),
          reason: inspect(reason)
        )

        {:error,
         JError.new(-32_000, "Circuit breaker error",
           category: :provider_error,
           retriable?: true
         )}
    end
  end

  # Handles successful channel request result
  @spec handle_channel_success(any(), number(), Channel.t(), map(), RequestContext.t()) ::
          {:ok, any(), Channel.t(), RequestContext.t()}
  defp handle_channel_success(result, io_ms, channel, rpc_request, ctx) do
    Logger.debug("✓ Request Success via #{Channel.to_string(channel)}",
      chain: ctx.chain,
      request_id: ctx.request_id,
      io_latency_ms: io_ms
    )

    log_slow_request_if_needed(io_ms, Map.get(rpc_request, "method"), channel, ctx)

    ctx = RequestContext.set_upstream_latency(ctx, io_ms)
    {:ok, result, channel, ctx}
  end

  # Unified error handler - decides between retry, failover, or terminal error
  @spec handle_channel_error(
          any(),
          number() | nil,
          Channel.t(),
          map(),
          timeout(),
          RequestContext.t(),
          [Channel.t()]
        ) ::
          {:ok, any(), Channel.t(), RequestContext.t()}
          | {:error, atom(), Channel.t(), RequestContext.t()}
          | {:error, atom(), RequestContext.t()}
  defp handle_channel_error(reason, io_ms, channel, rpc_request, timeout, ctx, rest_channels) do
    ctx = RequestContext.set_upstream_latency(ctx, io_ms || 0)

    case FailoverStrategy.decide(reason, rest_channels, ctx) do
      {:failover, failover_reason} ->
        FailoverStrategy.execute_failover(
          ctx,
          channel,
          reason,
          failover_reason,
          rest_channels,
          rpc_request,
          timeout,
          &attempt_request_on_channels/4
        )

      {:terminal_error, terminal_reason} ->
        FailoverStrategy.handle_terminal_error(
          ctx,
          channel,
          reason,
          terminal_reason,
          length(rest_channels)
        )
    end
  end

  @spec execute_channel_request(Channel.t(), map(), timeout(), RequestContext.t(), [Channel.t()]) ::
          {:ok, any(), Channel.t(), RequestContext.t()}
          | {:error, atom(), Channel.t(), RequestContext.t()}
          | {:error, atom(), RequestContext.t()}
  defp execute_channel_request(channel, rpc_request, timeout, ctx, rest_channels) do
    # Update context with selected provider
    ctx = %{
      ctx
      | selected_provider: %{id: channel.provider_id, protocol: channel.transport},
        circuit_breaker_state: :unknown
    }

    result = execute_with_circuit_breaker(channel, rpc_request, timeout, ctx)

    case result do
      # Success: circuit breaker wraps transport result as {:ok, {:ok, result, io_ms}}
      {:ok, {:ok, result, io_ms}} ->
        handle_channel_success(result, io_ms, channel, rpc_request, ctx)

      # Unsupported method: fast fallthrough, try next channel immediately
      {:ok, {:error, :unsupported_method, _io_ms}} ->
        Logger.debug("Method not supported on channel, trying next",
          channel: Channel.to_string(channel),
          method: Map.get(rpc_request, "method")
        )

        attempt_request_on_channels(rest_channels, rpc_request, timeout, ctx)

      # Transport error: use failover strategy to decide next action
      {:ok, {:error, reason, io_ms}} ->
        handle_channel_error(reason, io_ms, channel, rpc_request, timeout, ctx, rest_channels)

      # Circuit breaker open: fast fail to next provider
      {:error, :circuit_open} ->
        Logger.info("Circuit breaker open, fast-failing to next channel",
          request_id: ctx.request_id,
          channel: Channel.to_string(channel),
          chain: ctx.chain,
          method: Map.get(rpc_request, "method")
        )

        ctx = RequestContext.set_upstream_latency(ctx, 0)
        ctx = RequestContext.increment_retries(ctx)

        Observability.record_circuit_open(ctx, channel)

        attempt_request_on_channels(rest_channels, rpc_request, timeout, ctx)

      # Direct errors from circuit breaker (timeouts, crashes, etc.)
      {:error, reason} ->
        handle_channel_error(reason, nil, channel, rpc_request, timeout, ctx, rest_channels)
    end
  end

  @spec normalize_channel_error(any(), String.t()) :: JError.t()
  defp normalize_channel_error(%JError{} = jerr, _provider_id), do: jerr

  defp normalize_channel_error(reason, provider_id),
    do: JError.from(reason, provider_id: provider_id)

  # Logs slow requests based on configured thresholds.
  # Thresholds:
  # - ERROR: > 4000ms (4 seconds) - May cause client timeouts
  # - WARN:  > 2000ms (2 seconds)
  # - INFO:  > 1000ms (1 second)
  @spec log_slow_request_if_needed(number(), String.t(), Channel.t(), RequestContext.t()) :: :ok
  defp log_slow_request_if_needed(latency_ms, method, channel, ctx) when latency_ms > 4000 do
    Logger.error("VERY SLOW request detected (may timeout clients)",
      request_id: ctx.request_id,
      method: method,
      provider: channel.provider_id,
      transport: channel.transport,
      chain: ctx.chain,
      latency_ms: latency_ms,
      threshold: "4s"
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
    Logger.warning("Slow request detected",
      request_id: ctx.request_id,
      method: method,
      provider: channel.provider_id,
      transport: channel.transport,
      chain: ctx.chain,
      latency_ms: latency_ms,
      threshold: "2s"
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
    Logger.info("Elevated latency detected",
      request_id: ctx.request_id,
      method: method,
      provider: channel.provider_id,
      transport: channel.transport,
      chain: ctx.chain,
      latency_ms: latency_ms
    )
  end

  defp log_slow_request_if_needed(_latency_ms, _method, _channel, _ctx), do: :ok

  # Calculates the minimum recovery time across all circuit breakers for a chain.
  # Returns the shortest time until any circuit breaker will attempt recovery,
  # or nil if no recovery times are available.
  #
  # This uses the cached recovery times in ProviderPool (single GenServer call)
  # instead of making N sequential calls to each CircuitBreaker.
  @spec calculate_min_recovery_time(String.t(), atom() | nil) :: non_neg_integer() | nil
  defp calculate_min_recovery_time(chain, transport_filter) do
    transport = transport_filter || :both

    case ProviderPool.get_min_recovery_time(chain, transport: transport, timeout: 2000) do
      {:ok, min_time} ->
        min_time

      {:error, :timeout} ->
        Logger.warning("Timeout calculating recovery time, using default", chain: chain)
        60_000

      {:error, reason} ->
        Logger.warning("Failed to get recovery times", chain: chain, reason: inspect(reason))
        nil
    end
  end

  defp compute_params_digest(params) when params in [nil, []], do: nil

  defp compute_params_digest(params) do
    params
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  rescue
    _ -> nil
  end

  # Helper to check if an error is retriable (defaults to false)
  @spec retriable_error?(any()) :: boolean()
  defp retriable_error?(%JError{retriable?: retriable?}) when is_boolean(retriable?),
    do: retriable?

  defp retriable_error?(_), do: false
end

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
  alias Lasso.RPC.{Selection, ProviderPool, Metrics, TransportRegistry, Channel}
  alias Lasso.RPC.{RequestContext, Observability, CircuitBreaker}
  alias Lasso.RPC.Providers.AdapterFilter

  @type chain :: String.t()
  @type method :: String.t()
  @type params :: list()

  # Configuration constants
  @max_channel_candidates 10
  @max_failover_attempts 4

  @doc """
  Execute an RPC request with resilient behavior using transport-agnostic channels.

  This is a channel-based API that supports mixed HTTP and WebSocket routing.
  It automatically selects the best channels across different transports based on
  strategy, health, and capabilities.

  Options:
  - :strategy => :fastest | :cheapest | :priority | :round_robin
  - :provider_override => provider_id (optional)
  - :transport_override => :http | :ws (optional, force specific transport)
  - :failover_on_override => boolean (default: false)
  - :timeout => ms (per-attempt timeout)
  - :request_context => RequestContext.t() (optional, for observability)
  """
  @spec execute_via_channels(chain, method, params, keyword()) :: {:ok, any()} | {:error, any()}
  def execute_via_channels(chain, method, params, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :round_robin)
    provider_override = Keyword.get(opts, :provider_override)
    transport_override = Keyword.get(opts, :transport_override)
    failover_on_override = Keyword.get(opts, :failover_on_override, false)
    timeout = Keyword.get(opts, :timeout, 30_000)

    # Get or create request context for observability
    ctx =
      case Keyword.get(opts, :request_context) do
        %RequestContext{} = existing_ctx ->
          existing_ctx

        _ ->
          params_digest =
            if params != [] and not is_nil(params) do
              RequestContext.compute_params_digest(params)
            else
              nil
            end

          # Use Phoenix request_id if provided for consistent tracing
          request_id = Keyword.get(opts, :request_id)

          RequestContext.new(chain, method,
            params_present: params != [] and not is_nil(params),
            params_digest: params_digest,
            transport: transport_override || :http,
            strategy: strategy,
            request_id: request_id
          )
      end

    # Build JSON-RPC request
    rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => ctx.request_id
    }

    case provider_override do
      provider_id when is_binary(provider_id) ->
        execute_with_provider_override(
          chain,
          rpc_request,
          strategy,
          provider_id,
          transport_override,
          failover_on_override: failover_on_override,
          timeout: timeout
        )

      _ ->
        start_time = System.monotonic_time(:millisecond)

        # Log request start for traceability
        Logger.info("RPC request started",
          request_id: ctx.request_id,
          chain: chain,
          method: method,
          timeout_ms: timeout,
          strategy: strategy
        )

        # Emit telemetry start event
        :telemetry.execute([:lasso, :rpc, :request, :start], %{count: 1}, %{
          chain: chain,
          method: method,
          strategy: strategy
        })

        case execute_with_channel_selection(chain, rpc_request, ctx, transport_override, timeout) do
          {:ok, result, updated_ctx} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time

            # Emit observability log
            Observability.log_request_completed(updated_ctx)

            # Emit telemetry stop event for success
            :telemetry.execute([:lasso, :rpc, :request, :stop], %{duration: duration_ms}, %{
              chain: chain,
              method: method,
              provider_id: updated_ctx.selected_provider,
              transport: updated_ctx.transport,
              status: :success,
              retry_count: updated_ctx.retries
            })

            # Store context for controller access (if needed for response metadata)
            Process.put(:request_context, updated_ctx)
            {:ok, result}

          {:error, reason, updated_ctx} ->
            duration_ms = System.monotonic_time(:millisecond) - start_time

            # Emit observability log for errors too
            Observability.log_request_completed(updated_ctx)

            # Emit telemetry stop event for error
            :telemetry.execute([:lasso, :rpc, :request, :stop], %{duration: duration_ms}, %{
              chain: chain,
              method: method,
              provider_id: updated_ctx.selected_provider,
              transport: updated_ctx.transport,
              status: :error,
              error: reason,
              retry_count: updated_ctx.retries
            })

            # Store context for controller access
            Process.put(:request_context, updated_ctx)
            {:error, reason}
        end
    end
  end

  defp record_rpc_failure(chain, provider_id, method, reason, duration_ms, transport \\ nil) do
    Metrics.record_failure(chain, provider_id, method, duration_ms)

    case transport do
      nil -> ProviderPool.report_failure(chain, provider_id, reason)
      t -> ProviderPool.report_failure(chain, provider_id, reason, t)
    end
  end

  # New channel-based implementation functions

  defp execute_with_provider_override(
         chain,
         rpc_request,
         strategy,
         provider_id,
         transport_override,
         opts
       ) do
    failover_on_override = Keyword.get(opts, :failover_on_override, false)
    timeout = Keyword.get(opts, :timeout, 30_000)
    method = Map.get(rpc_request, "method")

    start_time = System.monotonic_time(:millisecond)

    :telemetry.execute([:lasso, :rpc, :request, :start], %{count: 1}, %{
      chain: chain,
      method: method,
      strategy: strategy,
      provider_id: provider_id
    })

    # Get channels for the specific provider
    channels = get_provider_channels(chain, provider_id, transport_override)

    # Create minimal context for provider override path
    ctx =
      RequestContext.new(chain, method,
        transport: transport_override || :http,
        strategy: strategy
      )

    case attempt_request_on_channels(channels, rpc_request, timeout, ctx) do
      {:ok, result, channel, updated_ctx} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        record_channel_success_metrics(chain, channel, method, strategy, duration_ms)
        Observability.log_request_completed(updated_ctx)
        Process.put(:request_context, updated_ctx)

        # Emit telemetry stop event for success
        :telemetry.execute([:lasso, :rpc, :request, :stop], %{duration: duration_ms}, %{
          chain: chain,
          method: method,
          provider_id: provider_id,
          transport: transport_override || :http,
          status: :success,
          retry_count: 0
        })

        {:ok, result}

      {:error, :no_channels_available, _updated_ctx} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time

        jerr =
          JError.new(-32_000, "Provider not found or no channels available",
            category: :provider_error
          )

        record_channel_failure_metrics(chain, provider_id, method, strategy, jerr, duration_ms)

        # Emit telemetry stop event for no channels
        :telemetry.execute([:lasso, :rpc, :request, :stop], %{duration: duration_ms}, %{
          chain: chain,
          method: method,
          provider_id: provider_id,
          transport: transport_override || :http,
          status: :error,
          error: jerr,
          retry_count: 0
        })

        {:error, jerr}

      {:error, reason, channel, _ctx1} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        jerr = normalize_channel_error(reason, provider_id)

        record_channel_failure_metrics(
          chain,
          provider_id,
          method,
          strategy,
          jerr,
          duration_ms,
          channel.transport
        )

        should_failover =
          case jerr do
            %JError{retriable?: retriable?} -> retriable?
            _ -> false
          end

        if failover_on_override and should_failover do
          # Attempt failover and emit telemetry for final result
          case try_channel_failover(
                 chain,
                 rpc_request,
                 strategy,
                 [provider_id],
                 1,
                 timeout
               ) do
            {:ok, _result} = success ->
              final_duration_ms = System.monotonic_time(:millisecond) - start_time

              :telemetry.execute(
                [:lasso, :rpc, :request, :stop],
                %{duration: final_duration_ms},
                %{
                  chain: chain,
                  method: method,
                  provider_id: provider_id,
                  transport: transport_override || :http,
                  status: :success,
                  retry_count: 1
                }
              )

              success

            {:error, failover_err} = failure ->
              final_duration_ms = System.monotonic_time(:millisecond) - start_time

              :telemetry.execute(
                [:lasso, :rpc, :request, :stop],
                %{duration: final_duration_ms},
                %{
                  chain: chain,
                  method: method,
                  provider_id: provider_id,
                  transport: transport_override || :http,
                  status: :error,
                  error: failover_err,
                  retry_count: 1
                }
              )

              failure
          end
        else
          # Emit telemetry stop event for failure (no failover)
          :telemetry.execute([:lasso, :rpc, :request, :stop], %{duration: duration_ms}, %{
            chain: chain,
            method: method,
            provider_id: provider_id,
            transport: transport_override || :http,
            status: :error,
            error: jerr,
            retry_count: 0
          })

          {:error, jerr}
        end
    end
  end

  defp execute_with_channel_selection(chain, rpc_request, ctx, transport_override, timeout) do
    method = Map.get(rpc_request, "method")

    # Mark selection start and get candidate channels
    ctx = RequestContext.mark_selection_start(ctx)

    channels =
      Selection.select_channels(chain, method,
        strategy: ctx.strategy,
        transport: transport_override || :both,
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
        handle_no_channels_available(chain, rpc_request, method, ctx, transport_override, timeout)

      _ ->
        handle_normal_mode_request(chain, rpc_request, method, ctx, channels, timeout)
    end
  end

  # Handles the case when no channels are available with closed circuits
  defp handle_no_channels_available(chain, rpc_request, method, ctx, transport_override, timeout) do
    Logger.info(
      "No closed circuit channels available, attempting degraded mode with half-open circuits",
      chain: chain,
      method: method
    )

    :telemetry.execute([:lasso, :failover, :degraded_mode], %{count: 1}, %{
      chain: chain,
      method: method
    })

    degraded_channels =
      Selection.select_channels(chain, method,
        strategy: ctx.strategy,
        transport: transport_override || :both,
        limit: @max_channel_candidates,
        include_half_open: true
      )

    case degraded_channels do
      [] ->
        handle_channel_exhaustion(chain, method, ctx, transport_override)

      _ ->
        handle_degraded_mode_request(
          chain,
          rpc_request,
          method,
          ctx,
          degraded_channels,
          timeout
        )
    end
  end

  # Handles request execution when all circuits are open
  defp handle_channel_exhaustion(chain, method, ctx, transport_override) do
    retry_after_ms = calculate_min_recovery_time(chain, transport_override)
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

    :telemetry.execute([:lasso, :failover, :exhaustion], %{count: 1}, %{
      chain: chain,
      method: method,
      retry_after_ms: retry_after_ms || 0
    })

    {:error, jerr, updated_ctx}
  end

  # Builds error message with retry-after hint for channel exhaustion
  defp build_exhaustion_error_message(method, retry_after_ms, chain) do
    case retry_after_ms do
      nil ->
        message = "No available channels for method: #{method}. All circuit breakers are open."
        {message, %{}}

      ms when is_integer(ms) and ms > 0 ->
        seconds = div(ms, 1000)

        message =
          "No available channels for method: #{method}. " <>
            "All circuits open, retry after #{seconds}s"

        {message, %{retry_after_ms: ms}}

      _ ->
        Logger.warning("Invalid recovery time returned: #{inspect(retry_after_ms)}",
          chain: chain,
          method: method
        )

        message = "No available channels for method: #{method}. All circuit breakers are open."
        {message, %{}}
    end
  end

  # Handles request execution in degraded mode (half-open circuits)
  defp handle_degraded_mode_request(chain, rpc_request, method, ctx, degraded_channels, timeout) do
    Logger.info("Degraded mode: attempting #{length(degraded_channels)} half-open channels",
      chain: chain,
      method: method,
      channels: Enum.map(degraded_channels, &"#{&1.provider_id}:#{&1.transport}")
    )

    # Update context to reflect degraded mode selection
    ctx =
      RequestContext.mark_selection_end(ctx,
        candidates: Enum.map(degraded_channels, &"#{&1.provider_id}:#{&1.transport}"),
        selected: if(length(degraded_channels) > 0, do: List.first(degraded_channels), else: nil)
      )

    # Mark upstream start and attempt request
    ctx = RequestContext.mark_upstream_start(ctx)

    case attempt_request_on_channels(degraded_channels, rpc_request, timeout, ctx) do
      {:ok, result, channel, updated_ctx} ->
        handle_degraded_success(chain, method, ctx, result, channel, updated_ctx)

      {:error, reason, channel, _ctx1} ->
        handle_degraded_failure(chain, method, ctx, reason, channel)

      {:error, :no_channels_available, _updated_ctx} ->
        handle_request_failure(ctx, :no_channels_available)
    end
  end

  # Handles successful request in degraded mode
  defp handle_degraded_success(chain, method, ctx, result, channel, updated_ctx) do
    updated_ctx = RequestContext.mark_upstream_end(updated_ctx)
    updated_ctx = RequestContext.record_success(updated_ctx, result)

    record_channel_success_metrics(
      chain,
      channel,
      method,
      ctx.strategy,
      updated_ctx.upstream_latency_ms || 0
    )

    Logger.info("Degraded mode success via half-open channel",
      chain: chain,
      method: method,
      channel: "#{channel.provider_id}:#{channel.transport}"
    )

    :telemetry.execute([:lasso, :failover, :degraded_success], %{count: 1}, %{
      chain: chain,
      method: method,
      provider_id: channel.provider_id,
      transport: channel.transport
    })

    {:ok, result, updated_ctx}
  end

  # Handles failed request in degraded mode
  defp handle_degraded_failure(chain, method, ctx, reason, channel) do
    updated_ctx = RequestContext.mark_upstream_end(ctx)
    final_ctx = RequestContext.record_error(updated_ctx, reason)
    jerr = normalize_channel_error(reason, "no_channels")
    duration = final_ctx.upstream_latency_ms || 0

    record_channel_failure_metrics(
      chain,
      channel.provider_id,
      method,
      ctx.strategy,
      jerr,
      duration,
      channel.transport
    )

    {:error, jerr, final_ctx}
  end

  # Handles normal mode request execution (with closed circuits)
  defp handle_normal_mode_request(chain, rpc_request, method, ctx, channels, timeout) do
    # Mark upstream start
    ctx = RequestContext.mark_upstream_start(ctx)

    case attempt_request_on_channels(channels, rpc_request, timeout, ctx) do
      {:ok, result, channel, updated_ctx} ->
        handle_normal_success(chain, method, ctx, result, channel, updated_ctx)

      {:error, reason, channel, _ctx1} ->
        handle_normal_failure(chain, method, ctx, reason, channel)

      {:error, :no_channels_available, _updated_ctx} ->
        handle_request_failure(ctx, :no_channels_available)
    end
  end

  # Handles successful request in normal mode
  defp handle_normal_success(chain, method, ctx, result, channel, updated_ctx) do
    updated_ctx = RequestContext.mark_upstream_end(updated_ctx)
    updated_ctx = RequestContext.record_success(updated_ctx, result)

    record_channel_success_metrics(
      chain,
      channel,
      method,
      ctx.strategy,
      updated_ctx.upstream_latency_ms || 0
    )

    {:ok, result, updated_ctx}
  end

  # Handles failed request in normal mode
  defp handle_normal_failure(chain, method, ctx, reason, channel) do
    updated_ctx = RequestContext.mark_upstream_end(ctx)
    final_ctx = RequestContext.record_error(updated_ctx, reason)
    jerr = normalize_channel_error(reason, "no_channels")
    duration = final_ctx.upstream_latency_ms || 0

    record_channel_failure_metrics(
      chain,
      channel.provider_id,
      method,
      ctx.strategy,
      jerr,
      duration,
      channel.transport
    )

    {:error, jerr, final_ctx}
  end

  # Handles generic request failures (no channels available)
  defp handle_request_failure(ctx, reason) do
    updated_ctx = RequestContext.mark_upstream_end(ctx)
    final_ctx = RequestContext.record_error(updated_ctx, reason)
    jerr = normalize_channel_error(reason, "no_channels")
    {:error, jerr, final_ctx}
  end

  defp get_provider_channels(chain, provider_id, transport_override) do
    transports =
      case transport_override do
        nil -> [:http, :ws]
        transport -> [transport]
      end

    transports
    |> Enum.map(fn transport ->
      try do
        case TransportRegistry.get_channel(chain, provider_id, transport) do
          {:ok, channel} -> channel
          {:error, _} -> nil
        end
      catch
        :exit, {:noproc, _} ->
          # Registry or chain supervisor not running
          nil

        :exit, _ ->
          # Other exit reasons
          nil
      end
    end)
    |> Enum.filter(&(&1 != nil))
  end

  defp attempt_request_on_channels([], _rpc_request, _timeout, ctx) do
    {:error, :no_channels_available, ctx}
  end

  defp attempt_request_on_channels([channel | rest_channels], rpc_request, timeout, ctx) do
    method = Map.get(rpc_request, "method")
    params = Map.get(rpc_request, "params")

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

  defp execute_channel_request(channel, rpc_request, timeout, ctx, rest_channels) do
    attempt_fun = fn -> Channel.request(channel, rpc_request, timeout) end

    cb_id =
      case channel.transport do
        :http -> {channel.chain, channel.provider_id, :http}
        :ws -> {channel.chain, channel.provider_id, :ws}
      end

    # Update context with selected provider (CB state captured later to avoid blocking)
    ctx = %{
      ctx
      | selected_provider: %{id: channel.provider_id, protocol: channel.transport},
        circuit_breaker_state: :unknown
    }

    # Log provider attempt
    Logger.debug("Attempting provider",
      request_id: ctx.request_id,
      channel: Channel.to_string(channel),
      method: Map.get(rpc_request, "method"),
      attempt: ctx.retries + 1,
      timeout_ms: timeout
    )

    result =
      try do
        CircuitBreaker.call(cb_id, attempt_fun, timeout)
      catch
        :exit, {:timeout, _} ->
          # GenServer.call timeout - convert to JSONRPC timeout error
          Logger.error("Request timeout on channel (GenServer.call)",
            request_id: ctx.request_id,
            channel: Channel.to_string(channel),
            method: Map.get(rpc_request, "method"),
            timeout: timeout
          )

          {:error, JError.new(-32_000, "Request timeout", category: :timeout, retriable?: true)}

        :exit, {:noproc, _} ->
          # Circuit breaker not started - log error and fail with non-retriable error
          Logger.error("Circuit breaker not found for channel - provider may not be initialized",
            channel: Channel.to_string(channel),
            circuit_breaker_id: inspect(cb_id)
          )

          {:error,
           JError.new(-32_000, "Provider not available",
             category: :provider_error,
             retriable?: true
           )}

        :exit, reason ->
          # Other exit reasons
          Logger.error("Circuit breaker unexpected exit",
            channel: Channel.to_string(channel),
            reason: inspect(reason)
          )

          {:error,
           JError.new(-32_000, "Circuit breaker error",
             category: :provider_error,
             retriable?: true
           )}
      end

    case result do
      # Circuit breaker wraps transport result: {:ok, {:ok, result, io_ms}}
      {:ok, {:ok, result, io_ms}} ->
        Logger.debug("✓ Request Success via #{Channel.to_string(channel)}",
          chain: ctx.chain,
          io_latency_ms: io_ms
        )

        log_slow_request_if_needed(
          io_ms,
          Map.get(rpc_request, "method"),
          channel,
          ctx
        )

        # Update context with explicit I/O latency from transport
        ctx = RequestContext.set_upstream_latency(ctx, io_ms)

        {:ok, result, channel, ctx}

      # Circuit breaker wraps transport error: {:ok, {:error, reason, io_ms}}
      {:ok, {:error, :unsupported_method, _io_ms}} ->
        # Fast fallthrough - try next channel immediately (no I/O was performed)
        Logger.debug("Method not supported on channel, trying next",
          channel: Channel.to_string(channel),
          method: Map.get(rpc_request, "method")
        )

        attempt_request_on_channels(rest_channels, rpc_request, timeout, ctx)

      {:ok, {:error, reason, io_ms}} ->
        Logger.debug("Request error via #{Channel.to_string(channel)}",
          reason: inspect(reason),
          chain: ctx.chain,
          io_latency_ms: io_ms
        )

        ctx = RequestContext.set_upstream_latency(ctx, io_ms)

        # Determine if this error should trigger fast-fail (immediate failover)
        # or if we've exhausted all channels
        {should_failover, failover_reason} = should_fast_fail_error?(reason, rest_channels)

        if should_failover do
          # Fast-fail: skip to next channel immediately (< 10ms)
          Logger.info("Fast-failing to next channel",
            channel: Channel.to_string(channel),
            error_category: extract_error_category(reason),
            reason: failover_reason,
            remaining_channels: length(rest_channels),
            chain: ctx.chain
          )

          # Emit telemetry for fast-fail events
          :telemetry.execute(
            [:lasso, :failover, :fast_fail],
            %{count: 1},
            %{
              chain: ctx.chain,
              provider_id: channel.provider_id,
              transport: channel.transport,
              error_category: extract_error_category(reason)
            }
          )

          # Increment retries and try next channel
          ctx = RequestContext.increment_retries(ctx)
          attempt_request_on_channels(rest_channels, rpc_request, timeout, ctx)
        else
          # No more channels or non-retriable error
          Logger.warning("Channel request failed - no failover",
            channel: Channel.to_string(channel),
            error: inspect(reason),
            reason: failover_reason,
            remaining_channels: length(rest_channels),
            chain: ctx.chain
          )

          {:error, reason, channel, ctx}
        end

      # Direct errors from circuit breaker (not from transport)
      # These include :circuit_open and errors from catch blocks
      {:error, reason} ->
        Logger.debug("Circuit breaker error via #{Channel.to_string(channel)}",
          reason: inspect(reason),
          chain: ctx.chain
        )

        # No I/O latency since we never reached the transport
        ctx = RequestContext.set_upstream_latency(ctx, 0)

        {should_failover, failover_reason} = should_fast_fail_error?(reason, rest_channels)

        if should_failover do
          Logger.info("Fast-failing to next channel (circuit breaker error)",
            channel: Channel.to_string(channel),
            error_category: extract_error_category(reason),
            reason: failover_reason,
            remaining_channels: length(rest_channels),
            chain: ctx.chain
          )

          :telemetry.execute(
            [:lasso, :failover, :fast_fail],
            %{count: 1},
            %{
              chain: ctx.chain,
              provider_id: channel.provider_id,
              transport: channel.transport,
              error_category: extract_error_category(reason)
            }
          )

          ctx = RequestContext.increment_retries(ctx)
          attempt_request_on_channels(rest_channels, rpc_request, timeout, ctx)
        else
          Logger.warning("Channel request failed - no failover (circuit breaker)",
            channel: Channel.to_string(channel),
            error: inspect(reason),
            reason: failover_reason,
            remaining_channels: length(rest_channels),
            chain: ctx.chain
          )

          {:error, reason, channel, ctx}
        end

      :circuit_open ->
        # Circuit breaker is open - fast fail to next provider
        Logger.info("Circuit breaker open, fast-failing to next channel",
          channel: Channel.to_string(channel),
          chain: ctx.chain
        )

        ctx = RequestContext.set_upstream_latency(ctx, 0)
        ctx = RequestContext.increment_retries(ctx)

        :telemetry.execute(
          [:lasso, :failover, :circuit_open],
          %{count: 1},
          %{
            chain: ctx.chain,
            provider_id: channel.provider_id,
            transport: channel.transport
          }
        )

        attempt_request_on_channels(rest_channels, rpc_request, timeout, ctx)
    end
  end

  defp try_channel_failover(chain, rpc_request, strategy, excluded_providers, attempt, timeout) do
    if attempt > @max_failover_attempts do
      {:error, JError.new(-32_000, "Failover limit reached")}
    else
      method = Map.get(rpc_request, "method")

      channels =
        Selection.select_channels(chain, method,
          strategy: strategy,
          transport: :both,
          exclude: excluded_providers,
          limit: @max_channel_candidates
        )

      case channels do
        [] ->
          {:error, JError.new(-32_000, "No more channels available for failover")}

        _ ->
          ctx =
            RequestContext.new(chain, method,
              strategy: strategy,
              transport: :both
            )

          case attempt_request_on_channels(channels, rpc_request, timeout, ctx) do
            {:ok, result, _channel, _updated_ctx} ->
              # Consider logging or returning context for observability
              {:ok, result}

            {:error, :no_channels_available, _ctx} ->
              # No channels available, keep trying with new attempt
              try_channel_failover(
                chain,
                rpc_request,
                strategy,
                excluded_providers,
                attempt + 1,
                timeout
              )

            {:error, _reason, _channel, _ctx} ->
              # Channel-specific error, keep trying with new attempt
              try_channel_failover(
                chain,
                rpc_request,
                strategy,
                excluded_providers,
                attempt + 1,
                timeout
              )
          end
      end
    end
  end

  defp record_channel_success_metrics(chain, channel, method, strategy, duration_ms) do
    provider_id = channel.provider_id
    transport = channel.transport

    # Record with transport dimension
    Metrics.record_success(chain, provider_id, method, duration_ms, transport: transport)
    ProviderPool.report_success(chain, provider_id, transport)

    publish_channel_routing_decision(
      chain,
      method,
      strategy,
      provider_id,
      transport,
      duration_ms,
      :success,
      0
    )

    :telemetry.execute(
      [:lasso, :rpc, :request, :stop],
      %{duration: duration_ms},
      %{
        chain: chain,
        method: method,
        strategy: strategy,
        provider_id: provider_id,
        transport: transport,
        result: :success,
        failovers: 0
      }
    )
  end

  defp record_channel_failure_metrics(chain, provider_id, method, strategy, reason, duration_ms) do
    # We may not always know the transport here; leave as legacy for now
    record_rpc_failure(chain, provider_id, method, reason, duration_ms)

    :telemetry.execute(
      [:lasso, :rpc, :request, :stop],
      %{duration: duration_ms},
      %{
        chain: chain,
        method: method,
        strategy: strategy,
        provider_id: provider_id,
        transport: :unknown,
        result: :error,
        failovers: 0
      }
    )
  end

  defp record_channel_failure_metrics(
         chain,
         provider_id,
         method,
         strategy,
         reason,
         duration_ms,
         transport
       ) do
    record_rpc_failure(chain, provider_id, method, reason, duration_ms, transport)

    :telemetry.execute(
      [:lasso, :rpc, :request, :stop],
      %{duration: duration_ms},
      %{
        chain: chain,
        method: method,
        strategy: strategy,
        provider_id: provider_id,
        transport: transport,
        result: :error,
        failovers: 0
      }
    )
  end

  defp publish_channel_routing_decision(
         chain,
         method,
         strategy,
         provider_id,
         transport,
         duration_ms,
         result,
         failovers
       ) do
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "routing:decisions",
      %{
        ts: System.system_time(:millisecond),
        chain: chain,
        method: method,
        strategy: to_string(strategy),
        provider_id: provider_id,
        transport: transport,
        duration_ms: duration_ms,
        result: result,
        failover_count: failovers
      }
    )
  end

  defp normalize_channel_error(reason, provider_id) do
    case reason do
      %JError{} = jerr -> jerr
      other -> JError.from(other, provider_id: provider_id)
    end
  end

  # ===========================================================================
  # Fast-Fail Logic for Failover Optimization
  # ===========================================================================

  # Determines if an error should trigger immediate failover (fast-fail) to the next channel.
  #
  # Fast-fail categories eliminate timeout stacking by skipping to the next provider
  # immediately (<10ms) instead of waiting for full timeout (1-2s).
  #
  # Fast-fail categories:
  # - :rate_limit - Provider explicitly said quota exceeded
  # - :circuit_open - Circuit already open, provider unavailable
  # - :auth_error - Authentication failed, won't work on retry
  # - :server_error - 5xx indicates provider issue (if retriable)
  # - :network_error - Connection/timeout already occurred
  # - :capability_violation - Provider doesn't support this request
  # - :timeout - Already waited for timeout, no point waiting more
  #
  # Returns:
  # - {true, reason} - Should fast-fail with reason
  # - {false, reason} - Should not failover (no channels or non-retriable)
  @spec should_fast_fail_error?(any(), list()) :: {boolean(), atom()}
  defp should_fast_fail_error?(_reason, []) do
    # No more channels to try
    {false, :no_channels_remaining}
  end

  defp should_fast_fail_error?(%JError{} = error, _rest_channels) do
    cond do
      # Non-retriable errors should not trigger failover
      not error.retriable? ->
        {false, :non_retriable_error}

      # Fast-fail categories - these errors indicate immediate provider unavailability
      error.category == :rate_limit ->
        {true, :rate_limit_detected}

      error.category == :server_error ->
        {true, :server_error_detected}

      error.category == :network_error ->
        {true, :network_error_detected}

      error.category == :timeout ->
        {true, :timeout_detected}

      error.category == :auth_error ->
        {true, :auth_error_detected}

      error.category == :capability_violation ->
        {true, :capability_violation_detected}

      # Other retriable errors also fast-fail (conservative approach)
      true ->
        {true, :retriable_error}
    end
  end

  defp should_fast_fail_error?(:circuit_open, _rest_channels) do
    # Circuit already open - fast-fail to next provider
    {true, :circuit_open}
  end

  defp should_fast_fail_error?(_reason, _rest_channels) do
    # Unknown error format - don't failover (conservative)
    {false, :unknown_error_format}
  end

  # Extracts error category for telemetry and logging.
  @spec extract_error_category(any()) :: atom()
  defp extract_error_category(%JError{category: category}), do: category || :unknown
  defp extract_error_category(:circuit_open), do: :circuit_open
  defp extract_error_category(_), do: :unknown

  # Logs slow requests based on configured thresholds.
  # Thresholds:
  # - ERROR: > 4000ms (4 seconds) - May cause client timeouts
  # - WARN:  > 2000ms (2 seconds)
  # - INFO:  > 1000ms (1 second)
  defp log_slow_request_if_needed(latency_ms, method, channel, ctx) do
    cond do
      latency_ms > 4000 ->
        Logger.error("VERY SLOW request detected (may timeout clients)",
          request_id: ctx.request_id,
          method: method,
          provider: channel.provider_id,
          transport: channel.transport,
          chain: ctx.chain,
          latency_ms: latency_ms,
          threshold: "4s"
        )

        :telemetry.execute(
          [:lasso, :request, :very_slow],
          %{latency_ms: latency_ms},
          %{
            chain: ctx.chain,
            method: method,
            provider: channel.provider_id,
            transport: channel.transport
          }
        )

      latency_ms > 2000 ->
        Logger.warning("Slow request detected",
          request_id: ctx.request_id,
          method: method,
          provider: channel.provider_id,
          transport: channel.transport,
          chain: ctx.chain,
          latency_ms: latency_ms,
          threshold: "2s"
        )

        :telemetry.execute(
          [:lasso, :request, :slow],
          %{latency_ms: latency_ms},
          %{
            chain: ctx.chain,
            method: method,
            provider: channel.provider_id,
            transport: channel.transport
          }
        )

      latency_ms > 1000 ->
        Logger.info("Elevated latency detected",
          request_id: ctx.request_id,
          method: method,
          provider: channel.provider_id,
          transport: channel.transport,
          chain: ctx.chain,
          latency_ms: latency_ms
        )

      true ->
        :ok
    end
  end

  # Calculates the minimum recovery time across all circuit breakers for a chain.
  # Returns the shortest time until any circuit breaker will attempt recovery,
  # or nil if no recovery times are available.
  #
  # This now uses the cached recovery times in ProviderPool (single GenServer call)
  # instead of making N sequential calls to each CircuitBreaker.
  @spec calculate_min_recovery_time(String.t(), atom() | nil) :: non_neg_integer() | nil
  defp calculate_min_recovery_time(chain, transport_filter) do
    transport =
      case transport_filter do
        nil -> :both
        t -> t
      end

    case ProviderPool.get_min_recovery_time(chain, transport: transport, timeout: 2000) do
      {:ok, min_time} ->
        min_time

      {:error, :timeout} ->
        Logger.warning("Timeout calculating recovery time for chain #{chain}, using default",
          chain: chain
        )

        # Default fallback: 60 second retry-after on timeout
        60_000

      {:error, reason} ->
        Logger.warning("Failed to get recovery times for chain #{chain}",
          chain: chain,
          reason: inspect(reason)
        )

        nil
    end
  end
end

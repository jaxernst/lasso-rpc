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

  alias Lasso.RPC.{Selection, ProviderPool, Metrics, TransportRegistry, Channel}
  alias Lasso.RPC.{RequestContext, Observability, CircuitBreaker}
  alias Lasso.JSONRPC.Error, as: JError

  @type chain :: String.t()
  @type method :: String.t()
  @type params :: list()

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

          RequestContext.new(chain, method,
            params_present: params != [] and not is_nil(params),
            params_digest: params_digest,
            transport: transport_override || :http,
            strategy: strategy
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
        case execute_with_channel_selection(chain, rpc_request, ctx, transport_override, timeout) do
          {:ok, result, updated_ctx} ->
            # Emit observability log
            Observability.log_request_completed(updated_ctx)
            # Store context for controller access (if needed for response metadata)
            Process.put(:request_context, updated_ctx)
            {:ok, result}

          {:error, reason, updated_ctx} ->
            # Emit observability log for errors too
            Observability.log_request_completed(updated_ctx)
            # Store context for controller access
            Process.put(:request_context, updated_ctx)
            {:error, reason}
        end
    end
  end

  defp record_rpc_failure(chain, provider_id, method, reason, duration_ms) do
    Metrics.record_failure(chain, provider_id, method, duration_ms)
    ProviderPool.report_failure(chain, provider_id, reason)
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
        {:ok, result}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - start_time
        jerr = normalize_channel_error(reason, provider_id)
        record_channel_failure_metrics(chain, provider_id, method, strategy, jerr, duration_ms)

        should_failover =
          case jerr do
            %Lasso.JSONRPC.Error{retriable?: retriable?} -> retriable?
            _ -> false
          end

        if failover_on_override and should_failover do
          try_channel_failover(
            chain,
            rpc_request,
            strategy,
            [provider_id],
            1,
            timeout
          )
        else
          {:error, jerr}
        end
    end
  end

  defp execute_with_channel_selection(chain, rpc_request, ctx, transport_override, timeout) do
    method = Map.get(rpc_request, "method")

    # Mark selection start
    ctx = RequestContext.mark_selection_start(ctx)

    # Get candidate channels from unified Selection
    channels =
      Selection.select_channels(chain, method,
        strategy: ctx.strategy,
        transport: transport_override || :both,
        limit: 10
      )

    # Update context with selection metadata
    ctx =
      RequestContext.mark_selection_end(ctx,
        candidates: Enum.map(channels, &"#{&1.provider_id}:#{&1.transport}"),
        selected: if(length(channels) > 0, do: List.first(channels), else: nil)
      )

    case channels do
      [] ->
        updated_ctx =
          RequestContext.record_error(ctx, JError.new(-32000, "No available channels"))

        {:error, JError.new(-32000, "No available channels for method: #{method}"), updated_ctx}

      _ ->
        # Mark upstream start and attempt request
        ctx = RequestContext.mark_upstream_start(ctx)

        case attempt_request_on_channels(channels, rpc_request, timeout, ctx) do
          {:ok, result, channel, updated_ctx} ->
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

          {:error, reason} ->
            updated_ctx = RequestContext.mark_upstream_end(ctx)
            final_ctx = RequestContext.record_error(updated_ctx, reason)
            jerr = normalize_channel_error(reason, "no_channels")
            {:error, jerr, final_ctx}
        end
    end
  end

  defp get_provider_channels(chain, provider_id, transport_override) do
    transports =
      case transport_override do
        nil -> [:http, :ws]
        transport -> [transport]
      end

    transports
    |> Enum.map(fn transport ->
      case TransportRegistry.get_channel(chain, provider_id, transport) do
        {:ok, channel} -> channel
        {:error, _} -> nil
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
    case Lasso.RPC.Providers.AdapterFilter.validate_params(channel, method, params) do
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
        :http -> {channel.provider_id, :http}
        :ws -> {channel.provider_id, :ws}
      end

    # Update context with selected provider (CB state captured later to avoid blocking)
    ctx = %{
      ctx
      | selected_provider: %{id: channel.provider_id, protocol: channel.transport},
        circuit_breaker_state: :unknown
    }

    case CircuitBreaker.call(cb_id, attempt_fun, timeout + 1_000) do
      {:ok, result} ->
        Logger.debug("✓ Request Success via #{Channel.to_string(channel)}", result: result)
        {:ok, result, channel, ctx}

      {:error, :unsupported_method} ->
        # Fast fallthrough - try next channel immediately
        Logger.debug("Method not supported on channel, trying next",
          channel: Channel.to_string(channel),
          method: Map.get(rpc_request, "method")
        )

        attempt_request_on_channels(rest_channels, rpc_request, timeout, ctx)

      {:error, reason} ->
        Logger.warning("Channel request failed",
          channel: Channel.to_string(channel),
          error: inspect(reason),
          retriable: false,
          remaining_channels: length(rest_channels)
        )

        # Check if error is retriable and we have more channels to try
        should_retry =
          case reason do
            %JError{retriable?: true} -> true
            _ -> false
          end

        if should_retry and rest_channels != [] do
          Logger.info("Retriable error on channel, failing over to next",
            channel: Channel.to_string(channel),
            error: inspect(reason),
            remaining_channels: length(rest_channels)
          )

          # Increment retries and try next channel
          ctx = RequestContext.increment_retries(ctx)
          attempt_request_on_channels(rest_channels, rpc_request, timeout, ctx)
        else
          Logger.warning("Channel request failed - no failover",
            channel: Channel.to_string(channel),
            error: inspect(reason),
            retriable: should_retry,
            remaining_channels: length(rest_channels)
          )

          {:error, reason}
        end
    end
  end

  defp try_channel_failover(chain, rpc_request, strategy, excluded_providers, attempt, timeout) do
    # Could be configurable
    max_attempts = 3

    if attempt > max_attempts do
      {:error, JError.new(-32000, "Failover limit reached")}
    else
      method = Map.get(rpc_request, "method")

      channels =
        Selection.select_channels(chain, method,
          strategy: strategy,
          transport: :both,
          exclude: excluded_providers,
          limit: 10
        )

      case channels do
        [] ->
          {:error, JError.new(-32000, "No more channels available for failover")}

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

            {:error, _reason} ->
              # Conservative: keep exclusions unchanged and bump attempt
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
    ProviderPool.report_success(chain, provider_id)

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
      %{duration_ms: duration_ms},
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
    # For now, we don't know the transport that failed, so use legacy metrics
    record_rpc_failure(chain, provider_id, method, reason, duration_ms)

    :telemetry.execute(
      [:lasso, :rpc, :request, :stop],
      %{duration_ms: duration_ms},
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
end

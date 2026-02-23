defmodule Lasso.RPC.RequestPipeline.Observability do
  @moduledoc """
  Centralized observability for request pipeline events.

  Handles all telemetry, metrics recording, and structured logging for the request pipeline.
  This module consolidates scattered observability concerns into a single source of truth,
  making it easier to:
  - Modify telemetry schemas
  - Add new monitoring dimensions
  - Test observability in isolation
  - Maintain consistent event structure

  Events are published to profile-scoped PubSub topics to support multi-tenant
  dashboard subscriptions without cross-tenant data leakage.
  """

  require Logger

  alias Lasso.Core.Benchmarking.Metrics
  alias Lasso.Events.RoutingDecision
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{Channel, ProviderPool, RequestContext}

  @type telemetry_metadata :: %{
          chain: String.t(),
          method: String.t(),
          strategy: atom(),
          provider_id: String.t(),
          transport: atom(),
          result: atom(),
          failovers: non_neg_integer()
        }

  @doc """
  Records a successful channel request with all observability concerns.

  Emits metrics, telemetry events, and PubSub notifications for successful requests.
  """
  @spec record_success(RequestContext.t(), Channel.t(), String.t(), atom(), non_neg_integer()) ::
          :ok
  def record_success(
        ctx,
        %Channel{provider_id: provider_id, transport: transport},
        method,
        strategy,
        duration_ms
      ) do
    profile = ctx.opts.profile

    # Record metrics with transport dimension
    Metrics.record_success(profile, ctx.chain, provider_id, method, duration_ms,
      transport: transport
    )

    ProviderPool.report_success(profile, ctx.chain, provider_id, transport)

    # Publish routing decision for dashboard/analytics (profile-scoped)
    publish_routing_decision(
      request_id: ctx.request_id,
      account_id: ctx.account_id,
      profile: profile,
      chain: ctx.chain,
      method: method,
      strategy: strategy,
      provider_id: provider_id,
      transport: transport,
      duration_ms: duration_ms,
      result: :success,
      failovers: ctx.retries
    )

    # Emit telemetry for observability stack
    emit_request_telemetry(
      ctx.chain,
      method,
      strategy,
      provider_id,
      transport,
      duration_ms,
      :success,
      ctx.retries
    )

    :ok
  end

  @doc """
  Records a failed channel request with all observability concerns.

  Emits metrics, telemetry events, and PubSub notifications for failed requests.
  Handles both variants: with and without transport information.
  """
  @spec record_failure(
          RequestContext.t(),
          Channel.t() | String.t(),
          String.t(),
          atom(),
          term(),
          non_neg_integer()
        ) :: :ok
  def record_failure(ctx, channel_or_provider_id, method, strategy, reason, duration_ms)

  # Variant with full channel info (has transport)
  def record_failure(
        ctx,
        %Channel{provider_id: provider_id, transport: transport} = _channel,
        method,
        strategy,
        reason,
        duration_ms
      ) do
    profile = ctx.opts.profile

    # Record failure with transport dimension
    record_rpc_failure(profile, ctx.chain, provider_id, method, reason, duration_ms, transport)

    # Publish routing decision (profile-scoped)
    publish_routing_decision(
      request_id: ctx.request_id,
      account_id: ctx.account_id,
      profile: profile,
      chain: ctx.chain,
      method: method,
      strategy: strategy,
      provider_id: provider_id,
      transport: transport,
      duration_ms: duration_ms,
      result: :error,
      failovers: ctx.retries
    )

    # Emit telemetry
    emit_request_telemetry(
      ctx.chain,
      method,
      strategy,
      provider_id,
      transport,
      duration_ms,
      :error,
      ctx.retries
    )

    :ok
  end

  # Variant with just provider_id (no transport info - legacy path)
  def record_failure(ctx, provider_id, method, strategy, reason, duration_ms)
      when is_binary(provider_id) do
    profile = ctx.opts.profile

    # Record failure without transport dimension
    record_rpc_failure(profile, ctx.chain, provider_id, method, reason, duration_ms, nil)

    # Emit telemetry with unknown transport
    emit_request_telemetry(
      ctx.chain,
      method,
      strategy,
      provider_id,
      :unknown,
      duration_ms,
      :error,
      ctx.retries
    )

    :ok
  end

  @doc """
  Records a fast-fail event when failing over to next channel.

  Emits telemetry for failover events with error categorization,
  and records the failure in metrics so per-provider success rates
  reflect all attempts (not just final responses).
  """
  @spec record_fast_fail(RequestContext.t(), Channel.t(), atom(), term(), non_neg_integer()) ::
          :ok
  def record_fast_fail(
        ctx,
        %Channel{provider_id: provider_id, transport: transport},
        failover_reason,
        error_reason,
        duration_ms
      ) do
    profile = ctx.opts.profile

    :telemetry.execute(
      [:lasso, :failover, :fast_fail],
      %{count: 1},
      %{
        chain: ctx.chain,
        method: ctx.method,
        request_id: ctx.request_id,
        provider_id: provider_id,
        transport: transport,
        error_category: extract_error_category(error_reason),
        failover_reason: failover_reason
      }
    )

    # Record failure in metrics so dashboard success rates reflect this attempt
    Metrics.record_failure(profile, ctx.chain, provider_id, ctx.method, duration_ms,
      transport: transport
    )

    # Report failure to ProviderPool (which will update circuit breaker)
    jerr = JError.from(error_reason, provider_id: provider_id)
    ProviderPool.report_failure(profile, ctx.chain, provider_id, jerr, transport)

    :ok
  end

  @doc """
  Records a circuit breaker open event during failover.
  """
  @spec record_circuit_open(RequestContext.t(), Channel.t()) :: :ok
  def record_circuit_open(ctx, %Channel{provider_id: provider_id, transport: transport}) do
    :telemetry.execute(
      [:lasso, :failover, :circuit_open],
      %{count: 1},
      %{chain: ctx.chain, provider_id: provider_id, transport: transport}
    )

    :ok
  end

  @doc """
  Records request start telemetry.
  """
  @spec record_request_start(String.t(), String.t(), atom(), String.t() | nil) :: :ok
  def record_request_start(chain, method, strategy, provider_id \\ nil) do
    metadata = %{
      chain: chain,
      method: method,
      strategy: strategy
    }

    metadata = if provider_id, do: Map.put(metadata, :provider_id, provider_id), else: metadata

    :telemetry.execute([:lasso, :rpc, :request, :start], %{count: 1}, metadata)

    :ok
  end

  @doc """
  Records when entering degraded mode (attempting half-open circuits).
  """
  @spec record_degraded_mode(String.t(), String.t()) :: :ok
  def record_degraded_mode(chain, method) do
    :telemetry.execute(
      [:lasso, :failover, :degraded_mode],
      %{count: 1},
      %{chain: chain, method: method}
    )

    :ok
  end

  @doc """
  Records successful request via degraded mode (half-open circuit).
  """
  @spec record_degraded_success(String.t(), String.t(), Channel.t()) :: :ok
  def record_degraded_success(chain, method, %Channel{
        provider_id: provider_id,
        transport: transport
      }) do
    :telemetry.execute(
      [:lasso, :failover, :degraded_success],
      %{count: 1},
      %{chain: chain, method: method, provider_id: provider_id, transport: transport}
    )

    :ok
  end

  @doc """
  Records channel exhaustion (all circuits open).
  """
  @spec record_exhaustion(String.t(), String.t(), atom(), non_neg_integer() | nil) :: :ok
  def record_exhaustion(chain, method, transport, retry_after_ms) do
    :telemetry.execute(
      [:lasso, :failover, :exhaustion],
      %{count: 1},
      %{
        chain: chain,
        method: method,
        retry_after_ms: retry_after_ms || 0,
        transport: transport || :both
      }
    )

    :ok
  end

  @doc """
  Records slow request (>2000ms) telemetry.
  """
  @spec record_slow_request(String.t(), String.t(), String.t(), atom(), float()) :: :ok
  def record_slow_request(chain, method, provider_id, transport, latency_ms) do
    :telemetry.execute(
      [:lasso, :request, :slow],
      %{latency_ms: latency_ms},
      %{
        chain: chain,
        method: method,
        provider: provider_id,
        transport: transport
      }
    )

    :ok
  end

  @doc """
  Records very slow request (>4000ms) telemetry.
  """
  @spec record_very_slow_request(String.t(), String.t(), String.t(), atom(), float()) :: :ok
  def record_very_slow_request(chain, method, provider_id, transport, latency_ms) do
    :telemetry.execute(
      [:lasso, :request, :very_slow],
      %{latency_ms: latency_ms},
      %{
        chain: chain,
        method: method,
        provider: provider_id,
        transport: transport
      }
    )

    :ok
  end

  # Private helpers

  @spec publish_routing_decision(keyword()) :: :ok | {:error, term()}
  defp publish_routing_decision(opts) do
    event =
      RoutingDecision.new(
        request_id: opts[:request_id],
        account_id: opts[:account_id],
        profile: opts[:profile],
        chain: opts[:chain],
        method: opts[:method],
        strategy: opts[:strategy],
        provider_id: opts[:provider_id],
        transport: opts[:transport],
        duration_ms: opts[:duration_ms],
        result: opts[:result],
        failover_count: opts[:failovers]
      )

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      RoutingDecision.topic(opts[:profile]),
      event
    )
  end

  @spec emit_request_telemetry(
          String.t(),
          String.t(),
          atom(),
          String.t(),
          atom(),
          non_neg_integer(),
          atom(),
          non_neg_integer()
        ) :: :ok
  defp emit_request_telemetry(
         chain,
         method,
         strategy,
         provider_id,
         transport,
         duration_ms,
         result,
         failovers
       ) do
    :telemetry.execute(
      [:lasso, :rpc, :request, :stop],
      %{duration: duration_ms},
      %{
        chain: chain,
        method: method,
        strategy: strategy,
        provider_id: provider_id,
        transport: transport,
        result: result,
        failovers: failovers
      }
    )
  end

  @spec record_rpc_failure(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          term(),
          non_neg_integer(),
          atom() | nil
        ) :: :ok
  defp record_rpc_failure(profile, chain, provider_id, method, reason, duration_ms, transport) do
    # Record failure metrics
    Metrics.record_failure(profile, chain, provider_id, method, duration_ms, transport: transport)

    # Normalize to JError and report to provider pool
    jerr = JError.from(reason, provider_id: provider_id)
    ProviderPool.report_failure(profile, chain, provider_id, jerr, transport)
  end

  @spec extract_error_category(term()) :: atom()
  defp extract_error_category(%JError{category: category}), do: category || :unknown
  defp extract_error_category(_), do: :unknown
end

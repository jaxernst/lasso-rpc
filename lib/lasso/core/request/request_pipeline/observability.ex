defmodule Lasso.RPC.RequestPipeline.Observability do
  @moduledoc """
  Centralized observability for request pipeline events.

  Handles all telemetry, metrics recording, and structured logging for the request pipeline.
  This module consolidates scattered observability concerns into a single source of truth.

  ## ETS Writes

  On success/failure, writes health counters and rate limit state directly to
  `:lasso_instance_state` ETS. Publishes provider health events to PubSub
  for dashboard live updates.
  """

  require Logger

  alias Lasso.Core.Benchmarking.Metrics
  alias Lasso.Core.Support.ErrorClassification
  alias Lasso.Events.Provider
  alias Lasso.Events.RoutingDecision
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.{Channel, RateLimitState, RequestContext}

  @type telemetry_metadata :: %{
          chain_id: pos_integer(),
          method: String.t(),
          strategy: atom(),
          provider_id: String.t(),
          transport: atom(),
          result: atom(),
          failovers: non_neg_integer()
        }

  @doc """
  Records a successful channel request with all observability concerns.
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

    Metrics.record_success(profile, ctx.chain_id, provider_id, method, duration_ms,
      transport: transport
    )

    instance_id = Catalog.lookup_instance_id(profile, ctx.chain_id, provider_id)
    report_success_to_ets(instance_id, transport)

    publish_routing_decision(
      request_id: ctx.request_id,
      profile: profile,
      chain_id: ctx.chain_id,
      method: method,
      strategy: strategy,
      provider_id: provider_id,
      transport: transport,
      duration_ms: duration_ms,
      result: :success,
      failovers: ctx.retries
    )

    emit_request_telemetry(
      ctx.chain_id,
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

  def record_failure(
        ctx,
        %Channel{provider_id: provider_id, transport: transport} = _channel,
        method,
        strategy,
        reason,
        duration_ms
      ) do
    profile = ctx.opts.profile
    jerr = JError.from(reason, provider_id: provider_id)

    if ErrorClassification.provider_health_failure?(jerr.category) do
      Metrics.record_failure(profile, ctx.chain_id, provider_id, method, duration_ms,
        transport: transport
      )
    end

    instance_id = Catalog.lookup_instance_id(profile, ctx.chain_id, provider_id)
    report_failure_to_ets(instance_id, transport, jerr, profile, ctx.chain_id, provider_id)

    publish_routing_decision(
      request_id: ctx.request_id,
      profile: profile,
      chain_id: ctx.chain_id,
      method: method,
      strategy: strategy,
      provider_id: provider_id,
      transport: transport,
      duration_ms: duration_ms,
      result: :error,
      failovers: ctx.retries
    )

    emit_request_telemetry(
      ctx.chain_id,
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

  def record_failure(ctx, provider_id, _method, _strategy, _reason, _duration_ms)
      when is_binary(provider_id) do
    Logger.warning("record_failure called with bare provider_id, skipping metrics",
      provider_id: provider_id,
      chain_id: ctx.chain_id
    )

    :ok
  end

  @doc """
  Records a fast-fail event when failing over to next channel.
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
      %{count: 1, duration: duration_ms},
      %{
        chain_id: ctx.chain_id,
        method: ctx.method,
        request_id: ctx.request_id,
        provider_id: provider_id,
        transport: transport,
        error_category: extract_error_category(error_reason),
        failover_reason: failover_reason
      }
    )

    instance_id = Catalog.lookup_instance_id(profile, ctx.chain_id, provider_id)
    jerr = JError.from(error_reason, provider_id: provider_id)
    report_failure_to_ets(instance_id, transport, jerr, profile, ctx.chain_id, provider_id)

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
      %{chain_id: ctx.chain_id, provider_id: provider_id, transport: transport}
    )

    :ok
  end

  @doc """
  Records request start telemetry.
  """
  @spec record_request_start(pos_integer(), String.t(), atom(), String.t() | nil) :: :ok
  def record_request_start(chain_id, method, strategy, provider_id \\ nil) do
    metadata = %{chain_id: chain_id, method: method, strategy: strategy}
    metadata = if provider_id, do: Map.put(metadata, :provider_id, provider_id), else: metadata
    :telemetry.execute([:lasso, :rpc, :request, :start], %{count: 1}, metadata)
    :ok
  end

  @doc """
  Records when entering degraded mode (attempting half-open circuits).
  """
  @spec record_degraded_mode(pos_integer(), String.t()) :: :ok
  def record_degraded_mode(chain_id, method) do
    :telemetry.execute(
      [:lasso, :failover, :degraded_mode],
      %{count: 1},
      %{chain_id: chain_id, method: method}
    )

    :ok
  end

  @doc """
  Records successful request via degraded mode (half-open circuit).
  """
  @spec record_degraded_success(pos_integer(), String.t(), Channel.t()) :: :ok
  def record_degraded_success(chain_id, method, %Channel{
        provider_id: provider_id,
        transport: transport
      }) do
    :telemetry.execute(
      [:lasso, :failover, :degraded_success],
      %{count: 1},
      %{chain_id: chain_id, method: method, provider_id: provider_id, transport: transport}
    )

    :ok
  end

  @doc """
  Records channel exhaustion (all circuits open).
  """
  @spec record_exhaustion(pos_integer(), String.t(), atom(), non_neg_integer() | nil) :: :ok
  def record_exhaustion(chain_id, method, transport, retry_after_ms) do
    :telemetry.execute(
      [:lasso, :failover, :exhaustion],
      %{count: 1},
      %{
        chain_id: chain_id,
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
  @spec record_slow_request(pos_integer(), String.t(), String.t(), atom(), float()) :: :ok
  def record_slow_request(chain_id, method, provider_id, transport, latency_ms) do
    :telemetry.execute(
      [:lasso, :request, :slow],
      %{latency_ms: latency_ms},
      %{chain_id: chain_id, method: method, provider: provider_id, transport: transport}
    )

    :ok
  end

  @doc """
  Records very slow request (>4000ms) telemetry.
  """
  @spec record_very_slow_request(pos_integer(), String.t(), String.t(), atom(), float()) :: :ok
  def record_very_slow_request(chain_id, method, provider_id, transport, latency_ms) do
    :telemetry.execute(
      [:lasso, :request, :very_slow],
      %{latency_ms: latency_ms},
      %{chain_id: chain_id, method: method, provider: provider_id, transport: transport}
    )

    :ok
  end

  # ETS write helpers

  defp report_success_to_ets(nil, _transport), do: :ok

  defp report_success_to_ets(instance_id, transport) do
    now = System.system_time(:millisecond)

    clear_expired_rate_limit(instance_id, transport)

    existing =
      case :ets.lookup(:lasso_instance_state, {:health_routing, instance_id}) do
        [{_, data}] -> data
        [] -> %{}
      end

    merged =
      Map.merge(existing, %{
        status: :healthy,
        last_health_check: now,
        consecutive_failures: 0,
        consecutive_successes: Map.get(existing, :consecutive_successes, 0) + 1,
        last_error: nil
      })

    :ets.insert(:lasso_instance_state, {{:health_routing, instance_id}, merged})
  end

  defp report_failure_to_ets(nil, _transport, _jerr, _profile, _chain_id, _provider_id), do: :ok

  defp report_failure_to_ets(instance_id, transport, jerr, profile, chain_id, provider_id) do
    cond do
      jerr.category == :rate_limit ->
        retry_after_ms = RateLimitState.extract_retry_after(jerr.data)
        now_ms = System.monotonic_time(:millisecond)
        new_expiry = now_ms + (retry_after_ms || 30_000)

        case :ets.lookup(:lasso_instance_state, {:rate_limit, instance_id, transport}) do
          [{_, %{expiry_ms: existing}}] when existing >= new_expiry ->
            :ok

          _ ->
            :ets.insert(:lasso_instance_state, {
              {:rate_limit, instance_id, transport},
              %{expiry_ms: new_expiry, retry_after_ms: retry_after_ms || 30_000}
            })
        end

        publish_provider_event(profile, chain_id, provider_id, :rate_limited)

      not ErrorClassification.breaker_penalty?(jerr.category) ->
        :ok

      true ->
        existing =
          case :ets.lookup(:lasso_instance_state, {:health_routing, instance_id}) do
            [{_, data}] -> data
            [] -> %{}
          end

        new_failures = Map.get(existing, :consecutive_failures, 0) + 1
        new_status = if new_failures >= 3, do: :unhealthy, else: :degraded
        now = System.system_time(:millisecond)

        merged =
          Map.merge(existing, %{
            status: new_status,
            last_health_check: now,
            consecutive_failures: new_failures,
            consecutive_successes: 0,
            last_error: jerr
          })

        :ets.insert(:lasso_instance_state, {{:health_routing, instance_id}, merged})

        if new_status == :unhealthy do
          publish_provider_event(profile, chain_id, provider_id, :unhealthy)
        end
    end
  end

  defp clear_expired_rate_limit(instance_id, transport) do
    now_ms = System.monotonic_time(:millisecond)

    case :ets.lookup(:lasso_instance_state, {:rate_limit, instance_id, transport}) do
      [{_, %{expiry_ms: expiry}}] when expiry <= now_ms ->
        :ets.delete(:lasso_instance_state, {:rate_limit, instance_id, transport})

      _ ->
        :ok
    end
  end

  defp publish_provider_event(profile, chain_id, provider_id, event_type) do
    ts = System.system_time(:millisecond)

    typed =
      case event_type do
        :unhealthy ->
          %Provider.Unhealthy{ts: ts, chain_id: chain_id, provider_id: provider_id, reason: nil}

        :rate_limited ->
          %Provider.Unhealthy{
            ts: ts,
            chain_id: chain_id,
            provider_id: provider_id,
            reason: :rate_limit
          }
      end

    Phoenix.PubSub.broadcast(Lasso.PubSub, Lasso.Topics.provider_event(profile, chain_id), typed)
  end

  # Private helpers

  @spec publish_routing_decision(keyword()) :: :ok | {:error, term()}
  defp publish_routing_decision(opts) do
    instance_id =
      Catalog.lookup_instance_id(opts[:profile], opts[:chain_id], opts[:provider_id])

    event =
      RoutingDecision.new(
        request_id: opts[:request_id],
        profile: opts[:profile],
        chain_id: opts[:chain_id],
        method: opts[:method],
        strategy: opts[:strategy],
        provider_id: opts[:provider_id],
        instance_id: instance_id,
        transport: opts[:transport],
        duration_ms: opts[:duration_ms],
        result: opts[:result],
        failover_count: opts[:failovers]
      )

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      Lasso.Topics.routing_decision(opts[:profile]),
      event
    )
  end

  @spec emit_request_telemetry(
          pos_integer(),
          String.t(),
          atom(),
          String.t(),
          atom(),
          non_neg_integer(),
          atom(),
          non_neg_integer()
        ) :: :ok
  defp emit_request_telemetry(
         chain_id,
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
        chain_id: chain_id,
        method: method,
        strategy: strategy,
        provider_id: provider_id,
        transport: transport,
        result: result,
        failovers: failovers
      }
    )
  end

  @spec extract_error_category(term()) :: atom()
  defp extract_error_category(%JError{category: category}), do: category || :unknown
  defp extract_error_category(_), do: :unknown
end

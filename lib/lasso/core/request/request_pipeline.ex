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

  alias Lasso.Config.{ConfigStore, ProfileValidator}
  alias Lasso.Core.Request.{ExecutionScope, RequestOwner}
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Core.Support.CircuitBreaker.AdmissionReceipt
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.{CandidateListing, Catalog}

  alias Lasso.RPC.{
    AttemptIdentity,
    AttemptProjection,
    AttemptTerminal,
    BoundedIdentifier,
    Channel,
    ExecutionEnvelope,
    ExecutionProjector,
    RequestContext,
    RequestTerminal,
    Selection,
    TransportRegistry
  }

  alias Lasso.RPC.Providers.AdapterFilter
  alias Lasso.RPC.RequestOptions

  # Type definitions
  @type chain_id :: pos_integer()
  @type method :: String.t()
  @type params :: list()
  @type result :: {:ok, any(), RequestContext.t()} | {:error, JError.t(), RequestContext.t()}

  # A channel source is a function that returns channels to try
  @type channel_source :: (RequestContext.t() -> [Channel.t()])

  # Configuration
  @max_channel_candidates 10

  @doc """
  Execute an RPC request using transport-agnostic channels.

  This is the main entry point for request execution. It handles:
  - Provider selection (or override)
  - Automatic failover on retriable errors
  - Circuit breaker integration
  - Full observability tracking

  ## Options

  Takes a `RequestOptions` struct with:
  - `strategy` - Routing strategy (:fastest, :load_balanced, :latency_weighted, :priority)
  - `provider_override` - Force specific provider (optional)
  - `transport` - Transport preference (:http, :ws, :both)
  - `failover_on_override` - Retry on other providers if override fails
  - `timeout_ms` - Total request-envelope timeout in milliseconds
  - `request_id` - Request tracing ID (optional)
  - `request_context` - Pre-created RequestContext (optional)

  ## Examples

      {:ok, result, ctx} = execute_via_channels(
        1,
        "eth_blockNumber",
        [],
        %RequestOptions{strategy: :fastest}
      )
      # ctx.executed_channel contains the channel that succeeded

      {:error, %JError{}, ctx} = execute_via_channels(
        1,
        "eth_call",
        [],
        %RequestOptions{provider_override: "failing_provider"}
      )
  """
  @spec execute_via_channels(chain_id(), method(), params(), RequestOptions.t()) :: result()
  def execute_via_channels(chain_id, method, params, %RequestOptions{} = opts)
      when is_integer(chain_id) and chain_id > 0 do
    execute_owned(ExecutionScope.local(self()), chain_id, method, params, opts)
  end

  @doc false
  @spec execute_owned(
          ExecutionScope.t(),
          chain_id(),
          method(),
          params(),
          RequestOptions.t()
        ) :: result()
  def execute_owned(
        execution_scope,
        chain_id,
        method,
        params,
        %RequestOptions{} = opts
      )
      when is_integer(chain_id) and chain_id > 0 do
    caller_guard = ExecutionScope.open(execution_scope)

    try do
      execute_owned_request(execution_scope, caller_guard, chain_id, method, params, opts)
    after
      ExecutionScope.close(caller_guard)
    end
  end

  defp execute_owned_request(execution_scope, caller_guard, chain_id, method, params, opts) do
    ctx =
      chain_id |> initialize_context(method, params, opts) |> RequestContext.bound_request_id()

    rpc_request = build_rpc_request(method, params, ctx, opts)

    ctx =
      RequestContext.set_execution_params(
        ctx,
        rpc_request,
        opts.timeout_ms,
        opts,
        ExecutionScope.deadline_us(execution_scope)
      )

    result =
      case request_open(ctx, caller_guard) do
        :ok ->
          case validate_provider_override(chain_id, opts) do
            :ok ->
              channel_source = build_channel_source(opts)
              execute_pipeline(channel_source, ctx, caller_guard)

            {:error, jerr} ->
              finalize_error(jerr, ctx)
          end

        {:error, :caller_abandoned} ->
          finalize_caller_abandoned(ctx)

        {:error, :deadline_exhausted} ->
          finalize_bounded_error(ctx, :deadline_exhausted)
      end

    finalize_request_terminal(result)
  end

  @spec validate_provider_override(chain_id(), RequestOptions.t()) :: :ok | {:error, JError.t()}
  defp validate_provider_override(_chain_id, %RequestOptions{provider_override: nil}), do: :ok

  defp validate_provider_override(chain_id, %RequestOptions{
         provider_override: provider_id,
         profile: profile
       }) do
    case active_catalog_provider(profile, chain_id, provider_id) do
      {:ok, _snapshot, _provider, _instance} ->
        :ok

      {:error, _} ->
        {:error,
         JError.new(-32_602, "Provider '#{provider_id}' not found",
           category: :invalid_params,
           retriable?: false,
           data: %{provider_id: provider_id, chain_id: chain_id, profile: profile}
         )}
    end
  end

  @spec execute_pipeline(
          channel_source(),
          RequestContext.t(),
          ExecutionScope.CallerGuard.t() | nil
        ) ::
          result()
  defp execute_pipeline(channel_source, ctx, caller_guard) do
    case request_open(ctx, caller_guard) do
      :ok -> do_execute_pipeline(channel_source, ctx, caller_guard)
      {:error, :caller_abandoned} -> finalize_caller_abandoned(ctx)
      {:error, :deadline_exhausted} -> finalize_bounded_error(ctx, :deadline_exhausted)
    end
  end

  defp do_execute_pipeline(channel_source, ctx, caller_guard) do
    ctx = RequestContext.mark_request_start(ctx)

    # Get channels from the source
    ctx = RequestContext.mark_selection_start(ctx)

    channels = get_channels_from_source(channel_source, ctx)

    ctx =
      RequestContext.mark_selection_end(ctx,
        candidates: Enum.map(channels, &"#{&1.provider_id}:#{&1.transport}"),
        selected: List.first(channels)
      )

    case request_open(ctx, caller_guard) do
      :ok ->
        case channels do
          [] ->
            handle_no_channels(ctx)

          _ ->
            ctx = RequestContext.mark_upstream_start(ctx)
            attempt_channels(channels, ctx, [], caller_guard)
        end

      {:error, :caller_abandoned} ->
        finalize_caller_abandoned(ctx)

      {:error, :deadline_exhausted} ->
        finalize_bounded_error(ctx, :deadline_exhausted)
    end
  end

  @spec get_channels_from_source(channel_source(), RequestContext.t()) :: [Channel.t()]
  defp get_channels_from_source(channel_source, ctx), do: channel_source.(ctx)

  # Builds a function that returns channels to try, unifying override vs normal selection
  # Params are extracted from RequestContext - no need to pass separately (prevents closure footgun)
  @spec build_channel_source(RequestOptions.t()) :: channel_source()
  defp build_channel_source(%RequestOptions{provider_override: nil, profile: profile} = opts) do
    fn %RequestContext{chain_id: chain_id, method: method, params: params} = _ctx ->
      Selection.select_channels(profile, chain_id, method,
        strategy: opts.strategy,
        transport: opts.transport || :both,
        limit: @max_channel_candidates,
        params: params
      )
    end
  end

  defp build_channel_source(
         %RequestOptions{provider_override: provider_id, profile: profile} = opts
       ) do
    fn %RequestContext{chain_id: chain_id, method: method, params: params} = _ctx ->
      primary_channels = get_provider_channels(profile, chain_id, provider_id, opts.transport)

      if opts.failover_on_override do
        failover_channels =
          Selection.select_channels(profile, chain_id, method,
            strategy: opts.strategy,
            transport: :both,
            exclude: [provider_id],
            limit: @max_channel_candidates,
            params: params
          )

        primary_channels ++ failover_channels
      else
        primary_channels
      end
    end
  end

  @spec attempt_channels(
          [Channel.t()],
          RequestContext.t(),
          [Channel.t()],
          ExecutionScope.CallerGuard.t() | nil
        ) :: result()
  defp attempt_channels(channels, ctx, param_rejected, caller_guard) do
    case request_open(ctx, caller_guard) do
      :ok ->
        do_attempt_channels(channels, ctx, param_rejected, caller_guard)

      {:error, :caller_abandoned} ->
        finalize_caller_abandoned(ctx)

      {:error, :deadline_exhausted} ->
        finalize_bounded_error(ctx, :deadline_exhausted)
    end
  end

  defp do_attempt_channels([], ctx, [_ | _] = param_rejected, caller_guard) do
    if ctx.attempted_channels == [] do
      retry_param_rejected(param_rejected, ctx, caller_guard)
    else
      exhausted(ctx)
    end
  end

  defp do_attempt_channels([], ctx, _param_rejected, _caller_guard), do: exhausted(ctx)

  defp do_attempt_channels(
         [%Channel{} = channel | rest],
         %{bypass_param_limits: true} = ctx,
         _acc,
         caller_guard
       ) do
    case ExecutionEnvelope.admit_candidate(ctx.execution_envelope) do
      {:ok, envelope} ->
        execute_on_channel(
          channel,
          rest,
          %{ctx | execution_envelope: envelope},
          caller_guard
        )

      {:error, reason} ->
        finalize_bounded_error(ctx, reason)
    end
  end

  defp do_attempt_channels([%Channel{} = channel | rest], ctx, param_rejected, caller_guard)
       when is_list(rest) do
    case ExecutionEnvelope.admit_candidate(ctx.execution_envelope) do
      {:ok, envelope} ->
        ctx = %{ctx | execution_envelope: envelope}
        %{"method" => method, "params" => params} = ctx.rpc_request

        case AdapterFilter.validate_params(channel, method, params) do
          :ok ->
            execute_on_channel(channel, rest, ctx, caller_guard)

          {:error, reason} ->
            Logger.debug("Parameters invalid for channel, skipping",
              channel: Channel.to_string(channel),
              method: method,
              reason: inspect(reason)
            )

            ctx = RequestContext.increment_retries(ctx)
            attempt_channels(rest, ctx, param_rejected ++ [channel], caller_guard)
        end

      {:error, reason} ->
        finalize_bounded_error(ctx, reason)
    end
  end

  defp retry_param_rejected(channels, ctx, caller_guard) do
    Logger.warning("All channels rejected by parameter limits, attempting anyway",
      chain_id: ctx.chain_id,
      method: ctx.method,
      request_id: ctx.request_id,
      candidates: length(channels)
    )

    attempt_channels(channels, %{ctx | bypass_param_limits: true}, [], caller_guard)
  end

  defp exhausted(ctx) do
    Logger.warning("All channels exhausted",
      chain_id: ctx.chain_id,
      method: ctx.method,
      request_id: ctx.request_id,
      attempts: length(ctx.attempted_channels)
    )

    jerr =
      JError.new(-32_000, "No channels available",
        category: :provider_error,
        retriable?: true
      )

    finalize_error(jerr, %{ctx | terminal_reason: ctx.terminal_reason || :providers_exhausted})
  end

  @spec execute_on_channel(
          Channel.t(),
          [Channel.t()],
          RequestContext.t(),
          ExecutionScope.CallerGuard.t() | nil
        ) :: result()
  defp execute_on_channel(
         %Channel{instance_id: instance_id} = channel,
         rest_channels,
         ctx,
         caller_guard
       )
       when is_binary(instance_id) do
    breaker_id = {instance_id, channel.transport}

    case CircuitBreaker.admit(breaker_id, ctx.execution_envelope.deadline_us) do
      {:ok, receipt} ->
        reserve_admitted_channel(
          channel,
          instance_id,
          rest_channels,
          ctx,
          receipt,
          caller_guard
        )

      {:error, reason} ->
        handle_breaker_rejection(channel, rest_channels, ctx, reason, caller_guard)
    end
  end

  defp execute_on_channel(channel, rest_channels, ctx, caller_guard) do
    Logger.error("Channel has no stable upstream instance identity",
      channel: Channel.to_string(channel),
      request_id: ctx.request_id
    )

    ctx = RequestContext.increment_retries(ctx)
    attempt_channels(rest_channels, ctx, [], caller_guard)
  end

  defp reserve_admitted_channel(
         channel,
         instance_id,
         rest_channels,
         ctx,
         receipt,
         caller_guard
       ) do
    reserved_at_us = System.monotonic_time(:microsecond)

    case ExecutionEnvelope.reserve_dispatch(
           ctx.execution_envelope,
           instance_id,
           channel.transport,
           reserved_at_us
         ) do
      {:ok, envelope, attempt_timeout_ms} ->
        attempt_deadline_us =
          min(envelope.deadline_us, reserved_at_us + attempt_timeout_ms * 1_000)

        execute_owned_channel(
          channel,
          instance_id,
          rest_channels,
          %{ctx | execution_envelope: envelope},
          receipt,
          attempt_deadline_us,
          caller_guard
        )

      {:error, reason} ->
        abandon_unclaimed(receipt)
        handle_dispatch_rejection(rest_channels, ctx, reason, caller_guard)
    end
  end

  defp execute_owned_channel(
         channel,
         instance_id,
         rest_channels,
         ctx,
         receipt,
         attempt_deadline_us,
         caller_guard
       ) do
    cb_state = if receipt.kind == :half_open, do: :half_open, else: :closed

    ctx = %{
      ctx
      | selected_provider: %{id: channel.provider_id, protocol: channel.transport},
        circuit_breaker_state: cb_state
    }

    identity = attempt_identity(channel, instance_id, ctx, receipt)
    rpc_request = ctx.rpc_request

    case CircuitBreaker.activate_attempt(receipt, self()) do
      :ok ->
        run_owned_attempt(
          channel,
          rest_channels,
          ctx,
          receipt,
          identity,
          rpc_request,
          attempt_deadline_us,
          caller_guard
        )

      {:error, :stale} ->
        abandon_unclaimed(receipt)
        handle_activation_failure(channel, instance_id, rest_channels, ctx, caller_guard)
    end
  end

  defp run_owned_attempt(
         channel,
         rest_channels,
         ctx,
         receipt,
         identity,
         rpc_request,
         attempt_deadline_us,
         caller_guard
       ) do
    timeout_ms = max(div(attempt_deadline_us - System.monotonic_time(:microsecond), 1_000), 1)

    outcome =
      RequestOwner.execute(
        identity,
        attempt_deadline_us,
        build_transport_task(channel, rpc_request, timeout_ms),
        caller_guard_options(caller_guard)
      )

    _control_result = CircuitBreaker.report_canonical(receipt, outcome.fact, outcome.projection)

    _projection_result =
      AttemptProjection.process(
        AttemptProjection.new(outcome.fact, channel.provider_id, ctx.method)
      )

    ctx = commit_attempt_context(ctx, channel, identity.upstream_instance_id, outcome)
    handle_owner_outcome(outcome, channel, rest_channels, ctx, caller_guard)
  end

  @doc false
  @spec build_transport_task(Channel.t(), map(), timeout()) :: (-> term())
  def build_transport_task(%Channel{} = channel, rpc_request, timeout_ms)
      when is_map(rpc_request) and is_integer(timeout_ms) do
    fn -> Channel.request(channel, rpc_request, timeout_ms) end
  end

  defp handle_activation_failure(channel, instance_id, rest_channels, ctx, caller_guard) do
    envelope =
      ExecutionEnvelope.release_dispatch(ctx.execution_envelope, instance_id, channel.transport)

    ctx =
      ctx
      |> Map.put(:execution_envelope, envelope)
      |> Map.put(:terminal_reason, :admission_unavailable)
      |> RequestContext.increment_retries()

    attempt_channels(rest_channels, ctx, [], caller_guard)
  end

  defp abandon_unclaimed(%AdmissionReceipt{kind: :half_open} = receipt),
    do: CircuitBreaker.abandon_unclaimed(receipt, self())

  defp abandon_unclaimed(%AdmissionReceipt{}), do: :ok

  defp handle_dispatch_rejection(rest_channels, ctx, :duplicate_dispatch, caller_guard),
    do: attempt_channels(rest_channels, ctx, [], caller_guard)

  defp handle_dispatch_rejection(
         _rest_channels,
         ctx,
         :dispatch_budget_exhausted,
         _caller_guard
       ),
       do: finalize_dispatch_exhaustion(%{ctx | terminal_reason: :dispatch_budget_exhausted})

  defp handle_dispatch_rejection(_rest_channels, ctx, reason, _caller_guard),
    do: finalize_bounded_error(%{ctx | terminal_reason: reason}, reason)

  defp handle_breaker_rejection(channel, rest_channels, ctx, reason, caller_guard)
       when reason in [:circuit_open, :half_open_busy] do
    handle_circuit_open(channel, rest_channels, ctx, caller_guard)
  end

  defp handle_breaker_rejection(
         channel,
         rest_channels,
         ctx,
         :admission_timeout,
         caller_guard
       ) do
    Logger.warning("Circuit breaker admission timeout",
      channel: Channel.to_string(channel),
      request_id: ctx.request_id
    )

    ctx = RequestContext.increment_retries(ctx)

    attempt_channels(
      rest_channels,
      %{ctx | terminal_reason: :admission_unavailable},
      [],
      caller_guard
    )
  end

  defp handle_breaker_rejection(
         channel,
         rest_channels,
         ctx,
         :admission_unavailable,
         caller_guard
       ) do
    Logger.error("Circuit breaker admission unavailable",
      channel: Channel.to_string(channel),
      request_id: ctx.request_id
    )

    ctx = RequestContext.increment_retries(ctx)

    attempt_channels(
      rest_channels,
      %{ctx | terminal_reason: :admission_unavailable},
      [],
      caller_guard
    )
  end

  defp attempt_identity(channel, instance_id, ctx, receipt) do
    envelope = ctx.execution_envelope

    AttemptIdentity.new(
      request_id: ctx.request_id,
      attempt_id: "#{envelope.execution_nonce}:#{envelope.candidate_admission_count}",
      profile: ctx.opts.profile,
      subject_token: nil,
      chain_id: ctx.chain_id,
      upstream_instance_id: instance_id,
      transport: channel.transport,
      route_generation: channel.route_generation,
      circuit_scope: :broad,
      circuit_epoch: receipt.epoch,
      execution_safety: envelope.execution_safety,
      routing_intent: Atom.to_string(ctx.opts.strategy),
      workload_key: "default",
      request_budget_ms: envelope.original_timeout_ms,
      candidate_admission_count: envelope.candidate_admission_count,
      dispatch_count: envelope.dispatch_count
    )
  end

  defp commit_attempt_context(ctx, channel, instance_id, outcome) do
    certainty = strongest_certainty(ctx.request_dispatch_certainty, fact_certainty(outcome.fact))

    envelope =
      if authoritative_not_dispatched?(outcome.fact) do
        ExecutionEnvelope.release_dispatch(
          ctx.execution_envelope,
          instance_id,
          channel.transport
        )
      else
        ctx.execution_envelope
      end

    %{
      ctx
      | execution_envelope: envelope,
        terminal_attempt_fact: outcome.fact,
        terminal_attempt_projection: outcome.projection,
        request_dispatch_certainty: certainty,
        terminal_reason: nil
    }
  end

  defp handle_owner_outcome(
         %{fact: %AttemptTerminal.Response{kind: :success} = fact, result: {:ok, result, _io_ms}},
         channel,
         _rest_channels,
         ctx,
         _caller_guard
       ),
       do: handle_success(result, fact_latency_ms(fact), channel, ctx)

  defp handle_owner_outcome(outcome, channel, rest_channels, ctx, caller_guard) do
    cond do
      outcome.projection.fallback_eligible and rest_channels != [] ->
        handle_owner_fallback(outcome, channel, rest_channels, ctx, caller_guard)

      outcome.projection.fallback_eligible and
          match?(%AttemptTerminal.PredispatchFailure{}, outcome.fact) ->
        attempt_channels([], ctx, [], caller_guard)

      true ->
        handle_owner_terminal(outcome, channel, ctx)
    end
  end

  defp handle_owner_fallback(outcome, channel, rest_channels, ctx, caller_guard) do
    {reason, _latency_ms} = owner_error(outcome)
    ctx = record_owner_failure(ctx, channel, outcome.fact, reason)

    ctx =
      ctx
      |> RequestContext.increment_retries()
      |> RequestContext.track_error_category(extract_error_category(reason))

    next_channels = maybe_exclude_provider_for_method_not_found(rest_channels, channel, reason)
    attempt_channels(next_channels, ctx, [], caller_guard)
  end

  defp handle_owner_terminal(outcome, channel, ctx) do
    {reason, _latency_ms} = owner_error(outcome)
    ctx = record_owner_failure(ctx, channel, outcome.fact, reason)
    ctx = record_public_response_attempt(ctx, outcome.fact)
    ctx = RequestContext.set_executed_channel(ctx, channel)
    finalize_error(owner_terminal_error(outcome, channel), ctx)
  end

  defp record_public_response_attempt(ctx, %AttemptTerminal.Response{} = fact),
    do: %{ctx | public_response_attempt: fact}

  defp record_public_response_attempt(ctx, _fact), do: ctx

  defp owner_error(%{result: {:error, reason, _io_ms}, fact: fact}),
    do: {reason, fact_latency_ms(fact)}

  defp owner_error(%{result: {:error, reason}, fact: fact}), do: {reason, fact_latency_ms(fact)}

  defp owner_error(%{result: other, fact: fact}),
    do: {{:unexpected_attempt_result, result_kind(other)}, fact_latency_ms(fact)}

  defp owner_terminal_error(
         %{projection: %ExecutionProjector{recommended_action: :finish_unsafe_indeterminate}},
         channel
       ) do
    JError.new(-32_000, "Upstream dispatch outcome is indeterminate",
      provider_id: channel.provider_id,
      category: :indeterminate_dispatch,
      retriable?: false,
      breaker_penalty?: false
    )
  end

  defp owner_terminal_error(%{fact: %AttemptTerminal.Deadline{}}, channel) do
    JError.new(-32_007, "Request timeout",
      provider_id: channel.provider_id,
      category: :timeout,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  defp owner_terminal_error(%{fact: %AttemptTerminal.Cancelled{}}, channel) do
    JError.new(-32_000, "Request cancelled",
      provider_id: channel.provider_id,
      category: :cancelled,
      retriable?: false,
      breaker_penalty?: false
    )
  end

  defp owner_terminal_error(%{fact: %AttemptTerminal.InvalidResponse{}}, channel) do
    JError.new(-32_000, "Invalid upstream response",
      provider_id: channel.provider_id,
      category: :provider_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  defp owner_terminal_error(outcome, channel) do
    {reason, _latency_ms} = owner_error(outcome)
    JError.from(reason, provider_id: channel.provider_id, transport: channel.transport)
  end

  defp record_owner_failure(ctx, channel, fact, reason) do
    if authoritative_not_dispatched?(fact) do
      ctx
    else
      ctx
      |> RequestContext.add_upstream_latency(fact_latency_ms(fact))
      |> RequestContext.record_channel_attempt(channel, reason)
    end
  end

  defp fact_latency_ms(%AttemptTerminal.Response{io_duration_us: us}), do: us / 1_000
  defp fact_latency_ms(%AttemptTerminal.InvalidResponse{io_duration_us: us}), do: us / 1_000
  defp fact_latency_ms(%AttemptTerminal.PredispatchFailure{elapsed_us: us}), do: us / 1_000

  defp fact_latency_ms(%AttemptTerminal.TransportFailure{io_duration_us: us})
       when is_integer(us),
       do: us / 1_000

  defp fact_latency_ms(%AttemptTerminal.Deadline{censoring_boundary_us: us}), do: us / 1_000
  defp fact_latency_ms(%AttemptTerminal.Cancelled{censoring_boundary_us: us}), do: us / 1_000
  defp fact_latency_ms(_fact), do: 0

  defp authoritative_not_dispatched?(%AttemptTerminal.PredispatchFailure{}), do: true

  defp authoritative_not_dispatched?(%{dispatch_certainty: :not_dispatched}),
    do: true

  defp authoritative_not_dispatched?(_fact), do: false

  defp fact_certainty(%AttemptTerminal.PredispatchFailure{}), do: :not_dispatched
  defp fact_certainty(%AttemptTerminal.Response{}), do: :dispatched
  defp fact_certainty(%AttemptTerminal.InvalidResponse{}), do: :dispatched
  defp fact_certainty(%{dispatch_certainty: certainty}), do: certainty

  defp strongest_certainty(left, right) do
    rank = %{not_dispatched: 0, indeterminate: 1, dispatched: 2}
    if rank[right] > rank[left], do: right, else: left
  end

  defp result_kind({:ok, _value}), do: :success
  defp result_kind({:ok, _value, _latency}), do: :success
  defp result_kind({:error, _reason}), do: :error
  defp result_kind({:error, _reason, _latency}), do: :error
  defp result_kind(_other), do: :unknown

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
      |> Map.put(:public_response_attempt, ctx.terminal_attempt_fact)

    {:ok, result, ctx}
  end

  @spec handle_circuit_open(
          Channel.t(),
          [Channel.t()],
          RequestContext.t(),
          ExecutionScope.CallerGuard.t() | nil
        ) :: result()
  defp handle_circuit_open(channel, rest_channels, ctx, caller_guard) do
    Logger.info("Circuit breaker open, skipping",
      channel: Channel.to_string(channel),
      request_id: ctx.request_id
    )

    ctx = RequestContext.increment_retries(ctx)

    attempt_channels(
      rest_channels,
      %{ctx | terminal_reason: :admission_unavailable},
      [],
      caller_guard
    )
  end

  @spec handle_no_channels(RequestContext.t()) :: result()
  defp handle_no_channels(ctx) do
    profile = if ctx.opts, do: ctx.opts.profile, else: ProfileValidator.default_profile()

    retry_after_ms =
      calculate_min_recovery_time(profile, ctx.chain_id, ctx.opts && ctx.opts.transport)

    {message, data} = build_exhaustion_error_message(ctx.method, retry_after_ms, ctx.chain_id)

    jerr =
      JError.new(-32_000, message,
        category: :provider_error,
        retriable?: true,
        data: data
      )

    Logger.warning("No channels available",
      chain_id: ctx.chain_id,
      method: ctx.method,
      retry_after_ms: retry_after_ms
    )

    finalize_error(jerr, %{ctx | terminal_reason: :providers_exhausted})
  end

  @spec finalize_error(JError.t(), RequestContext.t()) :: result()
  defp finalize_error(jerr, ctx) do
    ctx =
      ctx
      |> RequestContext.mark_upstream_end()
      |> RequestContext.record_error(jerr)

    {:error, jerr, ctx}
  end

  defp finalize_caller_abandoned(ctx) do
    jerr =
      JError.new(-32_000, "Request caller abandoned execution",
        category: :cancelled,
        retriable?: false,
        breaker_penalty?: false
      )

    finalize_error(jerr, %{ctx | terminal_reason: :caller_abandoned})
  end

  defp request_open(ctx, caller_guard) do
    cond do
      not ExecutionScope.caller_alive?(caller_guard) ->
        {:error, :caller_abandoned}

      System.monotonic_time(:microsecond) >= ctx.execution_envelope.deadline_us ->
        {:error, :deadline_exhausted}

      true ->
        :ok
    end
  end

  defp caller_guard_options(nil), do: []

  defp caller_guard_options(%ExecutionScope.CallerGuard{} = caller_guard),
    do: [caller_guard: caller_guard]

  defp finalize_bounded_error(ctx, reason) do
    {message, category} =
      case reason do
        :deadline_exhausted ->
          {"Request deadline exhausted", :timeout}

        :dispatch_budget_exhausted ->
          {"Request dispatch budget exhausted", :provider_error}

        :candidate_budget_exhausted ->
          {"Candidate admission budget exhausted", :local_capacity_rejection}
      end

    code = if category == :local_capacity_rejection, do: -32_005, else: -32_000

    jerr =
      JError.new(code, message,
        category: category,
        retriable?: false,
        data: %{reason: reason}
      )

    finalize_error(jerr, %{ctx | terminal_reason: reason})
  end

  defp finalize_dispatch_exhaustion(
         %RequestContext{attempted_channels: [_ | _] = attempted_channels} = ctx
       ) do
    %{channel: channel, category: category, code: code} = List.last(attempted_channels)

    jerr =
      JError.new(code || -32_000, "Request dispatch budget exhausted",
        provider_id: channel.provider_id,
        transport: channel.transport,
        category: category || :provider_error,
        retriable?: false
      )

    finalize_error(jerr, ctx)
  end

  defp finalize_dispatch_exhaustion(ctx),
    do: finalize_bounded_error(ctx, :dispatch_budget_exhausted)

  defp finalize_request_terminal({status, value, %RequestContext{} = ctx})
       when status in [:ok, :error] do
    request_terminal = build_request_terminal(status, value, ctx)
    _enqueue_result = AttemptProjection.enqueue_request_terminal(request_terminal)
    {status, value, release_execution_payloads(ctx)}
  end

  @doc false
  @spec build_request_terminal(:ok | :error, term(), RequestContext.t()) :: RequestTerminal.t()
  def build_request_terminal(
        _status,
        _value,
        %RequestContext{
          terminal_attempt_projection: %ExecutionProjector{
            recommended_action: :finish_unsafe_indeterminate
          }
        } = ctx
      ) do
    RequestTerminal.UnsafeIndeterminateExhaustion.new(request_terminal_attrs(ctx))
  end

  def build_request_terminal(
        _status,
        _value,
        %RequestContext{
          terminal_attempt_fact: %AttemptTerminal.Cancelled{reason: :caller_abandoned}
        } = ctx
      ) do
    RequestTerminal.CallerAbandonment.new(
      request_terminal_attrs(ctx),
      ctx.request_dispatch_certainty
    )
  end

  def build_request_terminal(
        _status,
        _value,
        %RequestContext{terminal_reason: :caller_abandoned} = ctx
      ) do
    RequestTerminal.CallerAbandonment.new(
      request_terminal_attrs(ctx),
      ctx.request_dispatch_certainty
    )
  end

  def build_request_terminal(
        :ok,
        _value,
        %RequestContext{
          public_response_attempt: %AttemptTerminal.Response{} = attempt
        } = ctx
      ) do
    RequestTerminal.UpstreamResponse.new(request_terminal_attrs(ctx), attempt)
  end

  def build_request_terminal(
        :error,
        _value,
        %RequestContext{
          public_response_attempt: %AttemptTerminal.Response{} = attempt
        } = ctx
      ) do
    RequestTerminal.UpstreamResponse.new(request_terminal_attrs(ctx), attempt)
  end

  def build_request_terminal(
        :error,
        %JError{category: :timeout},
        %RequestContext{} = ctx
      ) do
    RequestTerminal.Deadline.new(request_terminal_attrs(ctx), ctx.request_dispatch_certainty)
  end

  def build_request_terminal(:error, %JError{category: :invalid_params}, ctx) do
    RequestTerminal.LocalFailure.new(request_terminal_attrs(ctx), :invalid_request)
  end

  def build_request_terminal(:error, %JError{category: :local_capacity_rejection}, ctx) do
    RequestTerminal.LocalFailure.new(request_terminal_attrs(ctx), :capacity)
  end

  def build_request_terminal(:error, %JError{}, ctx) do
    RequestTerminal.OrdinaryExhaustion.new(
      request_terminal_attrs(ctx),
      final_exhaustion_reason(ctx)
    )
  end

  def build_request_terminal(_status, _value, ctx) do
    RequestTerminal.LocalFailure.new(request_terminal_attrs(ctx), :internal)
  end

  defp request_terminal_attrs(ctx) do
    envelope = ctx.execution_envelope

    [
      request_id: ctx.request_id,
      profile: ctx.opts.profile,
      subject_token: nil,
      chain_id: ctx.chain_id,
      execution_safety: envelope.execution_safety,
      routing_intent: Atom.to_string(ctx.opts.strategy),
      workload_key: "default",
      elapsed_us: max(System.monotonic_time(:microsecond) - envelope.started_at_us, 0),
      candidate_admission_count: envelope.candidate_admission_count,
      dispatch_count: envelope.dispatch_count,
      observed_at: nil
    ]
  end

  defp final_exhaustion_reason(%RequestContext{terminal_reason: reason})
       when reason in [
              :candidate_budget_exhausted,
              :dispatch_budget_exhausted,
              :admission_unavailable
            ],
       do: reason

  defp final_exhaustion_reason(_ctx), do: :providers_exhausted

  defp release_execution_payloads(ctx) do
    opts = bounded_return_options(ctx.opts)

    %{
      ctx
      | request_id: BoundedIdentifier.encode(ctx.request_id),
        method: BoundedIdentifier.encode(ctx.method),
        path: bounded_optional(ctx.path),
        client_ip: bounded_optional(ctx.client_ip),
        user_agent: bounded_optional(ctx.user_agent),
        candidate_providers: Enum.map(ctx.candidate_providers, &BoundedIdentifier.encode/1),
        selected_provider: bounded_selected_provider(ctx.selected_provider),
        selection_reason: bounded_optional(ctx.selection_reason),
        params: [],
        rpc_request: nil,
        opts: opts
    }
  end

  defp bounded_return_options(nil), do: nil

  defp bounded_return_options(%RequestOptions{} = opts) do
    %{
      opts
      | profile: BoundedIdentifier.encode(opts.profile),
        provider_override: bounded_optional(opts.provider_override),
        request_id: bounded_optional(opts.request_id),
        jsonrpc_id: nil,
        request_context: nil
    }
  end

  defp bounded_selected_provider(nil), do: nil

  defp bounded_selected_provider(%{id: id, protocol: protocol}),
    do: %{id: BoundedIdentifier.encode(id), protocol: protocol}

  defp bounded_selected_provider(_other), do: nil

  defp bounded_optional(nil), do: nil
  defp bounded_optional(value) when is_binary(value), do: BoundedIdentifier.encode(value)
  defp bounded_optional(_value), do: nil

  @spec initialize_context(chain_id(), method(), params(), RequestOptions.t()) ::
          RequestContext.t()
  defp initialize_context(chain_id, method, params, opts) do
    opts.request_context ||
      RequestContext.new(chain_id, method, params,
        transport: opts.transport || :http,
        strategy: opts.strategy,
        request_id: opts.request_id,
        plug_start_time: opts.plug_start_time
      )
  end

  @spec build_rpc_request(method(), params(), RequestContext.t(), RequestOptions.t()) :: map()
  defp build_rpc_request(method, params, ctx, opts) do
    jsonrpc_id = if opts.jsonrpc_id_present?, do: opts.jsonrpc_id, else: ctx.request_id

    %{
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params,
      "id" => jsonrpc_id
    }
  end

  @spec get_provider_channels(String.t(), chain_id(), String.t(), atom() | nil) :: [Channel.t()]
  defp get_provider_channels(profile, chain_id, provider_id, transport_override) do
    case active_catalog_provider(profile, chain_id, provider_id) do
      {:ok, snapshot, provider, instance} ->
        transports = if transport_override, do: [transport_override], else: [:http, :ws]

        channels =
          for transport <- transports,
              channel =
                fetch_channel_safe(profile, chain_id, provider_id, transport,
                  provider_config: instance,
                  instance_id: provider.instance_id,
                  route_generation: snapshot.generation
                ),
              not is_nil(channel),
              do: channel

        if Catalog.snapshot() == snapshot and
             ConfigStore.route_generation() == snapshot.generation,
           do: channels,
           else: []

      _unavailable ->
        []
    end
  end

  @spec fetch_channel_safe(String.t(), chain_id(), String.t(), atom(), keyword()) ::
          Channel.t() | nil
  defp fetch_channel_safe(profile, chain_id, provider_id, transport, opts) do
    case TransportRegistry.get_channel(profile, chain_id, provider_id, transport, opts) do
      {:ok, channel} -> channel
      {:error, _} -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp active_catalog_provider(profile, chain_id, provider_id) do
    with %{generation: generation} = snapshot <- Catalog.snapshot(),
         true <- generation == ConfigStore.route_generation(),
         provider when not is_nil(provider) <-
           Enum.find(
             Catalog.get_profile_providers(snapshot, profile, chain_id),
             &(&1.provider_id == provider_id)
           ),
         {:ok, instance} <- Catalog.get_instance(snapshot, provider.instance_id),
         true <- Catalog.snapshot() == snapshot,
         true <- ConfigStore.route_generation() == generation do
      {:ok, snapshot, provider, instance}
    else
      _unavailable -> {:error, :not_found}
    end
  end

  @spec build_exhaustion_error_message(method(), non_neg_integer() | nil, chain_id()) ::
          {String.t(), map()}
  defp build_exhaustion_error_message(method, nil, _chain_id) do
    {"No available channels for method: #{method}. All circuit breakers are open.", %{}}
  end

  defp build_exhaustion_error_message(method, ms, _chain_id) when is_integer(ms) and ms > 0 do
    seconds = div(ms, 1000)

    message =
      "No available channels for method: #{method}. All circuits open, retry after #{seconds}s"

    {message, %{retry_after_ms: ms}}
  end

  defp build_exhaustion_error_message(method, retry_after_ms, chain_id) do
    Logger.warning("Invalid recovery time: #{inspect(retry_after_ms)}", chain_id: chain_id)
    {"No available channels for method: #{method}. All circuit breakers are open.", %{}}
  end

  @spec calculate_min_recovery_time(String.t(), chain_id(), atom() | nil) ::
          non_neg_integer() | nil
  defp calculate_min_recovery_time(profile, chain_id, transport_filter) do
    transport = transport_filter || :both

    {:ok, min_time} =
      CandidateListing.get_min_recovery_time(profile, chain_id, transport: transport)

    min_time
  end

  @spec extract_error_category(any()) :: atom()
  defp extract_error_category(%JError{category: category}), do: category || :unknown
  defp extract_error_category(:circuit_open), do: :circuit_open
  defp extract_error_category(_), do: :unknown

  @spec maybe_exclude_provider_for_method_not_found([Channel.t()], Channel.t(), any()) :: [
          Channel.t()
        ]
  defp maybe_exclude_provider_for_method_not_found(rest_channels, channel, %JError{
         category: :method_not_found
       }) do
    Enum.reject(rest_channels, &(&1.provider_id == channel.provider_id))
  end

  defp maybe_exclude_provider_for_method_not_found(rest_channels, _channel, _reason),
    do: rest_channels

  @spec log_slow_request_if_needed(number(), method(), Channel.t(), RequestContext.t()) :: :ok
  defp log_slow_request_if_needed(latency_ms, method, channel, ctx) when latency_ms > 4000 do
    Logger.warning("VERY SLOW request (may timeout clients)",
      request_id: ctx.request_id,
      method: method,
      provider: channel.provider_id,
      latency_ms: latency_ms
    )

    :ok
  end

  defp log_slow_request_if_needed(latency_ms, method, channel, ctx) when latency_ms > 2000 do
    Logger.warning("Slow request",
      request_id: ctx.request_id,
      method: method,
      provider: channel.provider_id,
      latency_ms: latency_ms
    )

    :ok
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

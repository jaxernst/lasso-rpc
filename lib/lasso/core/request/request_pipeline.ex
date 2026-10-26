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

  alias Lasso.Config.{MethodConstraints, ProfileValidator}
  alias Lasso.Core.Request.{ExecutionScope, RequestOwner}
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Core.Support.CircuitBreaker.AdmissionReceipt
  alias Lasso.Core.Support.{ClaimAudit, CredentialHealth, LogRangeLimit}
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.{CandidateListing, Catalog, ChainIdentity}

  alias Lasso.RPC.{
    AttemptIdentity,
    AttemptProjection,
    AttemptTerminal,
    BoundedIdentifier,
    Channel,
    ExecutionEnvelope,
    ExecutionProjector,
    HeadPolicy,
    MissingBlock,
    NullRecovery,
    PreparedRequest,
    ProviderKnowledge,
    RequestAnalysis,
    RequestContext,
    RequestProjection,
    RequestTerminal,
    Selection,
    Selection.CandidateCursor,
    Selection.Exhaustion,
    TransportRegistry
  }

  alias Lasso.RPC.ProviderKnowledge.Decision, as: LearningDecision

  alias Lasso.RPC.ProviderKnowledge.{
    ShadowAgreement,
    Template,
    TemplateClassification,
    TemplateObservation,
    TemplateOutcomeObservation
  }

  alias Lasso.RPC.Providers.AdapterFilter
  alias Lasso.RPC.RequestOptions
  alias Lasso.RPC.Response.{Capacity, Success}
  alias Lasso.RPC.RoutingEvidence.Workload
  alias Lasso.RPC.Selection.Exploration

  # Type definitions
  @type chain_id :: pos_integer()
  @type method :: String.t()
  @type params :: list() | map()
  @type result :: {:ok, any(), RequestContext.t()} | {:error, JError.t(), RequestContext.t()}

  # A channel source is a function that returns channels to try
  @type candidates :: [Channel.t()] | CandidateCursor.t()
  @type selection_source :: candidates() | {:unavailable, map()}
  @type channel_source :: (RequestContext.t() -> selection_source())

  # Configuration
  @max_channel_candidates 10

  # Reasons a channel was skipped before dispatch; requests ending on one report admission_unavailable.
  @admission_causes [
    :chain_identity_rejected,
    :breaker_receipt_stale,
    :breaker_admission_timeout,
    :breaker_unavailable,
    :circuit_open,
    :shared_public_capacity_exhausted
  ]

  @doc """
  Execute an RPC request using transport-agnostic channels.

  This is the main entry point for request execution. It handles:
  - Provider selection (or override)
  - Automatic failover on retriable errors
  - Circuit breaker integration
  - Full observability tracking

  ## Options

  Takes a `RequestOptions` struct with:
  - `strategy` - Routing strategy (:fastest, :load_balanced, :balanced_fast, :priority)
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

  @doc "Executes a request inside an explicitly owned and caller-guarded scope."
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
      Lasso.Observability.Tracing.request(chain_id, method, opts, fn ->
        execute_owned_request(execution_scope, caller_guard, chain_id, method, params, opts)
      end)
    after
      ExecutionScope.close(caller_guard)
    end
  end

  defp execute_owned_request(execution_scope, caller_guard, chain_id, method, params, opts) do
    ctx = initialize_context(chain_id, method, params, opts)
    ctx = %{ctx | block_facts: RequestAnalysis.block_facts(method, params)}

    rpc_request = build_rpc_request(method, params, ctx, opts)

    ctx =
      RequestContext.initialize_execution(
        ctx,
        rpc_request,
        opts.timeout_ms,
        opts,
        ExecutionScope.deadline_us(execution_scope)
      )

    result =
      if MethodConstraints.disallowed?(method) do
        finalize_error(product_policy_error(), ctx)
      else
        execute_open_request(
          HeadPolicy.initialize(ctx),
          rpc_request,
          chain_id,
          opts,
          caller_guard
        )
      end

    result
    |> finalize_request_terminal()
  end

  defp execute_admitted_request(ctx, opts, caller_guard) do
    case Lasso.BlockPublication.Admission.choose(ctx, caller_guard) do
      {:continue, ctx} ->
        execute_pipeline(build_channel_source(opts), ctx, caller_guard)

      {:ok, result, ctx} ->
        case request_open(ctx, caller_guard) do
          :ok ->
            ctx =
              %{ctx | selection_reason: "served_locally"}
              |> RequestContext.add_upstream_latency(0)
              |> RequestContext.record_success(result)

            {:ok, result, ctx}

          {:error, :caller_abandoned} ->
            finalize_caller_abandoned(ctx)

          {:error, :deadline_exhausted} ->
            finalize_bounded_error(ctx, :deadline_exhausted)
        end

      {:error, :caller_abandoned, ctx} ->
        finalize_caller_abandoned(ctx)

      {:error, :deadline_exhausted, ctx} ->
        finalize_bounded_error(ctx, :deadline_exhausted)

      {:error, error, ctx} ->
        finalize_error(error, ctx)
    end
  end

  defp execute_open_request(ctx, rpc_request, chain_id, opts, caller_guard) do
    case request_open(ctx, caller_guard) do
      :ok ->
        case prepare_request(ctx, rpc_request) do
          {:ok, prepared_request} ->
            ctx = RequestContext.set_prepared_request(ctx, prepared_request)

            case request_open(ctx, caller_guard) do
              :ok ->
                case validate_provider_override(chain_id, opts) do
                  :ok ->
                    execute_admitted_request(ctx, opts, caller_guard)

                  {:error, jerr} ->
                    finalize_error(jerr, ctx)
                end

              {:error, :caller_abandoned} ->
                finalize_caller_abandoned(ctx)

              {:error, :deadline_exhausted} ->
                finalize_bounded_error(ctx, :deadline_exhausted)
            end

          {:error, reason} ->
            finalize_prepare_error(reason, ctx)
        end

      {:error, :caller_abandoned} ->
        finalize_caller_abandoned(ctx)

      {:error, :deadline_exhausted} ->
        finalize_bounded_error(ctx, :deadline_exhausted)
    end
  end

  defp product_policy_error do
    JError.new(-32_601, "Method not supported by proxy",
      category: :method_not_found,
      retriable?: false,
      breaker_penalty?: false
    )
  end

  @spec validate_provider_override(chain_id(), RequestOptions.t()) :: :ok | {:error, JError.t()}
  defp validate_provider_override(_chain_id, %RequestOptions{
         captured_channel: channel,
         request_origin: :system
       })
       when not is_nil(channel),
       do: :ok

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
    ctx = if ctx.request_start_ms, do: ctx, else: RequestContext.mark_request_start(ctx)

    # Facts belong to one selection phase. Only this phase's cursor may supply
    # them, so list, override and unavailable phases carry none.
    ctx = %{ctx | request_facts: nil}

    # Get channels from the source
    ctx = RequestContext.mark_selection_start(ctx)

    source = get_channels_from_source(channel_source, ctx)

    candidates =
      case source do
        {:unavailable, _} -> []
        candidates -> candidates
      end

    {selected, remaining, candidate_labels, ctx} = prepare_candidates(candidates, ctx)
    {selected, remaining, ctx} = maybe_explore(selected, remaining, ctx)

    ctx =
      RequestContext.mark_selection_end(ctx,
        candidates: ctx.candidate_providers ++ candidate_labels,
        selected: selected
      )

    try do
      execute_selected(selected, remaining, ctx, caller_guard, source)
    after
      Exploration.release(ctx.exploration_token)
    end
  end

  defp maybe_explore(selected, remaining, ctx) do
    selection_opts =
      case remaining do
        %CandidateCursor{effect_context: %{head_suitability: head}} -> [head_suitability: head]
        _other -> []
      end

    case Exploration.select(selected, ctx, selection_opts) do
      {:ok, exploratory, token} ->
        remaining = prepend_candidate(remaining, selected)
        {exploratory, remaining, %{ctx | exploration_token: token}}

      :skip ->
        {selected, remaining, ctx}
    end
  end

  defp prepend_candidate(%CandidateCursor{} = cursor, channel),
    do: CandidateCursor.prepend(cursor, channel)

  defp prepend_candidate(channels, channel) when is_list(channels), do: [channel | channels]

  defp execute_selected(selected, remaining, ctx, caller_guard, candidates) do
    case request_open(ctx, caller_guard) do
      :ok ->
        case selected do
          nil ->
            handle_no_channels(
              ctx,
              caller_guard,
              selection_exhaustion_reason(candidates),
              if(match?(%CandidateCursor{}, remaining), do: remaining, else: candidates)
            )

          %Channel{} = channel ->
            ctx = RequestContext.mark_upstream_start(ctx)
            attempt_channels({channel, remaining}, ctx, [], caller_guard)
        end

      {:error, :caller_abandoned} ->
        finalize_caller_abandoned(ctx)

      {:error, :deadline_exhausted} ->
        result = finalize_bounded_error(ctx, :deadline_exhausted)

        case result do
          {:error, _, %{selected_provider: nil}} when is_nil(selected) ->
            Exhaustion.log_failure(
              ctx,
              if(match?(%CandidateCursor{}, remaining), do: remaining, else: candidates),
              :deadline_exhausted
            )

          _ ->
            :ok
        end

        result
    end
  end

  @spec get_channels_from_source(channel_source(), RequestContext.t()) :: selection_source()
  defp get_channels_from_source(channel_source, ctx), do: channel_source.(ctx)

  defp retain_learning_decision(existing, decision),
    do: LearningDecision.retain(existing, decision)

  # Builds a function that returns channels to try, unifying override vs normal selection
  # Params are extracted from RequestContext - no need to pass separately (prevents closure footgun)
  @spec build_channel_source(RequestOptions.t()) :: channel_source()
  defp build_channel_source(%RequestOptions{captured_channel: channel, request_origin: :system})
       when not is_nil(channel) do
    fn _ctx ->
      case channel do
        %Channel{} -> [channel]
        {:unavailable, _} = unavailable -> unavailable
      end
    end
  end

  defp build_channel_source(%RequestOptions{provider_override: nil, profile: profile} = opts) do
    fn %RequestContext{chain_id: chain_id} = ctx ->
      {method, params} = HeadPolicy.selection_request(ctx)

      Selection.select_channel_candidates(
        profile,
        chain_id,
        method,
        captured_block_options(ctx) ++
          HeadPolicy.selection_options(ctx) ++
          [
            strategy: opts.strategy,
            transport: opts.transport || :both,
            limit: @max_channel_candidates,
            attempted_instances:
              Enum.map(Map.keys(ctx.attempted_instance_transports), &elem(&1, 0)),
            params: params,
            request_origin: opts.request_origin,
            deadline_us: ctx.execution_envelope.deadline_us
          ]
      )
    end
  end

  defp build_channel_source(
         %RequestOptions{provider_override: provider_id, profile: profile} = opts
       ) do
    fn %RequestContext{chain_id: chain_id} = ctx ->
      {method, params} = HeadPolicy.selection_request(ctx)
      deadline_us = ctx.execution_envelope.deadline_us

      primary_channels =
        get_provider_channels(profile, chain_id, provider_id, opts.transport, deadline_us)

      if opts.failover_on_override do
        failover_channels =
          Selection.select_channels(
            profile,
            chain_id,
            method,
            captured_block_options(ctx) ++
              [
                strategy: opts.strategy,
                transport: :both,
                exclude: [provider_id],
                request_origin: opts.request_origin,
                limit: @max_channel_candidates,
                attempted_instances:
                  Enum.map(Map.keys(ctx.attempted_instance_transports), &elem(&1, 0)),
                deadline_us: deadline_us,
                params: params
              ]
          )

        primary_channels ++ failover_channels
      else
        primary_channels
      end
    end
  end

  # Continuity may select for a different block; its phase captures its own facts.
  defp captured_block_options(%RequestContext{head_policy: nil, block_facts: facts}),
    do: [block_facts: facts]

  defp captured_block_options(_ctx), do: []

  @spec attempt_channels(
          candidates() | {Channel.t(), candidates()},
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

  defp do_attempt_channels({%Channel{} = channel, rest}, ctx, param_rejected, caller_guard) do
    do_attempt_channels(
      [channel],
      track_materialized_candidate(ctx, channel),
      param_rejected,
      caller_guard,
      rest
    )
  end

  defp do_attempt_channels(%CandidateCursor{} = cursor, ctx, param_rejected, caller_guard) do
    case pop_candidate(cursor, ctx) do
      {%Channel{} = channel, rest, ctx} ->
        do_attempt_channels(
          [channel],
          track_materialized_candidate(ctx, channel),
          param_rejected,
          caller_guard,
          rest
        )

      {nil, _remaining, ctx} ->
        do_attempt_channels([], ctx, param_rejected, caller_guard)
    end
  end

  defp do_attempt_channels([], ctx, [_ | _] = param_rejected, caller_guard) do
    if ctx.phase_attempt_count == 0 do
      retry_param_rejected(param_rejected, ctx, caller_guard)
    else
      exhausted(ctx, caller_guard)
    end
  end

  defp do_attempt_channels([], ctx, _param_rejected, caller_guard),
    do: exhausted(ctx, caller_guard)

  defp do_attempt_channels(
         [%Channel{} = channel | rest],
         %{bypass_param_limits: true} = ctx,
         _acc,
         caller_guard
       ) do
    do_attempt_channels([channel], ctx, [], caller_guard, rest)
  end

  defp do_attempt_channels([%Channel{} = channel | rest], ctx, param_rejected, caller_guard)
       when is_list(rest) do
    do_attempt_channels([channel], ctx, param_rejected, caller_guard, rest)
  end

  defp do_attempt_channels(
         [%Channel{} = channel],
         %{bypass_param_limits: true} = ctx,
         _acc,
         caller_guard,
         rest
       ) do
    case ExecutionEnvelope.admit_candidate(ctx.execution_envelope) do
      {:ok, envelope} ->
        execute_on_channel(channel, rest, %{ctx | execution_envelope: envelope}, caller_guard)

      {:error, reason} ->
        finalize_bounded_error(ctx, reason)
    end
  end

  defp do_attempt_channels([%Channel{} = channel], ctx, param_rejected, caller_guard, rest) do
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

  defp prepare_candidates(channels, ctx) when is_list(channels) do
    channels = deduplicate_attempted_instances(channels, ctx)
    {selected, remaining, ctx} = pop_candidate(channels, ctx)

    labels =
      Enum.map(channels, &"#{&1.provider_id}:#{&1.transport}")

    {selected, remaining, labels, ctx}
  end

  defp prepare_candidates(%CandidateCursor{} = cursor, ctx) do
    {selected, remaining, ctx} = pop_candidate(cursor, ctx)

    labels =
      case {cursor.candidate_labels, selected} do
        {[_ | _] = candidate_labels, _selected} ->
          candidate_labels

        {[], %Channel{} = channel} ->
          ["#{channel.provider_id}:#{channel.transport}"]

        {[], nil} ->
          []
      end

    {selected, remaining, labels, ctx}
  end

  defp pop_candidate([%Channel{} = channel | rest], ctx), do: {channel, rest, ctx}
  defp pop_candidate([], ctx), do: {nil, [], ctx}

  defp pop_candidate(%CandidateCursor{} = cursor, ctx) do
    {cursor, ctx} = capture_cursor_decisions(cursor, ctx)

    case CandidateCursor.next_with_evidence(cursor) do
      {:ok, channel, remaining} ->
        {remaining, ctx} = capture_cursor_decisions(remaining, ctx)

        if RequestContext.attempted_instance?(ctx, channel.instance_id, channel.transport) do
          pop_candidate(remaining, ctx)
        else
          {channel, remaining, ctx}
        end

      {terminal, remaining} when terminal in [:done, :stale] ->
        {remaining, ctx} = capture_cursor_decisions(remaining, ctx)

        ctx =
          if terminal == :stale,
            do: %{ctx | terminal_reason: :routing_configuration_changed},
            else: ctx

        {nil, remaining, ctx}
    end
  end

  # Each selection phase records the facts and head reference it used, so every
  # dispatch from that phase, including a delayed retry, evaluates the same
  # reference. A head-policy acquisition selects and dispatches a rewritten head
  # request rather than the client's selector, so it records no client facts.
  defp capture_cursor_decisions(cursor, ctx) do
    {decisions, cursor} = CandidateCursor.take_learning_decisions(cursor)
    {proposals, cursor} = CandidateCursor.take_shadow_proposals(cursor)
    ctx = ShadowAgreement.prepare(ctx, %{shadow_proposals: proposals})

    {cursor,
     %{
       ctx
       | learning_decision: retain_learning_decision(ctx.learning_decision, decisions),
         request_facts: if(is_nil(ctx.head_policy), do: CandidateCursor.request_facts(cursor))
     }}
  end

  defp track_materialized_candidate(ctx, channel) do
    label = "#{channel.provider_id}:#{channel.transport}"

    if label in ctx.candidate_providers do
      ctx
    else
      %{ctx | candidate_providers: ctx.candidate_providers ++ [label]}
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

  defp exhausted(%{null_recovery: %NullRecovery.State{}} = ctx, caller_guard),
    do: return_original_null(ctx, :alternate_unavailable, caller_guard)

  defp exhausted(ctx, caller_guard) do
    log_exhaustion(ctx)

    {reason, jerr} = exhaustion_error(ctx)

    advance_or_exhaust(
      %{ctx | terminal_reason: ctx.terminal_reason || reason},
      reason,
      jerr,
      caller_guard
    )
  end

  defp exhaustion_error(%RequestContext{shared_capacity_denials: count}) when count > 0 do
    {
      :shared_public_capacity_exhausted,
      JError.new(-32_005, "Shared public fallback capacity exhausted",
        category: :rate_limit,
        retriable?: true,
        breaker_penalty?: false,
        data: %{shared_capacity_denials: count, capacity: :shared_public}
      )
    }
  end

  defp exhaustion_error(
         %{
           execution_envelope: %{
             execution_safety: :replay_safe,
             dispatch_count: count,
             dispatch_limit: limit
           }
         } = ctx
       )
       when count >= limit,
       do: {:providers_exhausted, dispatch_exhaustion_error(ctx)}

  defp exhaustion_error(%RequestContext{log_range_error: %JError{} = error}),
    do: {:providers_exhausted, error}

  defp exhaustion_error(%{head_policy: %{last_error: %JError{} = error}}),
    do: {:providers_exhausted, error}

  defp exhaustion_error(ctx) do
    {
      :providers_exhausted,
      JError.new(-32_000, "No available upstream completed the request within the routing policy",
        category: :provider_error,
        retriable?: true,
        breaker_penalty?: false,
        data: %{
          reason:
            if(ctx.execution_envelope.dispatch_count > 0,
              do: :upstream_attempts_exhausted,
              else: :admission_unavailable
            ),
          upstream_attempts: ctx.execution_envelope.dispatch_count
        }
      )
    }
  end

  @spec execute_on_channel(
          Channel.t(),
          candidates(),
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

    case CircuitBreaker.admit(breaker_id, candidate_deadline(channel, ctx)) do
      {:ok, %AdmissionReceipt{kind: :half_open} = receipt}
      when not is_nil(ctx.exploration_token) ->
        if Exploration.matches?(ctx.exploration_token, channel) do
          abandon_unclaimed(receipt)
          attempt_channels(rest_channels, ctx, [], caller_guard)
        else
          admit_shared_capacity(channel, instance_id, rest_channels, ctx, receipt, caller_guard)
        end

      {:ok, receipt} ->
        admit_shared_capacity(
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

  defp admit_shared_capacity(channel, instance_id, rest_channels, ctx, receipt, caller_guard) do
    case check_chain_identity(channel, ctx) do
      :ok ->
        admit_identity_checked_capacity(
          channel,
          instance_id,
          rest_channels,
          ctx,
          receipt,
          caller_guard
        )

      {:error, :chain_identity_rejected} ->
        abandon_unclaimed(receipt)

        Logger.warning("HTTP provider chain identity rejected, skipping",
          instance_id: instance_id,
          request_id: ctx.request_id
        )

        ctx = RequestContext.increment_retries(ctx)

        attempt_channels(
          rest_channels,
          %{ctx | terminal_reason: :chain_identity_rejected},
          [],
          caller_guard
        )
    end
  end

  defp check_chain_identity(%Channel{transport: :http}, %{
         method: "eth_chainId",
         opts: %RequestOptions{
           request_origin: :system,
           observation_activity: :diagnostic_identity
         }
       }),
       do: :ok

  defp check_chain_identity(channel, _ctx),
    do: ChainIdentity.check(channel.instance_id, channel.transport)

  defp admit_identity_checked_capacity(
         channel,
         instance_id,
         rest_channels,
         ctx,
         receipt,
         caller_guard
       ) do
    reserve_admitted_channel(channel, instance_id, rest_channels, ctx, receipt, caller_guard)
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

    if Exploration.matches?(ctx.exploration_token, channel) and
         (not Exploration.current?(ctx.exploration_token) or
            candidate_deadline(channel, ctx) - reserved_at_us < 25_000) do
      abandon_unclaimed(receipt)
      attempt_channels(rest_channels, ctx, [], caller_guard)
    else
      reserve_current_channel(
        channel,
        instance_id,
        rest_channels,
        ctx,
        receipt,
        caller_guard,
        reserved_at_us
      )
    end
  end

  defp reserve_current_channel(
         channel,
         instance_id,
         rest_channels,
         ctx,
         receipt,
         caller_guard,
         reserved_at_us
       ) do
    case ExecutionEnvelope.reserve_dispatch(
           ctx.execution_envelope,
           instance_id,
           channel.transport,
           reserved_at_us,
           fallback_channel_available?(rest_channels) or fallback_profile_available?(ctx)
         ) do
      {:ok, envelope, attempt_timeout_ms} ->
        # A full remaining-time allocation keeps the exact absolute cutoff.
        # Shorter attempt allocations preserve their reserved fallback share.
        allocated_deadline_us =
          if attempt_timeout_ms == ExecutionEnvelope.remaining_ms(envelope, reserved_at_us),
            do: envelope.deadline_us,
            else: reserved_at_us + attempt_timeout_ms * 1_000

        attempt_deadline_us = min(candidate_deadline(channel, ctx), allocated_deadline_us)

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

  defp candidate_deadline(channel, ctx) do
    if Exploration.matches?(ctx.exploration_token, channel),
      do: min(ctx.execution_envelope.deadline_us, ctx.exploration_token.attempt_deadline_us),
      else: ctx.execution_envelope.deadline_us
  end

  defp fallback_channel_available?(%CandidateCursor{} = cursor),
    do: CandidateCursor.pending?(cursor)

  defp fallback_channel_available?([]), do: false
  defp fallback_channel_available?(_candidates), do: true

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

    ctx = HeadPolicy.prepare_attempt(ctx)
    identity = attempt_identity(channel, instance_id, ctx, receipt)
    prepared_request = ctx.prepared_request

    case CircuitBreaker.activate_attempt(receipt, self()) do
      :ok ->
        run_owned_attempt(
          channel,
          rest_channels,
          ctx,
          receipt,
          identity,
          prepared_request,
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
         prepared_request,
         attempt_deadline_us,
         caller_guard
       ) do
    remaining_us = attempt_deadline_us - System.monotonic_time(:microsecond)
    timeout_ms = max(-Integer.floor_div(-remaining_us, 1_000), 1)

    knowledge_dispatch =
      case channel.learning_subject do
        %{id: subject} ->
          target = {identity.profile, identity.chain_id, subject}

          {Lasso.RPC.ProviderKnowledge.Persistence.adapter().epoch(target),
           System.system_time(:millisecond)}

        _ ->
          nil
      end

    ctx = ctx |> retire_last_error(:retry_started) |> ClaimAudit.record_peer(channel)

    outcome =
      Lasso.Observability.Tracing.attempt(channel, ctx, fn ->
        RequestOwner.execute(
          identity,
          attempt_deadline_us,
          build_transport_task(channel, prepared_request, timeout_ms, ctx.opts)
          |> Lasso.BlockSync.ClientObservation.wrap(
            prepared_request,
            identity,
            ctx.opts.request_origin
          ),
          caller_guard_options(caller_guard)
        )
      end)

    {decision, ctx} = qualify_response(outcome, ctx)

    qualification =
      if elem(decision, 0) in [:error, :retry], do: :policy_rejected, else: :accepted

    projection = ExecutionProjector.qualify(outcome.projection, qualification)

    _control_result = CircuitBreaker.report_canonical(receipt, outcome.fact, projection)

    _projection_result =
      AttemptProjection.process(
        AttemptProjection.new(outcome.fact, channel.provider_id, ctx.method, qualification),
        Lasso.ExecutionProjectionDispatcher,
        channel.instance_id
      )

    prepared_template = prepare_template(outcome, ctx, channel)

    ctx =
      TemplateOutcomeObservation.capture(
        ctx,
        channel,
        outcome.fact,
        prepared_template,
        projection,
        knowledge_dispatch
      )

    knowledge_options =
      transaction_evidence_options(channel, ctx, outcome) ++
        template_options(prepared_template)

    knowledge_options =
      case knowledge_dispatch do
        {epoch, dispatched_at_ms} ->
          [epoch: epoch, dispatched_at_ms: dispatched_at_ms] ++ knowledge_options

        nil ->
          knowledge_options
      end

    _knowledge_result =
      ProviderKnowledge.record_attempt(
        channel,
        ctx,
        outcome.fact,
        qualification,
        knowledge_options
      )

    _template_result = TemplateObservation.record(channel, ctx, outcome, prepared_template)
    :ok = TemplateClassification.observe(outcome, prepared_template, channel.profile)

    ctx =
      ShadowAgreement.observe(
        ctx,
        channel,
        outcome,
        qualification,
        knowledge_options
      )

    ctx = %{
      ctx
      | attempt_observation:
          LearningDecision.observe(
            ctx.attempt_observation,
            outcome.fact,
            qualification
          )
    }

    ctx = commit_attempt_context(ctx, channel, identity.upstream_instance_id, outcome)
    ctx = %{ctx | terminal_attempt_projection: projection}
    :ok = ClaimAudit.census(outcome, ctx, channel)

    if Exploration.matches?(ctx.exploration_token, channel),
      do: Exploration.complete(ctx.exploration_token, outcome.fact, qualification)

    handle_owner_outcome(outcome, channel, rest_channels, ctx, caller_guard, decision)
  end

  defp transaction_evidence_options(_channel, %{method: "eth_sendRawTransaction"}, _outcome),
    do: []

  defp transaction_evidence_options(channel, ctx, outcome),
    do: Lasso.RPC.ProviderKnowledge.Constraint.evidence_options(channel, ctx, outcome)

  @doc false
  @spec build_transport_task(Channel.t(), PreparedRequest.t(), timeout()) :: (-> term())
  def build_transport_task(
        %Channel{} = channel,
        %PreparedRequest{} = prepared_request,
        timeout_ms
      )
      when is_integer(timeout_ms) do
    fn -> Channel.request(channel, prepared_request, timeout_ms) end
  end

  defp build_transport_task(
         %Channel{} = channel,
         prepared_request,
         timeout_ms,
         %{request_origin: :system, observation_activity: activity}
       )
       when activity in [:head, :diagnostic_head, :diagnostic_identity, :revalidation] do
    fn ->
      Channel.request(channel, prepared_request, timeout_ms, observation_activity: activity)
    end
  end

  defp build_transport_task(channel, prepared_request, timeout_ms, _opts),
    do: build_transport_task(channel, prepared_request, timeout_ms)

  defp handle_activation_failure(channel, instance_id, rest_channels, ctx, caller_guard) do
    envelope =
      ExecutionEnvelope.release_dispatch(ctx.execution_envelope, instance_id, channel.transport)

    ctx =
      ctx
      |> Map.put(:execution_envelope, envelope)
      |> Map.put(:terminal_reason, :breaker_receipt_stale)
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
         caller_guard
       ) do
    ctx = %{ctx | terminal_reason: :dispatch_budget_exhausted}

    advance_or_exhaust(
      ctx,
      :dispatch_budget_exhausted,
      dispatch_exhaustion_error(ctx),
      caller_guard
    )
  end

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
      %{ctx | terminal_reason: :breaker_admission_timeout},
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
    Logger.warning("Circuit breaker admission unavailable",
      channel: Channel.to_string(channel),
      request_id: ctx.request_id
    )

    :telemetry.execute([:lasso, :circuit_breaker, :admission_unavailable], %{count: 1}, %{
      chain_id: channel.chain_id,
      provider_id: channel.provider_id,
      transport: channel.transport
    })

    ctx = RequestContext.increment_retries(ctx)

    attempt_channels(
      rest_channels,
      %{ctx | terminal_reason: :breaker_unavailable},
      [],
      caller_guard
    )
  end

  defp attempt_identity(channel, instance_id, ctx, receipt) do
    envelope = ctx.execution_envelope

    AttemptIdentity.new_runtime(%{
      request_id: ctx.request_id,
      attempt_id: "#{envelope.execution_nonce}:#{envelope.candidate_admission_count}",
      profile: ctx.routing_profile || ctx.opts.profile,
      subject_token: nil,
      chain_id: ctx.chain_id,
      upstream_instance_id: instance_id,
      transport: channel.transport,
      route_generation: channel.route_generation,
      circuit_scope: :broad,
      circuit_epoch: receipt.epoch,
      execution_safety: envelope.execution_safety,
      attempt_kind:
        if(Exploration.matches?(ctx.exploration_token, channel),
          do: :exploration,
          else: :ordinary
        ),
      routing_intent: Atom.to_string(ctx.opts.strategy),
      workload_key: origin_workload_key(ctx),
      request_budget_ms: envelope.original_timeout_ms,
      candidate_admission_count: envelope.candidate_admission_count,
      dispatch_count: envelope.dispatch_count
    })
  end

  defp commit_attempt_context(ctx, channel, instance_id, outcome) do
    if match?(%AttemptTerminal.Response{kind: :success}, outcome.fact),
      do: CredentialHealth.observe_success(instance_id)

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

    ctx = RequestContext.record_terminal_attempt(ctx, channel, outcome.fact)

    %{
      ctx
      | execution_envelope: envelope,
        terminal_attempt_projection: outcome.projection,
        request_dispatch_certainty: certainty,
        terminal_reason: nil
    }
  end

  defp qualify_response(
         %{fact: %AttemptTerminal.Response{kind: :success}, result: {:ok, result, _io_ms}},
         ctx
       ) do
    {disposition, value, ctx} = HeadPolicy.accept(result, ctx)
    {{disposition, value}, ctx}
  end

  defp qualify_response(_outcome, ctx), do: {{:continue, nil}, ctx}

  defp handle_owner_outcome(outcome, channel, rest_channels, ctx, caller_guard, decision) do
    head =
      if MissingBlock.candidate?(ctx, outcome),
        do: MissingBlock.capture(ctx, channel, rest_channels)

    ctx = MissingBlock.observe(ctx, channel, outcome, head)
    do_handle_owner_outcome(outcome, channel, rest_channels, ctx, caller_guard, decision, head)
  end

  defp do_handle_owner_outcome(
         %{fact: %AttemptTerminal.Response{kind: :success} = fact, result: {:ok, result, _io_ms}},
         channel,
         rest_channels,
         ctx,
         caller_guard,
         decision,
         head
       ) do
    case decision do
      {:error, error} ->
        Success.release_capacity(result, :head_policy_rejected)
        finalize_error(error, RequestContext.record_channel_success(ctx, channel))

      {:ok, result} ->
        require_open? =
          ctx.head_policy || ctx.null_recovery ||
            match?(%ClaimAudit.State{status: :peer}, ctx.claim_audit)

        case if(require_open?, do: request_open(ctx, caller_guard), else: :ok) do
          :ok ->
            serve_success(result, fact, channel, rest_channels, ctx, caller_guard, head)

          {:error, :caller_abandoned} ->
            Success.release_capacity(result, :caller_abandoned)
            finalize_caller_abandoned(RequestContext.record_channel_success(ctx, channel))

          {:error, :deadline_exhausted} ->
            Success.release_capacity(result, :deadline_exhausted)

            finalize_bounded_error(
              RequestContext.record_channel_success(ctx, channel),
              :deadline_exhausted
            )
        end

      {:retry, error} ->
        Success.release_capacity(result, :head_policy_rejected)

        ctx =
          ctx
          |> RequestContext.add_upstream_latency(fact_latency_ms(fact))
          |> RequestContext.record_channel_attempt(channel, error)
          |> RequestContext.increment_retries()

        if match?(%ClaimAudit.State{status: :peer}, ctx.claim_audit) do
          :ok = ClaimAudit.decision(ctx, :peer_policy_rejected)
          finalize_error(error, ctx)
        else
          attempt_channels(rest_channels, ctx, [], caller_guard)
        end
    end
  end

  defp do_handle_owner_outcome(
         outcome,
         channel,
         _rest_channels,
         %{null_recovery: %NullRecovery.State{}} = ctx,
         caller_guard,
         {:continue, nil},
         _head
       ) do
    {reason, _latency_ms} = owner_error(outcome)

    # Recovery keeps its original-null terminal. Explain why the alternate's
    # request-fault claim cannot spend a second exploratory send.
    if ClaimAudit.mode(channel.profile) == :on and
         ClaimAudit.assess(outcome, ctx) == :eligible_claim do
      :ok = ClaimAudit.decision(ctx, :extra_send_spent)
    end

    ctx
    |> record_owner_failure(channel, outcome.fact, reason)
    |> return_original_null(:alternate_failed, caller_guard)
  end

  defp do_handle_owner_outcome(
         outcome,
         channel,
         _rest_channels,
         %{claim_audit: %ClaimAudit.State{status: :peer}} = ctx,
         _caller_guard,
         {:continue, nil},
         _head
       ) do
    :ok = ClaimAudit.decision(ctx, :peer_inconclusive)
    handle_owner_terminal(outcome, channel, ctx)
  end

  defp do_handle_owner_outcome(
         outcome,
         channel,
         rest_channels,
         ctx,
         caller_guard,
         {:continue, nil},
         _head
       ),
       do: ordinary_owner_error(outcome, channel, rest_channels, ctx, caller_guard)

  defp ordinary_owner_error(outcome, channel, rest_channels, ctx, caller_guard) do
    {reason, _latency_ms} = owner_error(outcome)
    profile = channel.profile
    mode = ClaimAudit.mode(profile)
    eligibility = if mode == :on, do: ClaimAudit.assess(outcome, ctx), else: :disabled

    if mode == :on and eligibility == :eligible_claim do
      begin_claim_audit(outcome, channel, rest_channels, ctx, caller_guard)
    else
      case LogRangeLimit.translate(ctx.method, reason,
             provider_id: channel.provider_id,
             transport: channel.transport
           ) do
        {:ok, range_error} ->
          if LogRangeLimit.upstream_limit?(reason) do
            ctx = %{ctx | log_range_error: range_error}

            handle_owner_fallback(
              outcome,
              channel,
              rest_channels,
              ctx,
              caller_guard,
              :log_range_limit
            )
          else
            handle_owner_terminal(outcome, channel, ctx, range_error)
          end

        :not_range_limit ->
          if outcome.projection.fallback_eligible do
            handle_owner_fallback(outcome, channel, rest_channels, ctx, caller_guard)
          else
            handle_owner_terminal(outcome, channel, ctx)
          end
      end
    end
  end

  defp begin_claim_audit(outcome, channel, rest_channels, ctx, caller_guard) do
    {reason, _latency_ms} = owner_error(outcome)

    cond do
      ctx.execution_envelope.dispatch_count >= ctx.execution_envelope.dispatch_limit ->
        :ok = ClaimAudit.decision(ctx, :dispatch_budget_denied)
        handle_owner_terminal(outcome, channel, ctx, nil, caller_guard)

      ExecutionEnvelope.remaining_ms(ctx.execution_envelope) < 25 ->
        :ok = ClaimAudit.decision(ctx, :deadline_denied)
        handle_owner_terminal(outcome, channel, ctx, nil, caller_guard)

      true ->
        case pop_candidate(rest_channels, ctx) do
          {%Channel{} = peer, remaining, ctx} ->
            case ClaimAudit.start(ctx, outcome, channel, caller_guard) do
              {:ok, ctx} ->
                ctx =
                  ctx
                  |> record_owner_failure(channel, outcome.fact, reason)
                  |> RequestContext.increment_retries()

                :ok = ClaimAudit.decision(ctx, :proposed)
                attempt_channels({peer, remaining}, ctx, [], caller_guard)

              {:error, :extra_send_spent} ->
                handle_owner_terminal(outcome, channel, ctx, nil, caller_guard)
            end

          {nil, _remaining, ctx} ->
            if fallback_profile_available?(ctx) do
              case ClaimAudit.start(ctx, outcome, channel, caller_guard) do
                {:ok, ctx} ->
                  ctx = record_owner_failure(ctx, channel, outcome.fact, reason)
                  :ok = ClaimAudit.decision(ctx, :fallback_proposed)
                  advance_or_exhaust(ctx, :claim_audit, reason, caller_guard)

                {:error, :extra_send_spent} ->
                  handle_owner_terminal(outcome, channel, ctx, nil, caller_guard)
              end
            else
              :ok = ClaimAudit.decision(ctx, :no_peer)
              handle_owner_terminal(outcome, channel, ctx, nil, caller_guard)
            end
        end
    end
  end

  defp handle_owner_fallback(
         outcome,
         channel,
         rest_channels,
         ctx,
         caller_guard,
         exhaustion_category \\ nil
       ) do
    {reason, _latency_ms} = owner_error(outcome)
    next_channels = maybe_exclude_provider_for_method_not_found(rest_channels, channel, reason)

    case pop_candidate(next_channels, ctx) do
      {%Channel{} = next_channel, remaining, ctx} ->
        ctx = record_owner_failure(ctx, channel, outcome.fact, reason, exhaustion_category)

        ctx =
          ctx
          |> RequestContext.increment_retries()
          |> RequestContext.track_error_category(extract_error_category(reason))

        attempt_channels({next_channel, remaining}, ctx, [], caller_guard)

      {nil, _remaining, ctx} ->
        handle_exhausted_owner_fallback(
          outcome,
          channel,
          ctx,
          caller_guard,
          reason,
          exhaustion_category
        )
    end
  end

  defp handle_exhausted_owner_fallback(
         outcome,
         channel,
         ctx,
         caller_guard,
         reason,
         exhaustion_category
       ) do
    cond do
      ctx.execution_envelope.execution_safety == :replay_safe and
          ctx.execution_envelope.dispatch_count >= ctx.execution_envelope.dispatch_limit ->
        ctx = record_owner_failure(ctx, channel, outcome.fact, reason, exhaustion_category)
        handle_dispatch_rejection([], ctx, :dispatch_budget_exhausted, caller_guard)

      match?(%AttemptTerminal.PredispatchFailure{}, outcome.fact) ->
        attempt_channels([], ctx, [], caller_guard)

      mixed_method_not_found?(ctx, reason) ->
        ctx = record_owner_failure(ctx, channel, outcome.fact, reason, exhaustion_category)
        attempt_channels([], ctx, [], caller_guard)

      true ->
        handle_owner_terminal(
          outcome,
          channel,
          %{ctx | terminal_reason: :providers_exhausted},
          ctx.log_range_error
        )
    end
  end

  defp handle_owner_terminal(
         outcome,
         channel,
         ctx,
         terminal_error \\ nil,
         caller_guard \\ :unchecked
       ) do
    {reason, _latency_ms} = owner_error(outcome)
    ctx = record_owner_failure(ctx, channel, outcome.fact, reason)
    ctx = record_public_response_attempt(ctx, outcome.fact)
    ctx = RequestContext.set_executed_channel(ctx, channel)
    finalize_error(terminal_error || owner_terminal_error(outcome, channel), ctx, caller_guard)
  end

  defp record_public_response_attempt(ctx, %AttemptTerminal.Response{} = fact),
    do: %{ctx | public_response_attempt: fact}

  defp record_public_response_attempt(ctx, _fact), do: ctx

  defp prepare_template(_outcome, %{method: "eth_sendRawTransaction"}, _channel), do: nil

  defp prepare_template(
         %{fact: %AttemptTerminal.Response{kind: :application_error}, result: result},
         ctx,
         channel
       ) do
    provider_config = channel.template_provider_config

    case {result, provider_config} do
      {{:error, %JError{message: message}}, config}
      when is_binary(message) and is_map(config) ->
        masked_template(message, ctx.params, provider_config)

      {{:error, %JError{message: message}, _elapsed}, config}
      when is_binary(message) and is_map(config) ->
        masked_template(message, ctx.params, provider_config)

      _ ->
        nil
    end
  end

  defp prepare_template(_outcome, _ctx, _channel), do: nil

  defp masked_template(message, params, provider_config) do
    case Template.prepare(message, params, provider_config) do
      {:ok, prepared} -> prepared
      _ -> nil
    end
  end

  defp template_options(%{fingerprint: fingerprint}), do: [template_fingerprint: fingerprint]
  defp template_options(_), do: []

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

  defp record_owner_failure(ctx, channel, fact, reason, exhaustion_category \\ nil) do
    observe_upstream_capacity(channel, fact, reason)

    if authoritative_not_dispatched?(fact) do
      ctx
    else
      maybe_observe_credential_failure(ctx, channel, reason)

      ctx
      |> RequestContext.add_upstream_latency(fact_latency_ms(fact))
      |> RequestContext.record_channel_attempt(channel, reason, exhaustion_category)
    end
  end

  defp maybe_observe_credential_failure(ctx, channel, %JError{
         category: category,
         http_status: status
       })
       when category == :auth_error or status == 401 do
    observe_credential_rejection(ctx, channel)
  end

  defp maybe_observe_credential_failure(ctx, channel, {kind, %{status: 401}})
       when kind in [:client_error, :server_error] do
    observe_credential_rejection(ctx, channel)
  end

  defp maybe_observe_credential_failure(_ctx, _channel, _reason), do: :ok

  defp observe_credential_rejection(ctx, channel) do
    CredentialHealth.observe_failure(%{
      error_category: :auth_error,
      upstream_instance_id: channel.instance_id,
      provider_id: channel.provider_id,
      chain_id: ctx.chain_id
    })
  end

  defp observe_upstream_capacity(
         channel,
         %AttemptTerminal.Response{},
         %JError{category: :rate_limit} = error
       ) do
    outcome =
      if Lasso.Core.Support.ErrorClassification.quota_exhausted?(error.http_status) or
           Lasso.Core.Support.ErrorClassification.quota_exhausted?(error.message),
         do: :quota_exhausted,
         else: :throttled

    :telemetry.execute([:lasso, :rpc, :upstream_capacity], %{count: 1}, %{
      transport: channel.transport,
      capacity_class: :customer_owned,
      outcome: outcome
    })
  end

  defp observe_upstream_capacity(_channel, _fact, _error), do: :ok

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
  defp serve_success(
         result,
         fact,
         channel,
         _rest_channels,
         %{null_recovery: %NullRecovery.State{} = state} = ctx,
         caller_guard,
         _head
       ) do
    if Success.null_result?(result) do
      Success.release_capacity(result, :null_recovery_alternate_null)

      ctx
      |> RequestContext.add_upstream_latency(fact_latency_ms(fact))
      |> RequestContext.record_channel_success(channel)
      |> return_original_null(:alternate_null, caller_guard)
    else
      Capacity.release(state.original, :null_recovery_replaced)
      :ok = NullRecovery.decision(ctx, :replaced)
      handle_success(result, fact_latency_ms(fact), channel, %{ctx | null_recovery: nil})
    end
  end

  defp serve_success(result, fact, channel, rest_channels, ctx, caller_guard, head) do
    case NullRecovery.assess(ctx, channel, result, head) do
      :ordinary ->
        handle_success(result, fact_latency_ms(fact), channel, ctx)

      {:declined, reason} ->
        decline_missing(result, fact, channel, ctx, caller_guard, reason)

      {:recover, _, _} = assessment ->
        recover_missing(result, fact, channel, rest_channels, ctx, caller_guard, assessment)
    end
  end

  defp recover_missing(
         result,
         fact,
         channel,
         cursor,
         ctx,
         caller_guard,
         {:recover, height, routes}
       ) do
    case NullRecovery.denial(ctx.execution_envelope) do
      nil ->
        ctx = %{
          ctx
          | execution_envelope: NullRecovery.reserve(ctx.execution_envelope),
            null_recovery: %NullRecovery.State{
              height: height,
              original: result,
              original_channel: channel,
              original_fact: ctx.terminal_attempt_fact,
              caller_guard: caller_guard
            }
        }

        cursor = cap_recovery_cursor(cursor, ctx.execution_envelope)
        ctx = record_missing_attempt(ctx, channel, fact, result)

        case alternate(cursor, ctx, routes, 8) do
          {%Channel{} = alternate, _rest, ctx} ->
            :ok = NullRecovery.decision(ctx, :proposed)

            attempt_channels(
              {alternate, []},
              RequestContext.increment_retries(ctx),
              [],
              caller_guard
            )

          {nil, _rest, ctx} ->
            return_original_null(ctx, :alternate_unavailable, caller_guard)
        end

      reason ->
        decline_missing(result, fact, channel, ctx, caller_guard, reason)
    end
  end

  defp cap_recovery_cursor(%CandidateCursor{} = cursor, envelope) do
    envelope = ExecutionEnvelope.cap_deadline(envelope, cursor.deadline_us)
    %{cursor | deadline_us: envelope.deadline_us}
  end

  defp cap_recovery_cursor(cursor, _envelope), do: cursor

  defp decline_missing(result, fact, channel, ctx, caller_guard, reason) do
    :ok = NullRecovery.decision(ctx, reason)
    finish_missing_response(result, fact, channel, ctx, caller_guard)
  end

  defp record_missing_attempt(ctx, channel, fact, %JError{} = error),
    do: record_owner_failure(ctx, channel, fact, error)

  defp record_missing_attempt(ctx, channel, fact, %Success{}),
    do:
      ctx
      |> RequestContext.add_upstream_latency(fact_latency_ms(fact))
      |> RequestContext.record_channel_success(channel)

  defp finish_missing_response(result, fact, channel, ctx, caller_guard) do
    case request_open(ctx, caller_guard) do
      :ok ->
        case result do
          %JError{} = error ->
            ctx =
              ctx
              |> record_owner_failure(channel, fact, error)
              |> record_public_response_attempt(fact)
              |> RequestContext.set_executed_channel(channel)

            finalize_error(error, ctx, caller_guard)

          %Success{} ->
            handle_success(result, fact_latency_ms(fact), channel, ctx)
        end

      {:error, reason} ->
        Capacity.release(result, reason)

        if reason == :caller_abandoned,
          do: finalize_caller_abandoned(ctx),
          else: finalize_bounded_error(ctx, reason)
    end
  end

  defp alternate(_cursor, ctx, _routes, 0), do: {nil, [], ctx}

  defp alternate(cursor, ctx, routes, budget) do
    case pop_candidate(cursor, ctx) do
      {%Channel{} = channel, rest, ctx} ->
        if MapSet.member?(routes, {channel.instance_id, channel.transport}),
          do: {channel, rest, ctx},
          else: alternate(rest, ctx, routes, budget - 1)

      {nil, rest, ctx} ->
        {nil, rest, ctx}
    end
  end

  defp return_original_null(%{null_recovery: state} = ctx, decision, caller_guard) do
    :ok = NullRecovery.decision(ctx, decision)
    ctx = ctx |> retire_last_error(:null_recovery_discarded) |> Map.put(:null_recovery, nil)

    if ExecutionScope.caller_alive?(caller_guard) and not RequestOwner.shutdown_requested?() do
      ctx =
        ctx
        |> RequestContext.set_executed_channel(state.original_channel)
        |> Map.put(:effective_profile, state.original_channel.profile)
        |> RequestContext.mark_upstream_end()
        |> Map.put(:public_response_attempt, state.original_fact)

      case state.original do
        %Success{} = original -> {:ok, original, RequestContext.record_success(ctx, original)}
        %JError{} = original -> finalize_error(original, ctx)
      end
    else
      Capacity.release(state.original, :caller_abandoned)
      finalize_caller_abandoned(ctx)
    end
  end

  defp handle_success(result, io_ms, channel, ctx) do
    log_slow_request_if_needed(io_ms, ctx.method, channel, ctx)

    ctx = ClaimAudit.finish_success(ctx)

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
          candidates(),
          RequestContext.t(),
          ExecutionScope.CallerGuard.t() | nil
        ) :: result()
  defp handle_circuit_open(channel, rest_channels, ctx, caller_guard) do
    log_circuit_open(channel, ctx)

    ctx = RequestContext.increment_retries(ctx)

    attempt_channels(
      rest_channels,
      %{ctx | terminal_reason: :circuit_open},
      [],
      caller_guard
    )
  end

  defp log_circuit_open(channel, %{request_id: request_id}) do
    level = if block_sync_request?(request_id), do: :debug, else: :info

    Logger.log(level, "Circuit breaker open, skipping",
      channel: Channel.to_string(channel),
      request_id: request_id
    )
  end

  defp log_exhaustion(ctx) do
    level = if block_sync_request?(ctx.request_id), do: :debug, else: :warning

    Logger.log(level, "All channels exhausted",
      chain_id: ctx.chain_id,
      method: ctx.method,
      request_id: ctx.request_id,
      attempts: length(ctx.attempted_channels),
      shared_capacity_denials: ctx.shared_capacity_denials,
      terminal_reason: ctx.terminal_reason
    )
  end

  defp block_sync_request?(request_id) when is_binary(request_id),
    do: String.starts_with?(request_id, "block-sync:")

  defp block_sync_request?(_), do: false

  defp selection_exhaustion_reason(%CandidateCursor{} = cursor),
    do: CandidateCursor.exhaustion_reason(cursor)

  defp selection_exhaustion_reason(_candidates), do: :no_eligible_providers

  @spec handle_no_channels(
          RequestContext.t(),
          ExecutionScope.CallerGuard.t() | nil,
          atom(),
          selection_source()
        ) ::
          result()
  defp handle_no_channels(ctx, caller_guard, reason, candidates) do
    profile =
      ctx.routing_profile ||
        if(ctx.opts, do: ctx.opts.profile, else: ProfileValidator.default_profile())

    retry_after_ms =
      if reason == :no_eligible_providers,
        do: calculate_min_recovery_time(profile, ctx.chain_id, ctx.opts && ctx.opts.transport)

    {message, data} = build_exhaustion_error_message(ctx.method, retry_after_ms, ctx.chain_id)

    message =
      case reason do
        :archive_required ->
          "No eligible upstream for #{ctx.method}: the requested block requires archival support, but no remaining provider on the requested transport declares it."

        :transport_unavailable ->
          "No eligible upstream for #{ctx.method}: no remaining provider supports the requested transport."

        _ ->
          message
      end

    data =
      Map.merge(data, %{reason: reason, upstream_attempts: ctx.execution_envelope.dispatch_count})

    jerr =
      JError.new(-32_000, message,
        category: :provider_error,
        retriable?:
          reason not in [
            :archive_required,
            :transport_unavailable,
            :no_providers_configured,
            :providers_excluded
          ],
        breaker_penalty?: false,
        data: data
      )

    Exhaustion.record(ctx, candidates, reason)

    advance_or_exhaust(
      %{ctx | terminal_reason: :no_candidates},
      :no_channels,
      jerr,
      caller_guard
    )
  end

  defp advance_or_exhaust(ctx, _reason, terminal_error, _caller_guard),
    do: finalize_profile_exhaustion(ctx, terminal_error)

  defp fallback_profile_available?(_ctx), do: false

  defp finalize_profile_exhaustion(ctx, %JError{} = terminal_error) do
    ctx = %{ctx | terminal_reason: ctx.terminal_reason || :providers_exhausted}

    terminal_error =
      if ctx.execution_envelope.dispatch_count >= ctx.execution_envelope.dispatch_limit and
           ctx.execution_envelope.execution_safety == :replay_safe,
         do: elem(exhaustion_error(ctx), 1),
         else: ctx.log_range_error || terminal_error

    {terminal_error, ctx} = method_not_found_terminal(terminal_error, ctx)

    finalize_error(terminal_error, ctx)
  end

  # The caller learns the method is unsupported only when every upstream the request reached
  # said so and the context still holds the latest rejection whole. That rejection is then
  # delivered as the upstream's own response, replacing Lasso's generic exhaustion error. A
  # rejection mixed with any other outcome, or one a later pre-dispatch failure reduced to a
  # diagnostic summary, never becomes the answer.
  defp method_not_found_terminal(%JError{category: :provider_error} = generic, ctx) do
    if rejection_is_answer?(ctx),
      do: {ctx.last_attempt_error, RequestContext.adopt_terminal_response(ctx)},
      else: {generic, ctx}
  end

  defp method_not_found_terminal(%JError{category: :method_not_found} = rejection, ctx) do
    if rejection_is_answer?(ctx),
      do: {rejection, RequestContext.adopt_terminal_response(ctx)},
      else: {elem(exhaustion_error(ctx), 1), ctx}
  end

  defp method_not_found_terminal(terminal_error, ctx), do: {terminal_error, ctx}

  defp rejection_is_answer?(%RequestContext{
         last_attempt_error: %JError{category: :method_not_found},
         terminal_attempt_fact: %AttemptTerminal.Response{},
         attempted_channels: [_ | _] = attempts
       }),
       do: Enum.all?(attempts, &(&1.category == :method_not_found))

  defp rejection_is_answer?(_ctx), do: false

  defp mixed_method_not_found?(%RequestContext{attempted_channels: attempts}, %JError{
         category: :method_not_found
       }),
       do: Enum.any?(attempts, &(&1.category != :method_not_found))

  defp mixed_method_not_found?(_ctx, _reason), do: false

  defp retire_last_error(%{last_attempt_error: %JError{} = error} = ctx, reason) do
    retired =
      if ClaimAudit.holds_original?(ctx, error) or NullRecovery.holds_original?(ctx, error),
        do: JError.summary(error),
        else: Capacity.discard(error, reason)

    %{ctx | last_attempt_error: retired}
  end

  defp retire_last_error(ctx, _reason), do: ctx

  @spec finalize_error(JError.t(), RequestContext.t()) :: result()
  defp finalize_error(jerr, ctx, caller_guard \\ :unchecked) do
    caller_guard =
      case {caller_guard, ctx.claim_audit} do
        {:unchecked, %ClaimAudit.State{status: status, caller_guard: guard}}
        when status in [:pending, :peer] ->
          guard

        _ ->
          caller_guard
      end

    openness =
      cond do
        caller_guard == :unchecked ->
          :ok

        ctx.terminal_reason == :caller_abandoned or jerr.category == :cancelled ->
          {:error, :caller_abandoned}

        true ->
          request_open(ctx, caller_guard)
      end

    case openness do
      :ok ->
        finalize_selected_error(jerr, ctx)

      {:error, :caller_abandoned} ->
        finalize_selected_error(caller_abandoned_error(), %{
          ctx
          | terminal_reason: :caller_abandoned,
            public_response_attempt: nil
        })

      {:error, :deadline_exhausted} ->
        finalize_selected_error(bounded_error(:deadline_exhausted), %{
          ctx
          | terminal_reason: :deadline_exhausted,
            public_response_attempt: nil
        })
    end
  end

  defp finalize_selected_error(jerr, ctx) do
    {ctx, jerr} = ClaimAudit.finish_failure(ctx, jerr)
    previous = ctx.last_attempt_error

    if Capacity.lease(previous) != Capacity.lease(jerr),
      do: Capacity.release(previous, :translated_or_replaced)

    ctx = %{
      ctx
      | last_attempt_error:
          if(match?(%JError{}, previous), do: JError.summary(previous), else: previous)
    }

    ctx =
      ctx
      |> RequestContext.mark_upstream_end()
      |> RequestContext.record_error(jerr)

    {:error, jerr, ctx}
  end

  defp finalize_caller_abandoned(%{null_recovery: %NullRecovery.State{} = state} = ctx) do
    Capacity.release(state.original, :caller_abandoned)
    finalize_caller_abandoned(%{ctx | null_recovery: nil})
  end

  defp finalize_caller_abandoned(ctx) do
    finalize_error(caller_abandoned_error(), %{ctx | terminal_reason: :caller_abandoned})
  end

  defp caller_abandoned_error do
    JError.new(-32_000, "Request caller abandoned execution",
      category: :cancelled,
      retriable?: false,
      breaker_penalty?: false
    )
  end

  defp request_open(ctx, caller_guard) do
    cond do
      not ExecutionScope.caller_alive?(caller_guard) or RequestOwner.shutdown_requested?() ->
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

  # The alternate's deadline sits inside the request's, so the original null is
  # still returned on time.
  defp finalize_bounded_error(%{null_recovery: %NullRecovery.State{} = state} = ctx, _reason),
    do: return_original_null(ctx, :alternate_failed, state.caller_guard)

  defp finalize_bounded_error(ctx, reason) do
    if is_nil(ctx.selected_provider) and is_nil(ctx.selection_start) do
      Exhaustion.log_failure(ctx, [], reason)
    end

    finalize_error(bounded_error(reason), %{ctx | terminal_reason: reason})
  end

  defp bounded_error(reason) do
    bounded_errors = %{
      deadline_exhausted: {"Request deadline exhausted", :timeout},
      dispatch_budget_exhausted: {"Request dispatch budget exhausted", :provider_error},
      candidate_budget_exhausted: {
        "Candidate admission budget exhausted",
        :local_capacity_rejection
      }
    }

    {message, category} = Map.fetch!(bounded_errors, reason)

    code = if category == :local_capacity_rejection, do: -32_005, else: -32_000

    JError.new(code, message,
      category: category,
      retriable?: false,
      data: %{reason: reason}
    )
  end

  defp dispatch_exhaustion_error(%{head_policy: %{last_error: %JError{} = error}}),
    do: %{error | retriable?: false}

  defp dispatch_exhaustion_error(%RequestContext{last_attempt_error: %JError{} = error} = ctx) do
    if error.category == :method_not_found and not rejection_is_answer?(ctx),
      do: bounded_error(:dispatch_budget_exhausted),
      else: %{error | retriable?: false}
  end

  defp dispatch_exhaustion_error(%RequestContext{attempted_channels: [_ | _] = attempts}) do
    %{channel: channel, category: category, code: code} = List.last(attempts)

    JError.new(code || -32_000, "Request dispatch budget exhausted",
      provider_id: channel.provider_id,
      transport: channel.transport,
      category: category || :provider_error,
      retriable?: false
    )
  end

  defp dispatch_exhaustion_error(_ctx), do: bounded_error(:dispatch_budget_exhausted)

  defp finalize_request_terminal({status, value, %RequestContext{} = ctx})
       when status in [:ok, :error] do
    :ok = MissingBlock.finish(status, value, ctx)
    :ok = ShadowAgreement.record(ctx)
    _template_outcomes = TemplateOutcomeObservation.record(status, ctx)
    request_terminal = build_request_terminal(status, value, ctx)

    ctx = %{
      ctx
      | learning_decision:
          LearningDecision.attach(
            ctx.learning_decision,
            ctx.attempt_observation
          )
    }

    _enqueue_result =
      RequestProjection.record_and_enqueue(
        request_terminal,
        ctx.method,
        request_projection_route(ctx),
        ctx.retries,
        ctx.opts.request_origin,
        ctx.account_id,
        %{
          ingress_transport: ctx.opts.ingress_transport,
          requested_profile: ctx.requested_profile,
          service_profile: ctx.service_profile,
          effective_profile: ctx.effective_profile,
          fallback_depth: ctx.fallback_depth,
          fallback_reason: ctx.fallback_reason,
          learning_decision: ctx.learning_decision,
          exhaustion_cause: exhaustion_cause(request_terminal, ctx),
          selector: selector_cell(ctx)
        }
      )

    {status, value, release_execution_payloads(ctx)}
  end

  defp selector_cell(%RequestContext{opts: %{request_origin: :client} = opts} = ctx) do
    strategy = if is_binary(opts.provider_override), do: :override, else: opts.strategy
    {RequestAnalysis.selector_class(ctx.method, ctx.block_facts), strategy}
  end

  defp selector_cell(_ctx), do: nil

  defp request_projection_route(%RequestContext{executed_channel: %{} = route}), do: route

  defp request_projection_route(%RequestContext{attempted_channels: attempted_channels}) do
    case List.last(attempted_channels) do
      %{channel: %{} = route} -> route
      _other -> nil
    end
  end

  @doc "Materializes the single request terminal from the final public outcome."
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
        %RequestContext{terminal_attempt_fact: %AttemptTerminal.Cancelled{reason: reason}} = ctx
      )
      when reason in [:caller_abandoned, :owner_shutdown] do
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
    build_upstream_request_terminal(ctx, attempt)
  end

  def build_request_terminal(
        :error,
        _value,
        %RequestContext{
          public_response_attempt: %AttemptTerminal.Response{} = attempt
        } = ctx
      ) do
    build_upstream_request_terminal(ctx, attempt)
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

  def build_request_terminal(
        :error,
        %JError{category: :block_not_available, data: %{policy: "global"}},
        ctx
      ) do
    RequestTerminal.LocalFailure.new(request_terminal_attrs(ctx), :block_publication)
  end

  def build_request_terminal(:ok, _value, %{head_policy: %{mode: "global"}} = ctx) do
    RequestTerminal.LocalSuccess.new(request_terminal_attrs(ctx), :published_block)
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

  defp build_upstream_request_terminal(ctx, attempt) do
    envelope = ctx.execution_envelope

    RequestTerminal.UpstreamResponse.new_runtime(
      attempt,
      request_elapsed_us(envelope),
      envelope.candidate_admission_count,
      envelope.dispatch_count,
      nil
    )
  end

  defp request_terminal_attrs(ctx) do
    envelope = ctx.execution_envelope

    [
      request_id: ctx.request_id,
      profile: ctx.routing_profile || ctx.opts.profile,
      subject_token: nil,
      chain_id: ctx.chain_id,
      execution_safety: envelope.execution_safety,
      routing_intent: Atom.to_string(ctx.opts.strategy),
      workload_key: request_workload_key(ctx),
      elapsed_us: request_elapsed_us(envelope),
      candidate_admission_count: envelope.candidate_admission_count,
      dispatch_count: envelope.dispatch_count,
      observed_at: nil
    ]
  end

  defp request_elapsed_us(envelope) do
    max(System.monotonic_time(:microsecond) - envelope.started_at_us, 0)
  end

  defp final_exhaustion_reason(%RequestContext{terminal_reason: reason})
       when reason in [:candidate_budget_exhausted, :dispatch_budget_exhausted],
       do: reason

  defp final_exhaustion_reason(%RequestContext{terminal_reason: reason})
       when reason in [:admission_unavailable | @admission_causes],
       do: :admission_unavailable

  defp final_exhaustion_reason(_ctx), do: :providers_exhausted

  # The precise reason no upstream attempt completed, for telemetry and routing decisions; the
  # request terminal keeps its coarse class.
  defp exhaustion_cause(%RequestTerminal.OrdinaryExhaustion{}, %RequestContext{} = ctx),
    do: ctx.terminal_reason || :providers_exhausted

  defp exhaustion_cause(_request_terminal, _ctx), do: nil

  defp request_workload_key(%RequestContext{public_response_attempt: fact})
       when not is_nil(fact) do
    fact.identity.workload_key
  end

  defp request_workload_key(%RequestContext{terminal_attempt_fact: fact}) when not is_nil(fact),
    do: fact.identity.workload_key

  defp request_workload_key(ctx), do: origin_workload_key(ctx)

  defp origin_workload_key(ctx),
    do: Workload.encode(Workload.for_request(ctx.opts.request_origin, ctx.method))

  defp release_execution_payloads(ctx) do
    opts = bounded_return_options(ctx.opts)

    %{
      ctx
      | request_id: BoundedIdentifier.encode(ctx.request_id),
        account_id: bounded_optional(ctx.account_id),
        method: BoundedIdentifier.encode(ctx.method),
        requested_profile: bounded_optional(ctx.requested_profile),
        service_profile: bounded_optional(ctx.service_profile),
        effective_profile: bounded_optional(ctx.effective_profile),
        path: bounded_optional(ctx.path),
        client_ip: bounded_optional(ctx.client_ip),
        user_agent: bounded_optional(ctx.user_agent),
        candidate_providers: Enum.map(ctx.candidate_providers, &BoundedIdentifier.encode/1),
        selected_provider: bounded_selected_provider(ctx.selected_provider),
        selection_reason: bounded_optional(ctx.selection_reason),
        params: [],
        shadow_predictions: %{},
        rpc_request: nil,
        prepared_request: nil,
        opts: opts
    }
  end

  defp bounded_return_options(nil), do: nil

  defp bounded_return_options(%RequestOptions{} = opts) do
    %{
      opts
      | profile: BoundedIdentifier.encode(opts.profile),
        requested_profile: bounded_optional(opts.requested_profile),
        account_id: bounded_optional(opts.account_id),
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
    case opts.request_context do
      %RequestContext{} = ctx -> RequestContext.bound_request_id(ctx)
      nil -> RequestContext.new(chain_id, method, params, opts)
    end
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

  defp prepare_request(%RequestContext{execution_envelope: envelope}, rpc_request) do
    PreparedRequest.new(rpc_request, "lasso-" <> envelope.execution_nonce)
  end

  defp finalize_prepare_error(reason, ctx) do
    error =
      JError.new(-32_602, "Invalid JSON-RPC request payload",
        category: :invalid_params,
        retriable?: false,
        data: %{reason: inspect(reason, limit: 4, printable_limit: 256)}
      )

    finalize_error(error, %{ctx | terminal_reason: :invalid_request})
  end

  @spec get_provider_channels(String.t(), chain_id(), String.t(), atom() | nil, integer()) :: [
          Channel.t()
        ]
  defp get_provider_channels(profile, chain_id, provider_id, transport_override, deadline_us) do
    case active_catalog_provider(profile, chain_id, provider_id) do
      {:ok, snapshot, provider, instance} ->
        transports = if transport_override, do: [transport_override], else: [:http, :ws]

        channels =
          for transport <- transports,
              channel =
                fetch_channel_safe(profile, chain_id, provider_id, transport,
                  provider_config: instance,
                  deadline_us: deadline_us,
                  instance_id: provider.instance_id,
                  route_generation: snapshot.generation
                ),
              not is_nil(channel),
              do: channel

        channels

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
    with %{} = snapshot <- Catalog.snapshot(),
         {:ok, plan} <- Catalog.get_routing_plan(snapshot, profile, chain_id),
         provider when not is_nil(provider) <-
           Enum.find(plan.providers, &(&1.id == provider_id)) do
      {:ok, snapshot, provider, provider.config}
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

  @spec maybe_exclude_provider_for_method_not_found(candidates(), Channel.t(), any()) ::
          candidates()
  defp maybe_exclude_provider_for_method_not_found(rest_channels, channel, %JError{
         category: :method_not_found
       }) do
    case rest_channels do
      %CandidateCursor{} = cursor -> CandidateCursor.exclude_provider(cursor, channel.provider_id)
      channels -> Enum.reject(channels, &(&1.provider_id == channel.provider_id))
    end
  end

  defp maybe_exclude_provider_for_method_not_found(rest_channels, _channel, _reason),
    do: rest_channels

  defp deduplicate_attempted_instances(channels, ctx) do
    Enum.reject(channels, fn channel ->
      RequestContext.attempted_instance?(ctx, channel.instance_id, channel.transport)
    end)
  end

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

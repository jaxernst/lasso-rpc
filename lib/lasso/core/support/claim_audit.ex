defmodule Lasso.Core.Support.ClaimAudit do
  @moduledoc """
  Request-local policy for auditing an upstream request-fault claim.

  This control is independent of learned support, semantic interpretation and
  learned stops. Classification is a claim; a peer outcome is an observation.
  Only canonical dispatched attempts enter the census. No customer body or
  provider identifier is retained by the census or exported as a metric label.

  The execution envelope owns the extra-send allowance shared with numeric-null
  recovery. Audit state retains the original response and peer attribution.
  """

  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.Core.Support.ErrorResolution
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{AttemptTerminal, ExecutionEnvelope, RequestContext}
  alias Lasso.RPC.ProviderKnowledge.Effects
  alias Lasso.RPC.Response.Capacity

  defmodule State do
    @moduledoc false
    @enforce_keys [:original_error, :original_channel, :original_fact, :dispatch_limit]
    defstruct @enforce_keys ++
                [
                  status: :pending,
                  outcome: nil,
                  original_vendor: nil,
                  vendor_relation: :unknown,
                  caller_guard: nil
                ]

    @type t :: %__MODULE__{}
  end

  @type mode :: :off | :shadow | :on
  @claim_categories [:invalid_request, :parse_error, :invalid_params, :client_error]
  @revert_claim_version 1
  @exact_execution_messages [
    "execution reverted",
    "out of gas",
    "insufficient funds for transfer",
    "insufficient funds for gas * price + value"
  ]

  @doc "Resolves the routing-policy mode using the existing validated profile override map."
  @spec mode(binary()) :: mode()
  def mode(profile) do
    value =
      Effects.profile_override(:claim_audit, profile) ||
        Application.get_env(:lasso, :claim_audit_mode, :off)

    if value in [:off, :on], do: value, else: :off
  end

  @doc "Assesses a canonical upstream response without granting physical-send permission."
  @spec assess(map(), map()) :: atom()
  def assess(
        %{fact: %AttemptTerminal.Response{kind: :application_error} = fact} = outcome,
        ctx
      ) do
    case error(outcome) do
      %JError{resolution: %ErrorResolution{} = resolution} ->
        cond do
          resolution.baseline_path == :data_selector -> :structural_revert
          fact.error_code == 3 -> :execution_code
          resolution.category == :local_capacity_rejection -> :local_safety
          fact.identity.execution_safety != :replay_safe -> :unsafe_execution
          is_nil(ctx.prepared_request) -> :unproven_envelope
          override_prohibits_failover?(ctx) -> :operator_policy
          resolution.category == :execution_revert -> :message_revert_shadow_only
          resolution.category in @claim_categories -> :eligible_claim
          true -> :ordinary_policy
        end

      _ ->
        :missing_resolution
    end
  end

  def assess(_outcome, _ctx), do: :not_application_claim

  @doc "Records one canonical attempt, including denominators and shadow-only revert claims."
  @spec census(map(), map(), map()) :: :ok
  def census(outcome, ctx, channel) do
    census_mode =
      if match?(%State{status: :peer}, ctx.claim_audit), do: :on, else: mode(channel.profile)

    case census_mode do
      :off ->
        :ok

      mode ->
        emit_census(outcome, ctx, channel, mode)

        if mode == :shadow and assess(outcome, ctx) == :eligible_claim,
          do: decision(ctx, :shadow_eligible)

        observe_peer(outcome, ctx)
    end
  end

  defp observe_peer(outcome, %{claim_audit: %State{status: :peer}} = ctx) do
    result =
      case attempt_kind(outcome.fact) do
        kind when kind in [:response, :dispatched_failure] -> :applied
        :not_dispatched -> :peer_not_dispatched
        :indeterminate -> :peer_dispatch_indeterminate
      end

    decision(ctx, result)
  end

  defp observe_peer(_outcome, _ctx), do: :ok

  @doc "Spends the shared extra-send allowance and retains the original claim for its peer."
  @spec start(map(), map(), map(), ExecutionScope.CallerGuard.t() | nil) ::
          {:ok, map()} | {:error, :extra_send_spent}
  def start(ctx, outcome, channel, caller_guard) do
    case ExecutionEnvelope.spend_extra_send(ctx.execution_envelope) do
      {:ok, envelope} ->
        {:ok,
         %{
           ctx
           | execution_envelope: envelope,
             claim_audit: %State{
               original_error: error(outcome),
               original_channel:
                 RequestContext.set_executed_channel(ctx, channel).executed_channel,
               original_vendor: vendor_group(channel),
               original_fact: outcome.fact,
               dispatch_limit: envelope.dispatch_limit,
               caller_guard: caller_guard
             }
         }}

      {:error, :extra_send_spent} = denial ->
        :ok = decision(ctx, :extra_send_spent)
        denial
    end
  end

  @doc "Caps fallback dispatches; the envelope alone tracks the shared extra-send allowance."
  @spec preserve_budget(map()) :: map()
  def preserve_budget(
        %{claim_audit: %State{dispatch_limit: limit}, execution_envelope: envelope} = ctx
      ),
      do: %{
        ctx
        | execution_envelope: %{envelope | dispatch_limit: min(envelope.dispatch_limit, limit)}
      }

  def preserve_budget(ctx), do: ctx

  @doc "Conservative known vendor group; unknown hosts do not establish independence."
  @spec vendor_group(map()) :: atom() | nil
  def vendor_group(%{template_provider_config: config, transport: transport})
      when is_map(config) do
    url =
      if transport == :ws,
        do: Map.get(config, :ws_url),
        else: Map.get(config, :url) || Map.get(config, :http_url)

    if is_binary(url) and byte_size(url) <= 2_048 do
      host = URI.parse(url).host
      if is_binary(host), do: known_vendor(String.downcase(host))
    end
  end

  def vendor_group(_channel), do: nil

  @vendor_domains [
    {"alchemy.com", :alchemy},
    {"drpc.org", :drpc},
    {"publicnode.com", :publicnode},
    {"blastapi.io", :blast},
    {"ankr.com", :ankr},
    {"1rpc.io", :one_rpc},
    {"infura.io", :infura},
    {"quiknode.pro", :quicknode},
    {"thirdweb.com", :thirdweb},
    {"chainstack.com", :chainstack},
    {"chainstacklabs.com", :chainstack},
    {"blockpi.network", :blockpi}
  ]

  defp known_vendor(host) do
    Enum.find_value(@vendor_domains, fn {suffix, vendor} ->
      if host == suffix or String.ends_with?(host, "." <> suffix), do: vendor
    end)
  end

  @doc "Records peer attribution when its owned attempt starts; start/4 already spent the allowance."
  @spec record_peer(map(), map()) :: map()
  def record_peer(%{claim_audit: %State{status: :pending} = state} = ctx, channel) do
    peer_vendor = vendor_group(channel)

    relation =
      cond do
        is_nil(state.original_vendor) or is_nil(peer_vendor) -> :unknown
        state.original_vendor == peer_vendor -> :same_known
        true -> :different_known
      end

    %{ctx | claim_audit: %{state | status: :peer, vendor_relation: relation}}
  end

  def record_peer(ctx, _channel), do: ctx

  @doc "Prevents retiring the authoritative original response before the audit concludes."
  @spec holds_original?(map(), term()) :: boolean()
  def holds_original?(%{claim_audit: %State{original_error: original}}, error),
    do:
      not is_nil(original) and Capacity.lease(original) == Capacity.lease(error) and
        original == error

  def holds_original?(_ctx, _error), do: false

  @doc "Releases retained claim bytes after an accepted peer success."
  @spec finish_success(map()) :: map()
  def finish_success(%{claim_audit: %State{original_error: %JError{}} = state} = ctx) do
    Capacity.release(state.original_error, :claim_audit_succeeded)

    %{
      ctx
      | claim_audit: %{
          state
          | original_error: nil,
            original_channel: nil,
            original_fact: nil,
            caller_guard: nil,
            status: :done,
            outcome: :served
        }
    }
  end

  def finish_success(ctx), do: ctx

  @doc "Preserves failed-audit response semantics while retaining every physical attempt fact."
  @spec finish_failure(map(), JError.t()) :: {map(), JError.t()}
  def finish_failure(%{claim_audit: %State{original_error: %JError{}} = state} = ctx, error) do
    {ctx, error} =
      if ctx.terminal_reason != :caller_abandoned and error.category != :cancelled and
           System.monotonic_time(:microsecond) >= ctx.execution_envelope.deadline_us do
        {%{ctx | terminal_reason: :deadline_exhausted},
         JError.new(-32_000, "Request deadline exhausted",
           category: :timeout,
           retriable?: false,
           data: %{reason: :deadline_exhausted}
         )}
      else
        {ctx, error}
      end

    authoritative? =
      ctx.terminal_reason in [:caller_abandoned, :deadline_exhausted] or
        error.category in [:cancelled, :local_capacity_rejection]

    {ctx, selected, outcome} =
      if authoritative? do
        Capacity.release(state.original_error, :claim_audit_local_terminal)
        {%{ctx | public_response_attempt: nil}, error, :local_terminal}
      else
        route = state.original_channel

        ctx = %{
          ctx
          | executed_channel: route,
            selected_provider: %{id: route.provider_id, protocol: route.transport},
            effective_profile: route.profile,
            public_response_attempt: state.original_fact
        }

        {ctx, state.original_error, :inconclusive}
      end

    state = %{
      state
      | original_error: nil,
        original_channel: nil,
        original_fact: nil,
        caller_guard: nil,
        status: :done,
        outcome: outcome
    }

    {%{ctx | claim_audit: state}, selected}
  end

  def finish_failure(ctx, error), do: {ctx, error}

  @doc "Reports audit decisions without messages, parameters or instance identities."
  @spec decision(map(), atom()) :: :ok
  def decision(ctx, result) do
    :telemetry.execute([:lasso, :rpc, :claim_audit, :decision], %{count: 1}, %{
      profile: ctx.routing_profile || ctx.opts.profile,
      method: ctx.method,
      request_origin: ctx.opts.request_origin,
      result: result
    })
  end

  defp emit_census(outcome, ctx, channel, mode) do
    error = error(outcome)
    resolution = if match?(%JError{}, error), do: error.resolution

    :telemetry.execute(
      [:lasso, :rpc, :claim_audit, :census],
      %{count: 1, remaining_ms: ExecutionEnvelope.remaining_ms(ctx.execution_envelope)},
      %{
        mode: mode,
        profile: channel.profile,
        method: ctx.method,
        request_origin: ctx.opts.request_origin,
        transport: channel.transport,
        category: if(resolution, do: resolution.category, else: :none),
        classification_path: if(resolution, do: resolution.classification_path, else: :none),
        code_class: code_class(if(match?(%JError{}, error), do: error.code)),
        http_status_class: http_status_class(error),
        eligibility: assess(outcome, ctx),
        revert_claim: revert_claim(error, resolution),
        revert_claim_version: @revert_claim_version,
        attempt_kind: attempt_kind(outcome.fact),
        vendor_relation:
          if(ctx.claim_audit, do: ctx.claim_audit.vendor_relation, else: :not_audit),
        audit_role:
          if(match?(%State{status: :peer}, ctx.claim_audit), do: :peer, else: :ordinary),
        consent_scope: consent_scope(channel.learning_subject)
      }
    )
  end

  # Exact-message cohorts size claims; they do not prove a client or grant replay.
  defp revert_claim(_error, %ErrorResolution{baseline_path: :data_selector}),
    do: :selector_data

  defp revert_claim(%JError{code: 3}, _resolution), do: :execution_code

  defp revert_claim(%JError{message: message}, %ErrorResolution{category: :execution_revert}) do
    if is_binary(message) and byte_size(message) <= 128 and String.valid?(message) and
         String.downcase(String.trim(message)) in @exact_execution_messages,
       do: :exact_message,
       else: :other_message
  end

  defp revert_claim(_error, _resolution), do: :not_revert

  defp error(%{result: {:error, %JError{} = error, _elapsed}}), do: error
  defp error(%{result: {:error, %JError{} = error}}), do: error
  defp error(_outcome), do: nil

  defp override_prohibits_failover?(ctx),
    do: is_binary(ctx.opts.provider_override) and not ctx.opts.failover_on_override

  defp attempt_kind(%AttemptTerminal.Response{}), do: :response
  defp attempt_kind(%AttemptTerminal.PredispatchFailure{}), do: :not_dispatched
  defp attempt_kind(%{dispatch_certainty: :not_dispatched}), do: :not_dispatched
  defp attempt_kind(%{dispatch_certainty: :dispatched}), do: :dispatched_failure
  defp attempt_kind(_fact), do: :indeterminate

  defp consent_scope(%{sharing_scope: :curated}), do: :curated
  defp consent_scope(%{sharing_scope: {:account, _}}), do: :account
  defp consent_scope(%{sharing_scope: {:profile, _}}), do: :profile
  defp consent_scope(_subject), do: :unknown

  defp http_status_class(%JError{http_status: status}) when status in [401, 403],
    do: :authentication

  defp http_status_class(%JError{http_status: 429}), do: :rate_limit
  defp http_status_class(%JError{http_status: 408}), do: :timeout

  defp http_status_class(%JError{http_status: status}) when status in 400..499,
    do: :client_error

  defp http_status_class(%JError{http_status: status}) when status in 500..599,
    do: :server_error

  defp http_status_class(%JError{http_status: status}) when status in 100..399,
    do: :other_status

  defp http_status_class(_error), do: :not_recorded

  defp code_class(-32_600), do: :invalid_request
  defp code_class(-32_700), do: :parse_error
  defp code_class(-32_602), do: :invalid_params
  defp code_class(3), do: :execution
  defp code_class(code) when is_integer(code) and code in 400..499, do: :numeric_4xx
  defp code_class(_code), do: :other
end

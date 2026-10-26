defmodule Lasso.RPC.ProviderKnowledge.Effects do
  @moduledoc "Bounded candidate deferral at the descriptor ordering seam."

  alias Lasso.RPC.BoundedIdentifier
  alias Lasso.RPC.ProviderKnowledge
  alias Lasso.RPC.ProviderKnowledge.Decision
  alias Lasso.RPC.ProviderKnowledge.Learners.HistoricalDepth
  alias Lasso.RPC.Selection.HeadSuitability
  alias Lasso.RPC.TransportRegistry

  @kinds [:method_refusal, :span_limit, :historical_depth]
  @max_head_evidence 2

  @type mode :: :off | :shadow | :on
  @type shadow_mode :: :off | :shadow

  @doc "Resolves a serving effect's mode for a profile, falling back to the global mode."
  @spec mode(atom(), String.t()) :: mode()
  def mode(:quota_exhaustion, profile),
    do: resolve(:quota_exhaustion, profile, [:off, :shadow], &global_mode/1)

  def mode(kind, profile) when kind in @kinds,
    do: resolve(kind, profile, [:off, :on], &global_mode/1)

  @doc "Resolves local latency selection independently of capability deferral modes."
  @spec response_latency_mode(String.t()) :: mode()
  def response_latency_mode(profile),
    do: resolve(:response_latency, profile, [:off, :shadow, :on], &global_mode/1)

  @doc "Resolves the error-classifier shadow mode for a profile, falling back to the global mode."
  @spec classifier_mode(String.t()) :: shadow_mode()
  def classifier_mode(profile) do
    resolve(:classifier, profile, [:off, :shadow], fn _kind ->
      Application.get_env(:lasso, :provider_knowledge_classifier_mode, :off)
    end)
  end

  @doc "Resolves the request-fault shadow mode for a profile, falling back to the global mode."
  @spec request_fault_mode(String.t()) :: shadow_mode()
  def request_fault_mode(profile) do
    resolve(:request_fault, profile, [:off, :shadow], fn _kind ->
      Application.get_env(:lasso, :provider_knowledge_request_fault_mode, :off)
    end)
  end

  defp resolve(kind, profile, allowed, global_fun) do
    override = profile_override(kind, profile)

    if override in allowed, do: override, else: valid(global_fun.(kind), allowed)
  end

  defp global_mode(kind) do
    default = if kind in [:method_refusal, :span_limit, :historical_depth], do: :on, else: :off
    Application.get_env(:lasso, :provider_knowledge_effect_modes, %{}) |> Map.get(kind, default)
  end

  defp valid(value, allowed), do: if(value in allowed, do: value, else: :off)

  @doc "Configured per-profile override for one effect, or nil."
  @spec profile_override(atom(), String.t() | nil) :: atom() | nil
  def profile_override(kind, profile) do
    Application.get_env(:lasso, :provider_knowledge_profile_modes, %{})
    |> get_in([profile, kind])
  end

  @doc "Bounded routing cohort, independent of a provider's sharing scope."
  @spec cohort(binary()) :: :public | :premium | :custom | :other
  def cohort(profile) do
    case Lasso.Config.ProfileValidator.resolve_alias(profile) do
      "public" -> :public
      "public-safe" -> :public
      "premium" -> :premium
      _profile -> :other
    end
  end

  @doc "A cached winner is usable only while current serving effects allow it first."
  @spec cached_winner_eligible?(term(), term(), binary(), map()) :: boolean()
  def cached_winner_eligible?(descriptor, plan, method, context) do
    active_constraint? =
      Enum.any?(@kinds, &(mode(&1, plan.profile) == :on)) and
        is_map(learned_deferral(descriptor, plan, method, context))

    not active_constraint?
  end

  @doc """
  Orders one batch of descriptors by head suitability and learned deferral in
  one precedence step, and captures the decisions that changed it.

  Routes deferred by neither come first, head class 0 before class 1. Routes
  with head evidence against suitability or an `on`-mode learned deferral
  follow; the returned set names them so they can wait behind the rest of their
  availability tier. Shadow-mode effects never change the order.
  """
  @spec order_with_decision(list(), term(), binary(), map(), boolean()) ::
          {list(), MapSet.t(HeadSuitability.route()), [map()]}
  def order_with_decision(descriptors, plan, method, context, complete? \\ true)

  def order_with_decision([], _plan, _method, _context, _complete?),
    do: {[], MapSet.new(), []}

  def order_with_decision(descriptors, plan, method, context, complete?) do
    historical_mode = mode(:historical_depth, plan.profile)
    head = Map.get(context, :head_suitability)

    predictions =
      if historical_mode == :off,
        do: Enum.map(descriptors, fn _descriptor -> nil end),
        else: Enum.map(descriptors, &historical_prediction(&1, plan, method, context))

    learned = learned_deferrals(descriptors, predictions, historical_mode, plan, method, context)

    {classes, verdicts} =
      if head do
        descriptors
        |> Enum.map(fn descriptor ->
          {class, verdict, reason} = HeadSuitability.classify(head, Decision.route(descriptor))
          {class, {verdict, reason}}
        end)
        |> Enum.unzip()
      else
        {Enum.map(descriptors, fn _descriptor -> 0 end), Enum.map(descriptors, fn _ -> nil end)}
      end

    entries = Enum.zip([descriptors, classes, learned])

    applied =
      entries
      |> Enum.sort_by(fn {_descriptor, class, learned?} ->
        {class == 2 or is_map(learned?), class, is_map(learned?)}
      end)
      |> Enum.map(&elem(&1, 0))

    deferred =
      for {descriptor, class, learned?} <- entries,
          class == 2 or is_map(learned?),
          into: MapSet.new(),
          do: Decision.route(descriptor)

    order = %{baseline: descriptors, applied: applied, complete?: complete?}

    if Enum.any?(learned, &is_map/1) do
      head_only = entries |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))
      Lasso.RPC.ProviderKnowledge.AppliedEffects.record(plan.profile, head_only, applied, learned)
    end

    decisions =
      (capability_decisions(learned, plan, method, context, order) ++
         [
           historical_decision(predictions, historical_mode, plan, method, context, order),
           quota_decision(plan, method, context, order),
           head_decision(head, Enum.zip([descriptors, classes, learned, verdicts]), plan, order)
         ])
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&Decision.capture/1)

    {applied, deferred, decisions}
  end

  @doc "Captures a head-against route queued while ranked batches remain pending."
  @spec head_bucket_decision(term(), term(), map()) :: map() | nil
  def head_bucket_decision(descriptor, plan, %{head_suitability: head}) when not is_nil(head) do
    {class, verdict, reason} = HeadSuitability.classify(head, Decision.route(descriptor))

    if class == 2 do
      head_decision(
        head,
        [{descriptor, class, false, {verdict, reason}}],
        plan,
        %{baseline: [descriptor], applied: [descriptor], complete?: false},
        true
      )
      |> Map.put(:order_scope, :deferred_bucket)
      |> Decision.capture()
    end
  end

  def head_bucket_decision(_descriptor, _plan, _context), do: nil

  defp learned_deferrals(descriptors, predictions, historical_mode, plan, method, context) do
    if Enum.any?(@kinds, &(mode(&1, plan.profile) == :on)) do
      Enum.zip_with(descriptors, predictions, fn descriptor, hint ->
        if historical_mode == :on and is_map(hint) do
          deferral(descriptor, :historical_depth, context.historical_resource)
        else
          learned_deferral(descriptor, plan, method, context, [:method_refusal, :span_limit])
        end
      end)
    else
      Enum.map(descriptors, fn _ -> nil end)
    end
  end

  defp deferral(descriptor, kind, dimension),
    do: %{route: Decision.route(descriptor), kind: kind, dimension: dimension}

  defp capability_decisions(deferrals, plan, method, context, order) do
    for kind <- [:method_refusal, :span_limit],
        hints = Enum.filter(deferrals, &(is_map(&1) and &1.kind == kind)),
        hints != [] do
      deferred_routes = MapSet.new(hints, & &1.route)

      proposed =
        Enum.sort_by(order.baseline, &MapSet.member?(deferred_routes, Decision.route(&1)))

      %{
        kind: kind,
        mode: :on,
        origin_profile: plan.profile,
        budget_result: :no_extra_dispatch,
        method: BoundedIdentifier.encode(method),
        partition: context.partition,
        hints: Enum.take(hints, 2),
        omitted_hints: max(length(hints) - 2, 0),
        order_scope: :materialized_candidates,
        orders: Decision.orders(order.baseline, proposed, order.applied, order.complete?)
      }
    end
  end

  defp historical_decision(predictions, historical_mode, plan, method, context, order) do
    hints = Enum.reject(predictions, &is_nil/1)

    if hints != [] do
      {ordinary, deferred} =
        order.baseline
        |> Enum.zip(predictions)
        |> Enum.split_with(&is_nil(elem(&1, 1)))

      %{
        kind: :historical_depth,
        mode: historical_mode,
        origin_profile: plan.profile,
        budget_result: :no_extra_dispatch,
        method: method,
        partition: context.partition,
        resource: context.historical_resource,
        request_age: context.historical_age,
        hints: Enum.take(hints, 2),
        omitted_hints: max(length(hints) - 2, 0),
        order_scope: :materialized_candidates,
        orders:
          Decision.orders(
            order.baseline,
            Enum.map(ordinary ++ deferred, &elem(&1, 0)),
            order.applied,
            order.complete?
          )
      }
    end
  end

  defp quota_decision(plan, method, context, order) do
    if mode(:quota_exhaustion, plan.profile) == :shadow do
      hints =
        for descriptor <- order.baseline,
            quota_prediction?(descriptor, plan, method, context),
            do: deferral(descriptor, :quota_exhaustion, :quota)

      if hints != [] do
        routes = MapSet.new(hints, & &1.route)
        proposed = Enum.sort_by(order.baseline, &MapSet.member?(routes, Decision.route(&1)))

        %{
          kind: :quota_exhaustion,
          mode: :shadow,
          origin_profile: plan.profile,
          budget_result: :no_extra_dispatch,
          method: BoundedIdentifier.encode(method),
          partition: context.partition,
          hints: Enum.take(hints, 2),
          omitted_hints: max(length(hints) - 2, 0),
          order_scope: :materialized_candidates,
          orders: Decision.orders(order.baseline, proposed, order.applied, order.complete?)
        }
      end
    end
  end

  defp quota_prediction?(descriptor, plan, _method, context) do
    {provider, transport} = route(descriptor)

    case TransportRegistry.learning_subject_for(
           plan.profile,
           plan.chain_id,
           transport,
           provider.config
         ) do
      %{id: subject} ->
        match?(
          {:ok, _},
          ProviderKnowledge.quota_exhaustion(%{
            subject: subject,
            profile: plan.profile,
            chain_id: plan.chain_id,
            partition: context.partition
          })
        )

      _ ->
        false
    end
  end

  # Recorded when head suitability moved a route relative to the order learned
  # deferral alone would apply, or when it kept an outlying head from the mark.
  # Routes are named by baseline position to stay within the frame budget.
  defp head_decision(head, entries, plan, order, bucket_deferral? \\ false)

  defp head_decision(nil, _entries, _plan, _order, _bucket_deferral?), do: nil

  defp head_decision(head, entries, plan, order, bucket_deferral?) do
    learned_only =
      entries
      |> Enum.sort_by(fn {_descriptor, _class, learned?, _verdict} -> is_map(learned?) end)
      |> Enum.map(&elem(&1, 0))

    if bucket_deferral? or learned_only != order.applied or head.outliers != [] do
      positions = Decision.route_positions(order.baseline)

      proposed =
        entries
        |> Enum.sort_by(fn {_descriptor, class, _learned?, _verdict} -> class end)
        |> Enum.map(&elem(&1, 0))

      evidence =
        for {descriptor, _class, _learned?, {verdict, reason}} <- entries,
            verdict != :supports do
          route = Decision.route(descriptor)
          observation = Map.get(head.evidence, route)

          %{
            baseline_position: Map.get(positions, route),
            verdict: verdict,
            reason: reason,
            reached: HeadSuitability.reached?(head, route),
            height: observation && observation.height,
            age_ms: observation && age_ms(head, observation)
          }
        end
        |> Enum.sort_by(&(&1.verdict != :against))

      %{
        kind: :head_suitability,
        mode: :on,
        origin_profile: plan.profile,
        budget_result: :no_extra_dispatch,
        requirement: requirement_source(head.requirement),
        target_height: HeadSuitability.target_height(head),
        band: head.band,
        cadence: %{source: head.cadence.source, block_time_ms: head.cadence.block_time_ms},
        mark: head.mark && %{height: head.mark.height, age_ms: age_ms(head, head.mark)},
        outlier:
          case head.outliers do
            [highest | _rest] ->
              %{
                baseline_position: Map.get(positions, highest.route),
                height: highest.height,
                age_ms: age_ms(head, highest)
              }

            [] ->
              nil
          end,
        omitted_outliers: max(length(head.outliers) - 1, 0),
        evidence: Enum.take(evidence, @max_head_evidence),
        omitted_evidence: max(length(evidence) - @max_head_evidence, 0),
        order_scope: :materialized_candidates,
        orders: Decision.orders(order.baseline, proposed, order.applied, order.complete?)
      }
    end
  end

  defp age_ms(head, observation), do: max(head.captured_at_ms - observation.observed_at_ms, 0)

  defp requirement_source({source, _height}), do: source
  defp requirement_source(:at_head), do: :at_head

  defp historical_prediction(
         descriptor,
         plan,
         method,
         %{historical_resource: resource, historical_age: age} = context
       )
       when not is_nil(resource) do
    {provider, transport} = route(descriptor)

    case TransportRegistry.learning_subject_for(
           plan.profile,
           plan.chain_id,
           transport,
           provider.config
         ) do
      %{id: subject} ->
        scope = %{
          subject: subject,
          profile: plan.profile,
          chain_id: plan.chain_id,
          method: method,
          partition: context.partition
        }

        case ProviderKnowledge.historical_depth(scope, resource) do
          {:ok, hint} ->
            if HistoricalDepth.unavailable?(
                 hint,
                 age,
                 Map.get(context, :historical_height)
               ) do
              hint
              |> Map.take([
                :source,
                :coordinate,
                :value,
                :epoch,
                :observed_at_ms,
                :expires_at_ms,
                :support
              ])
              |> Map.put(:route, {provider.instance_id, transport})
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp historical_prediction(_descriptor, _plan, _method, _context), do: nil

  @doc "Returns bounded quota predictions without changing route order."
  @spec shadow_proposals(list(), term(), binary(), map()) :: [map()]
  def shadow_proposals(descriptors, plan, method, context) when is_list(descriptors) do
    if mode(:quota_exhaustion, plan.profile) == :shadow do
      proposals =
        descriptors
        |> Enum.take(10)
        |> Enum.flat_map(fn descriptor ->
          {provider, transport} = route(descriptor)

          case TransportRegistry.learning_subject_for(
                 plan.profile,
                 plan.chain_id,
                 transport,
                 provider.config
               ) do
            %{id: subject, sharing_scope: sharing_scope} ->
              scope = %{
                subject: subject,
                profile: plan.profile,
                chain_id: plan.chain_id,
                method: method,
                partition: context.partition
              }

              if is_binary(Map.get(provider, :instance_id)) do
                [
                  %{
                    instance_id: provider.instance_id,
                    transport: transport,
                    kind: :quota_exhaustion,
                    predicted?: match?({:ok, _}, ProviderKnowledge.quota_exhaustion(scope)),
                    cohort: cohort(plan.profile),
                    profile_class: if(sharing_scope == :curated, do: :managed, else: :custom),
                    chain_id: plan.chain_id,
                    origin_profile: plan.profile,
                    partition: context.partition,
                    method: BoundedIdentifier.encode(method)
                  }
                ]
              else
                []
              end

            _ ->
              []
          end
        end)

      :ok = Lasso.RPC.ProviderKnowledge.ShadowAgreement.consider(proposals)
      Enum.filter(proposals, & &1.predicted?)
    else
      []
    end
  end

  def shadow_proposals(_descriptors, _plan, _method, _context), do: []

  defp learned_deferral(descriptor, plan, method, context, kinds \\ @kinds) do
    {provider, transport} = route(descriptor)

    case TransportRegistry.learning_subject_for(
           plan.profile,
           plan.chain_id,
           transport,
           provider.config
         ) do
      %{id: subject} ->
        scope = %{
          subject: subject,
          profile: plan.profile,
          chain_id: plan.chain_id,
          method: method,
          partition: context.partition
        }

        cond do
          :method_refusal in kinds and mode(:method_refusal, plan.profile) == :on and
              ProviderKnowledge.method_refused?(scope, method) ->
            deferral(descriptor, :method_refusal, BoundedIdentifier.encode(method))

          :span_limit in kinds and mode(:span_limit, plan.profile) == :on and
              span_limited?(scope, method, context) ->
            deferral(descriptor, :span_limit, :logs)

          :historical_depth in kinds and mode(:historical_depth, plan.profile) == :on and
              historical_depth_limited?(scope, context) ->
            deferral(descriptor, :historical_depth, context.historical_resource)

          true ->
            nil
        end

      _ ->
        nil
    end
  end

  defp span_limited?(scope, "eth_getLogs", %{span: span}) when is_integer(span) do
    case ProviderKnowledge.span_limit(scope, :logs) do
      {:ok, %{value: smallest_failure}} when is_integer(smallest_failure) ->
        span >= smallest_failure

      _ ->
        false
    end
  end

  defp span_limited?(_scope, _method, _context), do: false

  defp historical_depth_limited?(
         scope,
         %{historical_resource: resource, historical_age: age} = context
       )
       when not is_nil(resource) do
    case ProviderKnowledge.historical_depth(scope, resource) do
      {:ok, hint} ->
        HistoricalDepth.unavailable?(
          hint,
          age,
          Map.get(context, :historical_height)
        )

      _ ->
        false
    end
  end

  defp historical_depth_limited?(_scope, _context), do: false

  defp route({:ranked, provider, transport}), do: {provider, transport}
  defp route({provider, transport}), do: {provider, transport}
end

defmodule Lasso.RPC.ProviderKnowledge.Effects do
  @moduledoc "Bounded candidate deferral at the descriptor ordering seam."

  alias Lasso.Config.ProfileId
  alias Lasso.RPC.BoundedIdentifier
  alias Lasso.RPC.ProviderKnowledge
  alias Lasso.RPC.ProviderKnowledge.{Decision, Evidence}
  alias Lasso.RPC.ProviderKnowledge.Learners.{DisprovedError, HistoricalDepth}
  alias Lasso.RPC.Selection.HeadSuitability
  alias Lasso.RPC.TransportRegistry

  @kinds [:method_refusal, :span_limit, :historical_depth, :disproved_error]
  @ordering_kinds [:method_refusal, :span_limit, :disproved_error]
  @max_head_evidence 2
  @custom_class "u_*"

  @type mode :: :off | :shadow | :on

  @doc "Resolves a serving effect's mode for a profile, falling back to the global mode."
  @spec mode(atom(), String.t()) :: mode()
  def mode(:quota_exhaustion, profile),
    do: resolve(:quota_exhaustion, profile, [:off, :shadow], &global_mode/1)

  def mode(kind, profile) when kind in [:failure_rate_deferral | @kinds],
    do: resolve(kind, profile, [:off, :on], &global_mode/1)

  defp resolve(kind, profile, allowed, global_fun) do
    override = profile_override(kind, profile)

    if override in allowed, do: override, else: valid(global_fun.(kind), allowed)
  end

  defp global_mode(kind) do
    default =
      if kind in [
           :method_refusal,
           :span_limit,
           :historical_depth,
           :disproved_error,
           :failure_rate_deferral
         ],
         do: :on,
         else: :off

    Application.get_env(:lasso, :provider_knowledge_effect_modes, %{}) |> Map.get(kind, default)
  end

  defp valid(value, allowed), do: if(value in allowed, do: value, else: :off)

  @doc """
  The configured mode for one kind and profile: the profile's own entry, then
  the `u_*` entry for any Custom profile, otherwise nil.
  """
  @spec profile_override(atom(), String.t() | nil) :: atom() | nil
  def profile_override(kind, profile) do
    overrides = Application.get_env(:lasso, :provider_knowledge_profile_modes, %{})

    case overrides |> Map.get(profile, %{}) |> Map.get(kind) do
      nil -> if custom_profile?(profile), do: get_in(overrides, [@custom_class, kind])
      mode -> mode
    end
  end

  defp custom_profile?(profile),
    do: is_binary(profile) and profile != @custom_class and ProfileId.user?(profile)

  @doc "Bounded routing cohort, independent of a provider's sharing scope."
  @spec cohort(binary()) :: :public | :premium | :custom | :other
  def cohort(profile) do
    case Lasso.Config.ProfileValidator.resolve_alias(profile) do
      "public" -> :public
      "public-safe" -> :public
      "premium" -> :premium
      profile -> if(ProfileId.user?(profile), do: :custom, else: :other)
    end
  end

  @doc """
  Orders one batch of descriptors by head suitability and learned deferral in
  one precedence step, and captures the decisions that changed it.

  Routes deferred by neither come first, head class 0 before class 1. Routes
  with head evidence against suitability or an `on`-mode learned deferral
  follow; the returned set names them so they can wait behind the rest of their
  availability tier. Shadow-mode effects never change the order.
  """
  @spec order_with_decision(list(), term(), binary(), map()) ::
          {list(), MapSet.t(HeadSuitability.route()), [map()]}
  def order_with_decision([], _plan, _method, _context), do: {[], MapSet.new(), []}

  def order_with_decision(descriptors, plan, method, context) do
    historical_mode = mode(:historical_depth, plan.profile)
    head = Map.get(context, :head_suitability)

    scopes =
      if Enum.any?(@kinds, &(mode(&1, plan.profile) == :on)),
        do: Enum.map(descriptors, &effect_scope(&1, plan, method, context)),
        else: Enum.map(descriptors, fn _descriptor -> nil end)

    predictions =
      if historical_mode == :off,
        do: Enum.map(descriptors, fn _descriptor -> nil end),
        else: Enum.zip_with(descriptors, scopes, &historical_prediction(&1, &2, context))

    learned =
      Enum.zip([descriptors, scopes, predictions])
      |> learned_deferrals(historical_mode, plan, method, context)

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

    order = %{baseline: descriptors, applied: applied}

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

  defp learned_deferrals(entries, historical_mode, plan, method, context) do
    if Enum.any?(@kinds, &(mode(&1, plan.profile) == :on)) do
      Enum.map(entries, fn {descriptor, scope, hint} ->
        if historical_mode == :on and is_map(hint) do
          deferral(descriptor, :historical_depth, context.historical_resource)
        else
          learned_deferral(descriptor, scope, plan, method, context, @ordering_kinds)
        end
      end)
    else
      Enum.map(entries, fn _ -> nil end)
    end
  end

  defp deferral(descriptor, kind, dimension),
    do: %{route: Decision.route(descriptor), kind: kind, dimension: dimension}

  defp capability_decisions(deferrals, plan, method, context, order) do
    for kind <- @ordering_kinds,
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
        orders: Decision.orders(order.baseline, proposed, order.applied)
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
            order.applied
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
          orders: Decision.orders(order.baseline, proposed, order.applied)
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
  # deferral alone would apply. Routes are named by baseline position to stay
  # within the frame budget.
  defp head_decision(nil, _entries, _plan, _order), do: nil

  defp head_decision(head, entries, plan, order) do
    learned_only =
      entries
      |> Enum.sort_by(fn {_descriptor, _class, learned?, _verdict} -> is_map(learned?) end)
      |> Enum.map(&elem(&1, 0))

    if learned_only != order.applied do
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
          round_lag = observation && observation.round_lag

          %{
            baseline_position: Map.get(positions, route),
            verdict: verdict,
            reason: reason,
            reached: HeadSuitability.reached?(head, route),
            height: observation && observation.height,
            age_ms: observation && age_ms(head, observation.observed_at_ms),
            lag: round_lag && round_lag.lag,
            lag_age_ms: round_lag && age_ms(head, round_lag.measured_at_ms)
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
        evidence: Enum.take(evidence, @max_head_evidence),
        omitted_evidence: max(length(evidence) - @max_head_evidence, 0),
        order_scope: :materialized_candidates,
        orders: Decision.orders(order.baseline, proposed, order.applied)
      }
    end
  end

  defp age_ms(head, at_ms), do: max(head.captured_at_ms - at_ms, 0)

  defp requirement_source({source, _height}), do: source
  defp requirement_source(:at_head), do: :at_head

  defp historical_prediction(
         descriptor,
         scope,
         %{historical_resource: resource, historical_age: age} = context
       )
       when is_map(scope) and not is_nil(resource) do
    case ProviderKnowledge.historical_depth(scope, resource) do
      {:ok, %{source: source} = hint} when source in [:local, :imported] ->
        if HistoricalDepth.unavailable?(hint, age, Map.get(context, :historical_height)) do
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
          |> Map.put(:route, Decision.route(descriptor))
        end

      _ ->
        nil
    end
  end

  defp historical_prediction(_descriptor, _scope, _context), do: nil

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

  defp learned_deferral(_descriptor, nil, _plan, _method, _context, _kinds), do: nil

  defp learned_deferral(descriptor, scope, plan, method, context, kinds) do
    cond do
      :method_refusal in kinds and mode(:method_refusal, plan.profile) == :on and
          learned_method_refusal?(scope, method) ->
        deferral(descriptor, :method_refusal, BoundedIdentifier.encode(method))

      :span_limit in kinds and mode(:span_limit, plan.profile) == :on and
          span_limited?(scope, method, context) ->
        deferral(descriptor, :span_limit, :logs)

      :disproved_error in kinds and mode(:disproved_error, plan.profile) == :on and
          disproved?(scope, method, context) ->
        deferral(descriptor, :disproved_error, BoundedIdentifier.encode(method))

      :historical_depth in kinds and mode(:historical_depth, plan.profile) == :on and
          historical_depth_limited?(scope, context) ->
        deferral(descriptor, :historical_depth, context.historical_resource)

      true ->
        nil
    end
  end

  # A sampled share of matching requests keeps the deferred credential first, so
  # a provider that serves again retracts its own deferral. A context without the
  # request's shape (the cached-winner check) treats any disproval as matching.
  defp disproved?(scope, method, context) do
    with {:ok, %{source: source, shapes: shapes}} when source in [:local, :imported] <-
           ProviderKnowledge.disproved_error(scope, method),
         true <- shape_disproved?(shapes, method, context) do
      not Map.has_key?(context, :request_shape) or :rand.uniform() >= DisprovedError.probe_share()
    else
      _ -> false
    end
  end

  defp shape_disproved?(shapes, method, %{request_shape: {params, head_height}}) do
    case Map.fetch(shapes, Evidence.request_shape(method, params, head_height)) do
      {:ok, expires_at_ms} -> expires_at_ms > System.system_time(:millisecond)
      :error -> false
    end
  end

  defp shape_disproved?(_shapes, _method, _context), do: true

  defp effect_scope(descriptor, plan, method, context) do
    {provider, transport} = route(descriptor)

    case TransportRegistry.learning_subject_for(
           plan.profile,
           plan.chain_id,
           transport,
           provider.config
         ) do
      %{id: _id} = subject ->
        ProviderKnowledge.capability_scope(
          %{
            learning_subject: subject,
            profile: plan.profile,
            chain_id: plan.chain_id,
            historical_resource: Map.get(context, :historical_resource)
          },
          Map.get(provider.config, :capabilities),
          method
        )
        |> Map.merge(%{method: method, partition: context.partition, allow_learned?: true})

      _ ->
        nil
    end
  end

  @doc "Method refusal evidence shared by cursor and materialized-list admission."
  @spec method_refusal(map(), String.t(), term()) :: map() | nil
  def method_refusal(channel, method, partition) do
    scope =
      ProviderKnowledge.capability_scope(channel, channel.capabilities, method)
      |> Map.merge(%{partition: partition, allow_learned?: true})

    if mode(:method_refusal, channel.profile) == :on and learned_method_refusal?(scope, method),
      do: %{
        route: {channel.instance_id, channel.transport},
        kind: :method_refusal,
        dimension: BoundedIdentifier.encode(method)
      }
  end

  @doc "Whether live method evidence excludes this route."
  @spec method_refused?(term(), map(), String.t(), map()) :: boolean()
  def method_refused?(descriptor, plan, method, context) do
    scope = effect_scope(descriptor, plan, method, context)

    scope != nil and mode(:method_refusal, plan.profile) == :on and
      learned_method_refusal?(scope, method)
  end

  defp learned_method_refusal?(scope, method) do
    case ProviderKnowledge.method_refusal(scope, method) do
      {:ok, %{source: source, value: true}} when source in [:local, :imported] -> true
      _ -> false
    end
  end

  defp span_limited?(scope, "eth_getLogs", %{span: span}) when is_integer(span) do
    case ProviderKnowledge.span_limit(scope, :logs) do
      {:ok, %{source: source, value: smallest_failure}}
      when source in [:local, :imported] and is_integer(smallest_failure) ->
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
      {:ok, %{source: source} = hint} when source in [:local, :imported] ->
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

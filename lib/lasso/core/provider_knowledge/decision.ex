defmodule Lasso.RPC.ProviderKnowledge.Decision do
  @moduledoc "Bounded serving decisions and canonical attempt observations, without request bodies."

  alias Lasso.RPC.AttemptTerminal

  @max_routes 16
  @max_attempts 8
  @max_frame_bytes 1_536
  @max_head_frame_bytes 2_048
  @max_bytes 3_072
  @observation_fields [:dispatch_observation, :attempts, :omitted_attempts]
  @frame_fields [
    :kind,
    :mode,
    :origin_profile,
    :budget_result,
    :resource,
    :partition,
    :changed_at,
    :baseline_at_change,
    :proposed_at_change,
    :baseline_first,
    :proposed_first,
    :applied_first,
    :evidence,
    :orders,
    :order_scope,
    :method,
    :request_age,
    :hints,
    :omitted_hints,
    :policy_kind,
    :reason,
    :requirement,
    :target_height,
    :band,
    :cadence,
    :mark,
    :omitted_evidence,
    :outlier,
    :omitted_outliers
  ]

  @spec orders(list(), list(), list(), boolean()) :: map()
  def orders(baseline, proposed, applied, complete? \\ true) do
    routes = baseline |> Enum.take(@max_routes) |> Enum.map(&route/1)
    positions = routes |> Enum.with_index(1) |> Map.new()

    %{
      routes: routes,
      baseline: Enum.to_list(1..length(routes)//1),
      proposed: order_positions(proposed, positions),
      applied: order_positions(applied, positions),
      omitted_routes: max(length(baseline) - @max_routes, 0),
      complete?: complete? and length(baseline) <= @max_routes
    }
  end

  @doc "Baseline positions, starting at 1, of the routes an order records."
  @spec route_positions(list()) :: %{{String.t(), :http | :ws} => pos_integer()}
  def route_positions(baseline),
    do:
      baseline |> Enum.take(@max_routes) |> Enum.map(&route/1) |> Enum.with_index(1) |> Map.new()

  defp order_positions(channels, positions),
    do: channels |> Enum.map(&Map.get(positions, route(&1))) |> Enum.reject(&is_nil/1)

  @doc "The concrete route of a descriptor or channel."
  @spec route(tuple() | map()) :: {String.t(), :http | :ws}
  def route({:ranked, provider, transport}), do: {provider.instance_id, transport}
  def route({provider, transport}), do: {provider.instance_id, transport}
  def route(channel), do: {channel.instance_id, channel.transport}

  @doc "Marks existing orders incomplete while preserving decisions with omitted detail."
  @spec mark_incomplete(map()) :: map()
  def mark_incomplete(%{orders: %{} = orders} = decision),
    do: %{decision | orders: Map.put(orders, :complete?, false)}

  def mark_incomplete(decision), do: decision

  @spec retain(map() | nil, map() | list() | nil) :: map() | nil
  def retain(first, nil), do: first

  def retain(first, decisions) when is_list(decisions),
    do: Enum.reduce(decisions, first, &retain(&2, &1))

  def retain(nil, decision), do: Map.put(decision, :intervention_count, 1)

  def retain(first, decision),
    do:
      first |> Map.put(:latest, decision) |> Map.update(:intervention_count, 1, &min(&1 + 1, 32))

  @spec observe(map() | nil, AttemptTerminal.t(), atom()) :: map() | nil
  def observe(nil, fact, qualification), do: observe(%{}, fact, qualification)

  def observe(decision, fact, qualification) do
    certainty = certainty(fact)

    counts =
      Map.get(decision, :dispatch_observation, %{
        dispatched: 0,
        indeterminate: 0,
        not_dispatched: 0
      })

    counts = Map.update!(counts, certainty, &(&1 + 1))
    attempts = Map.get(decision, :attempts, [])

    attempt = %{
      route: {fact.identity.upstream_instance_id, fact.identity.transport},
      origin_profile: fact.identity.profile,
      route_generation: fact.identity.route_generation,
      certainty: certainty,
      outcome: outcome(fact),
      qualification: qualification,
      io_duration_us: Map.get(fact, :io_duration_us)
    }

    attempt = Map.merge(attempt, terminal_evidence(fact))

    decision
    |> Map.put(:dispatch_observation, counts)
    |> Map.put(:attempts, Enum.take(attempts ++ [attempt], @max_attempts))
    |> Map.update(
      :omitted_attempts,
      0,
      &(&1 + if(length(attempts) == @max_attempts, do: 1, else: 0))
    )
  end

  # Diagnostic facts only: these fields never participate in policy or learning.
  defp terminal_evidence(%AttemptTerminal.Cancelled{} = fact),
    do: %{cancellation_reason: fact.reason, censoring_boundary_us: fact.censoring_boundary_us}

  defp terminal_evidence(%{censoring_boundary_us: boundary}),
    do: %{censoring_boundary_us: boundary}

  defp terminal_evidence(_fact), do: %{}

  defp certainty(%AttemptTerminal.Response{}), do: :dispatched
  defp certainty(%AttemptTerminal.InvalidResponse{}), do: :dispatched
  defp certainty(%AttemptTerminal.PredispatchFailure{}), do: :not_dispatched
  defp certainty(fact), do: fact.dispatch_certainty

  defp outcome(%AttemptTerminal.Response{kind: kind}), do: kind
  defp outcome(%AttemptTerminal.InvalidResponse{}), do: :invalid_response
  defp outcome(%AttemptTerminal.PredispatchFailure{}), do: :predispatch_failure
  defp outcome(%AttemptTerminal.TransportFailure{}), do: :transport_failure
  defp outcome(%AttemptTerminal.Deadline{}), do: :deadline
  defp outcome(%AttemptTerminal.Cancelled{}), do: :cancelled

  @doc "Attaches observations for the entire request, including attempts before a fallback decision."
  @spec attach(map() | nil, map() | nil) :: map() | nil
  def attach(decision, nil),
    do:
      attach(decision, %{
        dispatch_observation: %{dispatched: 0, indeterminate: 0, not_dispatched: 0},
        attempts: [],
        omitted_attempts: 0
      })

  def attach(nil, observation),
    do:
      Map.merge(%{kind: :none, intervention_count: 0}, Map.take(observation, @observation_fields))

  def attach(decision, observation),
    do: Map.merge(decision, Map.take(observation, @observation_fields))

  @doc "Makes missing decision detail explicit without changing a qualified routing policy."
  @spec capture(map() | nil) :: map() | nil
  def capture(nil), do: nil

  def capture(frame) do
    normalize(frame) ||
      %{
        kind: :omitted,
        policy_kind: frame.kind,
        mode: frame.mode,
        origin_profile: frame.origin_profile,
        reason: :frame_budget
      }
  end

  @doc "Preserves canonical attempt counts when the enclosing projection cannot fit policy detail."
  @spec summarize(map()) :: map()
  def summarize(decision) do
    decision
    |> Map.take([:intervention_count, :dispatch_observation, :attempts, :omitted_attempts])
    |> Map.merge(%{kind: :summary, reason: :projection_budget})
  end

  @spec normalize(term()) :: map() | nil
  def normalize(decision) when is_map(decision) do
    raw =
      Map.drop(decision, [
        :latest,
        :intervention_count,
        :attempts,
        :dispatch_observation,
        :omitted_attempts
      ])

    if valid_frame?(raw) and byte_size(:erlang.term_to_binary(raw)) <= frame_budget(raw) do
      first = raw |> Map.take(@frame_fields) |> clean_evidence()
      count = Map.get(decision, :intervention_count, 1)
      first = Map.put(first, :intervention_count, if(count in 0..32, do: count, else: 1))

      latest =
        case Map.get(decision, :latest) do
          later when is_map(later) ->
            normalize(
              Map.drop(later, [:latest, :attempts, :dispatch_observation, :omitted_attempts])
            )

          _ ->
            nil
        end

      first = if latest, do: Map.put(first, :latest, latest), else: first
      first |> attach_attempts(decision) |> fit()
    end
  end

  def normalize(_decision), do: nil

  # A head-suitability frame names up to sixteen routes in its order and its
  # evidence by position; managed profiles reach that shape.
  defp frame_budget(%{kind: :head_suitability}), do: @max_head_frame_bytes
  defp frame_budget(_frame), do: @max_frame_bytes

  defp attach_attempts(first, %{attempts: attempts, dispatch_observation: counts} = decision)
       when is_list(attempts) and length(attempts) <= @max_attempts do
    omitted = Map.get(decision, :omitted_attempts, 0)

    if Enum.all?(attempts, &valid_attempt?/1) and valid_counts?(counts) and
         is_integer(omitted) and omitted in 0..64 and
         Enum.sum(Map.values(Map.take(counts, [:dispatched, :indeterminate, :not_dispatched]))) ==
           length(attempts) + omitted do
      first
      |> Map.put(
        :attempts,
        Enum.map(
          attempts,
          &Map.take(&1, [
            :route,
            :origin_profile,
            :route_generation,
            :certainty,
            :outcome,
            :qualification,
            :io_duration_us,
            :cancellation_reason,
            :censoring_boundary_us
          ])
        )
      )
      |> Map.put(
        :dispatch_observation,
        Map.take(counts, [:dispatched, :indeterminate, :not_dispatched])
      )
      |> Map.put(:omitted_attempts, Map.get(decision, :omitted_attempts, 0))
    else
      first
    end
  end

  defp attach_attempts(first, _decision), do: first

  defp fit(decision) do
    cond do
      byte_size(:erlang.term_to_binary(decision)) <= @max_bytes ->
        decision

      Map.has_key?(decision, :latest) ->
        fit(Map.delete(decision, :latest))

      Map.get(decision, :attempts, []) != [] ->
        decision
        |> Map.update!(:attempts, &Enum.drop(&1, -1))
        |> Map.update(:omitted_attempts, 1, &(&1 + 1))
        |> fit()

      true ->
        nil
    end
  end

  defp clean_evidence(%{kind: :historical_depth, hints: hints} = frame) do
    Map.put(
      frame,
      :hints,
      Enum.map(hints, fn hint ->
        hint =
          Map.take(hint, [
            :route,
            :source,
            :value,
            :coordinate,
            :epoch,
            :observed_at_ms,
            :expires_at_ms,
            :support
          ])

        Map.update(
          hint,
          :support,
          %{},
          &Map.take(&1, [
            :largest_success,
            :smallest_failure,
            :distinct_failure_requests,
            :failure_window_ms
          ])
        )
      end)
    )
  end

  defp clean_evidence(%{kind: :response_latency, evidence: evidence} = frame),
    do:
      Map.put(
        frame,
        :evidence,
        Map.new(evidence, fn {route, hint} ->
          {route,
           Map.take(hint, [
             :source,
             :age_ms,
             :accepted_samples,
             :accepted_successes,
             :p50_us,
             :p95_us,
             :resolution,
             :epoch,
             :expires_at_ms
           ])}
        end)
      )

  defp clean_evidence(%{kind: :head_suitability, evidence: evidence} = frame),
    do:
      Map.put(
        frame,
        :evidence,
        Enum.map(
          evidence,
          &Map.take(&1, [:baseline_position, :verdict, :reason, :reached, :height, :age_ms])
        )
      )

  defp clean_evidence(frame), do: frame

  defp valid_frame?(%{kind: :omitted, policy_kind: kind, reason: :frame_budget} = d),
    do:
      kind in [
        :method_refusal,
        :quota_exhaustion,
        :span_limit,
        :historical_depth,
        :response_latency,
        :head_suitability
      ] and valid_common?(d)

  defp valid_frame?(%{kind: :summary, reason: :projection_budget} = d),
    do: map_size(d) == 2

  defp valid_frame?(%{kind: :none} = d), do: map_size(d) == 1

  defp valid_frame?(
         %{
           kind: :response_latency,
           evidence: evidence,
           changed_at: index,
           baseline_at_change: baseline,
           proposed_at_change: proposed
         } = d
       )
       when is_map(evidence) and map_size(evidence) <= 2 do
    valid_common?(d) and is_integer(index) and index in 0..15 and
      valid_route?(baseline) and valid_route?(proposed) and
      valid_latency?(Map.get(evidence, baseline)) and valid_latency?(Map.get(evidence, proposed))
  end

  defp valid_frame?(
         %{kind: kind, hints: hints, method: method, partition: partition, omitted_hints: omitted} =
           d
       )
       when kind in [:method_refusal, :span_limit, :quota_exhaustion] and is_list(hints) and
              length(hints) in 1..2 do
    valid_common?(d) and Lasso.RPC.BoundedIdentifier.valid?(method) and
      partition in Lasso.RPC.RoutingEvidence.Workload.partitions() and
      is_integer(omitted) and omitted >= 0 and is_map(Map.get(d, :orders)) and
      Enum.all?(hints, fn
        %{route: route, kind: ^kind, dimension: dimension} ->
          valid_route?(route) and
            ((kind == :method_refusal and dimension == method) or
               (kind == :span_limit and dimension == :logs) or
               (kind == :quota_exhaustion and dimension == :quota and d.mode == :shadow))

        _ ->
          false
      end)
  end

  defp valid_frame?(
         %{
           kind: :historical_depth,
           hints: hints,
           request_age: age,
           method: method,
           resource: resource,
           partition: partition,
           omitted_hints: omitted
         } = d
       )
       when is_list(hints) and length(hints) in 1..2 and
              (is_nil(age) or (is_integer(age) and age >= 0)) and
              is_binary(method) do
    valid_common?(d) and
      resource in [:blocks, :balance, :state, :logs, :receipts, :proofs, :traces] and
      partition in Lasso.RPC.RoutingEvidence.Workload.partitions() and
      is_integer(omitted) and omitted >= 0 and
      method in Lasso.RPC.MethodRegistry.all_methods() and
      Enum.all?(hints, &valid_hint?/1) and is_map(Map.get(d, :orders))
  end

  defp valid_frame?(
         %{
           kind: :head_suitability,
           requirement: requirement,
           band: band,
           evidence: evidence,
           omitted_evidence: omitted,
           omitted_outliers: omitted_outliers
         } = d
       )
       when requirement in [:request_height, :recovery_height, :at_head] and is_integer(band) and
              band >= 0 and is_list(evidence) and length(evidence) <= 2 and
              is_integer(omitted) and omitted >= 0 and is_integer(omitted_outliers) and
              omitted_outliers >= 0 do
    valid_common?(d) and is_map(Map.get(d, :orders)) and
      optional_count?(Map.get(d, :target_height)) and valid_mark?(Map.get(d, :mark)) and
      valid_outlier?(Map.get(d, :outlier)) and valid_cadence?(Map.get(d, :cadence)) and
      Enum.all?(evidence, &valid_head_evidence?/1)
  end

  defp valid_frame?(_decision), do: false

  defp valid_cadence?(nil), do: true

  defp valid_cadence?(%{source: source, block_time_ms: block_time_ms}),
    do: source in [:measured, :seed, :unknown] and optional_count?(block_time_ms)

  defp valid_cadence?(_cadence), do: false

  defp valid_mark?(nil), do: true

  defp valid_mark?(%{height: height, age_ms: age}),
    do: is_integer(height) and height >= 0 and is_integer(age) and age >= 0

  defp valid_mark?(_mark), do: false

  defp valid_outlier?(nil), do: true

  defp valid_outlier?(%{baseline_position: position, height: height, age_ms: age}),
    do:
      optional_count?(position) and is_integer(height) and height >= 0 and is_integer(age) and
        age >= 0

  defp valid_outlier?(_outlier), do: false

  defp valid_head_evidence?(
         %{baseline_position: position, verdict: verdict, reason: reason, reached: reached} =
           evidence
       ),
       do:
         optional_count?(position) and verdict in [:unknown, :against] and is_boolean(reached) and
           reason in [
             :below_height,
             :behind_mark,
             :within_credit,
             :cadence_unknown,
             :observation_stale,
             :no_observation
           ] and optional_count?(Map.get(evidence, :height)) and
           optional_count?(Map.get(evidence, :age_ms))

  defp valid_head_evidence?(_evidence), do: false

  defp valid_common?(%{mode: mode, origin_profile: profile} = d),
    do:
      mode in [:on, :shadow] and is_binary(profile) and byte_size(profile) in 1..128 and
        valid_orders?(Map.get(d, :orders))

  defp valid_common?(_d), do: false

  defp valid_orders?(nil), do: true

  defp valid_orders?(%{
         routes: routes,
         baseline: base,
         proposed: proposed,
         applied: applied,
         complete?: complete,
         omitted_routes: omitted
       })
       when is_list(routes) and length(routes) in 1..@max_routes and is_boolean(complete) and
              is_integer(omitted) and omitted >= 0 do
    positions = Enum.to_list(1..length(routes))

    Enum.all?(routes, &valid_route?/1) and Enum.uniq(routes) == routes and
      base == positions and is_list(proposed) and is_list(applied) and
      Enum.sort(proposed) == positions and Enum.sort(applied) == positions
  end

  defp valid_orders?(_orders), do: false

  defp valid_route?({id, transport}),
    do: is_binary(id) and byte_size(id) in 1..128 and transport in [:http, :ws]

  defp valid_route?(_route), do: false

  defp valid_latency?(%{source: :local, age_ms: age, accepted_samples: samples, p95_us: p95}),
    do:
      is_integer(age) and age >= 0 and is_integer(samples) and samples >= 0 and is_integer(p95) and
        p95 > 0

  defp valid_latency?(_hint), do: false

  defp valid_hint?(%{route: route, source: source, value: value} = hint),
    do:
      valid_route?(route) and source in [:local, :imported, :declared, :observed_by_probe] and
        is_integer(value) and value >= 0 and valid_support?(Map.get(hint, :support, %{})) and
        Enum.all?(
          [:epoch, :observed_at_ms, :expires_at_ms],
          &optional_count?(Map.get(hint, &1))
        ) and
        byte_size(:erlang.term_to_binary(hint)) <= 512

  defp valid_hint?(_hint), do: false

  defp valid_support?(support) when is_map(support),
    do:
      Enum.all?(
        [:largest_success, :smallest_failure, :distinct_failure_requests, :failure_window_ms],
        &optional_count?(Map.get(support, &1))
      )

  defp valid_support?(_support), do: false
  defp optional_count?(nil), do: true
  defp optional_count?(value), do: is_integer(value) and value >= 0

  defp valid_attempt?(
         %{
           route: route,
           origin_profile: profile,
           route_generation: generation,
           certainty: certainty,
           outcome: outcome,
           qualification: qualification,
           io_duration_us: duration
         } = attempt
       ),
       do:
         valid_route?(route) and is_binary(profile) and byte_size(profile) in 1..128 and
           is_integer(generation) and generation >= 0 and
           certainty in [:dispatched, :indeterminate, :not_dispatched] and
           outcome in [
             :success,
             :application_error,
             :invalid_response,
             :predispatch_failure,
             :transport_failure,
             :deadline,
             :cancelled
           ] and
           qualification in [:accepted, :policy_rejected] and
           optional_count?(duration) and
           optional_count?(Map.get(attempt, :censoring_boundary_us)) and
           valid_cancellation_reason?(outcome, Map.get(attempt, :cancellation_reason))

  defp valid_attempt?(_attempt), do: false

  # Older projections have no cancellation detail; absence is not a different reason.
  defp valid_cancellation_reason?(_outcome, nil), do: true

  defp valid_cancellation_reason?(:cancelled, reason),
    do: reason in [:caller_abandoned, :socket_closed, :owner_shutdown, :superseded]

  defp valid_cancellation_reason?(_outcome, _reason), do: false

  defp valid_counts?(counts) when is_map(counts),
    do:
      Enum.all?(
        [:dispatched, :indeterminate, :not_dispatched],
        &(is_integer(Map.get(counts, &1)) and Map.get(counts, &1) in 0..64)
      )

  defp valid_counts?(_counts), do: false

  @doc "Adds order ordinals and outcomes without publishing internal route identities."
  @spec public_observation(map(), map()) :: map()
  def public_observation(public, decision) do
    public
    |> Map.put(:orders, public_orders(Map.get(decision, :orders)))
    |> Map.put(:order_scope, Map.get(decision, :order_scope))
    |> Map.put(:dispatch_observation, Map.get(decision, :dispatch_observation))
    |> Map.put(
      :attempts,
      Enum.map(Map.get(decision, :attempts, []), &public_attempt(&1, decision))
    )
    |> Map.put(:omitted_attempts, Map.get(decision, :omitted_attempts, 0))
  end

  @spec public_hints(map()) :: [map()]
  def public_hints(decision),
    do:
      Enum.map(decision.hints, fn hint ->
        hint |> Map.delete(:route) |> Map.put(:baseline_position, position(decision, hint.route))
      end)

  defp public_attempt(attempt, decision) do
    attempt
    |> Map.delete(:route)
    |> public_censoring_boundary()
    |> Map.put(:baseline_position, position(decision, attempt.route))
    |> Map.put(:latest_baseline_position, position(Map.get(decision, :latest), attempt.route))
  end

  defp public_censoring_boundary(%{censoring_boundary_us: us} = attempt) when is_integer(us),
    do:
      attempt |> Map.delete(:censoring_boundary_us) |> Map.put(:censoring_boundary_ms, us / 1_000)

  defp public_censoring_boundary(attempt), do: Map.delete(attempt, :censoring_boundary_us)

  defp position(%{orders: %{routes: routes}}, route) do
    case Enum.find_index(routes, &(&1 == route)) do
      nil -> nil
      index -> index + 1
    end
  end

  defp position(_decision, _route), do: nil

  defp public_orders(nil), do: nil

  defp public_orders(orders),
    do: Map.take(orders, [:baseline, :proposed, :applied, :complete?, :omitted_routes])
end

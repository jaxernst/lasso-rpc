defmodule Lasso.RPC.RequestProjection do
  @moduledoc false

  alias Lasso.Core.Benchmarking.Metrics
  alias Lasso.Core.ProjectionDispatcher
  alias Lasso.Events.RoutingDecision
  alias LassoWeb.Dashboard.TrafficCounters

  alias Lasso.RPC.{
    AttemptIdentity,
    AttemptTerminal,
    ExecutionFact,
    ExecutionProjector,
    RequestAggregate,
    RequestTerminal
  }

  alias Lasso.RPC.ExecutionFact.Codec
  alias Lasso.RPC.ProviderKnowledge.Decision, as: LearningDecision

  @schema :lasso_request_projection
  @version 5
  @max_bytes 4_096
  @dispatcher Lasso.ExecutionProjectionDispatcher
  @routing_decisions_per_second 256
  @routing_budget_buckets 256

  @enforce_keys [:version, :fact, :method, :request_origin, :failover_count, :emitted_at_ms]
  defstruct @enforce_keys ++
              [
                :provider_id,
                :instance_id,
                :transport,
                :account_id,
                :requested_profile,
                :service_profile,
                :effective_profile,
                :fallback_depth,
                :fallback_reason,
                :learning_decision,
                :exhaustion_cause,
                transaction_reason: :none,
                ingress_transport: :unavailable
              ]

  @type route_identity :: %{
          provider_id: binary(),
          instance_id: binary() | nil,
          transport: :http | :ws
        }

  @type t :: %__MODULE__{
          version: 5,
          fact: RequestTerminal.t(),
          method: binary(),
          provider_id: binary() | nil,
          instance_id: binary() | nil,
          transport: :http | :ws | nil,
          ingress_transport: Lasso.RPC.RequestOptions.ingress_transport(),
          account_id: binary() | nil,
          requested_profile: binary() | nil,
          service_profile: binary() | nil,
          effective_profile: binary() | nil,
          fallback_depth: non_neg_integer(),
          fallback_reason: atom() | nil,
          learning_decision: map() | nil,
          exhaustion_cause: atom() | nil,
          request_origin: :client | :system,
          failover_count: 0..16,
          emitted_at_ms: non_neg_integer()
        }

  @spec new(
          RequestTerminal.t(),
          binary(),
          route_identity() | nil,
          non_neg_integer(),
          :client | :system,
          binary() | nil,
          map()
        ) :: t()
  def new(
        fact,
        method,
        route_identity,
        failover_count,
        request_origin \\ :client,
        account_id \\ nil,
        routing_context \\ %{}
      ) do
    %__MODULE__{
      version: @version,
      fact: fact,
      method: method,
      provider_id: route_value(route_identity, :provider_id),
      instance_id: route_value(route_identity, :instance_id),
      transport: route_value(route_identity, :transport),
      account_id: account_id,
      transaction_reason: Map.get(routing_context, :transaction_reason, :none),
      ingress_transport: Map.get(routing_context, :ingress_transport, :unavailable),
      requested_profile: Map.get(routing_context, :requested_profile),
      service_profile: Map.get(routing_context, :service_profile),
      effective_profile: Map.get(routing_context, :effective_profile),
      fallback_depth: Map.get(routing_context, :fallback_depth, 0),
      fallback_reason: Map.get(routing_context, :fallback_reason),
      learning_decision: Map.get(routing_context, :learning_decision),
      exhaustion_cause:
        Map.get(
          routing_context,
          :exhaustion_cause,
          route_value(route_identity, :exhaustion_cause)
        ),
      request_origin: request_origin,
      failover_count: failover_count,
      emitted_at_ms: System.system_time(:millisecond)
    }
    |> validate!()
  end

  @spec enqueue(t(), atom()) :: term()
  def enqueue(%__MODULE__{} = event, dispatcher \\ @dispatcher) when is_atom(dispatcher) do
    _counter_result = TrafficCounters.record(event)

    enqueue_lazy(event, dispatcher, fn -> encode(event) end)
  end

  @doc false
  @spec new_and_enqueue(
          RequestTerminal.t(),
          binary(),
          route_identity() | nil,
          non_neg_integer(),
          :client | :system,
          binary() | nil,
          map(),
          atom()
        ) :: term()
  def new_and_enqueue(
        fact,
        method,
        route_identity,
        failover_count,
        request_origin \\ :client,
        account_id \\ nil,
        routing_context \\ %{},
        dispatcher \\ @dispatcher
      )
      when is_atom(dispatcher) do
    {account_id, dispatcher} =
      if is_atom(account_id) and not is_nil(account_id),
        do: {nil, account_id},
        else: {account_id, dispatcher}

    event =
      new_event(
        fact,
        method,
        route_identity,
        failover_count,
        request_origin,
        account_id,
        routing_context
      )

    _counter_result = TrafficCounters.record(event)
    enqueue_lazy(event, dispatcher, fn -> encode_validated(event) end)
  end

  @spec record_and_enqueue(
          RequestTerminal.t(),
          binary(),
          route_identity() | nil,
          non_neg_integer(),
          :client | :system,
          binary() | nil,
          map(),
          atom()
        ) :: term()
  def record_and_enqueue(
        fact,
        method,
        route_identity,
        failover_count,
        request_origin \\ :client,
        account_id \\ nil,
        routing_context \\ %{},
        dispatcher \\ @dispatcher
      )
      when is_atom(dispatcher) do
    _counter_result =
      TrafficCounters.record_request(fact, request_origin, failover_count)

    case RequestAggregate.record_and_reserve_detail(
           fact,
           request_origin,
           System.system_time(:millisecond)
         ) do
      :detail ->
        new_event_and_enqueue(
          fact,
          method,
          route_identity,
          failover_count,
          request_origin,
          account_id,
          routing_context,
          dispatcher
        )

      :aggregate_only ->
        {:drop, :sampled_out, :untracked}

      :untracked ->
        new_event_and_enqueue(
          fact,
          method,
          route_identity,
          failover_count,
          request_origin,
          account_id,
          routing_context,
          dispatcher
        )
    end
  end

  defp new_event_and_enqueue(
         fact,
         method,
         route_identity,
         failover_count,
         request_origin,
         account_id,
         routing_context,
         dispatcher
       ) do
    event =
      new_event(
        fact,
        method,
        route_identity,
        failover_count,
        request_origin,
        account_id,
        routing_context
      )

    enqueue_lazy(event, dispatcher, fn -> encode_validated(event) end)
  end

  defp new_event(
         fact,
         method,
         route_identity,
         failover_count,
         request_origin,
         account_id,
         routing_context
       ) do
    new(
      fact,
      method,
      route_identity,
      failover_count,
      request_origin,
      account_id,
      routing_context
    )
  end

  defp enqueue_lazy(event, dispatcher, encoder) do
    ProjectionDispatcher.enqueue_lazy(
      dispatcher,
      :diagnostics,
      {Map.fetch!(event.fact, :profile), Map.fetch!(event.fact, :chain_id)},
      encoder
    )
  end

  @spec encode(t()) :: {:ok, binary()} | {:error, atom()}
  def encode(%__MODULE__{} = event) do
    event |> validate!() |> encode_validated()
  end

  defp encode_validated(event) do
    payload = encode_payload(event)

    cond do
      byte_size(payload) <= @max_bytes ->
        {:ok, payload}

      event.learning_decision != nil and event.learning_decision.kind != :summary ->
        encode_validated(%{
          event
          | learning_decision: LearningDecision.summarize(event.learning_decision)
        })

      true ->
        {:error, :event_too_large}
    end
  rescue
    ArgumentError -> {:error, :invalid_event}
  end

  defp encode_payload(event) do
    :erlang.term_to_binary({
      @schema,
      @version,
      encode_fact_payload(event.fact),
      event.method,
      event.provider_id,
      event.instance_id,
      event.transport,
      event.account_id,
      event.requested_profile,
      event.service_profile,
      event.effective_profile,
      event.fallback_depth,
      event.fallback_reason,
      event.learning_decision,
      event.exhaustion_cause,
      event.request_origin,
      event.failover_count,
      event.emitted_at_ms,
      event.ingress_transport,
      event.transaction_reason
    })
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, atom()}
  def decode(payload) when is_binary(payload) and byte_size(payload) <= @max_bytes do
    case :erlang.binary_to_term(payload, [:safe]) do
      {@schema, @version, fact, method, provider, instance, transport, account, requested,
       service, effective, depth, fallback, learning, exhaustion, origin, failovers, emitted,
       ingress, reason} ->
        decoded(fact, %{
          method: method,
          provider_id: provider,
          instance_id: instance,
          transport: transport,
          account_id: account,
          requested_profile: requested,
          service_profile: service,
          effective_profile: effective,
          fallback_depth: depth,
          fallback_reason: fallback,
          learning_decision: learning,
          exhaustion_cause: exhaustion,
          request_origin: origin,
          failover_count: failovers,
          emitted_at_ms: emitted,
          ingress_transport: ingress,
          transaction_reason: reason
        })

      {
        @schema,
        4,
        fact_payload,
        method,
        provider_id,
        instance_id,
        transport,
        account_id,
        requested_profile,
        service_profile,
        effective_profile,
        fallback_depth,
        fallback_reason,
        learning_decision,
        exhaustion_cause,
        request_origin,
        failover_count,
        emitted_at_ms,
        ingress_transport
      } ->
        decoded(fact_payload, %{
          method: method,
          provider_id: provider_id,
          instance_id: instance_id,
          transport: transport,
          account_id: account_id,
          requested_profile: requested_profile,
          service_profile: service_profile,
          effective_profile: effective_profile,
          fallback_depth: fallback_depth,
          fallback_reason: fallback_reason,
          learning_decision: learning_decision,
          exhaustion_cause: exhaustion_cause,
          request_origin: request_origin,
          failover_count: failover_count,
          emitted_at_ms: emitted_at_ms,
          ingress_transport: ingress_transport
        })

      {
        @schema,
        3,
        fact_payload,
        method,
        provider_id,
        instance_id,
        transport,
        account_id,
        requested_profile,
        service_profile,
        effective_profile,
        fallback_depth,
        fallback_reason,
        learning_decision,
        exhaustion_cause,
        request_origin,
        failover_count,
        emitted_at_ms
      } ->
        decoded(fact_payload, %{
          method: method,
          provider_id: provider_id,
          instance_id: instance_id,
          transport: transport,
          account_id: account_id,
          requested_profile: requested_profile,
          service_profile: service_profile,
          effective_profile: effective_profile,
          fallback_depth: fallback_depth,
          fallback_reason: fallback_reason,
          learning_decision: learning_decision,
          exhaustion_cause: exhaustion_cause,
          request_origin: request_origin,
          failover_count: failover_count,
          emitted_at_ms: emitted_at_ms
        })

      {@schema, 2, fact_payload, method, provider, instance, transport, origin, failovers,
       emitted, exhaustion} ->
        decoded(fact_payload, %{
          method: method,
          provider_id: provider,
          instance_id: instance,
          transport: transport,
          request_origin: origin,
          failover_count: failovers,
          emitted_at_ms: emitted,
          fallback_depth: 0,
          exhaustion_cause: exhaustion
        })

      {@schema, 1, fact_payload, method, provider, instance, transport, origin, failovers,
       emitted} ->
        decoded(fact_payload, %{
          method: method,
          provider_id: provider,
          instance_id: instance,
          transport: transport,
          request_origin: origin,
          failover_count: failovers,
          emitted_at_ms: emitted,
          fallback_depth: 0
        })

      {@schema, 2, fact_payload, method, provider_id, instance_id, transport, account_id,
       requested_profile, service_profile, effective_profile, fallback_depth, fallback_reason,
       learning_decision, request_origin, failover_count, emitted_at_ms} ->
        decoded(fact_payload, %{
          method: method,
          provider_id: provider_id,
          instance_id: instance_id,
          transport: transport,
          account_id: account_id,
          requested_profile: requested_profile,
          service_profile: service_profile,
          effective_profile: effective_profile,
          fallback_depth: fallback_depth,
          fallback_reason: fallback_reason,
          learning_decision: learning_decision,
          request_origin: request_origin,
          failover_count: failover_count,
          emitted_at_ms: emitted_at_ms
        })

      {@schema, 1, fact_payload, method, provider_id, instance_id, transport, account_id,
       requested_profile, service_profile, effective_profile, fallback_depth, fallback_reason,
       request_origin, failover_count, emitted_at_ms} ->
        case decode_fact_payload(fact_payload) do
          {:ok, fact} ->
            {:ok,
             validate!(%__MODULE__{
               version: @version,
               fact: fact,
               method: method,
               provider_id: provider_id,
               instance_id: instance_id,
               transport: transport,
               account_id: account_id,
               requested_profile: requested_profile,
               service_profile: service_profile,
               effective_profile: effective_profile,
               fallback_depth: fallback_depth,
               fallback_reason: fallback_reason,
               learning_decision: nil,
               request_origin: request_origin,
               failover_count: failover_count,
               emitted_at_ms: emitted_at_ms
             })}

          {:error, _reason} ->
            {:error, :invalid_fact}
        end

      {@schema, version, _fact, _method, _provider, _instance, _transport, _account_id,
       _requested_profile, _service_profile, _effective_profile, _fallback_depth,
       _fallback_reason, _learning_decision, _exhaustion_cause, _request_origin, _failovers,
       _emitted_at_ms, _ingress_transport}
      when is_integer(version) ->
        {:error, :unsupported_version}

      {@schema, version, _fact, _method, _provider, _instance, _transport, _account_id,
       _requested_profile, _service_profile, _effective_profile, _fallback_depth,
       _fallback_reason, _learning_decision, _exhaustion_cause, _request_origin, _failovers,
       _emitted_at_ms}
      when is_integer(version) ->
        {:error, :unsupported_version}

      _other ->
        {:error, :invalid_event}
    end
  rescue
    ArgumentError -> {:error, :invalid_event}
  end

  def decode(payload) when is_binary(payload), do: {:error, :event_too_large}

  defp decoded(fact_payload, fields) do
    case decode_fact_payload(fact_payload) do
      {:ok, fact} ->
        {:ok, validate!(struct!(__MODULE__, Map.merge(fields, %{version: @version, fact: fact})))}

      {:error, _reason} ->
        {:error, :invalid_fact}
    end
  end

  defp decode_fact_payload(fact_payload) when is_binary(fact_payload),
    do: Codec.decode(fact_payload)

  defp decode_fact_payload({
         :compact_success_v1,
         request_id,
         attempt_id,
         profile,
         subject_token,
         chain_id,
         upstream_instance_id,
         transport,
         route_generation,
         circuit_scope,
         circuit_epoch,
         execution_safety,
         routing_intent,
         workload_key,
         request_budget_ms,
         candidate_admission_count,
         dispatch_count,
         elapsed_us,
         io_duration_us,
         observed_at
       }) do
    identity =
      AttemptIdentity.new_runtime(%{
        request_id: request_id,
        attempt_id: attempt_id,
        profile: profile,
        subject_token: subject_token,
        chain_id: chain_id,
        upstream_instance_id: upstream_instance_id,
        transport: transport,
        route_generation: route_generation,
        circuit_scope: circuit_scope,
        circuit_epoch: circuit_epoch,
        execution_safety: execution_safety,
        routing_intent: routing_intent,
        workload_key: workload_key,
        request_budget_ms: request_budget_ms,
        candidate_admission_count: candidate_admission_count,
        dispatch_count: dispatch_count
      })

    attempt = AttemptTerminal.Response.new(identity, :success, io_duration_us)

    {:ok,
     RequestTerminal.UpstreamResponse.new_runtime(
       attempt,
       elapsed_us,
       candidate_admission_count,
       dispatch_count,
       observed_at
     )}
  rescue
    ArgumentError -> {:error, :invalid_fact}
  end

  defp decode_fact_payload(%_module{} = fact), do: {:ok, fact}

  defp decode_fact_payload(_fact_payload), do: {:error, :invalid_fact}

  defp encode_fact_payload(
         %RequestTerminal.UpstreamResponse{
           attempt: %AttemptTerminal.Response{
             kind: :success,
             identity: %AttemptIdentity{} = identity,
             io_duration_us: io_duration_us
           }
         } = fact
       ) do
    {
      :compact_success_v1,
      identity.request_id,
      identity.attempt_id,
      identity.profile,
      identity.subject_token,
      identity.chain_id,
      identity.upstream_instance_id,
      identity.transport,
      identity.route_generation,
      identity.circuit_scope,
      identity.circuit_epoch,
      identity.execution_safety,
      identity.routing_intent,
      identity.workload_key,
      identity.request_budget_ms,
      identity.candidate_admission_count,
      identity.dispatch_count,
      fact.elapsed_us,
      io_duration_us,
      fact.observed_at
    }
  end

  defp encode_fact_payload(fact), do: fact

  @spec routing_decision(t()) :: {:ok, RoutingDecision.t()} | :not_routed
  def routing_decision(%__MODULE__{provider_id: provider_id, transport: transport} = event)
      when is_binary(provider_id) and transport in [:http, :ws] do
    fact = event.fact

    {:ok,
     RoutingDecision.new(
       ts: event.emitted_at_ms,
       request_id: Map.fetch!(fact, :request_id),
       profile: Map.fetch!(fact, :profile),
       chain_id: Map.fetch!(fact, :chain_id),
       method: event.method,
       strategy: Map.fetch!(fact, :routing_intent),
       provider_id: provider_id,
       instance_id: event.instance_id,
       transport: transport,
       ingress_transport: event.ingress_transport,
       dispatch_count: Map.fetch!(fact, :dispatch_count),
       account_id: event.account_id,
       requested_profile: event.requested_profile,
       service_profile: event.service_profile,
       effective_profile: event.effective_profile,
       fallback_depth: event.fallback_depth,
       fallback_reason: event.fallback_reason,
       exhaustion_cause: event.exhaustion_cause,
       learning_decision:
         public_learning_decision(event.learning_decision, {event.instance_id, event.transport}),
       request_origin: event.request_origin,
       duration_ms: div(Map.fetch!(fact, :elapsed_us), 1_000),
       result: result(event.fact),
       failover_count: event.failover_count
     )}
  end

  def routing_decision(%__MODULE__{}), do: :not_routed

  @doc "Bounded routing explanation without internal route identities or request bodies."
  @spec learning_metadata(map() | nil, map() | nil) :: map() | nil
  def learning_metadata(decision, channel \\ nil) do
    route =
      case channel do
        %{instance_id: instance, transport: transport} -> {instance, transport}
        _ -> nil
      end

    public_learning_decision(decision, route)
  end

  defp public_learning_decision(nil, _selected), do: nil

  defp public_learning_decision(
         %{kind: :response_latency, evidence: evidence} = decision,
         selected
       ) do
    previous = Map.get(evidence, decision.baseline_at_change)
    proposed = Map.get(evidence, decision.proposed_at_change)

    if is_map(previous) and is_map(proposed) do
      first = %{
        kind: :response_latency,
        mode: decision.mode,
        origin_profile: Map.get(decision, :origin_profile),
        budget_result: :no_extra_dispatch,
        counterfactual: :unobserved,
        rank: decision.changed_at + 1,
        resource: public_learning_resource(Map.get(decision, :resource)),
        source: :local,
        baseline_p95_us: previous.p95_us,
        proposed_p95_us: proposed.p95_us,
        baseline_accepted_samples: previous.accepted_samples,
        proposed_accepted_samples: proposed.accepted_samples,
        evidence_age_ms: max(previous.age_ms, proposed.age_ms),
        selected_proposal?:
          decision.changed_at == 0 and decision.mode == :on and
            selected == decision.proposed_at_change
      }

      latest = public_learning_decision(Map.get(decision, :latest), selected)
      count = Map.get(decision, :intervention_count, 1)
      retained = if latest, do: 2, else: 1

      first
      |> LearningDecision.public_observation(decision)
      |> Map.put(:intervention_count, count)
      |> Map.put(:omitted_interventions, max(count - retained, 0))
      |> maybe_put_latest(latest)
    end
  end

  defp public_learning_decision(%{kind: kind} = decision, selected)
       when kind in [:method_refusal, :span_limit] do
    decision
    |> Map.take([
      :kind,
      :mode,
      :origin_profile,
      :method,
      :partition,
      :omitted_hints,
      :order_scope,
      :intervention_count
    ])
    |> Map.put(:hints, LearningDecision.public_hints(decision))
    |> Map.put(:latest, public_learning_decision(Map.get(decision, :latest), selected))
    |> LearningDecision.public_observation(decision)
  end

  defp public_learning_decision(%{kind: :historical_depth} = decision, selected) do
    count = Map.get(decision, :intervention_count, 1)
    latest = public_learning_decision(Map.get(decision, :latest), selected)
    retained = if latest, do: 2, else: 1

    %{
      kind: :historical_depth,
      mode: decision.mode,
      origin_profile: decision.origin_profile,
      method: decision.method,
      resource: decision.resource,
      partition: decision.partition,
      request_age: decision.request_age,
      counterfactual: :unobserved,
      budget_result: :no_extra_dispatch,
      hints: LearningDecision.public_hints(decision),
      omitted_hints: decision.omitted_hints,
      intervention_count: count,
      omitted_interventions: max(count - retained, 0)
    }
    |> LearningDecision.public_observation(decision)
    |> maybe_put_latest(latest)
  end

  defp public_learning_decision(%{kind: :head_suitability} = decision, selected) do
    count = Map.get(decision, :intervention_count, 1)
    latest = public_learning_decision(Map.get(decision, :latest), selected)
    retained = if latest, do: 2, else: 1

    %{
      kind: :head_suitability,
      mode: decision.mode,
      origin_profile: decision.origin_profile,
      budget_result: :no_extra_dispatch,
      requirement: decision.requirement,
      target_height: decision.target_height,
      band: decision.band,
      cadence: Map.get(decision, :cadence),
      mark: decision.mark,
      outlier: decision.outlier,
      omitted_outliers: decision.omitted_outliers,
      evidence: decision.evidence,
      omitted_evidence: decision.omitted_evidence,
      intervention_count: count,
      omitted_interventions: max(count - retained, 0)
    }
    |> LearningDecision.public_observation(decision)
    |> maybe_put_latest(latest)
  end

  defp public_learning_decision(%{kind: :omitted} = decision, selected) do
    latest = public_learning_decision(Map.get(decision, :latest), selected)
    count = Map.get(decision, :intervention_count, 1)

    decision
    |> Map.take([:kind, :policy_kind, :reason, :mode, :origin_profile])
    |> Map.put(:intervention_count, count)
    |> Map.put(:omitted_interventions, max(count - if(latest, do: 2, else: 1), 0))
    |> LearningDecision.public_observation(decision)
    |> maybe_put_latest(latest)
  end

  defp public_learning_decision(%{kind: :none} = decision, _selected),
    do:
      LearningDecision.public_observation(
        %{kind: :none, intervention_count: 0},
        decision
      )

  defp public_learning_decision(%{kind: :summary} = decision, _selected),
    do:
      LearningDecision.public_observation(
        %{
          kind: :summary,
          reason: :projection_budget,
          intervention_count: Map.get(decision, :intervention_count, 0),
          omitted_interventions: Map.get(decision, :intervention_count, 0)
        },
        decision
      )

  defp public_learning_decision(_decision, _selected), do: nil

  defp maybe_put_latest(first, nil), do: first
  defp maybe_put_latest(first, latest), do: Map.put(first, :latest, latest)

  defp public_learning_resource(%{
         historical_resource: resource,
         historical_height: height
       })
       when resource in [nil, :blocks, :balance, :state, :logs, :receipts, :proofs, :traces] and
              (is_nil(height) or (is_integer(height) and height >= 0)),
       do: %{historical_resource: resource, historical_height: height}

  defp public_learning_resource(_resource), do: nil

  @spec deliver(t()) :: :ok
  def deliver(%__MODULE__{} = event) do
    publish_routing_decision(event)
    emit_terminal_telemetry(event)
    emit_request_telemetry(event)
    record_dashboard_metric(event)
    :ok
  end

  defp record_dashboard_metric(%__MODULE__{
         request_origin: :client,
         provider_id: provider_id,
         transport: transport,
         fact: fact,
         method: method
       })
       when is_binary(provider_id) and transport in [:http, :ws] do
    Metrics.record_request(
      Map.fetch!(fact, :profile),
      Map.fetch!(fact, :chain_id),
      provider_id,
      method,
      div(Map.fetch!(fact, :elapsed_us), 1_000),
      result(fact),
      transport: transport
    )
  end

  defp record_dashboard_metric(%__MODULE__{}), do: :ok

  defp publish_routing_decision(event) do
    with {:ok, decision} <- routing_decision(event),
         true <- publish_routing_decision?(event, decision) do
      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.routing_decision(decision.profile),
        decision
      )
    end
  end

  defp publish_routing_decision?(event, decision) do
    if result(event.fact) == :error do
      true
    else
      bucket =
        :erlang.phash2(
          {decision.profile, decision.chain_id, decision.request_origin},
          @routing_budget_buckets
        )

      key = {__MODULE__, :routing_budget, bucket}
      second = div(decision.ts, 1_000)

      case Process.get(key) do
        {^second, count} when count >= @routing_decisions_per_second ->
          :telemetry.execute(
            [:lasso, :rpc, :routing_decision, :sampled_out],
            %{count: 1},
            %{
              profile: decision.profile,
              chain_id: decision.chain_id,
              request_origin: decision.request_origin
            }
          )

          false

        {^second, count} ->
          Process.put(key, {second, count + 1})
          true

        _previous_window ->
          Process.put(key, {second, 1})
          true
      end
    end
  end

  defp emit_terminal_telemetry(event) do
    fact = event.fact
    projection = ExecutionProjector.project(fact)

    :telemetry.execute(
      [:lasso, :rpc, :request, :terminal],
      %{count: 1, elapsed_us: Map.fetch!(fact, :elapsed_us)},
      %{
        request_id: Map.fetch!(fact, :request_id),
        profile: Map.fetch!(fact, :profile),
        chain_id: Map.fetch!(fact, :chain_id),
        method: event.method,
        provider_id: event.provider_id,
        instance_id: event.instance_id,
        transport: event.transport,
        account_id: event.account_id,
        requested_profile: event.requested_profile,
        service_profile: event.service_profile,
        effective_profile: event.effective_profile,
        fallback_depth: event.fallback_depth,
        fallback_reason: event.fallback_reason,
        request_origin: event.request_origin,
        result: result(fact),
        failovers: event.failover_count,
        diagnostic: projection.diagnostic,
        ingress_transport: event.ingress_transport,
        exhaustion_cause: event.exhaustion_cause,
        candidate_admission_count: Map.fetch!(fact, :candidate_admission_count),
        dispatch_count: Map.fetch!(fact, :dispatch_count)
      }
    )
  end

  defp emit_request_telemetry(event) do
    fact = event.fact
    result = result(fact)

    :telemetry.execute(
      [:lasso, :rpc, :request, :stop],
      %{duration: div(Map.fetch!(fact, :elapsed_us), 1_000)},
      %{
        profile: Map.fetch!(fact, :profile),
        chain_id: Map.fetch!(fact, :chain_id),
        method: event.method,
        strategy: Map.fetch!(fact, :routing_intent),
        provider_id: event.provider_id,
        instance_id: event.instance_id,
        transport: event.transport,
        account_id: event.account_id,
        requested_profile: event.requested_profile,
        service_profile: event.service_profile,
        effective_profile: event.effective_profile,
        fallback_depth: event.fallback_depth,
        fallback_reason: event.fallback_reason,
        request_origin: event.request_origin,
        result: result,
        status: result,
        failovers: event.failover_count,
        reason: event.transaction_reason
      }
    )
  end

  defp validate!(%__MODULE__{} = event) do
    if event.version != @version, do: raise(ArgumentError, "unsupported version")
    unless request_terminal?(event.fact), do: raise(ArgumentError, "invalid request terminal")

    provider_id = ExecutionFact.optional_bounded!(event.provider_id, :provider_id)
    instance_id = ExecutionFact.optional_bounded!(event.instance_id, :instance_id)
    account_id = ExecutionFact.optional_bounded!(event.account_id, :account_id)

    requested_profile =
      ExecutionFact.optional_bounded!(event.requested_profile, :requested_profile)

    service_profile = ExecutionFact.optional_bounded!(event.service_profile, :service_profile)

    effective_profile =
      ExecutionFact.optional_bounded!(event.effective_profile, :effective_profile)

    transport =
      case event.transport do
        nil -> nil
        value -> ExecutionFact.transport!(value)
      end

    if is_nil(provider_id) != is_nil(transport),
      do: raise(ArgumentError, "provider and transport must be present together")

    if is_nil(provider_id) and not is_nil(instance_id),
      do: raise(ArgumentError, "instance requires a provider")

    if event.request_origin not in [:client, :system],
      do: raise(ArgumentError, "invalid request origin")

    if not is_integer(event.fallback_depth) or event.fallback_depth < 0,
      do: raise(ArgumentError, "invalid fallback depth")

    if not is_nil(event.fallback_reason) and not is_atom(event.fallback_reason),
      do: raise(ArgumentError, "invalid fallback reason")

    if not is_nil(event.exhaustion_cause) and not is_atom(event.exhaustion_cause),
      do: raise(ArgumentError, "invalid exhaustion cause")

    if event.transaction_reason not in [:none],
      do: raise(ArgumentError, "invalid transaction reason")

    learning_decision = bounded_learning_decision(event.learning_decision)

    %{
      event
      | version: @version,
        method: ExecutionFact.bounded!(event.method, :method),
        provider_id: provider_id,
        instance_id: instance_id,
        account_id: account_id,
        requested_profile: requested_profile,
        service_profile: service_profile,
        effective_profile: effective_profile,
        fallback_depth: event.fallback_depth,
        fallback_reason: event.fallback_reason,
        learning_decision: learning_decision,
        transport: transport,
        ingress_transport: ingress_transport(event),
        request_origin: event.request_origin,
        failover_count: ExecutionFact.candidate_count!(event.failover_count),
        emitted_at_ms: ExecutionFact.non_negative!(event.emitted_at_ms, :emitted_at_ms)
    }
  end

  defp ingress_transport(%{request_origin: :system}), do: :not_applicable
  defp ingress_transport(%{ingress_transport: ingress}) when ingress in [:http, :ws], do: ingress
  defp ingress_transport(_event), do: :unavailable

  defp bounded_learning_decision(decision),
    do: LearningDecision.normalize(decision)

  defp request_terminal?(%RequestTerminal.UpstreamResponse{}), do: true
  defp request_terminal?(%RequestTerminal.LocalSuccess{}), do: true
  defp request_terminal?(%RequestTerminal.LocalFailure{}), do: true
  defp request_terminal?(%RequestTerminal.Deadline{}), do: true
  defp request_terminal?(%RequestTerminal.CallerAbandonment{}), do: true
  defp request_terminal?(%RequestTerminal.UnsafeIndeterminateExhaustion{}), do: true
  defp request_terminal?(%RequestTerminal.OrdinaryExhaustion{}), do: true
  defp request_terminal?(_fact), do: false

  defp result(%RequestTerminal.UpstreamResponse{attempt: %{kind: :success}}), do: :success
  defp result(%RequestTerminal.LocalSuccess{}), do: :success
  defp result(_fact), do: :error

  defp route_value(nil, _key), do: nil
  defp route_value(route, key) when is_map(route), do: Map.get(route, key)
end

defmodule Lasso.RPC.ProviderKnowledge do
  @moduledoc "One local read interface and asynchronous evidence stream for provider knowledge."

  alias Lasso.Core.ProjectionDispatcher
  alias Lasso.RPC.AttemptTerminal
  alias Lasso.RPC.BoundedIdentifier
  alias Lasso.RPC.MethodRegistry
  alias Lasso.RPC.ProviderKnowledge.{Evidence, Persistence, ReadModel}

  alias Lasso.RPC.ProviderKnowledge.Learners.{
    HistoricalDepth,
    LocalResponseLatency,
    MethodRefusal,
    OutcomeStatistics,
    SpanBracket
  }

  alias Lasso.RPC.Providers.CapabilityObservation

  @dispatcher Lasso.ExecutionProjectionDispatcher
  @max_payload_bytes 2_048

  @spec learners() :: [module()]
  def learners,
    do:
      Application.get_env(:lasso, :provider_knowledge_learners, [
        OutcomeStatistics,
        LocalResponseLatency,
        MethodRefusal,
        SpanBracket,
        HistoricalDepth
      ])

  @spec lane_options() :: keyword()
  def lane_options do
    capacity = 1_024
    scope_capacity = 16

    [
      capacity: capacity,
      byte_capacity: capacity * @max_payload_bytes,
      scope_capacity: scope_capacity,
      scope_byte_capacity: scope_capacity * @max_payload_bytes,
      shards: 1,
      max_payload_bytes: @max_payload_bytes,
      # Authority restoration can delay feedback during a rolling restart.
      max_age_ms: :timer.minutes(5),
      audit_interval_ms: 1_000,
      sink: &__MODULE__.deliver/2
    ]
  end

  @doc "Reserves a feedback slot before constructing or encoding bounded evidence."
  @spec record_attempt(map(), map(), AttemptTerminal.t(), atom(), keyword()) :: term()
  def record_attempt(channel, ctx, fact, qualification, opts \\ []) do
    if Evidence.dispatched?(fact) and not is_nil(channel.learning_subject) do
      identity = fact.identity
      dispatcher = Keyword.get(opts, :dispatcher, @dispatcher)
      target = {identity.profile, identity.chain_id, channel.learning_subject.id}

      opts =
        case Keyword.fetch(opts, :epoch) do
          {:ok, _epoch} -> opts
          :error -> Keyword.put(opts, :epoch, Persistence.adapter().epoch(target))
        end

      ProjectionDispatcher.enqueue_lazy(
        dispatcher,
        :learned_feedback,
        {identity.profile, "#{identity.chain_id}:#{channel.learning_subject.id}"},
        fn ->
          case Evidence.from_attempt(channel, ctx, fact, qualification, opts) do
            %Evidence{} = evidence -> Evidence.encode(evidence)
            nil -> {:error, :not_dispatched}
          end
        end
      )
    else
      :not_dispatched
    end
  end

  @doc "Applies one encoded record on the feedback lane, away from request execution."
  @spec deliver(term(), binary()) :: :ok
  def deliver(_scope, payload) do
    case Evidence.decode(payload) do
      {:ok, evidence} -> Persistence.adapter().observe(evidence)
      _ -> :ok
    end
  end

  @spec span_limit(map(), term()) :: {:ok, map()} | :unknown
  def span_limit(scope, dimension), do: read_hint(scope, :span_limit, dimension)

  @spec historical_depth(map(), term()) :: {:ok, map()} | :unknown
  def historical_depth(scope, resource), do: read_hint(scope, :historical_depth, resource)

  @doc "Reconciles the constant-size quota latch, including newer recovery from either writer."
  @spec quota_exhaustion(map()) :: {:ok, map()} | :unknown
  def quota_exhaustion(%{subject: subject} = scope) do
    partition = MethodRefusal.quota_partition(scope)
    key = {subject, partition, :quota}
    allowed = allowed_learning?(scope, :quota_exhaustion, :quota)

    with true <- allowed,
         {:ok, hint} <- ReadModel.prediction(MethodRefusal, key),
         true <- current_epoch?(scope, hint),
         do: {:ok, Map.put(hint, :partition, partition)},
         else: (_ -> :unknown)
  end

  @doc "One retained quota row per credential, independent of request origin, for idle recovery."
  @spec retained_quota_exhaustion(map()) :: [map()]
  def retained_quota_exhaustion(%{subject: subject} = scope) do
    for partition <- [:client],
        {:ok, hint} <- [quota_exhaustion(Map.put(scope, :partition, partition))],
        do: Map.merge(hint, %{subject: subject, method: "eth_blockNumber"})
  end

  @doc "Bounded historical memory for off-path explanation and revalidation."
  @spec retained_historical_depth(map()) :: [map()]
  def retained_historical_depth(%{subject: subject} = scope) when is_binary(subject) do
    ReadModel.readable_subject(subject, [HistoricalDepth])
    |> Enum.filter(fn {_source, _learner, _key, state} -> current_epoch?(scope, state) end)
    |> Enum.group_by(fn {_source, _learner, key, _state} -> key end)
    |> Enum.take(128)
    |> Enum.flat_map(fn {_key, rows} ->
      states = Map.new(rows, fn {source, _learner, _key, state} -> {source, state} end)

      case HistoricalDepth.reconcile(states[:local], states[:imported], :retained) do
        nil -> []
        retained -> if current_epoch?(scope, retained), do: [retained], else: []
      end
    end)
  end

  def retained_historical_depth(_scope), do: []

  @doc "Fresh exact-method evidence for explanation, whether or not it warrants deferral."
  @spec retained_method_refusals(map()) :: [map()]
  def retained_method_refusals(%{subject: subject} = scope) when is_binary(subject) do
    ReadModel.readable_subject(subject, [MethodRefusal])
    |> Enum.filter(fn {_source, _learner, _key, state} -> current_epoch?(scope, state) end)
    |> Enum.group_by(fn {_, _, key, _} -> key end)
    |> Enum.take(128)
    |> Enum.flat_map(fn {{_, partition, method}, rows} ->
      states = Map.new(rows, fn {source, _, _, state} -> {source, state} end)

      state =
        case {states[:local], states[:imported]} do
          {nil, imported} -> imported
          {local, nil} -> local
          {local, imported} -> MethodRefusal.merge(local, imported)
        end

      source = if states[:local], do: :local, else: :imported
      attribution = Map.new(states, fn {source, state} -> {source, MethodRefusal.fact(state)} end)

      case MethodRefusal.fact(state) do
        nil ->
          []

        fact ->
          mode =
            Lasso.RPC.ProviderKnowledge.Effects.mode(:method_refusal, Map.get(scope, :profile))

          deferral? = fact.deferral? and allowed_learning?(scope, :method_refusal, method)

          [
            Map.merge(fact, %{
              source: source,
              attribution: attribution,
              partition: partition,
              mode: mode,
              deferral?: deferral?,
              deferral_active?: deferral? and mode == :on
            })
          ]
      end
    end)
  end

  def retained_method_refusals(_scope), do: []

  @spec method_refusal(map(), binary()) :: {:ok, map()} | :unknown
  def method_refusal(scope, method), do: read_hint(scope, :method_refusal, method)

  @spec method_refused?(map(), binary()) :: boolean()
  def method_refused?(scope, method) do
    case method_refusal(scope, method) do
      {:ok, %{value: true}} -> true
      _ -> false
    end
  end

  @spec outcome_stats(map()) :: {:ok, map()} | :unknown
  def outcome_stats(scope), do: read_hint(scope, :outcome_stats, Map.get(scope, :dimension, :all))

  @doc "Reads qualified successful-response latency for an exact bounded method on this node."
  @spec response_latency(map()) :: {:ok, map()} | :unknown
  def response_latency(
        %{
          subject: subject,
          profile: profile,
          chain_id: chain_id,
          partition: partition,
          instance_id: instance_id,
          method: method
        } = scope
      )
      when is_binary(subject) and is_binary(profile) and is_integer(chain_id) and
             is_binary(instance_id) and is_binary(method) do
    method_key = BoundedIdentifier.encode(method)

    dimension =
      {BoundedIdentifier.encode(Atom.to_string(Node.self())),
       BoundedIdentifier.encode(instance_id), method_key}

    key = {subject, partition, dimension}
    target = {profile, chain_id, subject}

    with true <- is_binary(method_key),
         {:ok, %{epoch: epoch} = hint} <-
           ReadModel.prediction(LocalResponseLatency, key),
         true <- epoch == Persistence.adapter().epoch(target),
         true <- allowed_learning?(scope, :response_latency, dimension),
         true <- epoch == Persistence.adapter().epoch(target) do
      {:ok, Map.merge(hint, %{source: :local, epoch: epoch})}
    else
      _ -> :unknown
    end
  end

  def response_latency(_scope), do: :unknown

  @doc """
  Adapts captured operator and probe capability facts to the knowledge read interface.

  The captured `:historical_resource` selects the depth dimension; parameter
  validation defaults to the shared `:state` dimension.
  """
  @spec capability_scope(map(), map() | nil, binary()) :: map()
  def capability_scope(channel, capabilities, method) do
    capabilities = if is_map(capabilities), do: capabilities, else: %{}
    observed = CapabilityObservation.active(capabilities)
    category = MethodRegistry.method_category(method)
    resource = Map.get(channel, :historical_resource, :state)
    declared_limits = capability_limits(capabilities)
    observed_limits = capability_limits(observed)
    probe_limits = Map.drop(observed_limits, Map.keys(declared_limits))

    age_methods =
      observed_limits
      |> Map.merge(declared_limits)
      |> Map.get(:block_age_methods)
      |> Kernel.||([])

    %{
      subject:
        case Map.get(channel, :learning_subject) do
          %{id: id} -> id
          _ -> nil
        end,
      profile: Map.get(channel, :profile),
      chain_id: Map.get(channel, :chain_id),
      partition: :client,
      allow_learned?: false,
      declared:
        capability_hints(capabilities, declared_limits, method, category, age_methods, resource),
      probe: capability_hints(observed, probe_limits, method, category, age_methods, resource)
    }
  end

  @spec explain(map()) :: map()
  def explain(scope) do
    %{
      subject: Map.get(scope, :subject),
      partition: Map.get(scope, :partition),
      hints: %{
        method_refusal: optional_hint(scope, :method_refusal, Map.get(scope, :method)),
        span_limit: optional_hint(scope, :span_limit, Map.get(scope, :span_dimension)),
        historical_depth:
          optional_hint(scope, :historical_depth, Map.get(scope, :historical_resource))
      },
      available_learners: ReadModel.learners(),
      lane: ProjectionDispatcher.stats(@dispatcher, :learned_feedback)
    }
  end

  @spec explain_subject(binary(), map()) :: [map()]
  def explain_subject(subject, scope \\ %{}) when is_binary(subject) do
    now_ms = System.system_time(:millisecond)

    ReadModel.readable_subject(subject, Map.values(hint_learners()))
    |> Enum.flat_map(fn {source, learner, {_subject, partition, dimension} = key, state} ->
      for hint <- inspection_hints(learner, state, key, source),
          Map.get(hint, :expires_at_ms, now_ms + 1) > now_ms do
        hint
        |> Map.put(:partition, partition)
        |> Map.put(:source, source)
        |> inspection_profile(hint.kind, dimension)
      end
    end)
    |> Kernel.++(quota_inspection(Map.put(scope, :subject, subject)))
    |> Enum.sort_by(&(&1.kind == :outcome_stats))
    |> Enum.take(128)
  end

  # Quota is a credential-wide latch: local recovery must defeat stale peer
  # exhaustion, and two witnesses may be split across writers.
  defp quota_inspection(scope) do
    case quota_exhaustion(Map.put(scope, :partition, :client)) do
      {:ok, hint} -> [hint]
      :unknown -> []
    end
  end

  defp inspection_hints(HistoricalDepth, _state, key, source) do
    case ReadModel.historical_prediction(key) do
      {:ok, %{source: ^source} = hint} -> [hint]
      _ -> []
    end
  end

  defp inspection_hints(MethodRefusal, _state, {_, _, :quota}, _source), do: []

  defp inspection_hints(learner, _state, key, source)
       when learner in [MethodRefusal, SpanBracket] do
    case ReadModel.prediction(learner, key) do
      {:ok, %{source: ^source} = hint} -> [hint]
      _ -> []
    end
  end

  defp inspection_hints(learner, state, {_, _, dimension}, _source) do
    for kind <- [:method_refusal, :span_limit, :outcome_stats],
        hint <- safe_hints(learner, state, {kind, inspection_dimension(kind, dimension)}),
        do: hint
  end

  defp inspection_dimension(:outcome_stats, {_, method, shape}), do: {method, shape}
  defp inspection_dimension(_, dimension), do: dimension

  defp inspection_profile(hint, :outcome_stats, {profile, _, _}),
    do: Map.put(hint, :profile, profile)

  defp inspection_profile(hint, _, _), do: hint

  defp safe_hints(learner, state, query) do
    learner.hints(state, query)
  rescue
    _ -> []
  end

  defp optional_hint(_scope, _kind, nil), do: :unknown
  defp optional_hint(scope, kind, dimension), do: read_hint(scope, kind, dimension)

  defp read_hint(scope, kind, dimension) do
    declared = get_in(scope, [:declared, kind, dimension])
    probe = get_in(scope, [:probe, kind, dimension])
    learner = Map.get(scope, :learner) || Map.get(hint_learners(), kind)

    learning_dimension =
      if kind == :method_refusal and is_binary(dimension),
        do: BoundedIdentifier.encode(dimension),
        else: dimension

    key_dimension =
      case {kind, dimension} do
        {:outcome_stats, {method, shape}} -> {Map.get(scope, :profile), method, shape}
        {:outcome_stats, _} -> {Map.get(scope, :profile), :all, :all}
        {:historical_depth, _} -> {dimension, Map.get(scope, :method)}
        _ -> learning_dimension
      end

    key = {Map.get(scope, :subject), Map.get(scope, :partition, :client), key_dimension}
    learned = allowed_learning?(scope, kind, learning_dimension)

    first_hint([
      fn -> tagged(declared, :declared, kind, dimension) end,
      fn ->
        hint = if learned, do: learned_hint(learner, key, kind, learning_dimension, scope)

        case hint do
          %{source: :local} -> hint
          _ -> tagged(probe, :observed_by_probe, kind, dimension) || hint
        end
      end
    ])
  end

  defp allowed_learning?(scope, kind, dimension) do
    if Map.get(scope, :allow_learned?, true),
      do: allowed_learning_for_scope?(scope, kind, dimension),
      else: false
  end

  defp allowed_learning_for_scope?(scope, kind, dimension) do
    case {Map.get(scope, :profile), Map.get(scope, :chain_id), Map.get(scope, :subject)} do
      {profile, chain_id, subject}
      when is_binary(profile) and is_integer(chain_id) and is_binary(subject) ->
        Persistence.adapter().allowed?(
          {profile, chain_id, subject},
          %{kind: kind, dimension: dimension, method: dimension}
        )

      _ ->
        Persistence.adapter() == Persistence.None
    end
  end

  defp capability_hints(capabilities, limits, method, category, age_methods, resource) do
    methods = Map.get(capabilities, :unsupported_methods) || []
    categories = Map.get(capabilities, :unsupported_categories) || []

    %{
      method_refusal:
        if(method in methods or category in categories, do: %{method => true}, else: %{}),
      span_limit: limit_hint(limits, :max_block_range, :logs),
      historical_depth:
        if(method in age_methods,
          do: limit_hint(limits, :max_block_age, resource),
          else: %{}
        )
    }
  end

  defp limit_hint(limits, key, dimension) do
    case Map.get(limits, key) do
      value when is_integer(value) and value >= 0 -> %{dimension => value}
      _ -> %{}
    end
  end

  defp capability_limits(capabilities) do
    case Map.get(capabilities, :limits) do
      limits when is_map(limits) -> limits
      _ -> %{}
    end
  end

  defp hint_learners,
    do:
      Application.get_env(:lasso, :provider_knowledge_hint_learners, %{
        outcome_stats: OutcomeStatistics,
        method_refusal: MethodRefusal,
        span_limit: SpanBracket,
        historical_depth: HistoricalDepth
      })

  defp learned_hint(learner, key, _kind, _dimension, scope) do
    with {:ok, hint} <- ReadModel.prediction(learner, key),
         true <- current_epoch?(scope, hint),
         do: hint,
         else: (_ -> nil)
  end

  defp current_epoch?(scope, state) do
    target = {Map.get(scope, :profile), Map.get(scope, :chain_id), Map.get(scope, :subject)}
    Map.get(state, :epoch) == Persistence.adapter().epoch(target)
  end

  defp tagged(nil, _source, _kind, _dimension), do: nil

  defp tagged(value, source, kind, dimension),
    do: %{kind: kind, dimension: dimension, value: value, source: source}

  defp first_hint(readers) do
    case Enum.find_value(readers, & &1.()) do
      nil -> :unknown
      hint -> {:ok, hint}
    end
  end
end

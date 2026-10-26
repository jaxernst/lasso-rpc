defmodule Lasso.RPC.ProviderKnowledge.ReadModel do
  @moduledoc "Per-learner local ETS state with bounded keys and read-only request access."

  alias Lasso.RPC.ProviderKnowledge.{Evidence, Learner}

  alias Lasso.RPC.ProviderKnowledge.Learners.{
    HistoricalDepth,
    LocalResponseLatency,
    MethodRefusal,
    OutcomeStatistics,
    SpanBracket
  }

  @registry :lasso_provider_knowledge_tables
  @counters :lasso_provider_knowledge_counters
  @predictions :provider_knowledge_predictions
  @historical_predictions :historical_depth_predictions
  @full_methods :lasso_provider_knowledge_full_methods
  @admission_interval_ms :timer.minutes(1)
  @max_full_subjects 128

  @spec create_tables!([module()]) :: :ok
  def create_tables!(learners) when is_list(learners) do
    :ets.new(@registry, [:named_table, :protected, :set, read_concurrency: true])
    :ets.new(@counters, [:named_table, :public, :set, write_concurrency: true])
    :ets.new(@full_methods, [:named_table, :public, :set, read_concurrency: true])

    :ets.new(@predictions, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@historical_predictions, [:named_table, :public, :set, read_concurrency: true])

    Enum.each(learners, fn learner ->
      bounds = learner.bounds()
      validate_bounds!(bounds)
      table = :ets.new(:provider_knowledge_learner, [:public, :set, read_concurrency: true])

      :ets.insert(@registry, {learner, table, bounds})
      :ets.insert(@counters, {{learner, :evictions}, 0})
      :ets.insert(@counters, {{learner, :invalid_state}, 0})
      :ets.insert(@counters, {{learner, :restore_expired}, 0})
    end)

    :ok
  end

  @spec apply(Evidence.t()) :: :ok
  def apply(%Evidence{} = evidence) do
    for {learner, table, bounds} <- tables() do
      apply_one(learner, table, bounds, evidence, learner.key(evidence))

      if learner == MethodRefusal,
        do: apply_one(learner, table, bounds, evidence, MethodRefusal.quota_key(evidence))
    end

    :ok
  end

  @spec lookup(module(), term(), :local | :imported) :: {:ok, term()} | :unknown
  def lookup(learner, key, source \\ :local) when source in [:local, :imported] do
    with {:ok, table, _bounds} <- table(learner),
         [{_, state, _observed_at_ms}] <- :ets.lookup(table, {source, key}) do
      {:ok, state}
    else
      _ -> :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  @doc "Reads a reconciled serving projection without loading learner evidence."
  @spec prediction(module(), term()) :: {:ok, map()} | :unknown
  def prediction(learner, key) do
    {table, stored_key} = projection_location(learner, key)

    with [{^stored_key, hint}] <- :ets.lookup(table, stored_key),
         true <- hint.expires_at_ms > System.system_time(:millisecond),
         do: {:ok, hint},
         else: (_ -> :unknown)
  rescue
    ArgumentError -> :unknown
  end

  @spec historical_prediction(term()) :: {:ok, map()} | :unknown
  def historical_prediction(key), do: prediction(HistoricalDepth, key)

  @doc "Reconciles expired projections off path as supporting witnesses age out."
  @spec refresh_expired_historical_predictions() :: :ok
  def refresh_expired_historical_predictions do
    now_ms = System.system_time(:millisecond)

    for table <- [@historical_predictions, @predictions],
        stored_key <-
          :ets.select(table, [
            {{:"$1", %{expires_at_ms: :"$2"}}, [{:"=<", :"$2", now_ms}], [:"$1"]}
          ]) do
      {learner, key} =
        if table == @historical_predictions, do: {HistoricalDepth, stored_key}, else: stored_key

      with {:ok, learner_table, _bounds} <- table(learner),
           do: refresh_prediction(learner, learner_table, key)
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec stats(module()) :: map()
  def stats(learner) do
    case table(learner) do
      {:ok, table, bounds} ->
        %{
          keys: :ets.info(table, :size),
          max_keys: bounds.max_keys,
          evictions: counter(learner, :evictions),
          invalid_state: counter(learner, :invalid_state),
          restore_expired: counter(learner, :restore_expired)
        }

      _ ->
        %{keys: 0, max_keys: 0, evictions: 0, invalid_state: 0, restore_expired: 0}
    end
  rescue
    ArgumentError -> %{keys: 0, max_keys: 0, evictions: 0, invalid_state: 0, restore_expired: 0}
  end

  @doc "Published hints contradicted by accepted successes, since node start."
  @spec retractions() :: [map()]
  def retractions do
    for {learner, kind} <- [
          {MethodRefusal, :method_refusal},
          {HistoricalDepth, :historical_depth},
          {SpanBracket, :span_limit}
        ],
        do: %{kind: kind, reason: :contradicted, count: counter(learner, :retractions)}
  end

  @spec learners() :: [module()]
  def learners, do: Enum.map(tables(), &elem(&1, 0))

  @doc "Returns a bounded off-path snapshot of one learner's local rows."
  @spec snapshot(module()) :: [{term(), term()}]
  def snapshot(learner) do
    case table(learner) do
      {:ok, table, _bounds} ->
        for {{:local, key}, state, _observed_at_ms} <- :ets.tab2list(table), do: {key, state}

      _ ->
        []
    end
  rescue
    ArgumentError -> []
  end

  @doc "Collects a subject's local learner rows for off-path snapshot encoding."
  @spec snapshot_subject(binary(), boolean()) :: [{module(), term(), term(), non_neg_integer()}]
  def snapshot_subject(subject, include_local? \\ false) when is_binary(subject) do
    for {learner, table, _bounds} <- tables(),
        include_local? or Learner.exchangeable?(learner),
        {{:local, key}, state, at_ms} <-
          :ets.match_object(table, {{:local, {subject, :_, :_}}, :_, :_}),
        do: {learner, key, state, at_ms}
  rescue
    ArgumentError -> []
  end

  @spec readable_subject(binary(), [module()] | nil) :: [
          {:local | :imported, module(), term(), term()}
        ]
  def readable_subject(subject, learners \\ nil) when is_binary(subject) do
    for {learner, table, _bounds} <- tables(),
        is_nil(learners) or learner in learners,
        {{source, {^subject, _, _} = key}, state, _at_ms} <-
          :ets.match_object(table, {{:_, {subject, :_, :_}}, :_, :_}),
        source in [:local, :imported],
        do: {source, learner, key, state}
  rescue
    ArgumentError -> []
  end

  @doc """
  Restores this writer's latest eligible snapshot as local knowledge.

  Rows that expired since publication are expected lifecycle skips, counted
  separately from invalid state. `restore_expired` counts skipped restore rows,
  including repeated refreshes of the same persisted snapshot.
  """
  @spec restore_local(list(), boolean(), :merge | :replace) :: :ok
  def restore_local(rows, include_local? \\ false, mode \\ :replace) when is_list(rows) do
    now_ms = System.system_time(:millisecond)

    Enum.each(rows, fn {learner, key, state, at_ms} ->
      with true <- include_local? or Learner.exchangeable?(learner),
           {:ok, table, bounds} <- table(learner),
           fresh when fresh != :expired <- learner.decay(state, now_ms) do
        row_key = {:local, key}

        case :ets.lookup(table, row_key) do
          [{^row_key, current, current_at}] when mode == :merge ->
            # Boot-time observations and a prior boot's checkpoint are disjoint.
            # State invokes this merge only once, even if its worker restarts.
            merged = learner.merge(fresh, current)
            restore_row(learner, table, bounds, row_key, merged, max(at_ms, current_at))

          [{^row_key, _current, current_at}] when current_at >= at_ms ->
            refresh_prediction(learner, table, key)

          _ ->
            restore_row(learner, table, bounds, row_key, fresh, at_ms)
        end
      else
        :expired -> increment(learner, :restore_expired)
        _ -> increment(learner, :invalid_state)
      end
    end)

    :ok
  end

  defp restore_row(learner, table, bounds, row_key, state, at_ms) do
    with {:ok, payload} <- learner.encode(state),
         true <- byte_size(payload) <= bounds.max_state_bytes do
      insert_admitted(table, bounds, row_key, learner, state, at_ms)
    else
      _ -> increment(learner, :invalid_state)
    end
  end

  @doc "Replaces one remote writer's provisional rows and rebuilds merged imports."
  @spec replace_imported(binary(), binary(), list()) :: :ok
  def replace_imported(writer, subject, rows)
      when is_binary(writer) and is_binary(subject) and is_list(rows),
      do: replace_imported_many(subject, [{writer, rows}])

  @doc "Replaces a subject's writer updates with one traversal and one merge per affected key."
  @spec replace_imported_many(binary(), [{binary(), list()}]) :: :ok
  def replace_imported_many(subject, []) when is_binary(subject), do: :ok

  def replace_imported_many(subject, updates) when is_binary(subject) and is_list(updates) do
    now_ms = System.system_time(:millisecond)
    changed_writers = MapSet.new(updates, &elem(&1, 0))

    for {learner, table, bounds} <- tables(), Learner.exchangeable?(learner) do
      previous = :ets.match_object(table, {{:writer, :_, {subject, :_, :_}}, :_, :_})

      {removed, retained} =
        Enum.split_with(previous, fn {{:writer, writer, _key}, _state, _at_ms} ->
          MapSet.member?(changed_writers, writer)
        end)

      Enum.each(removed, fn {row_key, _, _} ->
        :ets.delete(table, row_key)
      end)

      current =
        for {writer, rows} <- updates,
            {^learner, {^subject, _, _} = key, state, at_ms} <- rows,
            fresh = learner.decay(state, now_ms),
            fresh != :expired,
            row_key = {:writer, writer, key},
            evict_if_full(table, bounds.max_keys, row_key, learner) do
          :ets.insert(table, {row_key, fresh, at_ms})
          {row_key, fresh, at_ms}
        end

      by_key =
        (retained ++ current)
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.group_by(fn {:writer, _, key} -> key end)

      affected = Enum.uniq(Enum.map(removed ++ current, fn {{:writer, _, key}, _, _} -> key end))

      for key <- affected do
        # An earlier insertion can evict a writer row at capacity. Complete-key
        # lookups preserve the current retained set without another table scan.
        states =
          for row_key <- Map.get(by_key, key, []),
              [{^row_key, state, _at_ms}] <- [:ets.lookup(table, row_key)],
              do: state

        rebuild_imported_key(table, bounds, learner, key, states)
      end
    end

    :ok
  end

  defp rebuild_imported_key(table, bounds, learner, key, states) do
    aggregate_key = {:imported, key}

    case states do
      [] ->
        :ets.delete(table, aggregate_key)

      [first | rest] ->
        merged = Enum.reduce(rest, first, &learner.merge/2)

        if evict_if_full(table, bounds.max_keys, aggregate_key, learner) do
          :ets.insert(table, {aggregate_key, merged, at_ms(merged)})
        end
    end

    refresh_prediction(learner, table, key)
  end

  @doc "Drops local and imported rows for an authorized subject reset."
  @spec clear_subject(binary()) :: :ok
  def clear_subject(subject) when is_binary(subject) do
    clear_predictions(subject)
    :ets.match_delete(@full_methods, {{subject, :_}, :_})

    for {_learner, table, _bounds} <- tables(),
        {key, _state, _observed_at_ms} <- :ets.tab2list(table),
        subject_key?(key, subject) do
      :ets.delete(table, key)
    end

    :ok
  end

  defp subject_key?({_, {subject, _, _}}, subject), do: true
  defp subject_key?({:writer, _, {subject, _, _}}, subject), do: true
  defp subject_key?(_, _), do: false

  defp at_ms(%{observed_at_ms: at_ms}) when is_integer(at_ms), do: at_ms
  defp at_ms(_), do: 0

  defp apply_one(learner, table, bounds, evidence, key) do
    expected_partition =
      if learner == MethodRefusal and match?({_, _, :quota}, key),
        do: MethodRefusal.quota_partition(evidence),
        else: Learner.partition(learner, evidence)

    case key do
      :skip ->
        :ok

      {subject, partition, _dimension} = key
      when subject == evidence.subject and partition == expected_partition ->
        row_key = {:local, key}

        state =
          case :ets.lookup(table, row_key) do
            [{^row_key, current, _}] -> current
            [] -> learner.init(key)
          end

        updated = learner.observe(state, evidence)

        if encoded_state_fits?(learner, updated, bounds.max_state_bytes) do
          insert_admitted(
            table,
            bounds,
            row_key,
            learner,
            updated,
            evidence.observed_at_ms,
            evidence
          )
        else
          increment(learner, :invalid_state)
        end

      _ ->
        increment(learner, :invalid_state)
    end
  rescue
    _ -> increment(learner, :invalid_state)
  end

  defp contradiction_candidate(
         learner,
         key,
         %Evidence{
           outcome: :success,
           qualification: :accepted,
           epoch: epoch
         } = evidence
       )
       when learner in [MethodRefusal, HistoricalDepth, SpanBracket] do
    case prediction(learner, key) do
      {:ok, %{kind: kind, epoch: ^epoch} = hint}
      when kind in [:method_refusal, :historical_depth, :span_limit] ->
        if contradicts_hint?(hint, evidence), do: hint

      _ ->
        nil
    end
  end

  defp contradiction_candidate(_, _, _), do: nil

  defp contradicts_hint?(%{kind: :span_limit, value: limit}, %Evidence{shape_value: span})
       when is_integer(span),
       do: span >= limit

  defp contradicts_hint?(
         %{kind: :historical_depth, coordinate: :height, value: floor},
         %Evidence{historical_height: {lo, _hi}}
       )
       when is_integer(lo),
       do: lo <= floor

  defp contradicts_hint?(
         %{kind: :historical_depth, coordinate: :age, value: cutoff},
         %Evidence{historical_age: age}
       )
       when is_integer(age),
       do: age >= cutoff

  defp contradicts_hint?(%{kind: :method_refusal, dimension: method}, %Evidence{method: method}),
    do: true

  defp contradicts_hint?(_, _), do: false

  defp count_retraction(_learner, _key, nil), do: :ok

  defp count_retraction(learner, key, previous) do
    if previous.expires_at_ms > System.system_time(:millisecond) and
         prediction(learner, key) == :unknown do
      increment(learner, :retractions)
    end
  end

  defp encoded_state_fits?(learner, state, max_bytes) do
    upper_bound =
      if function_exported?(learner, :encoded_size_upper_bound, 1),
        do: learner.encoded_size_upper_bound(state)

    if is_integer(upper_bound) and upper_bound >= 0 and upper_bound <= max_bytes do
      true
    else
      case learner.encode(state) do
        {:ok, payload} when byte_size(payload) <= max_bytes -> true
        _ -> false
      end
    end
  end

  defp insert_admitted(table, bounds, row_key, learner, state, at_ms, evidence \\ nil) do
    if evict_if_full(table, bounds.max_keys, row_key, learner) do
      key = elem(row_key, tuple_size(row_key) - 1)
      previous = contradiction_candidate(learner, key, evidence)
      :ets.insert(table, {row_key, state, at_ms})
      refresh_prediction(learner, table, key)
      count_retraction(learner, key, previous)
    end
  end

  defp evict_if_full(table, max_keys, row_key, learner) do
    cond do
      not admit_method?(table, row_key, learner) ->
        false

      not :ets.member(table, row_key) and :ets.info(table, :size) >= max_keys ->
        inserting_local = match?({:local, _}, row_key)

        oldest =
          :ets.foldl(
            fn {key, _state, observed_at_ms}, best ->
              local = match?({:local, _}, key)

              if inserting_local or not local do
                candidate = {if(local, do: 1, else: 0), observed_at_ms, key}
                if is_nil(best) or candidate < best, do: candidate, else: best
              else
                best
              end
            end,
            nil,
            table
          )

        if oldest do
          {_priority, _at_ms, evicted_key} = oldest
          key = elem(evicted_key, tuple_size(evicted_key) - 1)
          :ets.delete(table, evicted_key)
          refresh_prediction(learner, table, key)
          increment(learner, :evictions)
          true
        else
          false
        end

      true ->
        true
    end
  end

  # One name consumes one slot across local and imported copies. A full
  # subject retries admission once a minute, rather than scanning for every
  # rejected random name. Existing local/imported names bypass this cache.
  # Snapshot-bounded writer rows carry names already admitted by their nodes.
  # Import and aggregate rebuild bypass live-evidence admission.
  defp admit_method?(_table, {:writer, _writer, _key}, MethodRefusal), do: true
  defp admit_method?(_table, {:imported, _key}, MethodRefusal), do: true

  defp admit_method?(_table, {:local, {_, _, :quota}}, MethodRefusal), do: true

  defp admit_method?(table, row_key, MethodRefusal) do
    {subject, partition, method} = key = elem(row_key, tuple_size(row_key) - 1)

    if Evidence.method_key(method) != :other or :ets.member(table, row_key) or
         :ets.member(table, {:local, key}) or :ets.member(table, {:imported, key}) do
      true
    else
      now_ms = System.system_time(:millisecond)
      budget_key = {subject, partition}

      case :ets.lookup(@full_methods, budget_key) do
        [{^budget_key, checked_at}] when now_ms - checked_at < @admission_interval_ms ->
          false

        _ ->
          scan_method_admission(table, budget_key, method, now_ms)
      end
    end
  end

  defp admit_method?(_table, _row_key, _learner), do: true

  defp scan_method_admission(table, {subject, partition} = budget_key, method, now_ms) do
    methods =
      (:ets.match_object(table, {{:_, {subject, partition, :_}}, :_, :_}) ++
         :ets.match_object(table, {{:writer, :_, {subject, partition, :_}}, :_, :_}))
      |> Enum.reduce(MapSet.new(), fn {stored_key, state, _at_ms}, methods ->
        {_, _, name} = elem(stored_key, tuple_size(stored_key) - 1)

        cond do
          # Ordinary reads decay hints without deleting stored rows; there is
          # no periodic table sweep. Admission removes expired rows to free slots.
          MethodRefusal.decay(state, now_ms) == :expired ->
            :ets.delete(table, stored_key)
            methods

          name != :quota and Evidence.method_key(name) == :other ->
            MapSet.put(methods, name)

          true ->
            methods
        end
      end)

    full? = MapSet.size(methods) >= MethodRefusal.unregistered_limit()

    if MapSet.size(methods) + if(MapSet.member?(methods, method), do: 0, else: 1) >=
         MethodRefusal.unregistered_limit() do
      remember_full_subject(budget_key, now_ms)
    else
      :ets.delete(@full_methods, budget_key)
    end

    MapSet.member?(methods, method) or not full?
  end

  defp remember_full_subject(key, now_ms) do
    if not :ets.member(@full_methods, key) and
         :ets.info(@full_methods, :size) >= @max_full_subjects do
      {oldest, _} = :ets.tab2list(@full_methods) |> Enum.min_by(&elem(&1, 1))
      :ets.delete(@full_methods, oldest)
    end

    :ets.insert(@full_methods, {key, now_ms})
  end

  defp projection_location(HistoricalDepth, key), do: {@historical_predictions, key}
  defp projection_location(learner, key), do: {@predictions, {learner, key}}

  # Keep the serving hint visible while its replacement is reconciled. Readers
  # see the prior complete projection or the next one, including a retraction.
  defp publish_prediction(learner, key, hint) do
    {table, stored_key} = projection_location(learner, key)

    if is_nil(hint),
      do: :ets.delete(table, stored_key),
      else: :ets.insert(table, {stored_key, hint})
  end

  defp refresh_prediction(HistoricalDepth, table, {_, _, {resource, _}} = key) do
    local = prediction_state(table, :local, key)
    imported = prediction_state(table, :imported, key)

    publish_prediction(HistoricalDepth, key, HistoricalDepth.reconcile(local, imported, resource))
  end

  defp refresh_prediction(learner, table, {_, _, dimension} = key)
       when learner in [MethodRefusal, SpanBracket] do
    local = prediction_state(table, :local, key)
    imported = prediction_state(table, :imported, key)

    state =
      case {local, imported} do
        {nil, nil} -> nil
        {nil, state} -> state
        {state, nil} -> state
        {local, imported} -> learner.merge(local, imported)
      end

    kind =
      case {learner, dimension} do
        {MethodRefusal, :quota} -> :quota_exhaustion
        {MethodRefusal, _} -> :method_refusal
        {SpanBracket, _} -> :span_limit
      end

    projection =
      if state do
        for hint <- learner.hints(state, {kind, dimension}) do
          # Expire at the first supporting witness boundary. The existing background
          # reconciliation can retain later support; routing never recomputes it.
          expires = projection_expiry(learner, state, hint)

          local_support? =
            local && local.epoch == state.epoch &&
              local_projection_support?(kind, local, state)

          source = if local_support?, do: :local, else: :imported

          sources =
            for {name, row} <- [local: local, imported: imported],
                row && row.epoch == state.epoch,
                do: name

          Map.merge(hint, %{
            epoch: state.epoch,
            source: source,
            sources: sources,
            support: Map.put(hint.support, :sources, sources),
            expires_at_ms: expires
          })
        end
        |> List.first()
      end

    publish_prediction(learner, key, projection)
  end

  defp refresh_prediction(learner, table, {_, _, dimension} = key)
       when learner in [LocalResponseLatency, OutcomeStatistics] do
    projection =
      case prediction_state(table, :local, key) do
        nil ->
          nil

        state ->
          query =
            case {learner, dimension} do
              {LocalResponseLatency, _} -> {:response_latency, dimension}
              {OutcomeStatistics, {_, method, shape}} -> {:outcome_stats, {method, shape}}
            end

          for hint <- learner.hints(state, query) do
            Map.merge(hint, %{epoch: state.epoch, source: :local})
          end
          |> List.first()
      end

    publish_prediction(learner, key, projection)
  end

  defp refresh_prediction(_, _, _), do: :ok

  defp local_projection_support?(:quota_exhaustion, local, reconciled) do
    Enum.all?(reconciled.samples, fn
      {_, :refusal, _} = witness -> MapSet.member?(local.samples, witness)
      _ -> true
    end)
  end

  defp local_projection_support?(_kind, _local, _reconciled), do: true

  defp projection_expiry(MethodRefusal, %{key: {_, _, :quota}} = state, _hint),
    do: state.observed_at_ms + :timer.hours(24)

  defp projection_expiry(MethodRefusal, state, _hint) do
    now = System.system_time(:millisecond)

    state.samples
    |> Enum.map(fn {at, _, _} -> at + :timer.hours(1) end)
    |> Enum.filter(&(&1 > now))
    |> Enum.min(fn -> now end)
  end

  defp projection_expiry(SpanBracket, _state, hint), do: hint.expires_at_ms

  defp prediction_state(table, source, key) do
    case :ets.lookup(table, {source, key}) do
      [{_, state, _}] -> state
      [] -> nil
    end
  end

  defp clear_predictions(subject) do
    if :ets.whereis(@historical_predictions) != :undefined,
      do: :ets.match_delete(@historical_predictions, {{subject, :_, :_}, :_})

    if :ets.whereis(@predictions) != :undefined,
      do: :ets.match_delete(@predictions, {{:_, {subject, :_, :_}}, :_})
  end

  defp table(learner) do
    case :ets.lookup(@registry, learner) do
      [{^learner, table, bounds}] -> {:ok, table, bounds}
      _ -> :unknown
    end
  end

  defp tables do
    :ets.tab2list(@registry)
  rescue
    ArgumentError -> []
  end

  defp counter(learner, kind) do
    case :ets.lookup(@counters, {learner, kind}) do
      [{{^learner, ^kind}, value}] -> value
      _ -> 0
    end
  end

  defp increment(learner, kind),
    do: :ets.update_counter(@counters, {learner, kind}, {2, 1}, {{learner, kind}, 0})

  defp validate_bounds!(%{max_keys: keys, max_state_bytes: bytes, version: version})
       when is_integer(keys) and keys > 0 and is_integer(bytes) and bytes > 0 and
              is_integer(version) and version > 0,
       do: :ok

  defp validate_bounds!(_), do: raise(ArgumentError, "learner bounds must be positive and finite")
end

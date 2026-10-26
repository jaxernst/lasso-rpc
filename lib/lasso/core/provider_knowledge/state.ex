defmodule Lasso.RPC.ProviderKnowledge.State do
  @moduledoc "Serializes causal learning state. Serving reads only its local ETS projection."
  use GenServer
  alias Lasso.RPC.ProviderKnowledge.{Evidence, Learner, ReadModel}

  @table :lasso_provider_knowledge_controls_v2
  @lease_ms :timer.hours(4)
  @empty %{epoch: 0, revision: 0, suspensions: []}
  @loss_reasons [:missing_dispatch_stamp, :not_admitted, :epoch_stale, :checkpoint_fenced]
  @writer_ttl_ms :timer.hours(24)

  @type target :: {binary(), pos_integer(), binary()}
  @type subject_key :: {pos_integer(), binary()}

  @spec create_table!() :: :ok
  def create_table! do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ok
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @spec epoch(target()) :: non_neg_integer()
  def epoch({_profile, chain, subject}), do: control({chain, subject}).epoch
  @spec control(subject_key()) :: map()
  def control(key), do: lookup(key, @empty)
  @spec reconcile(map()) :: :ok
  def reconcile(rows), do: GenServer.call(__MODULE__, {:controls, rows}, 10_000)
  @spec receive_control(subject_key(), map()) :: :ok
  def receive_control(key, row), do: GenServer.call(__MODULE__, {:control, key, row}, 10_000)
  @spec inventory([target()]) :: :ok
  def inventory(targets), do: call({:inventory, targets})
  @spec observe(Evidence.t()) :: :ok
  def observe(%Evidence{} = evidence), do: call({:observe, evidence})
  @spec restore_own(target(), map() | nil) :: :ok
  def restore_own(target, image), do: call({:restore_own, target, image})
  @spec import_image(target(), map(), :peer | :checkpoint) :: :ok
  def import_image(target, image, source \\ :peer), do: call({:import, target, image, source})
  @spec snapshot(target(), binary(), binary()) :: {:ok, map()} | {:error, atom()}
  def snapshot(target, writer, incarnation), do: call({:snapshot, target, writer, incarnation})
  @spec persisted(target(), non_neg_integer()) :: :ok
  def persisted(target, version), do: call({:persisted, target, version})
  @spec expire_imports() :: :ok
  def expire_imports, do: call(:expire_imports)
  @spec identity() :: {binary(), binary()} | nil
  def identity, do: lookup(:identity, nil)

  @spec start_writer(binary(), binary()) :: true
  def start_writer(writer, incarnation),
    do: :ets.insert(@table, {:identity, {writer, incarnation}})

  @spec targets() :: [target()]
  def targets do
    for {{:subject, _key}, entry} <- :ets.tab2list(@table), do: entry.target
  end

  @spec dirty?(target()) :: boolean()
  def dirty?(target) do
    case lookup({:subject, key(target)}, nil) do
      %{version: version, persisted: persisted} -> version > persisted
      _ -> false
    end
  end

  @spec publishable?(target(), map()) :: boolean()
  def publishable?(target, image) do
    lookup({:admitted, key(target)}, false) and lifecycle(key(target)) == :ready and
      image.epoch == epoch(target) and
      {image.writer, image.incarnation} == identity()
  end

  @spec digest() :: map()
  def digest do
    imported =
      for {{:subject, key}, entry} <- :ets.tab2list(@table),
          {writer, image} <- entry.writers,
          into: %{},
          do: {{key, writer}, {image.incarnation, image.revision}}

    case identity() do
      {writer, incarnation} ->
        Enum.reduce(targets(), imported, fn target, digest ->
          entry = lookup({:subject, key(target)}, nil)
          image = %{epoch: epoch(target), writer: writer, incarnation: incarnation}

          if publishable?(target, image),
            do: Map.put(digest, {key(target), writer}, {incarnation, entry.revision}),
            else: digest
        end)

      nil ->
        imported
    end
  end

  @spec applied?(target(), non_neg_integer(), non_neg_integer()) :: boolean()
  def applied?({profile, chain, subject} = target, epoch, revision) do
    lease = lookup(:lease, nil)

    is_integer(lease) and lease > System.monotonic_time(:millisecond) and
      lookup({:admitted, profile, chain, subject}, false) and
      lifecycle(key(target)) == :ready and
      match?(%{epoch: ^epoch, revision: ^revision}, control(key(target)))
  end

  @spec apply_loss_counters() :: %{atom() => non_neg_integer()}
  def apply_loss_counters do
    Map.new(@loss_reasons, &{&1, lookup({:loss, &1}, 0)})
  end

  @spec fence_counts() :: [atom()]
  def fence_counts do
    for {{:lifecycle, _key}, {:fenced, reason}} <- :ets.tab2list(@table), do: reason
  end

  @spec apply_loss() :: map()
  def apply_loss do
    counters = apply_loss_counters()

    %{
      total: Enum.sum(Map.values(counters)),
      counters: counters,
      pending: %{items: 0, subjects: 0, refresh_in_flight: 0}
    }
  end

  @spec allowed?(target(), map()) :: boolean()
  def allowed?({profile, chain, subject}, scope) do
    row = control({chain, subject})
    now = System.system_time(:microsecond)

    lease = lookup(:lease, nil)

    is_integer(lease) and lease > System.monotonic_time(:millisecond) and
      lifecycle({chain, subject}) == :ready and
      lookup({:admitted, profile, chain, subject}, false) and
      Enum.all?(row.suspensions, fn %{scope: rule, until_us: until_us} ->
        until_us <= now or not suspended?(rule, scope)
      end)
  end

  @doc "Off-path permission summary; scoped suspensions remain distinct from configured mode."
  @spec permission_status(target(), atom()) :: atom()
  def permission_status({profile, chain, subject} = target, kind) do
    lease = lookup(:lease, nil)
    now = System.system_time(:microsecond)

    rules =
      for %{scope: rule, until_us: until_us} <- control({chain, subject}).suspensions,
          until_us > now and rule.kind in [:all, kind],
          do: rule

    cond do
      not is_integer(lease) or lease <= System.monotonic_time(:millisecond) -> :lease_expired
      not lookup({:admitted, profile, chain, subject}, false) -> :not_admitted
      lifecycle(key(target)) == :pending_inspection -> :pending_inspection
      lifecycle(key(target)) != :ready -> :fenced
      Enum.any?(rules, &suspended?(&1, %{kind: kind})) -> :suspended
      rules != [] -> :partially_suspended
      true -> :allowed
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:controls, rows}, _from, state) do
    Enum.each(rows, fn {key, row} -> install_control(key, row) end)
    :ets.insert(@table, {:lease, System.monotonic_time(:millisecond) + @lease_ms})
    {:reply, :ok, state}
  end

  def handle_call({:control, key, row}, _from, state) do
    install_control(key, row)
    {:reply, :ok, state}
  end

  def handle_call({:inventory, targets}, _from, state) do
    wanted = Map.new(targets, &{key(&1), &1})
    admitted = MapSet.new(targets)

    for {_key, target} <- wanted, do: admit_subject(target)

    for {profile, chain, subject} <- targets,
        do: :ets.insert(@table, {{:admitted, profile, chain, subject}, true})

    for {{:admitted, profile, chain, subject} = key, _} <- :ets.tab2list(@table),
        not MapSet.member?(admitted, {profile, chain, subject}),
        do: :ets.delete(@table, key)

    for target <- targets(), not Map.has_key?(wanted, key(target)) do
      ReadModel.clear_subject(elem(target, 2))
      :ets.delete(@table, {:subject, key(target)})
      :ets.delete(@table, {:admitted, key(target)})
      :ets.delete(@table, {:lifecycle, key(target)})
      :ets.delete(@table, key(target))
    end

    {:reply, :ok, state}
  end

  def handle_call({:observe, evidence}, _from, state) do
    target = {evidence.profile, evidence.chain_id, evidence.subject}
    key = key(target)

    cond do
      not is_integer(evidence.dispatched_at_ms) ->
        loss(:missing_dispatch_stamp)

      not lookup({:admitted, evidence.profile, evidence.chain_id, evidence.subject}, false) ->
        loss(:not_admitted)

      evidence.epoch != epoch(target) ->
        loss(:epoch_stale)

      match?({:fenced, _}, lifecycle(key)) ->
        loss(:checkpoint_fenced)

      true ->
        ReadModel.apply(evidence)
        update_entry(key, &%{&1 | version: fresh_version()})
    end

    {:reply, :ok, state}
  end

  def handle_call({:restore_own, target, image}, _from, state) do
    cond do
      not lookup({:admitted, key(target)}, false) ->
        :ok

      is_map(image) and image.epoch < epoch(target) ->
        put_lifecycle(key(target), :ready)

      is_map(image) and image.status != :ok ->
        if image.status != :invalid, do: adopt_epoch(key(target), image.epoch)

        reason =
          if image.status == :incomplete, do: :checkpoint_incompatible, else: :checkpoint_invalid

        put_lifecycle(key(target), {:fenced, reason})

        :telemetry.execute([:lasso, :provider_knowledge, :snapshot, :fenced], %{count: 1}, %{
          reason: reason
        })

      true ->
        if is_map(image) do
          adopt_epoch(key(target), image.epoch)

          ReadModel.restore_local(
            image.rows,
            true,
            if(lifecycle(key(target)) == :pending_inspection, do: :merge, else: :replace)
          )

          update_entry(key(target), &%{&1 | revision: max(&1.revision, image.revision)})
        end

        put_lifecycle(key(target), :ready)
    end

    {:reply, :ok, state}
  end

  def handle_call({:import, target, image, source}, _from, state) do
    key = key(target)

    with true <- lookup({:admitted, key}, false), true <- image.epoch >= epoch(target) do
      adopt_epoch(key, image.epoch)
      entry = lookup({:subject, key}, nil)
      previous = Map.get(entry.writers, image.writer)

      if newer?(previous, image, source) do
        rows = Enum.filter(image.rows, &Learner.exchangeable?(elem(&1, 0)))
        ReadModel.replace_imported(image.writer, elem(target, 2), rows)

        retired =
          if previous, do: MapSet.put(previous.retired, previous.incarnation), else: MapSet.new()

        retained =
          Map.merge(
            Map.take(image, [:epoch, :writer, :incarnation, :revision]),
            %{
              retired: retired,
              received_at: Map.get(image, :received_at, System.system_time(:millisecond))
            }
          )

        update_entry(key, &put_in(&1, [:writers, image.writer], retained))
      end
    end

    {:reply, :ok, state}
  end

  def handle_call({:snapshot, target, writer, incarnation}, _from, state) do
    entry = lookup({:subject, key(target)}, nil)
    {_profile, _chain, subject} = target

    result =
      if entry && lifecycle(key(target)) == :ready do
        revision = entry.revision + 1
        update_entry(key(target), &%{&1 | revision: revision})

        {:ok,
         %{
           epoch: epoch(target),
           writer: writer,
           incarnation: incarnation,
           revision: revision,
           version: entry.version,
           rows: ReadModel.snapshot_subject(subject, true)
         }}
      else
        {:error, :checkpoint_fenced}
      end

    {:reply, result, state}
  end

  def handle_call({:persisted, target, version}, _from, state) do
    update_entry(key(target), &%{&1 | persisted: max(&1.persisted, version)})
    {:reply, :ok, state}
  end

  def handle_call(:expire_imports, _from, state) do
    now = System.system_time(:millisecond)

    for target <- targets() do
      entry = lookup({:subject, key(target)}, nil)

      {expired, retained} =
        Enum.split_with(entry.writers, fn {_writer, image} ->
          now - image.received_at >= @writer_ttl_ms
        end)

      ReadModel.replace_imported_many(
        elem(target, 2),
        Enum.map(expired, fn {writer, _} -> {writer, []} end)
      )

      update_entry(key(target), &%{&1 | writers: Map.new(retained)})
    end

    ReadModel.refresh_expired_historical_predictions()
    {:reply, :ok, state}
  end

  defp newer?(nil, _image, _source), do: true
  defp newer?(_previous, _image, :checkpoint), do: false

  defp newer?(
         %{incarnation: incarnation, revision: revision},
         %{incarnation: incarnation, revision: next},
         _source
       ),
       do: next > revision

  defp newer?(previous, image, _source),
    do: not MapSet.member?(previous.retired, image.incarnation)

  defp adopt_epoch({_chain, subject} = key, epoch) do
    previous = control(key)

    if epoch > previous.epoch do
      ReadModel.clear_subject(subject)
      :ets.insert(@table, {key, %{previous | epoch: epoch, revision: 0}})
      # An initial controls read can precede the own-checkpoint read. Only an
      # inspected subject may publish after a reset; observation starts at once.
      if lifecycle(key) != :pending_inspection, do: put_lifecycle(key, :ready)

      update_entry(key, &%{&1 | writers: %{}, version: fresh_version()})
    end
  end

  defp admit_subject(target) do
    key = key(target)
    :ets.insert_new(@table, {{:lifecycle, key}, :pending_inspection})

    :ets.insert_new(
      @table,
      {{:subject, key},
       %{target: target, version: fresh_version(), persisted: 0, revision: 0, writers: %{}}}
    )

    update_entry(key, &%{&1 | target: target})
    :ets.insert(@table, {{:admitted, key}, true})
  end

  defp lifecycle(key), do: lookup({:lifecycle, key}, :pending_inspection)
  defp put_lifecycle(key, value), do: :ets.insert(@table, {{:lifecycle, key}, value})

  defp update_entry(key, fun) do
    case lookup({:subject, key}, nil) do
      nil -> :ok
      entry -> :ets.insert(@table, {{:subject, key}, fun.(entry)})
    end
  end

  defp loss(reason),
    do: :ets.update_counter(@table, {:loss, reason}, {2, 1}, {{:loss, reason}, 0})

  defp call(message), do: GenServer.call(__MODULE__, message, 10_000)
  defp fresh_version, do: System.unique_integer([:positive, :monotonic])
  defp key({_profile, chain, subject}), do: {chain, subject}

  defp install_control(key, row) do
    previous = control(key)

    if row.epoch > previous.epoch or
         (row.epoch == previous.epoch and row.revision >= previous.revision) do
      adopt_epoch(key, row.epoch)
      :ets.insert(@table, {key, row})
    end
  end

  defp lookup(key, default) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  rescue
    ArgumentError -> default
  end

  defp suspended?(%{kind: :all}, _scope), do: true

  defp suspended?(%{kind: kind} = rule, %{kind: kind} = scope),
    do: Map.drop(rule, [:kind]) == Map.take(scope, Map.keys(Map.drop(rule, [:kind])))

  defp suspended?(_, _), do: false
end

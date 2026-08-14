defmodule Lasso.Core.ProjectionLane do
  @moduledoc """
  Hard-bounded asynchronous delivery for one optional projection class.

  Each fixed worker owns one ETS table containing a fixed number of logical
  slots. Scope hashing assigns `{profile, chain}` traffic to a fixed bucket;
  colliding scopes conservatively share that bucket's quota. Worker mailboxes
  contain only coalesced bucket wakes, never request or response payloads.

  Breaker leases and other critical accounting do not belong in this module.
  """

  use GenServer

  alias Lasso.RPC.{BoundedIdentifier, ExecutionFact.Codec}

  defmodule Metadata do
    @moduledoc false
    @enforce_keys [
      :control,
      :incarnation,
      :capacity,
      :byte_capacity,
      :scope_capacity,
      :scope_byte_capacity,
      :shards,
      :buckets_per_shard,
      :max_payload_bytes,
      :max_age_ms,
      :audit_interval_ms,
      :coalesce,
      :now,
      :test_hook,
      :global_counters
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  defmodule Token do
    @moduledoc "Opaque, incarnation- and generation-safe cancellation token."
    @enforce_keys [:incarnation, :shard, :shard_generation, :bucket, :slot, :sequence]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  defmodule Degradation do
    @moduledoc "Opaque reference to one independently versioned bucket degradation."
    @enforce_keys [:incarnation, :shard, :shard_generation, :bucket, :epoch]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  @type scope :: {binary(), binary() | pos_integer()}
  @type enqueue_result ::
          {:ok, Token.t()}
          | {:coalesced, Token.t(), Degradation.t()}
          | {:drop, atom(), Degradation.t() | :untracked}

  @counter_reasons [
    :bucket_contended,
    :cancelled,
    :coalesced,
    :expired,
    :invalid_payload,
    :invalid_scope,
    :recovered,
    :sink_failure,
    :unavailable,
    :worker_restart
  ]
  @counter_indexes @counter_reasons |> Enum.with_index(1) |> Map.new()
  @counter_count length(@counter_reasons)
  @max_counter 9_223_372_036_854_775_807
  @max_epoch div(@max_counter - 1, 2)
  @max_chain_id @max_counter

  defstruct [:metadata, :sink, workers: %{}]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Enqueues one previously encoded fact or bounded diagnostic batch."
  @spec enqueue(Metadata.t(), scope(), binary()) :: enqueue_result()
  def enqueue(%Metadata{} = metadata, scope, payload) do
    with {:ok, normalized_scope} <- normalize_scope(scope),
         :ok <- validate_payload(metadata, payload),
         {:ok, runtime} <- runtime_for_scope(metadata, normalized_scope) do
      publish(metadata, runtime, normalized_scope, payload)
    else
      {:error, :invalid_scope} -> untracked_drop(metadata, :invalid_scope)
      {:error, :invalid_payload} -> untracked_drop(metadata, :invalid_payload)
      {:error, :unavailable} -> untracked_drop(metadata, :unavailable)
    end
  rescue
    ArgumentError -> {:drop, :unavailable, :untracked}
  end

  @doc "Encodes a canonical tagged execution fact before bounded enqueue."
  @spec enqueue_fact(Metadata.t(), scope(), struct()) :: enqueue_result()
  def enqueue_fact(%Metadata{} = metadata, scope, fact) do
    case Codec.encode(fact) do
      {:ok, payload} -> enqueue(metadata, scope, payload)
      {:error, _reason} -> untracked_drop(metadata, :invalid_payload)
    end
  end

  @doc "Cancels an item if and only if its exact token is still queued."
  @spec cancel(Metadata.t(), Token.t()) :: :cancelled | :delivering | :not_found | :unavailable
  def cancel(
        %Metadata{incarnation: incarnation} = metadata,
        %Token{incarnation: incarnation} = token
      ) do
    case runtime_for_token(metadata, token) do
      {:ok, runtime} -> cancel_queued(metadata, runtime, token)
      {:error, :stale} -> :not_found
      {:error, :unavailable} -> :unavailable
    end
  rescue
    ArgumentError -> :unavailable
  end

  def cancel(%Metadata{}, %Token{}), do: :not_found

  @doc "Recovers only the exact independently versioned degradation supplied."
  @spec recover(Metadata.t(), Degradation.t()) :: :recovered | :stale | :unavailable
  def recover(
        %Metadata{incarnation: incarnation} = metadata,
        %Degradation{incarnation: incarnation} = degradation
      ) do
    case runtime_for_degradation(metadata, degradation) do
      {:ok, runtime} -> recover_degradation(metadata, runtime, degradation)
      {:error, :stale} -> :stale
      {:error, :unavailable} -> :unavailable
    end
  rescue
    ArgumentError -> :unavailable
  end

  def recover(%Metadata{}, %Degradation{}), do: :stale

  defp cancel_queued(metadata, runtime, token) do
    case lookup_slot(runtime.table, token.slot) do
      {:ok, row} when elem(row, 1) == :queued and elem(row, 2) == token ->
        delete_ready(runtime.table, row)

        if delete_exact(runtime.table, row) do
          record(metadata, runtime, token.bucket, :cancelled)
          :cancelled
        else
          cancel(metadata, token)
        end

      {:ok, row} when elem(row, 1) == :delivering and elem(row, 2) == token ->
        :delivering

      _other ->
        :not_found
    end
  end

  defp recover_degradation(metadata, runtime, degradation) do
    index = degradation.bucket + 1
    expected = degradation.epoch * 2 + 1

    case :atomics.compare_exchange(runtime.degradations, index, expected, expected - 1) do
      :ok ->
        record(metadata, runtime, degradation.bucket, :recovered)
        :recovered

      _current ->
        :stale
    end
  end

  @doc false
  @spec metadata(GenServer.server()) :: Metadata.t()
  def metadata(lane), do: GenServer.call(lane, :metadata)

  @doc false
  @spec workers(GenServer.server()) :: %{non_neg_integer() => {pid(), pos_integer()}}
  def workers(lane), do: GenServer.call(lane, :workers)

  @doc false
  @spec stats(GenServer.server()) :: map()
  def stats(lane), do: GenServer.call(lane, :stats)

  @doc false
  @spec audit(GenServer.server()) :: :ok
  def audit(lane), do: GenServer.call(lane, :audit)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    capacity = positive!(opts, :capacity)
    byte_capacity = positive!(opts, :byte_capacity)
    scope_capacity = positive!(opts, :scope_capacity)
    scope_byte_capacity = positive!(opts, :scope_byte_capacity)
    shards = positive!(opts, :shards)
    max_age_ms = positive!(opts, :max_age_ms)
    audit_interval_ms = positive!(opts, :audit_interval_ms)
    coalesce = Keyword.get(opts, :coalesce, :none)
    sink = Keyword.fetch!(opts, :sink)

    true = is_function(sink, 2)
    true = coalesce in [:none, :latest]
    true = coalesce != :latest or scope_capacity == 1
    true = rem(capacity, shards * scope_capacity) == 0

    buckets_per_shard = div(capacity, shards * scope_capacity)

    max_payload_bytes =
      Enum.min([
        Codec.max_bytes(),
        div(byte_capacity, capacity),
        div(scope_byte_capacity, scope_capacity)
      ])

    true = buckets_per_shard > 0
    true = max_payload_bytes > 0

    incarnation = make_ref()
    control = :ets.new(:projection_lane_control, table_options())
    global_counters = :atomics.new(@counter_count, signed: true)

    metadata = %Metadata{
      control: control,
      incarnation: incarnation,
      capacity: capacity,
      byte_capacity: byte_capacity,
      scope_capacity: scope_capacity,
      scope_byte_capacity: scope_byte_capacity,
      shards: shards,
      buckets_per_shard: buckets_per_shard,
      max_payload_bytes: max_payload_bytes,
      max_age_ms: max_age_ms,
      audit_interval_ms: audit_interval_ms,
      coalesce: coalesce,
      now: Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end),
      test_hook: Keyword.get(opts, :test_hook, fn _event -> :ok end),
      global_counters: global_counters
    }

    workers =
      Map.new(0..(shards - 1), fn shard ->
        runtime = start_worker(metadata, sink, shard, 1)
        publish_runtime(metadata, runtime)
        {shard, runtime}
      end)

    {:ok, %__MODULE__{metadata: metadata, sink: sink, workers: workers}}
  end

  @impl true
  def handle_call(:metadata, _from, state), do: {:reply, state.metadata, state}

  def handle_call(:workers, _from, state) do
    workers =
      Map.new(state.workers, fn {shard, runtime} -> {shard, {runtime.pid, runtime.generation}} end)

    {:reply, workers, state}
  end

  def handle_call(:stats, _from, state), do: {:reply, build_stats(state), state}

  def handle_call(:audit, _from, state) do
    Enum.each(state.workers, fn {_shard, runtime} -> send(runtime.pid, :audit_now) end)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    case Enum.find(state.workers, fn {_shard, runtime} -> runtime.pid == pid end) do
      {shard, old_runtime} ->
        runtime = start_worker(state.metadata, state.sink, shard, old_runtime.generation + 1)
        publish_runtime(state.metadata, runtime)
        increment_counter(state.metadata.global_counters, counter_index(:worker_restart))
        state.metadata.test_hook.({:worker_restarted, shard, runtime.pid, runtime.generation})
        {:noreply, put_in(state.workers[shard], runtime)}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.workers, fn {_shard, runtime} ->
      if Process.alive?(runtime.pid), do: Process.exit(runtime.pid, :shutdown)
    end)

    :ok
  end

  defp publish(metadata, runtime, scope, payload) do
    sequence = System.unique_integer([:positive, :monotonic])
    first_offset = rem(sequence, metadata.scope_capacity)
    token = token(metadata, runtime, first_offset, sequence)
    row = row(:queued, token, scope, metadata.now.(), payload)

    case metadata.coalesce do
      :latest -> publish_latest(metadata, runtime, row)
      :none -> publish_new(metadata, runtime, row, first_offset)
    end
  end

  defp publish_new(metadata, runtime, row, first_offset) do
    case insert_with_fixed_probe(metadata, runtime, row, first_offset) do
      {:ok, token, slot_operations} ->
        metadata.test_hook.({:published, token})
        metadata.test_hook.({:enqueue_ops, token, 1 + slot_operations})
        schedule_bucket(metadata, runtime, token.bucket)
        {:ok, token}

      :full ->
        degradation = degrade(metadata, runtime, runtime.bucket, :bucket_contended)
        {:drop, :bucket_contended, degradation}
    end
  end

  defp publish_latest(metadata, runtime, row) do
    token = elem(row, 2)
    replacement = latest_match(token.slot, elem(row, 3), row)

    case :ets.select_replace(runtime.table, replacement) do
      1 ->
        degradation = degrade(metadata, runtime, token.bucket, :coalesced)
        metadata.test_hook.({:published, token})
        metadata.test_hook.({:enqueue_ops, token, 2})
        schedule_bucket(metadata, runtime, token.bucket)
        {:coalesced, token, degradation}

      0 ->
        if :ets.insert_new(runtime.table, row) do
          metadata.test_hook.({:published, token})
          metadata.test_hook.({:enqueue_ops, token, 3})
          schedule_bucket(metadata, runtime, token.bucket)
          {:ok, token}
        else
          degradation = degrade(metadata, runtime, token.bucket, :bucket_contended)
          {:drop, :bucket_contended, degradation}
        end
    end
  end

  defp insert_with_fixed_probe(metadata, runtime, row, first_offset) do
    token = elem(row, 2)

    if insert_queued(runtime.table, row) do
      {:ok, token, 1}
    else
      maybe_insert_second(metadata, runtime, row, first_offset)
    end
  end

  defp maybe_insert_second(%Metadata{scope_capacity: 1}, _runtime, _row, _first_offset), do: :full

  defp maybe_insert_second(metadata, runtime, row, first_offset) do
    second_offset = rem(first_offset + 1, metadata.scope_capacity)
    token = elem(row, 2)
    second_token = %{token | slot: slot(token.bucket, second_offset, metadata.scope_capacity)}
    second_row = put_elem(row, 2, second_token) |> put_elem(0, second_token.slot)

    if insert_queued(runtime.table, second_row),
      do: {:ok, second_token, 2},
      else: :full
  end

  defp runtime_for_scope(metadata, scope) do
    bucket_count = metadata.shards * metadata.buckets_per_shard
    global_bucket = :erlang.phash2(scope, bucket_count)
    shard = div(global_bucket, metadata.buckets_per_shard)
    bucket = rem(global_bucket, metadata.buckets_per_shard)

    case lookup_runtime(metadata, shard) do
      {:ok, runtime} -> {:ok, Map.put(runtime, :bucket, bucket)}
      error -> error
    end
  end

  defp runtime_for_token(metadata, token) do
    case lookup_runtime(metadata, token.shard) do
      {:ok, %{generation: generation} = runtime} when generation == token.shard_generation ->
        {:ok, Map.put(runtime, :bucket, token.bucket)}

      {:ok, _runtime} ->
        {:error, :stale}

      error ->
        error
    end
  end

  defp runtime_for_degradation(metadata, degradation) do
    case lookup_runtime(metadata, degradation.shard) do
      {:ok, %{generation: generation} = runtime}
      when generation == degradation.shard_generation ->
        {:ok, Map.put(runtime, :bucket, degradation.bucket)}

      {:ok, _runtime} ->
        {:error, :stale}

      error ->
        error
    end
  end

  defp lookup_runtime(metadata, shard) do
    case :ets.lookup(metadata.control, {:shard, shard}) do
      [{{:shard, ^shard}, generation, pid, table, wakes, counters, degradations}] ->
        {:ok,
         %{
           shard: shard,
           generation: generation,
           pid: pid,
           table: table,
           wakes: wakes,
           counters: counters,
           degradations: degradations
         }}

      [] ->
        {:error, :unavailable}
    end
  rescue
    ArgumentError -> {:error, :unavailable}
  end

  defp start_worker(metadata, sink, shard, generation) do
    parent = self()
    wakes = :atomics.new(metadata.buckets_per_shard, signed: true)
    counters = :atomics.new(metadata.buckets_per_shard * @counter_count, signed: true)
    degradations = :atomics.new(metadata.buckets_per_shard, signed: true)

    worker_config = %{
      parent: parent,
      incarnation: metadata.incarnation,
      shard: shard,
      generation: generation,
      wakes: wakes,
      counters: counters,
      degradations: degradations,
      scope_capacity: metadata.scope_capacity,
      buckets_per_shard: metadata.buckets_per_shard,
      max_age_ms: metadata.max_age_ms,
      audit_interval_ms: metadata.audit_interval_ms,
      now: metadata.now,
      sink: sink,
      coalesce: metadata.coalesce,
      hook: metadata.test_hook,
      global_counters: metadata.global_counters
    }

    pid = spawn_link(fn -> initialize_worker(worker_config) end)

    receive do
      {:projection_worker_ready, ^pid, table} ->
        %{
          shard: shard,
          generation: generation,
          pid: pid,
          table: table,
          wakes: wakes,
          counters: counters,
          degradations: degradations
        }

      {:EXIT, ^pid, reason} ->
        exit({:projection_worker_start_failed, shard, reason})
    end
  end

  defp initialize_worker(config) do
    table = :ets.new(:projection_worker_slots, worker_table_options())
    send(config.parent, {:projection_worker_ready, self(), table})
    schedule_audit(config.audit_interval_ms)
    worker_loop(Map.merge(config, %{table: table, last_scopes: %{}}))
  end

  defp worker_loop(state) do
    receive do
      {:drain_bucket, incarnation, generation, bucket}
      when incarnation == state.incarnation and generation == state.generation ->
        state
        |> drain_one(bucket)
        |> worker_loop()

      :audit ->
        state.hook.({:audit, state.shard, state.generation})
        schedule_all_worker(state)
        schedule_audit(state.audit_interval_ms)
        worker_loop(state)

      :audit_now ->
        schedule_all_worker(state)
        worker_loop(state)

      {:barrier, from, reference} ->
        send(from, {:barrier, reference})
        worker_loop(state)

      _message ->
        worker_loop(state)
    end
  end

  defp drain_one(state, bucket) do
    case next_queued(state, bucket) do
      nil ->
        state.hook.({:before_empty_settle, bucket})
        reschedule_or_settle(state, bucket)
        state

      row ->
        token = elem(row, 2)
        scope = elem(row, 3)
        state.hook.({:before_claim, token})

        if claim(state.table, row) do
          state.hook.({:claimed, token})
          result = deliver(state, row)
          delete_delivering(state.table, put_elem(row, 1, :delivering))
          state.hook.({:completed, token, result})
        end

        reschedule_or_settle(state, bucket)
        %{state | last_scopes: Map.put(state.last_scopes, bucket, scope)}
    end
  end

  defp deliver(state, row) do
    token = elem(row, 2)
    scope = elem(row, 3)
    enqueued_at = elem(row, 4)
    payload = elem(row, 6)

    if state.now.() - enqueued_at >= state.max_age_ms do
      record_worker(state, token.bucket, :expired)
      :expired
    else
      try do
        state.sink.(scope, payload)
        :ok
      rescue
        _exception ->
          degrade_worker(state, token.bucket, :sink_failure)
          :sink_failure
      catch
        _kind, _reason ->
          degrade_worker(state, token.bucket, :sink_failure)
          :sink_failure
      end
    end
  end

  defp next_queued(%{coalesce: :none} = state, bucket) do
    next_indexed(state, bucket, state.scope_capacity + 1)
  end

  defp next_queued(state, bucket) do
    rows =
      for offset <- 0..(state.scope_capacity - 1),
          {:ok, row} <- [lookup_slot(state.table, slot(bucket, offset, state.scope_capacity))],
          elem(row, 1) == :queued,
          do: row

    choose_fair(rows, Map.get(state.last_scopes, bucket))
  end

  defp next_indexed(_state, _bucket, 0), do: nil

  defp next_indexed(state, bucket, remaining) do
    last_scope = Map.get(state.last_scopes, bucket)

    case next_ready_key(state.table, bucket, last_scope) do
      nil ->
        nil

      key ->
        case ready_row(state.table, key) do
          {:ok, slot, token} ->
            case lookup_slot(state.table, slot) do
              {:ok, row} when elem(row, 1) == :queued and elem(row, 2) == token ->
                row

              _stale ->
                :ets.delete(state.table, key)
                next_indexed(state, bucket, remaining - 1)
            end

          :error ->
            next_indexed(state, bucket, remaining - 1)
        end
    end
  end

  defp choose_fair([], _last_scope), do: nil

  defp choose_fair(rows, last_scope) do
    scopes = rows |> Enum.map(&elem(&1, 3)) |> Enum.uniq() |> Enum.sort()

    next_scope =
      Enum.find(scopes, fn scope -> is_nil(last_scope) or scope > last_scope end) || hd(scopes)

    rows
    |> Enum.filter(&(elem(&1, 3) == next_scope))
    |> Enum.min_by(fn row -> elem(row, 2).sequence end)
  end

  defp reschedule_or_settle(state, bucket) do
    if bucket_has_queued?(state, bucket) do
      send(self(), {:drain_bucket, state.incarnation, state.generation, bucket})
    else
      settle_wake(state, bucket)

      if bucket_has_queued?(state, bucket),
        do: schedule_bucket_worker(state, bucket)
    end
  end

  defp settle_wake(state, bucket), do: :atomics.put(state.wakes, bucket + 1, 0)

  defp schedule_all_worker(state) do
    Enum.each(0..(state.buckets_per_shard - 1), fn bucket ->
      if bucket_has_queued?(state, bucket),
        do: repair_bucket_wake(state, bucket)
    end)
  end

  defp schedule_bucket(metadata, runtime, bucket) do
    if :atomics.compare_exchange(runtime.wakes, bucket + 1, 0, 1) == :ok do
      metadata.test_hook.({:wake_claimed, runtime.shard, runtime.generation, bucket})
      send(runtime.pid, {:drain_bucket, metadata.incarnation, runtime.generation, bucket})
    end

    :ok
  end

  defp schedule_bucket_worker(state, bucket) do
    if :atomics.compare_exchange(state.wakes, bucket + 1, 0, 1) == :ok do
      send(self(), {:drain_bucket, state.incarnation, state.generation, bucket})
    end
  end

  defp repair_bucket_wake(state, bucket) do
    :atomics.put(state.wakes, bucket + 1, 1)
    send(self(), {:drain_bucket, state.incarnation, state.generation, bucket})
  end

  defp schedule_audit(interval), do: Process.send_after(self(), :audit, interval)

  defp bucket_has_queued?(%{coalesce: :none, table: table}, bucket),
    do: not is_nil(first_ready_key(table, bucket))

  defp bucket_has_queued?(state, bucket) do
    Enum.any?(0..(state.scope_capacity - 1), fn offset ->
      case lookup_slot(state.table, slot(bucket, offset, state.scope_capacity)) do
        {:ok, row} -> elem(row, 1) == :queued
        :error -> false
      end
    end)
  end

  defp claim(table, row), do: replace_exact(table, row, put_elem(row, 1, :delivering))

  defp delete_delivering(table, row) do
    delete_ready(table, row)
    delete_exact(table, row)
  end

  defp replace_exact(table, old, new) do
    :ets.select_replace(table, [{old, [], [{:const, new}]}]) == 1
  end

  defp delete_exact(table, row), do: :ets.select_delete(table, [{row, [], [true]}]) == 1

  defp latest_match(slot, scope, row) do
    [
      {
        {slot, :queued, :"$1", scope, :"$2", :"$3", :"$4"},
        [],
        [{:const, row}]
      }
    ]
  end

  defp lookup_slot(table, slot) do
    case :ets.lookup(table, slot) do
      [row] -> {:ok, row}
      [] -> :error
    end
  end

  defp insert_queued(table, row), do: :ets.insert_new(table, [row, indexed_row(row)])

  defp indexed_row(row) do
    token = elem(row, 2)
    scope = elem(row, 3)
    {ready_key(token.bucket, scope, token.sequence), token.slot, token}
  end

  defp delete_ready(table, row) do
    token = elem(row, 2)
    :ets.delete(table, ready_key(token.bucket, elem(row, 3), token.sequence))
  end

  defp ready_row(table, key) do
    case :ets.lookup(table, key) do
      [{^key, slot, %Token{} = token}] -> {:ok, slot, token}
      _other -> :error
    end
  end

  defp next_ready_key(table, bucket, nil), do: first_ready_key(table, bucket)

  defp next_ready_key(table, bucket, last_scope) do
    case :ets.next(table, ready_key_after_scope(bucket, last_scope)) do
      {:ready, ^bucket, _scope, _sequence} = key -> key
      _other -> first_ready_key(table, bucket)
    end
  end

  defp first_ready_key(table, bucket) do
    case :ets.next(table, {:ready, bucket}) do
      {:ready, ^bucket, _scope, _sequence} = key -> key
      _other -> nil
    end
  end

  defp ready_key(bucket, scope, sequence), do: {:ready, bucket, scope, sequence}
  defp ready_key_after_scope(bucket, scope), do: {:ready, bucket, scope, :end_of_scope}

  defp row(state, token, scope, enqueued_at, payload),
    do: {token.slot, state, token, scope, enqueued_at, byte_size(payload), payload}

  defp token(metadata, runtime, offset, sequence) do
    %Token{
      incarnation: metadata.incarnation,
      shard: runtime.shard,
      shard_generation: runtime.generation,
      bucket: runtime.bucket,
      slot: slot(runtime.bucket, offset, metadata.scope_capacity),
      sequence: sequence
    }
  end

  defp slot(bucket, offset, scope_capacity), do: bucket * scope_capacity + offset

  defp publish_runtime(metadata, runtime) do
    :ets.insert(
      metadata.control,
      {{:shard, runtime.shard}, runtime.generation, runtime.pid, runtime.table, runtime.wakes,
       runtime.counters, runtime.degradations}
    )
  end

  defp degrade(metadata, runtime, bucket, reason) do
    record(metadata, runtime, bucket, reason)
    epoch = next_degradation(runtime.degradations, bucket + 1)

    %Degradation{
      incarnation: metadata.incarnation,
      shard: runtime.shard,
      shard_generation: runtime.generation,
      bucket: bucket,
      epoch: epoch
    }
  end

  defp degrade_worker(state, bucket, reason) do
    record_worker(state, bucket, reason)
    epoch = next_degradation(state.degradations, bucket + 1)

    degradation = %Degradation{
      incarnation: state.incarnation,
      shard: state.shard,
      shard_generation: state.generation,
      bucket: bucket,
      epoch: epoch
    }

    state.hook.({:degraded, degradation, reason})
    degradation
  end

  defp next_degradation(atomics, index) do
    current = :atomics.get(atomics, index)
    epoch = div(current, 2)
    next_epoch = if epoch >= @max_epoch, do: 1, else: epoch + 1
    next = next_epoch * 2 + 1

    case :atomics.compare_exchange(atomics, index, current, next) do
      :ok -> next_epoch
      _other -> next_degradation(atomics, index)
    end
  end

  defp record(metadata, runtime, bucket, reason) do
    increment_counter(metadata.global_counters, counter_index(reason))
    increment_counter(runtime.counters, bucket_counter_index(bucket, reason))
  end

  defp record_worker(state, bucket, reason) do
    increment_counter(state.global_counters, counter_index(reason))
    increment_counter(state.counters, bucket_counter_index(bucket, reason))
  end

  defp untracked_drop(metadata, reason) do
    increment_counter(metadata.global_counters, counter_index(reason))
    {:drop, reason, :untracked}
  rescue
    ArgumentError -> {:drop, reason, :untracked}
  end

  defp increment_counter(atomics, index) do
    current = :atomics.get(atomics, index)

    cond do
      current >= @max_counter ->
        @max_counter

      :atomics.compare_exchange(atomics, index, current, current + 1) == :ok ->
        current + 1

      true ->
        increment_counter(atomics, index)
    end
  end

  defp counter_index(reason), do: Map.fetch!(@counter_indexes, reason)

  defp bucket_counter_index(bucket, reason),
    do: bucket * @counter_count + counter_index(reason)

  defp build_stats(state) do
    shard_stats =
      Map.new(state.workers, fn {shard, runtime} -> {shard, worker_stats(state, runtime)} end)

    %{
      capacity: state.metadata.capacity,
      byte_capacity: state.metadata.byte_capacity,
      scope_capacity: state.metadata.scope_capacity,
      scope_byte_capacity: state.metadata.scope_byte_capacity,
      max_payload_bytes: state.metadata.max_payload_bytes,
      retained_items:
        Enum.sum(Enum.map(shard_stats, fn {_shard, stats} -> stats.retained_items end)),
      queued_items: Enum.sum(Enum.map(shard_stats, fn {_shard, stats} -> stats.queued_items end)),
      bytes: Enum.sum(Enum.map(shard_stats, fn {_shard, stats} -> stats.bytes end)),
      active_scopes:
        shard_stats
        |> Enum.flat_map(fn {_shard, stats} -> stats.active_scopes end)
        |> MapSet.new(),
      counters: read_counters(state.metadata.global_counters),
      shards: shard_stats
    }
  end

  defp worker_stats(state, runtime) do
    rows = fixed_rows(runtime.table, state.metadata)

    bucket_stats =
      Map.new(0..(state.metadata.buckets_per_shard - 1), fn bucket ->
        bucket_rows = Enum.filter(rows, fn row -> elem(row, 2).bucket == bucket end)
        packed = :atomics.get(runtime.degradations, bucket + 1)

        {bucket,
         %{
           retained_items: length(bucket_rows),
           bytes: Enum.sum(Enum.map(bucket_rows, &elem(&1, 5))),
           status: if(rem(packed, 2) == 1, do: :degraded, else: :healthy),
           degradation_epoch: div(packed, 2),
           counters: read_bucket_counters(runtime.counters, bucket)
         }}
      end)

    %{
      generation: runtime.generation,
      worker: runtime.pid,
      table: runtime.table,
      retained_items: length(rows),
      queued_items: Enum.count(rows, &(elem(&1, 1) == :queued)),
      bytes: Enum.sum(Enum.map(rows, &elem(&1, 5))),
      active_scopes: Enum.map(rows, &elem(&1, 3)),
      buckets: bucket_stats,
      message_queue_len: message_queue_len(runtime.pid)
    }
  rescue
    ArgumentError ->
      %{
        generation: runtime.generation,
        worker: runtime.pid,
        table: runtime.table,
        retained_items: 0,
        queued_items: 0,
        bytes: 0,
        active_scopes: [],
        buckets: %{},
        message_queue_len: message_queue_len(runtime.pid)
      }
  end

  defp fixed_rows(table, metadata) do
    for slot <- 0..(div(metadata.capacity, metadata.shards) - 1),
        {:ok, row} <- [lookup_slot(table, slot)],
        do: row
  end

  defp read_counters(atomics) do
    Map.new(@counter_reasons, fn reason ->
      {reason, :atomics.get(atomics, counter_index(reason))}
    end)
  end

  defp read_bucket_counters(atomics, bucket) do
    Map.new(@counter_reasons, fn reason ->
      {reason, :atomics.get(atomics, bucket_counter_index(bucket, reason))}
    end)
  end

  defp message_queue_len(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} -> length
      nil -> 0
    end
  end

  defp normalize_scope({profile, chain}) when is_binary(profile) do
    with {:ok, chain} <- normalize_chain(chain) do
      {:ok, {BoundedIdentifier.encode(profile), chain}}
    end
  end

  defp normalize_scope(_scope), do: {:error, :invalid_scope}

  defp normalize_chain(chain) when is_binary(chain), do: {:ok, BoundedIdentifier.encode(chain)}

  defp normalize_chain(chain) when is_integer(chain) and chain > 0 and chain <= @max_chain_id,
    do: {:ok, Integer.to_string(chain)}

  defp normalize_chain(_chain), do: {:error, :invalid_scope}

  defp validate_payload(metadata, payload)
       when is_binary(payload) and byte_size(payload) <= metadata.max_payload_bytes,
       do: :ok

  defp validate_payload(_metadata, _payload), do: {:error, :invalid_payload}

  defp positive!(opts, key) do
    value = Keyword.fetch!(opts, key)
    true = is_integer(value) and value > 0
    value
  end

  defp table_options,
    do: [:set, :public, read_concurrency: true, write_concurrency: true]

  defp worker_table_options,
    do: [:ordered_set, :public, read_concurrency: true, write_concurrency: true]
end

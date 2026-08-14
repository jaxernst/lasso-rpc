defmodule Lasso.Prototypes.BreakerSuccessEpoch.Benchmark do
  @moduledoc """
  PROTOTYPE: operational cost harness for the fixed-slot ring and success epoch.

  The ring is a compact reproduction of the merged algorithm: metadata lookup,
  fixed-slot probing, coalesced wake, full-table drain, and a second full scan.
  """

  @capacity 64

  def run(count \\ 100_000) do
    _ = run_active(:ring, 2_000, 1)
    _ = run_active(:epoch, 2_000, 1)

    active =
      for producers <- [1, 10], kind <- [:ring, :epoch] do
        run_active(kind, count, producers)
      end

    suspended =
      for producers <- [1, 10], kind <- [:ring, :epoch] do
        run_suspended(kind, count, producers)
      end

    %{count: count, active: active, suspended: suspended}
  end

  defp run_active(:epoch, count, producers) do
    context = epoch_context()
    {elapsed_us, producer} = timed_producers(count, producers, fn -> epoch_success(context) end)
    epoch = :atomics.get(context.success_epoch, 1)
    :ets.delete(context.meta)

    result(:epoch, :active, count, producers, elapsed_us, producer,
      accepted: epoch,
      drops: 0,
      degraded?: false,
      owner_wakes: 0,
      owner_reductions: 0,
      owner_ets_ops: 0,
      owner_atomics_ops: 0
    )
  end

  defp run_active(:ring, count, producers) do
    context = ring_context(:active)
    {elapsed_us, producer} = timed_producers(count, producers, fn -> ring_success(context) end)
    {owner, settle_us} = settle_owner(context)
    stats = ring_stats(context)
    stop_ring(context)

    result(:ring, :active, count, producers, elapsed_us + settle_us, producer,
      accepted: producer.accepted,
      drops: producer.drops,
      degraded?: stats.degraded?,
      owner_wakes: owner.wakes,
      owner_reductions: owner.reductions,
      owner_ets_ops: owner.ets_ops,
      owner_atomics_ops: owner.atomics_ops
    )
  end

  defp run_suspended(:epoch, count, producers) do
    context = epoch_context()
    {elapsed_us, producer} = timed_producers(count, producers, fn -> epoch_success(context) end)
    epoch = :atomics.get(context.success_epoch, 1)
    :ets.delete(context.meta)

    result(:epoch, :suspended, count, producers, elapsed_us, producer,
      accepted: epoch,
      drops: 0,
      degraded?: false,
      owner_wakes: 0,
      owner_reductions: 0,
      owner_ets_ops: 0,
      owner_atomics_ops: 0
    )
  end

  defp run_suspended(:ring, count, producers) do
    context = ring_context(:suspended)
    {elapsed_us, producer} = timed_producers(count, producers, fn -> ring_success(context) end)
    stats = ring_stats(context)
    {:messages, messages} = Process.info(context.owner, :messages)
    stop_ring(context)

    result(:ring, :suspended, count, producers, elapsed_us, producer,
      accepted: producer.accepted,
      drops: producer.drops,
      degraded?: stats.degraded?,
      owner_wakes: Enum.count(messages, &(&1 == :control_ready)),
      owner_reductions: 0,
      owner_ets_ops: 0,
      owner_atomics_ops: 0
    )
  end

  defp timed_producers(count, producers, operation) do
    started = System.monotonic_time(:microsecond)
    tasks = partition(count, producers, operation)

    metrics =
      tasks
      |> Enum.map(&Task.await(&1, 120_000))
      |> Enum.reduce(zero_metrics(), &merge_metrics/2)

    {System.monotonic_time(:microsecond) - started, metrics}
  end

  defp partition(count, producers, operation) do
    quotient = div(count, producers)
    remainder = rem(count, producers)

    for index <- 0..(producers - 1) do
      local_count = quotient + if(index < remainder, do: 1, else: 0)

      Task.async(fn ->
        before_reductions = reductions()

        metrics =
          Enum.reduce(1..local_count, zero_metrics(), fn _index, acc ->
            merge_metrics(operation.(), acc)
          end)

        %{metrics | reductions: reductions() - before_reductions}
      end)
    end
  end

  defp epoch_context do
    meta = :ets.new(:success_epoch_meta, [:set, :public, read_concurrency: true])
    success_epoch = :atomics.new(1, signed: false)
    true = :ets.insert(meta, {:meta, 1, 1, success_epoch})
    %{meta: meta, success_epoch: success_epoch}
  end

  defp epoch_success(context) do
    [{:meta, 1, 1, success_epoch}] = :ets.lookup(context.meta, :meta)
    _next = :atomics.add_get(success_epoch, 1, 1)
    %{zero_metrics() | accepted: 1, ets_ops: 1, atomics_ops: 1}
  end

  defp ring_context(mode) do
    slots =
      :ets.new(:control_slots, [:set, :public, read_concurrency: true, write_concurrency: true])

    meta = :ets.new(:control_meta, [:set, :public, read_concurrency: true])
    ring_ref = make_ref()
    wakeup = :atomics.new(1, signed: false)
    degraded = :atomics.new(1, signed: false)
    drops = :atomics.new(1, signed: false)

    Enum.each(0..(@capacity - 1), fn index ->
      true = :ets.insert(slots, {index, {ring_ref, :empty}})
    end)

    owner =
      case mode do
        :active -> spawn(fn -> ring_owner(slots, ring_ref, wakeup, owner_zero()) end)
        :suspended -> spawn(fn -> suspended_owner() end)
      end

    true = :ets.insert(meta, {:meta, 1, 1, owner, ring_ref, wakeup, degraded, drops})

    %{
      slots: slots,
      meta: meta,
      owner: owner,
      ring_ref: ring_ref,
      wakeup: wakeup,
      degraded: degraded,
      drops: drops,
      mode: mode
    }
  end

  defp ring_success(context) do
    [{:meta, 1, 1, owner, ring_ref, wakeup, degraded, drops}] =
      :ets.lookup(context.meta, :meta)

    sequence = System.unique_integer([:positive, :monotonic])
    start = rem(sequence, @capacity)

    case reserve(context.slots, ring_ref, sequence, start, 0) do
      {:ok, probes} ->
        {messages, atomic_ops} = notify_once(owner, wakeup)

        %{
          zero_metrics()
          | accepted: 1,
            ets_ops: 1 + probes,
            atomics_ops: atomic_ops,
            messages: messages
        }

      {:full, probes} ->
        _ = :atomics.compare_exchange(degraded, 1, 0, 1)
        _ = :atomics.add_get(drops, 1, 1)
        {messages, notify_ops} = notify_once(owner, wakeup)

        %{
          zero_metrics()
          | drops: 1,
            ets_ops: 1 + probes,
            atomics_ops: 2 + notify_ops,
            messages: messages
        }
    end
  end

  defp reserve(_slots, _ring_ref, _sequence, _start, @capacity),
    do: {:full, @capacity}

  defp reserve(slots, ring_ref, sequence, start, offset) do
    index = rem(start + offset, @capacity)

    match_spec = [
      {{index, {ring_ref, :empty}}, [], [{:const, {index, {ring_ref, {sequence, :success}}}}]}
    ]

    case :ets.select_replace(slots, match_spec) do
      1 -> {:ok, offset + 1}
      0 -> reserve(slots, ring_ref, sequence, start, offset + 1)
    end
  end

  defp notify_once(owner, wakeup) do
    case :atomics.compare_exchange(wakeup, 1, 0, 1) do
      current when current in [:ok, 0] ->
        send(owner, :control_ready)
        {1, 1}

      _already_pending ->
        {0, 1}
    end
  end

  defp ring_owner(slots, ring_ref, wakeup, state) do
    receive do
      :control_ready ->
        {drain_metrics, occupied?} = drain_slots(slots, ring_ref, wakeup)
        state = merge_owner(state, drain_metrics, 1)

        if occupied? do
          case :atomics.compare_exchange(wakeup, 1, 0, 1) do
            current when current in [:ok, 0] -> send(self(), :control_ready)
            _ -> :ok
          end
        end

        ring_owner(slots, ring_ref, wakeup, state)

      {:settle, caller, ref} ->
        {drain_metrics, occupied?} = drain_slots(slots, ring_ref, wakeup)
        state = merge_owner(state, drain_metrics, 0)

        if occupied? do
          send(self(), {:settle, caller, ref})
          ring_owner(slots, ring_ref, wakeup, state)
        else
          send(caller, {:settled, ref, finalize_owner(state)})
          ring_owner(slots, ring_ref, wakeup, state)
        end

      :stop ->
        :ok
    end
  end

  defp drain_slots(slots, ring_ref, wakeup) do
    occupied = occupied(slots, ring_ref)

    consumed =
      occupied
      |> Enum.sort_by(fn {_index, {_ref, {sequence, _signal}}} -> sequence end)
      |> Enum.count(fn {index, {^ring_ref, value}} ->
        match_spec = [
          {{index, {ring_ref, value}}, [], [{:const, {index, {ring_ref, :empty}}}]}
        ]

        :ets.select_replace(slots, match_spec) == 1
      end)

    :ok = :atomics.put(wakeup, 1, 0)
    remaining? = occupied(slots, ring_ref) != []

    metrics = %{
      ets_ops: @capacity * 2 + consumed,
      atomics_ops: 1,
      consumed: consumed
    }

    {metrics, remaining?}
  end

  defp occupied(slots, ring_ref) do
    Enum.flat_map(0..(@capacity - 1), fn index ->
      case :ets.lookup(slots, index) do
        [{^index, {^ring_ref, {_sequence, _signal}} = value}] -> [{index, value}]
        _ -> []
      end
    end)
  end

  defp settle_owner(context) do
    started = System.monotonic_time(:microsecond)
    ref = make_ref()
    send(context.owner, {:settle, self(), ref})

    owner =
      receive do
        {:settled, ^ref, metrics} -> metrics
      after
        30_000 -> raise "ring owner did not settle"
      end

    {owner, System.monotonic_time(:microsecond) - started}
  end

  defp suspended_owner do
    receive do
      :stop -> :ok
    end
  end

  defp stop_ring(context) do
    send(context.owner, :stop)
    :ets.delete(context.meta)
    :ets.delete(context.slots)
  end

  defp ring_stats(context) do
    %{
      degraded?: :atomics.get(context.degraded, 1) == 1,
      drops: :atomics.get(context.drops, 1),
      occupied: length(occupied(context.slots, context.ring_ref))
    }
  end

  defp result(kind, mode, count, producers, elapsed_us, producer, extra) do
    total_reductions = producer.reductions + Keyword.fetch!(extra, :owner_reductions)
    total_ets = producer.ets_ops + Keyword.fetch!(extra, :owner_ets_ops)
    total_atomics = producer.atomics_ops + Keyword.fetch!(extra, :owner_atomics_ops)

    %{
      kind: kind,
      mode: mode,
      reports: count,
      producers: producers,
      elapsed_us: elapsed_us,
      reports_per_second: count * 1_000_000 / max(elapsed_us, 1),
      reductions_per_report: total_reductions / count,
      ets_ops_per_report: total_ets / count,
      atomics_ops_per_report: total_atomics / count,
      producer_messages: producer.messages,
      owner_wakes: Keyword.fetch!(extra, :owner_wakes),
      accepted: Keyword.fetch!(extra, :accepted),
      drops: Keyword.fetch!(extra, :drops),
      degraded?: Keyword.fetch!(extra, :degraded?),
      admission: if(Keyword.fetch!(extra, :degraded?), do: :exceptional, else: :ordinary)
    }
  end

  defp zero_metrics do
    %{accepted: 0, drops: 0, ets_ops: 0, atomics_ops: 0, messages: 0, reductions: 0}
  end

  defp merge_metrics(left, right) do
    Map.merge(left, right, fn _key, a, b -> a + b end)
  end

  defp owner_zero do
    %{
      wakes: 0,
      ets_ops: 0,
      atomics_ops: 0,
      consumed: 0,
      initial_reductions: reductions()
    }
  end

  defp merge_owner(state, metrics, wakes) do
    %{
      state
      | wakes: state.wakes + wakes,
        ets_ops: state.ets_ops + metrics.ets_ops,
        atomics_ops: state.atomics_ops + metrics.atomics_ops,
        consumed: state.consumed + metrics.consumed
    }
  end

  defp finalize_owner(state) do
    %{
      wakes: state.wakes,
      ets_ops: state.ets_ops,
      atomics_ops: state.atomics_ops,
      consumed: state.consumed,
      reductions: reductions() - state.initial_reductions
    }
  end

  defp reductions do
    {:reductions, reductions} = Process.info(self(), :reductions)
    reductions
  end
end

defmodule Lasso.Core.Support.CircuitBreaker.ControlRing do
  @moduledoc false

  alias Lasso.Core.Support.CircuitBreaker.{AdmissionReceipt, Snapshot, Storage}

  @default_capacity 64
  @maximum_capacity 1_024
  @success_refresh_retries 8
  @empty :empty
  @wakeup_slot 1
  @needs_success_slot 2

  @type base_signal :: :success | {:failure, atom(), boolean()} | :neutral
  @type signal :: base_signal() | {:route_generation, non_neg_integer(), base_signal()}

  @spec capacity(term()) :: pos_integer()
  def capacity(value) when is_integer(value) and value > 0, do: min(value, @maximum_capacity)
  def capacity(_value), do: @default_capacity

  @spec initialize({String.t(), :http | :ws}, pos_integer(), pos_integer(), pid(), keyword()) ::
          :ok
  def initialize(breaker_id, generation, epoch, owner_pid, opts \\ []) do
    capacity = capacity(Keyword.get(opts, :capacity, @default_capacity))
    wakeup = :atomics.new(2, signed: false)

    {failure_drops, success_drops, acknowledged_failure_drops} =
      previous_drop_counts(breaker_id)

    diagnostics = :atomics.new(3, signed: false)
    :atomics.put(diagnostics, 1, failure_drops)
    :atomics.put(diagnostics, 2, success_drops)
    :atomics.put(diagnostics, 3, acknowledged_failure_drops)
    ring_ref = make_ref()

    reset_slots(breaker_id, capacity, ring_ref)

    true =
      :ets.insert(
        Storage.control_meta_table(),
        {breaker_id, generation, epoch, owner_pid, capacity, wakeup, diagnostics, ring_ref}
      )

    :ok
  end

  @spec enqueue(AdmissionReceipt.t(), signal()) :: :ok | {:error, :saturated | :stale}
  def enqueue(%AdmissionReceipt{} = receipt, signal) do
    case :ets.lookup(Storage.control_meta_table(), receipt.breaker_id) do
      [meta] -> enqueue_with_meta(receipt, signal, meta)
      [] -> {:error, :stale}
    end
  rescue
    ArgumentError -> {:error, :stale}
  end

  @doc false
  @spec publish_success_requirement(
          {String.t(), :http | :ws},
          non_neg_integer(),
          pos_integer(),
          boolean()
        ) :: :ok | {:error, :stale}
  def publish_success_requirement(breaker_id, generation, epoch, required?)
      when is_boolean(required?) do
    case :ets.lookup(Storage.control_meta_table(), breaker_id) do
      [{^breaker_id, ^generation, ^epoch, _owner_pid, _capacity, wakeup, _diagnostics, _ring_ref}] ->
        :atomics.put(wakeup, @needs_success_slot, if(required?, do: 1, else: 0))
        :ok

      _other ->
        {:error, :stale}
    end
  rescue
    ArgumentError -> {:error, :stale}
  end

  @spec drain({String.t(), :http | :ws}, non_neg_integer(), pos_integer(), pos_integer()) ::
          [signal()]
  def drain(breaker_id, limit, generation, epoch) do
    case :ets.lookup(Storage.control_meta_table(), breaker_id) do
      [
        {^breaker_id, ^generation, ^epoch, _owner_pid, capacity, wakeup, _diagnostics, ring_ref}
      ] ->
        signals = take_slots(breaker_id, min(limit, capacity), capacity, ring_ref)

        :atomics.put(wakeup, @wakeup_slot, 0)
        maybe_notify_remaining(breaker_id, generation, epoch, capacity, wakeup, ring_ref)
        signals

      _ ->
        []
    end
  rescue
    ArgumentError -> []
  end

  @spec stats({String.t(), :http | :ws}) :: map() | {:error, :not_found}
  def stats(breaker_id) do
    case :ets.lookup(Storage.control_meta_table(), breaker_id) do
      [
        {^breaker_id, generation, epoch, owner_pid, capacity, wakeup, diagnostics, ring_ref}
      ] ->
        failure_drops = :atomics.get(diagnostics, 1)
        success_drops = :atomics.get(diagnostics, 2)
        acknowledged_failure_drops = acknowledged_failure_drops(diagnostics)

        %{
          generation: generation,
          epoch: epoch,
          capacity: capacity,
          occupied: occupied_count(breaker_id, capacity, ring_ref),
          wakeup_pending: :atomics.get(wakeup, @wakeup_slot),
          dropped: failure_drops + success_drops,
          failure_dropped: failure_drops,
          success_dropped: success_drops,
          failure_drop_acknowledged: acknowledged_failure_drops,
          failure_drop_pending?: failure_drops > acknowledged_failure_drops,
          success_marker?: success_marker?(breaker_id, ring_ref),
          owner_pid: owner_pid
        }

      [] ->
        {:error, :not_found}
    end
  end

  defp enqueue_with_meta(
         %AdmissionReceipt{breaker_id: breaker_id, generation: generation, epoch: epoch} =
           receipt,
         signal,
         {breaker_id, generation, epoch, owner_pid, capacity, wakeup, diagnostics, ring_ref}
       ) do
    case signal_kind(signal) do
      :success ->
        enqueue_success(
          receipt,
          signal,
          owner_pid,
          wakeup,
          diagnostics,
          ring_ref
        )

      :failure ->
        enqueue_failure(receipt, signal, owner_pid, capacity, wakeup, diagnostics, ring_ref)

      :neutral ->
        :ok
    end
  end

  defp enqueue_with_meta(_receipt, _signal, _meta), do: {:error, :stale}

  defp enqueue_success(
         receipt,
         signal,
         owner_pid,
         wakeup,
         diagnostics,
         ring_ref
       ) do
    if success_required?(wakeup) do
      reserve_success(receipt, signal, owner_pid, wakeup, diagnostics, ring_ref)
    else
      :ok
    end
  end

  defp enqueue_failure(receipt, signal, owner_pid, capacity, wakeup, diagnostics, ring_ref) do
    case reserve(receipt, signal, capacity, ring_ref) do
      :ok ->
        notify_once(owner_pid, receipt, wakeup)
        :ok

      :full ->
        :atomics.add(diagnostics, 1, 1)
        degrade(receipt)
        notify_once(owner_pid, receipt, wakeup)
        {:error, :saturated}
    end
  end

  defp reserve_success(
         receipt,
         signal,
         owner_pid,
         wakeup,
         diagnostics,
         ring_ref
       ) do
    case reserve_success_slot(receipt, signal, ring_ref, @success_refresh_retries) do
      result when result in [:ok, :refreshed] ->
        notify_once(owner_pid, receipt, wakeup)
        :ok

      :covered ->
        :ok

      failure when failure in [:refresh_failed, :stale] ->
        :atomics.add(diagnostics, 2, 1)
        notify_once(owner_pid, receipt, wakeup)
        {:error, if(failure == :stale, do: :stale, else: :saturated)}
    end
  end

  @spec success_required?(:atomics.atomics_ref()) :: boolean()
  defp success_required?(wakeup), do: :atomics.get(wakeup, @needs_success_slot) == 1

  defp reserve(receipt, signal, capacity, ring_ref) do
    sequence = System.unique_integer([:positive, :monotonic])
    start = rem(sequence, capacity)

    reserve_slot(
      receipt.breaker_id,
      signal,
      receipt.generation,
      receipt.epoch,
      sequence,
      start,
      capacity,
      ring_ref
    )
  end

  defp reserve_success_slot(receipt, signal, ring_ref, retries) do
    key = {receipt.breaker_id, :success}
    sequence = System.unique_integer([:positive, :monotonic])
    value = {sequence, receipt.generation, receipt.epoch, signal}

    do_reserve_success_slot(key, value, ring_ref, retries)
  end

  defp do_reserve_success_slot(key, value, ring_ref, retries) when retries > 0 do
    match_spec = [{{key, {ring_ref, @empty}}, [], [{:const, {key, {ring_ref, value}}}]}]

    case :ets.select_replace(Storage.control_table(), match_spec) do
      1 ->
        :ok

      0 ->
        refresh_success_slot(key, value, ring_ref, retries)
    end
  end

  defp do_reserve_success_slot(_key, _value, _ring_ref, 0), do: :refresh_failed

  defp refresh_success_slot(
         key,
         {sequence, generation, epoch, _signal} = value,
         ring_ref,
         retries
       ) do
    case :ets.lookup(Storage.control_table(), key) do
      [{^key, {^ring_ref, {current_sequence, ^generation, ^epoch, _current_signal} = current}}]
      when current_sequence < sequence ->
        match_spec = [{{key, {ring_ref, current}}, [], [{:const, {key, {ring_ref, value}}}]}]

        case :ets.select_replace(Storage.control_table(), match_spec) do
          1 -> :refreshed
          0 -> do_reserve_success_slot(key, value, ring_ref, retries - 1)
        end

      [{^key, {^ring_ref, {current_sequence, ^generation, ^epoch, _current_signal}}}]
      when current_sequence >= sequence ->
        :covered

      [{^key, {^ring_ref, @empty}}] ->
        do_reserve_success_slot(key, value, ring_ref, retries - 1)

      _other ->
        :stale
    end
  end

  @doc false
  @spec publish_without_notify(AdmissionReceipt.t(), signal()) :: :ok | {:error, :stale}
  def publish_without_notify(
        %AdmissionReceipt{breaker_id: breaker_id, generation: generation, epoch: epoch} = receipt,
        signal
      ) do
    case :ets.lookup(Storage.control_meta_table(), receipt.breaker_id) do
      [
        {^breaker_id, ^generation, ^epoch, _owner_pid, capacity, wakeup, diagnostics, ring_ref}
      ] ->
        case signal_kind(signal) do
          :success ->
            if success_required?(wakeup) do
              case reserve_success_slot(receipt, signal, ring_ref, @success_refresh_retries) do
                result when result in [:ok, :refreshed, :covered] ->
                  :ok

                failure when failure in [:refresh_failed, :stale] ->
                  :atomics.add(diagnostics, 2, 1)
                  failure
              end
            else
              :ok
            end

          :failure ->
            reserve(receipt, signal, capacity, ring_ref)

          :neutral ->
            :ok
        end
        |> case do
          :ok -> :ok
          :refresh_failed -> {:error, :stale}
          :stale -> {:error, :stale}
          :full -> {:error, :stale}
        end

      _ ->
        {:error, :stale}
    end
  rescue
    ArgumentError -> {:error, :stale}
  end

  @doc false
  @spec publish_after_barrier_without_notify(
          AdmissionReceipt.t(),
          signal(),
          pid(),
          reference()
        ) :: :ok | {:error, :stale}
  def publish_after_barrier_without_notify(
        %AdmissionReceipt{breaker_id: breaker_id, generation: generation, epoch: epoch},
        signal,
        observer,
        release_ref
      )
      when is_pid(observer) and is_reference(release_ref) do
    case :ets.lookup(Storage.control_meta_table(), breaker_id) do
      [
        {^breaker_id, ^generation, ^epoch, _owner_pid, capacity, _wakeup, _diagnostics, ring_ref}
      ] ->
        sequence = System.unique_integer([:positive, :monotonic])
        send(observer, {:control_publish_reserved, self(), release_ref})

        receive do
          ^release_ref -> :ok
        end

        start = rem(sequence, capacity)

        case reserve_slot(
               breaker_id,
               signal,
               generation,
               epoch,
               sequence,
               start,
               capacity,
               ring_ref
             ) do
          :ok -> :ok
          :full -> {:error, :stale}
        end

      _ ->
        {:error, :stale}
    end
  rescue
    ArgumentError -> {:error, :stale}
  end

  @spec audit_required?({String.t(), :http | :ws}, pos_integer(), pos_integer()) :: boolean()
  def audit_required?(breaker_id, generation, epoch) do
    case :ets.lookup(Storage.control_meta_table(), breaker_id) do
      [
        {^breaker_id, ^generation, ^epoch, _owner_pid, capacity, _wakeup, diagnostics, ring_ref}
      ] ->
        occupied_count(breaker_id, capacity, ring_ref) > 0 or
          failure_drop_pending?(diagnostics)

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end

  @spec failure_drop_pending?({String.t(), :http | :ws}, pos_integer(), pos_integer()) ::
          boolean()
  def failure_drop_pending?(breaker_id, generation, epoch) do
    case :ets.lookup(Storage.control_meta_table(), breaker_id) do
      [{^breaker_id, ^generation, ^epoch, _owner, _capacity, _wakeup, diagnostics, _ring_ref}] ->
        failure_drop_pending?(diagnostics)

      _other ->
        false
    end
  rescue
    ArgumentError -> false
  end

  @spec acknowledge_failure_degradation(
          {String.t(), :http | :ws},
          pos_integer(),
          pos_integer()
        ) :: :ok | {:error, :stale}
  def acknowledge_failure_degradation(breaker_id, generation, epoch) do
    case :ets.lookup(Storage.control_meta_table(), breaker_id) do
      [{^breaker_id, ^generation, ^epoch, _owner, _capacity, _wakeup, diagnostics, _ring_ref}] ->
        :atomics.put(diagnostics, 3, :atomics.get(diagnostics, 1))
        :ok

      _other ->
        {:error, :stale}
    end
  rescue
    ArgumentError -> {:error, :stale}
  end

  defp reserve_slot(breaker_id, signal, generation, epoch, sequence, start, capacity, ring_ref) do
    Enum.reduce_while(0..(capacity - 1), :full, fn offset, _acc ->
      index = rem(start + offset, capacity)
      key = {breaker_id, index}
      value = {sequence, generation, epoch, signal}
      match_spec = [{{key, {ring_ref, @empty}}, [], [{:const, {key, {ring_ref, value}}}]}]

      case :ets.select_replace(Storage.control_table(), match_spec) do
        1 -> {:halt, :ok}
        0 -> {:cont, :full}
      end
    end)
  end

  defp notify_once(owner_pid, receipt, wakeup) do
    case :atomics.compare_exchange(wakeup, @wakeup_slot, 0, 1) do
      value when value in [:ok, 0] ->
        send(
          owner_pid,
          {:breaker_control_ready, receipt.breaker_id, receipt.generation, receipt.epoch}
        )

      _already_pending ->
        :ok
    end
  end

  defp take_slots(breaker_id, limit, capacity, ring_ref) do
    breaker_id
    |> occupied_slots(capacity, ring_ref)
    |> Enum.sort_by(fn {_key, {_ring_ref, {sequence, _generation, _epoch, _signal}}} ->
      sequence
    end)
    |> Enum.take(limit)
    |> Enum.flat_map(fn {key, {^ring_ref, {_sequence, _generation, _epoch, signal} = value}} ->
      match_spec = [{{key, {ring_ref, value}}, [], [{:const, {key, {ring_ref, @empty}}}]}]

      if :ets.select_replace(Storage.control_table(), match_spec) == 1, do: [signal], else: []
    end)
  end

  defp maybe_notify_remaining(breaker_id, generation, epoch, capacity, wakeup, ring_ref) do
    if occupied_count(breaker_id, capacity, ring_ref) > 0 do
      case :ets.lookup(Storage.control_meta_table(), breaker_id) do
        [
          {^breaker_id, ^generation, ^epoch, owner_pid, ^capacity, ^wakeup, _diagnostics,
           ^ring_ref}
        ] ->
          receipt = %AdmissionReceipt{
            breaker_id: breaker_id,
            kind: :closed,
            generation: generation,
            epoch: epoch,
            owner_pid: owner_pid
          }

          notify_once(owner_pid, receipt, wakeup)

        _ ->
          :ok
      end
    end
  end

  defp occupied_count(breaker_id, capacity, ring_ref) do
    breaker_id |> occupied_slots(capacity, ring_ref) |> length()
  end

  defp occupied_slots(breaker_id, capacity, ring_ref) do
    Enum.flat_map([:success | Enum.to_list(0..(capacity - 1))], fn slot ->
      key = {breaker_id, slot}

      case :ets.lookup(Storage.control_table(), key) do
        [{^key, {^ring_ref, {_sequence, _generation, _epoch, _signal}} = value}] -> [{key, value}]
        _ -> []
      end
    end)
  end

  defp degrade(receipt) do
    case Snapshot.lookup(receipt.breaker_id) do
      {:ok, %Snapshot{generation: generation, epoch: epoch, control_health: :healthy} = snapshot}
      when generation == receipt.generation and epoch == receipt.epoch ->
        degraded = %{snapshot | control_health: :degraded}

        :ets.select_replace(Storage.snapshot_table(), [
          {{receipt.breaker_id, snapshot}, [], [{:const, {receipt.breaker_id, degraded}}]}
        ])

      _ ->
        :ok
    end
  end

  @spec delete({String.t(), :http | :ws}) :: :ok
  def delete(breaker_id) do
    capacity = previous_capacity(breaker_id)
    Enum.each(0..(capacity - 1), &:ets.delete(Storage.control_table(), {breaker_id, &1}))
    :ets.delete(Storage.control_table(), {breaker_id, :success})
    :ets.delete(Storage.control_meta_table(), breaker_id)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp reset_slots(breaker_id, capacity, ring_ref) do
    reset_capacity = max(capacity, previous_capacity(breaker_id))

    Enum.each(0..(reset_capacity - 1), fn index ->
      :ets.delete(Storage.control_table(), {breaker_id, index})
    end)

    Enum.each(0..(capacity - 1), fn index ->
      :ets.insert(Storage.control_table(), {{breaker_id, index}, {ring_ref, @empty}})
    end)

    :ets.insert(Storage.control_table(), {{breaker_id, :success}, {ring_ref, @empty}})
  end

  defp previous_capacity(breaker_id) do
    case :ets.lookup(Storage.control_meta_table(), breaker_id) do
      [{^breaker_id, _generation, _epoch, _owner, capacity, _wakeup, _diagnostics, _ring_ref}]
      when is_integer(capacity) and capacity > 0 ->
        min(capacity, @maximum_capacity)

      _ ->
        @default_capacity
    end
  end

  defp previous_drop_counts(breaker_id) do
    case :ets.lookup(Storage.control_meta_table(), breaker_id) do
      [{^breaker_id, _generation, _epoch, _owner, _capacity, _wakeup, diagnostics, _ring_ref}] ->
        case :atomics.info(diagnostics) do
          %{size: size} when size >= 3 ->
            {
              :atomics.get(diagnostics, 1),
              :atomics.get(diagnostics, 2),
              :atomics.get(diagnostics, 3)
            }

          %{size: size} when size >= 2 ->
            {:atomics.get(diagnostics, 1), :atomics.get(diagnostics, 2), 0}

          _ ->
            {:atomics.get(diagnostics, 1), 0, 0}
        end

      _ ->
        {0, 0, 0}
    end
  rescue
    ArgumentError -> {0, 0, 0}
  end

  defp failure_drop_pending?(diagnostics) do
    :atomics.get(diagnostics, 1) > acknowledged_failure_drops(diagnostics)
  end

  defp acknowledged_failure_drops(diagnostics) do
    case :atomics.info(diagnostics) do
      %{size: size} when size >= 3 -> :atomics.get(diagnostics, 3)
      _legacy -> 0
    end
  end

  defp signal_kind({:route_generation, _generation, signal}), do: signal_kind(signal)

  defp signal_kind({:failure, category, penalty?})
       when is_atom(category) and is_boolean(penalty?),
       do: :failure

  defp signal_kind(:success), do: :success
  defp signal_kind(:neutral), do: :neutral

  defp success_marker?(breaker_id, ring_ref) do
    case :ets.lookup(Storage.control_table(), {breaker_id, :success}) do
      [{{^breaker_id, :success}, {^ring_ref, {_sequence, _generation, _epoch, _signal}}}] -> true
      _ -> false
    end
  end
end

defmodule Lasso.Core.Support.CircuitBreaker.ControlRing do
  @moduledoc false

  alias Lasso.Core.Support.CircuitBreaker.{AdmissionReceipt, Snapshot, Storage}

  @default_capacity 64
  @maximum_capacity 1_024
  @empty :empty

  @type signal :: :success | {:failure, atom(), boolean()} | :neutral

  @spec capacity(term()) :: pos_integer()
  def capacity(value) when is_integer(value) and value > 0, do: min(value, @maximum_capacity)
  def capacity(_value), do: @default_capacity

  @spec initialize({String.t(), :http | :ws}, pos_integer(), pos_integer(), pid(), keyword()) ::
          :ok
  def initialize(breaker_id, generation, epoch, owner_pid, opts \\ []) do
    capacity = capacity(Keyword.get(opts, :capacity, @default_capacity))
    head = :atomics.new(1, signed: false)
    tail = :atomics.new(1, signed: false)
    wakeup = :atomics.new(1, signed: false)
    diagnostics = :atomics.new(1, signed: false)
    ring_ref = make_ref()

    reset_slots(breaker_id, capacity, ring_ref)

    true =
      :ets.insert(
        Storage.control_meta_table(),
        {breaker_id, generation, epoch, owner_pid, capacity, head, tail, wakeup, diagnostics,
         ring_ref}
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

  @spec drain({String.t(), :http | :ws}, non_neg_integer(), pos_integer(), pos_integer()) ::
          [signal()]
  def drain(breaker_id, limit, generation, epoch) do
    case :ets.lookup(Storage.control_meta_table(), breaker_id) do
      [
        {^breaker_id, ^generation, ^epoch, _owner_pid, capacity, head, tail, wakeup, _diagnostics,
         ring_ref}
      ] ->
        signals = take_slots(breaker_id, min(limit, capacity), capacity, head, ring_ref)
        :atomics.put(wakeup, 1, 0)

        maybe_notify_remaining(
          breaker_id,
          generation,
          epoch,
          capacity,
          head,
          tail,
          wakeup,
          ring_ref
        )

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
        {^breaker_id, generation, epoch, owner_pid, capacity, head, tail, wakeup, diagnostics,
         _ring_ref}
      ] ->
        %{
          generation: generation,
          epoch: epoch,
          capacity: capacity,
          occupied: min(max(:atomics.get(tail, 1) - :atomics.get(head, 1), 0), capacity),
          wakeup_pending: :atomics.get(wakeup, 1),
          dropped: :atomics.get(diagnostics, 1),
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
         {breaker_id, generation, epoch, owner_pid, capacity, head, tail, wakeup, diagnostics,
          ring_ref}
       ) do
    case reserve_ticket(head, tail, capacity) do
      {:ok, ticket} ->
        key = {breaker_id, rem(ticket, capacity)}
        value = {ticket, generation, epoch, signal}
        match_spec = [{{key, {ring_ref, @empty}}, [], [{:const, {key, {ring_ref, value}}}]}]

        case :ets.select_replace(Storage.control_table(), match_spec) do
          1 ->
            notify_once(owner_pid, breaker_id, generation, epoch, wakeup)
            :ok

          0 ->
            {:error, :stale}
        end

      :full ->
        :atomics.add(diagnostics, 1, 1)
        degrade(receipt)
        {:error, :saturated}
    end
  end

  defp enqueue_with_meta(_receipt, _signal, _meta), do: {:error, :stale}

  defp reserve_ticket(head, tail, capacity) do
    head_value = :atomics.get(head, 1)
    tail_value = :atomics.get(tail, 1)

    cond do
      tail_value - head_value >= capacity ->
        :full

      :atomics.compare_exchange(tail, 1, tail_value, tail_value + 1) in [:ok, tail_value] ->
        {:ok, tail_value}

      true ->
        reserve_ticket(head, tail, capacity)
    end
  end

  defp notify_once(owner_pid, breaker_id, generation, epoch, wakeup) do
    case :atomics.compare_exchange(wakeup, 1, 0, 1) do
      value when value in [:ok, 0] ->
        send(owner_pid, {:breaker_control_ready, breaker_id, generation, epoch})

      _already_pending ->
        :ok
    end
  end

  defp take_slots(_breaker_id, 0, _capacity, _head, _ring_ref), do: []

  defp take_slots(breaker_id, limit, capacity, head, ring_ref) do
    ticket = :atomics.get(head, 1)
    key = {breaker_id, rem(ticket, capacity)}

    case :ets.lookup(Storage.control_table(), key) do
      [{^key, {^ring_ref, {^ticket, _generation, _epoch, signal} = value}}] ->
        match_spec = [{{key, {ring_ref, value}}, [], [{:const, {key, {ring_ref, @empty}}}]}]

        case :ets.select_replace(Storage.control_table(), match_spec) do
          1 ->
            :atomics.add(head, 1, 1)
            [signal | take_slots(breaker_id, limit - 1, capacity, head, ring_ref)]

          0 ->
            []
        end

      _ ->
        []
    end
  end

  defp maybe_notify_remaining(
         breaker_id,
         generation,
         epoch,
         capacity,
         head,
         tail,
         wakeup,
         ring_ref
       ) do
    ticket = :atomics.get(head, 1)
    key = {breaker_id, rem(ticket, capacity)}

    if :atomics.get(tail, 1) > ticket and
         match?(
           [{^key, {^ring_ref, {^ticket, _, _, _}}}],
           :ets.lookup(Storage.control_table(), key)
         ) do
      case :ets.lookup(Storage.control_meta_table(), breaker_id) do
        [
          {^breaker_id, ^generation, ^epoch, owner_pid, ^capacity, ^head, ^tail, ^wakeup,
           _diagnostics, ^ring_ref}
        ] ->
          notify_once(owner_pid, breaker_id, generation, epoch, wakeup)

        _ ->
          :ok
      end
    end
  end

  defp degrade(receipt) do
    case Snapshot.lookup(receipt.breaker_id) do
      {:ok, %Snapshot{generation: generation, epoch: epoch, control_health: :healthy} = snapshot}
      when generation == receipt.generation and epoch == receipt.epoch ->
        degraded = %{snapshot | control_health: :degraded}

        :ets.select_replace(Storage.snapshot_table(), [
          {{receipt.breaker_id, snapshot}, [], [{:const, {receipt.breaker_id, degraded}}]}
        ])

        :telemetry.execute(
          [:lasso, :circuit_breaker, :control_saturated],
          %{count: 1},
          %{breaker_id: receipt.breaker_id, generation: generation, epoch: epoch}
        )

      _ ->
        :ok
    end
  end

  @spec delete({String.t(), :http | :ws}) :: :ok
  def delete(breaker_id) do
    capacity = previous_capacity(breaker_id)
    Enum.each(0..(capacity - 1), &:ets.delete(Storage.control_table(), {breaker_id, &1}))
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
  end

  defp previous_capacity(breaker_id) do
    case :ets.lookup(Storage.control_meta_table(), breaker_id) do
      [
        {^breaker_id, _generation, _epoch, _owner, capacity, _head, _tail, _wakeup, _diagnostics,
         _ring_ref}
      ]
      when is_integer(capacity) and capacity > 0 ->
        min(capacity, @maximum_capacity)

      _ ->
        @default_capacity
    end
  end
end

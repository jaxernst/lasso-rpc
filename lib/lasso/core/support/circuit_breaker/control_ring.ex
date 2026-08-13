defmodule Lasso.Core.Support.CircuitBreaker.ControlRing do
  @moduledoc false

  alias Lasso.Core.Support.CircuitBreaker.{AdmissionReceipt, Snapshot, Storage}

  @default_capacity 64
  @empty :empty

  @type signal :: :success | {:failure, atom(), boolean()} | :neutral

  @spec initialize({String.t(), :http | :ws}, pos_integer(), pos_integer(), pid(), keyword()) ::
          :ok
  def initialize(breaker_id, generation, epoch, owner_pid, opts \\ []) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)
    wakeup = :atomics.new(1, signed: false)
    diagnostics = :atomics.new(1, signed: false)

    clear_slots(breaker_id)

    Enum.each(0..(capacity - 1), fn index ->
      true = :ets.insert(Storage.control_table(), {{breaker_id, index}, @empty})
    end)

    true =
      :ets.insert(
        Storage.control_meta_table(),
        {breaker_id, generation, epoch, owner_pid, capacity, wakeup, diagnostics}
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
      [{^breaker_id, ^generation, ^epoch, _owner_pid, capacity, wakeup, _diagnostics}] ->
        signals = take_slots(breaker_id, min(limit, capacity), capacity)
        :atomics.put(wakeup, 1, 0)
        maybe_notify_remaining(breaker_id, generation, epoch, capacity, wakeup)
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
      [{^breaker_id, generation, epoch, owner_pid, capacity, wakeup, diagnostics}] ->
        %{
          generation: generation,
          epoch: epoch,
          capacity: capacity,
          occupied: occupied_count(breaker_id, capacity),
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
         {breaker_id, generation, epoch, owner_pid, capacity, wakeup, diagnostics}
       ) do
    start = rem(System.unique_integer([:positive, :monotonic]), capacity)

    case reserve_slot(breaker_id, signal, generation, epoch, start, capacity) do
      :ok ->
        notify_once(owner_pid, breaker_id, generation, epoch, wakeup)
        :ok

      :full ->
        :atomics.add(diagnostics, 1, 1)
        degrade(receipt)
        {:error, :saturated}
    end
  end

  defp enqueue_with_meta(_receipt, _signal, _meta), do: {:error, :stale}

  defp reserve_slot(breaker_id, signal, generation, epoch, start, capacity) do
    Enum.reduce_while(0..(capacity - 1), :full, fn offset, _acc ->
      index = rem(start + offset, capacity)
      key = {breaker_id, index}
      value = {generation, epoch, signal}

      match_spec = [{{key, @empty}, [], [{:const, {key, value}}]}]

      case :ets.select_replace(Storage.control_table(), match_spec) do
        1 -> {:halt, :ok}
        0 -> {:cont, :full}
      end
    end)
  end

  defp notify_once(owner_pid, breaker_id, generation, epoch, wakeup) do
    case :atomics.compare_exchange(wakeup, 1, 0, 1) do
      value when value in [:ok, 0] ->
        send(owner_pid, {:breaker_control_ready, breaker_id, generation, epoch})

      _already_pending ->
        :ok
    end
  end

  defp take_slots(breaker_id, limit, capacity) do
    Enum.reduce_while(0..(capacity - 1), [], fn index, signals ->
      if length(signals) >= limit do
        {:halt, Enum.reverse(signals)}
      else
        key = {breaker_id, index}

        case :ets.lookup(Storage.control_table(), key) do
          [{^key, {_generation, _epoch, signal} = value}] ->
            match_spec = [{{key, value}, [], [{:const, {key, @empty}}]}]

            case :ets.select_replace(Storage.control_table(), match_spec) do
              1 -> {:cont, [signal | signals]}
              0 -> {:cont, signals}
            end

          _ ->
            {:cont, signals}
        end
      end
    end)
  end

  defp maybe_notify_remaining(breaker_id, generation, epoch, capacity, wakeup) do
    if occupied_count(breaker_id, capacity) > 0 do
      case :ets.lookup(Storage.control_meta_table(), breaker_id) do
        [{^breaker_id, ^generation, ^epoch, owner_pid, ^capacity, ^wakeup, _diagnostics}] ->
          notify_once(owner_pid, breaker_id, generation, epoch, wakeup)

        _ ->
          :ok
      end
    end
  end

  defp occupied_count(breaker_id, capacity) do
    Enum.count(0..(capacity - 1), fn index ->
      case :ets.lookup(Storage.control_table(), {breaker_id, index}) do
        [{{^breaker_id, ^index}, @empty}] -> false
        [{{^breaker_id, ^index}, _signal}] -> true
        [] -> false
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

        :telemetry.execute(
          [:lasso, :circuit_breaker, :control_saturated],
          %{count: 1},
          %{breaker_id: receipt.breaker_id, generation: generation, epoch: epoch}
        )

      _ ->
        :ok
    end
  end

  defp clear_slots(breaker_id) do
    :ets.select_delete(Storage.control_table(), [
      {{{breaker_id, :_}, :_}, [], [true]}
    ])
  end
end

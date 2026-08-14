defmodule Lasso.Prototypes.BreakerSuccessEpoch.Model do
  @moduledoc """
  PROTOTYPE: pure breaker reducer used to compare the bounded control ring with
  a closed-success epoch. It has no runtime dependencies and is not production code.
  """

  @default_thresholds %{timeout: 3, rate_limit: 2, server_error: 4}

  def new(kind, opts \\ []) when kind in [:ring, :epoch] do
    %{
      kind: kind,
      state: :closed,
      generation: 1,
      owner_epoch: 1,
      failure_count: 0,
      success_count: 0,
      success_threshold: Keyword.get(opts, :success_threshold, 2),
      failure_threshold: Keyword.get(opts, :failure_threshold, 5),
      category_thresholds: Keyword.get(opts, :category_thresholds, @default_thresholds),
      opened_by: nil,
      control_health: :healthy,
      capacity: Keyword.get(opts, :capacity, 1_024),
      queue: [],
      next_sequence: 0,
      wake_pending?: false,
      wakes: 0,
      drops: 0,
      success_epoch: 0,
      applied_success_epoch: 0,
      half_open_capacity: Keyword.get(opts, :half_open_capacity, 1),
      leases: %{},
      next_lease: 0,
      stale_reports: 0
    }
  end

  def receipt(state, kind \\ :closed) do
    %{
      kind: kind,
      generation: state.generation,
      owner_epoch: state.owner_epoch
    }
  end

  def report(%{kind: :ring} = state, receipt, signal),
    do: enqueue_ring(state, receipt, signal)

  def report(%{kind: :epoch} = state, receipt, :success) do
    if current_closed_receipt?(state, receipt) do
      %{state | success_epoch: state.success_epoch + 1}
    else
      stale(state)
    end
  end

  def report(%{kind: :epoch} = state, receipt, :neutral) do
    if current_closed_receipt?(state, receipt), do: state, else: stale(state)
  end

  def report(%{kind: :epoch} = state, receipt, {:failure, _category} = signal) do
    if current_closed_receipt?(state, receipt) do
      entry = {
        state.next_sequence,
        receipt.generation,
        receipt.owner_epoch,
        state.success_epoch,
        signal
      }

      enqueue_bounded(%{state | next_sequence: state.next_sequence + 1}, entry)
    else
      stale(state)
    end
  end

  def report(state, _receipt, _signal), do: stale(state)

  def drain(%{control_health: :degraded} = state), do: enter_probation(state)

  def drain(%{kind: :ring} = state) do
    state.queue
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(%{state | queue: [], wake_pending?: false}, fn
      {_sequence, generation, owner_epoch, signal}, acc ->
        if generation == acc.generation and owner_epoch == acc.owner_epoch do
          apply_signal(acc, signal)
        else
          acc
        end
    end)
  end

  def drain(%{kind: :epoch} = state) do
    state.queue
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(%{state | queue: [], wake_pending?: false}, fn
      {_sequence, generation, owner_epoch, observed_success_epoch, signal}, acc ->
        if generation == acc.generation and owner_epoch == acc.owner_epoch do
          acc
          |> apply_observed_success(observed_success_epoch)
          |> apply_signal(signal)
        else
          acc
        end
    end)
  end

  def replace_generation(state, next_state \\ :closed) when next_state in [:closed, :open] do
    %{
      state
      | state: next_state,
        generation: state.generation + 1,
        failure_count: 0,
        success_count: 0,
        opened_by: nil,
        control_health: :healthy,
        queue: [],
        wake_pending?: false,
        success_epoch: 0,
        applied_success_epoch: 0,
        leases: %{}
    }
  end

  def restart_owner(state) do
    %{
      state
      | state: :half_open,
        generation: state.generation + 1,
        owner_epoch: state.owner_epoch + 1,
        failure_count: 0,
        success_count: 0,
        opened_by: nil,
        control_health: :healthy,
        queue: [],
        wake_pending?: false,
        success_epoch: 0,
        applied_success_epoch: 0,
        leases: %{}
    }
  end

  def force_half_open(state) do
    %{
      state
      | state: :half_open,
        generation: state.generation + 1,
        failure_count: 0,
        success_count: 0,
        opened_by: nil,
        queue: [],
        wake_pending?: false,
        success_epoch: 0,
        applied_success_epoch: 0,
        leases: %{}
    }
  end

  def admit_half_open(%{state: :half_open} = state) do
    if map_size(state.leases) < state.half_open_capacity do
      token = state.next_lease + 1

      lease = %{
        token: token,
        generation: state.generation,
        owner_epoch: state.owner_epoch
      }

      {%{state | leases: Map.put(state.leases, token, lease), next_lease: token}, {:ok, lease}}
    else
      {state, {:error, :half_open_busy}}
    end
  end

  def admit_half_open(state), do: {state, {:error, :not_half_open}}

  def report_half_open(state, lease, result) when result in [:success, :failure] do
    token = lease.token

    with %{^token => current} <- state.leases,
         true <- current == lease,
         true <- lease.generation == state.generation,
         true <- lease.owner_epoch == state.owner_epoch,
         true <- state.state == :half_open do
      state = %{state | leases: Map.delete(state.leases, lease.token)}

      case result do
        :success -> apply_half_open_success(state)
        :failure -> open(state, :half_open_failure)
      end
    else
      _ -> stale(state)
    end
  end

  def admission(%{state: :closed, control_health: :healthy}), do: :ordinary
  def admission(%{state: :open}), do: :rejected
  def admission(_state), do: :exceptional

  def semantic(state) do
    %{
      state: state.state,
      generation: state.generation,
      owner_epoch: state.owner_epoch,
      failure_count: effective_failure_count(state),
      success_count: state.success_count,
      opened_by: state.opened_by,
      control_health: state.control_health,
      leases: map_size(state.leases),
      admission: admission(state)
    }
  end

  def effective_failure_count(%{kind: :epoch} = state) do
    if state.state == :closed and state.success_epoch > state.applied_success_epoch,
      do: 0,
      else: state.failure_count
  end

  def effective_failure_count(state), do: state.failure_count

  defp enqueue_ring(state, receipt, signal) do
    if current_closed_receipt?(state, receipt) do
      entry = {state.next_sequence, receipt.generation, receipt.owner_epoch, signal}
      enqueue_bounded(%{state | next_sequence: state.next_sequence + 1}, entry)
    else
      stale(state)
    end
  end

  defp enqueue_bounded(state, entry) do
    if length(state.queue) < state.capacity do
      state
      |> Map.update!(:queue, &[entry | &1])
      |> notify_once()
    else
      state
      |> Map.put(:control_health, :degraded)
      |> Map.update!(:drops, &(&1 + 1))
      |> notify_once()
    end
  end

  defp notify_once(%{wake_pending?: true} = state), do: state
  defp notify_once(state), do: %{state | wake_pending?: true, wakes: state.wakes + 1}

  defp apply_observed_success(state, observed) when observed > state.applied_success_epoch do
    %{
      state
      | failure_count: 0,
        applied_success_epoch: observed
    }
  end

  defp apply_observed_success(state, _observed), do: state

  defp apply_signal(%{state: :closed} = state, :success),
    do: %{state | failure_count: 0}

  defp apply_signal(state, :neutral), do: state

  defp apply_signal(%{state: :closed} = state, {:failure, category}) do
    count = state.failure_count + 1
    threshold = Map.get(state.category_thresholds, category, state.failure_threshold)

    if count >= threshold,
      do: open(%{state | failure_count: count}, category),
      else: %{state | failure_count: count}
  end

  defp apply_signal(state, _signal), do: state

  defp apply_half_open_success(state) do
    count = state.success_count + 1

    if count >= state.success_threshold do
      %{
        state
        | state: :closed,
          generation: state.generation + 1,
          failure_count: 0,
          success_count: 0,
          opened_by: nil,
          success_epoch: 0,
          applied_success_epoch: 0,
          leases: %{}
      }
    else
      %{state | success_count: count}
    end
  end

  defp open(state, category) do
    %{
      state
      | state: :open,
        generation: state.generation + 1,
        opened_by: category,
        success_count: 0,
        queue: [],
        wake_pending?: false,
        success_epoch: 0,
        applied_success_epoch: 0,
        leases: %{}
    }
  end

  defp enter_probation(state) do
    %{
      state
      | state: :half_open,
        generation: state.generation + 1,
        failure_count: 0,
        success_count: 0,
        opened_by: nil,
        control_health: :healthy,
        queue: [],
        wake_pending?: false,
        success_epoch: 0,
        applied_success_epoch: 0,
        leases: %{}
    }
  end

  defp current_closed_receipt?(state, receipt) do
    state.state == :closed and receipt.kind == :closed and
      receipt.generation == state.generation and receipt.owner_epoch == state.owner_epoch
  end

  defp stale(state), do: %{state | stale_reports: state.stale_reports + 1}
end

defmodule Lasso.Prototypes.BreakerSuccessEpoch.Reference do
  @moduledoc """
  PROTOTYPE: scenario checks over the pure reducer.
  """

  alias Lasso.Prototypes.BreakerSuccessEpoch.Model

  @categories [:timeout, :rate_limit, :server_error, :unknown]

  def check! do
    checks = [
      ordering_check(),
      per_category_threshold_check(),
      threshold_before_success_check(),
      generation_check(),
      owner_restart_check(),
      half_open_check(),
      failure_saturation_check(),
      randomized_concurrent_check()
    ]

    case Enum.find(checks, fn {_name, result} -> result != :ok end) do
      nil -> checks
      {name, result} -> raise "reference check failed: #{name}: #{inspect(result)}"
    end
  end

  def naive_publication_race do
    reference =
      Model.new(:ring, failure_threshold: 2)
      |> then(fn state -> Model.report(state, Model.receipt(state), {:failure, :unknown}) end)
      |> then(fn state -> Model.report(state, Model.receipt(state), :success) end)
      |> Model.drain()

    naive =
      Model.new(:epoch, failure_threshold: 2)
      |> Map.put(:success_epoch, 1)
      |> Map.put(:applied_success_epoch, 1)
      |> Map.put(:failure_count, 0)
      |> then(fn state ->
        entry = {0, state.generation, state.owner_epoch, 0, {:failure, :unknown}}
        %{state | queue: [entry], wake_pending?: true}
      end)
      |> Model.drain()

    %{
      schedule: [
        "failure reads success epoch 0 and is descheduled before publication",
        "success advances epoch to 1",
        "owner applies epoch 1 while handling an earlier wake",
        "failure publishes its epoch-0 record"
      ],
      reference: Model.semantic(reference),
      naive: Model.semantic(naive),
      falsified?: Model.semantic(reference) != Model.semantic(naive)
    }
  end

  defp ordering_check do
    signals = [{:failure, :timeout}, :success, {:failure, :timeout}]
    {ring, epoch} = reduce_both(signals, failure_threshold: 9)

    result =
      if Model.semantic(ring) == Model.semantic(epoch) and
           Model.effective_failure_count(epoch) == 1,
         do: :ok,
         else: {Model.semantic(ring), Model.semantic(epoch)}

    {:success_failure_ordering, result}
  end

  defp threshold_before_success_check do
    signals = [{:failure, :rate_limit}, {:failure, :rate_limit}, :success]
    {ring, epoch} = reduce_both(signals)

    result =
      if Model.semantic(ring) == Model.semantic(epoch) and ring.state == :open,
        do: :ok,
        else: {Model.semantic(ring), Model.semantic(epoch)}

    {:threshold_transition_precedes_later_success, result}
  end

  defp per_category_threshold_check do
    expectations = [timeout: 3, rate_limit: 2, server_error: 4, unknown: 5]

    result =
      Enum.reduce_while(expectations, :ok, fn {category, threshold}, _acc ->
        signals = List.duplicate({:failure, category}, threshold)
        {ring, epoch} = reduce_both(signals)

        if Model.semantic(ring) == Model.semantic(epoch) and ring.state == :open and
             ring.opened_by == category,
           do: {:cont, :ok},
           else: {:halt, {category, Model.semantic(ring), Model.semantic(epoch)}}
      end)

    {:per_category_thresholds, result}
  end

  defp generation_check do
    ring = Model.new(:ring)
    epoch = Model.new(:epoch)
    ring_receipt = Model.receipt(ring)
    epoch_receipt = Model.receipt(epoch)
    ring = Model.replace_generation(ring)
    epoch = Model.replace_generation(epoch)
    ring = Model.report(ring, ring_receipt, {:failure, :timeout})
    epoch = Model.report(epoch, epoch_receipt, {:failure, :timeout})

    result =
      if Model.semantic(ring) == Model.semantic(epoch) and ring.stale_reports == 1 and
           epoch.stale_reports == 1,
         do: :ok,
         else: {Model.semantic(ring), Model.semantic(epoch)}

    {:generation_and_stale_receipts, result}
  end

  defp owner_restart_check do
    ring = Model.new(:ring)
    epoch = Model.new(:epoch)
    ring_receipt = Model.receipt(ring)
    epoch_receipt = Model.receipt(epoch)
    ring = Model.restart_owner(ring)
    epoch = Model.restart_owner(epoch)
    ring = Model.report(ring, ring_receipt, :success)
    epoch = Model.report(epoch, epoch_receipt, :success)

    result =
      if Model.semantic(ring) == Model.semantic(epoch) and
           Model.admission(ring) == :exceptional,
         do: :ok,
         else: {Model.semantic(ring), Model.semantic(epoch)}

    {:owner_restart_and_stale_epoch, result}
  end

  defp half_open_check do
    ring = Model.new(:ring, success_threshold: 2) |> Model.force_half_open()
    epoch = Model.new(:epoch, success_threshold: 2) |> Model.force_half_open()
    {ring, {:ok, ring_lease}} = Model.admit_half_open(ring)
    {epoch, {:ok, epoch_lease}} = Model.admit_half_open(epoch)
    ring = Model.report_half_open(ring, ring_lease, :success)
    epoch = Model.report_half_open(epoch, epoch_lease, :success)
    {ring, {:ok, ring_lease}} = Model.admit_half_open(ring)
    {epoch, {:ok, epoch_lease}} = Model.admit_half_open(epoch)
    ring = Model.report_half_open(ring, ring_lease, :success)
    epoch = Model.report_half_open(epoch, epoch_lease, :success)

    result =
      if Model.semantic(ring) == Model.semantic(epoch) and ring.state == :closed,
        do: :ok,
        else: {Model.semantic(ring), Model.semantic(epoch)}

    {:half_open_leases_remain_exact, result}
  end

  defp failure_saturation_check do
    ring = Model.new(:ring, capacity: 2, failure_threshold: 99)
    epoch = Model.new(:epoch, capacity: 2, failure_threshold: 99)
    ring_receipt = Model.receipt(ring)
    epoch_receipt = Model.receipt(epoch)
    failures = List.duplicate({:failure, :unknown}, 3)
    ring = Enum.reduce(failures, ring, &Model.report(&2, ring_receipt, &1)) |> Model.drain()
    epoch = Enum.reduce(failures, epoch, &Model.report(&2, epoch_receipt, &1)) |> Model.drain()

    result =
      if Model.semantic(ring) == Model.semantic(epoch) and ring.state == :half_open and
           ring.drops == 1 and epoch.drops == 1,
         do: :ok,
         else: {Model.semantic(ring), Model.semantic(epoch)}

    {:failure_saturation_still_degrades, result}
  end

  defp randomized_concurrent_check do
    trials = 250

    result =
      Enum.reduce_while(1..trials, :ok, fn seed, _acc ->
        case run_random_trial(seed) do
          :ok -> {:cont, :ok}
          mismatch -> {:halt, mismatch}
        end
      end)

    {:randomized_concurrent_linearizations, if(result == :ok, do: :ok, else: result)}
  end

  defp run_random_trial(seed) do
    :rand.seed(:exsss, {seed, seed * 17 + 3, seed * 101 + 11})
    ring = Model.new(:ring, capacity: 4_096)
    epoch = Model.new(:epoch, capacity: 4_096)

    Enum.reduce_while(1..20, {ring, epoch}, fn _burst, {ring, epoch} ->
      {ring, epoch} = normalize_closed(ring, epoch)
      ring_receipt = Model.receipt(ring)
      epoch_receipt = Model.receipt(epoch)
      signals = concurrent_linearization(10, 2 + :rand.uniform(12))

      ring = Enum.reduce(signals, ring, &Model.report(&2, ring_receipt, &1)) |> Model.drain()
      epoch = Enum.reduce(signals, epoch, &Model.report(&2, epoch_receipt, &1)) |> Model.drain()

      if Model.semantic(ring) == Model.semantic(epoch),
        do: {:cont, {ring, epoch}},
        else: {:halt, {:mismatch, seed, signals, Model.semantic(ring), Model.semantic(epoch)}}
    end)
    |> case do
      {:mismatch, _, _, _, _} = mismatch -> mismatch
      {_ring, _epoch} -> :ok
    end
  end

  defp concurrent_linearization(producers, count) do
    parent = self()
    per_producer = div(count + producers - 1, producers)

    tasks =
      for producer <- 1..producers do
        Task.async(fn ->
          :rand.seed(:exsss, {producer * count + 1, producer * 31 + count, producer * 97 + 7})

          Enum.each(1..per_producer, fn _index ->
            signal =
              if :rand.uniform(100) <= 62,
                do: :success,
                else: {:failure, Enum.at(@categories, :rand.uniform(length(@categories)) - 1)}

            send(parent, {:completion, System.unique_integer([:positive, :monotonic]), signal})
          end)
        end)
      end

    Enum.each(tasks, &Task.await(&1, 30_000))

    1..(per_producer * producers)
    |> Enum.map(fn _index ->
      receive do
        {:completion, sequence, signal} -> {sequence, signal}
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(count)
    |> Enum.map(&elem(&1, 1))
  end

  defp normalize_closed(%{state: :closed} = ring, %{state: :closed} = epoch),
    do: {ring, epoch}

  defp normalize_closed(ring, epoch),
    do: {Model.replace_generation(ring), Model.replace_generation(epoch)}

  defp reduce_both(signals, opts \\ []) do
    ring = Model.new(:ring, opts)
    epoch = Model.new(:epoch, opts)
    ring_receipt = Model.receipt(ring)
    epoch_receipt = Model.receipt(epoch)

    ring = Enum.reduce(signals, ring, &Model.report(&2, ring_receipt, &1)) |> Model.drain()
    epoch = Enum.reduce(signals, epoch, &Model.report(&2, epoch_receipt, &1)) |> Model.drain()
    {ring, epoch}
  end
end

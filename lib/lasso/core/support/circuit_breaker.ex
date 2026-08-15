defmodule Lasso.Core.Support.CircuitBreaker do
  @moduledoc """
  Circuit breaker implementation for RPC provider fault tolerance.

  Implements the circuit breaker pattern to prevent cascade failures
  when providers are experiencing issues. Provides automatic recovery
  and configurable failure thresholds.

  ## Key Scheme

  Circuit breakers are keyed by `{instance_id, transport}` where instance_id
  is a deterministic hash derived from the provider's chain + URL. This enables
  shared circuit breakers across profiles that use the same upstream provider.

  ## Recovery Mechanics

  When a circuit opens, a `recovery_deadline_ms` (monotonic timestamp) is set.
  Both proactive timer recovery and traffic-triggered recovery are gated by
  this deadline. The deadline is fixed for the duration of the open episode —
  additional failures while open do not extend it.

  On reopen (half_open → open), the deadline is computed with exponential
  backoff from the configured base recovery timeout. Rate-limit errors with
  retry-after headers use the retry-after value directly instead of backing off.

  Backoff schedule: base_recovery_timeout × 2^min(consecutive_reopens, 4),
  capped at `max_recovery_timeout` (default 10 minutes).

  ## ETS Write-Through

  On every state transition, writes to `:lasso_instance_state` at key
  `{:circuit, instance_id, transport}` with fields: state, error, recovery_deadline_ms.

  ## PubSub Fan-Out

  Broadcasts circuit events to `"circuit:events:{profile}:{chain}"` for ALL
  profiles referencing the instance (via `Catalog.get_instance_refs/1`).
  """

  use GenServer
  require Logger
  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.ErrorNormalizer

  alias Lasso.Core.Support.CircuitBreaker.{
    Admission,
    AdmissionReceipt,
    ControlRing,
    Snapshot,
    Storage
  }

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.{AttemptTerminal, ExecutionProjector}

  defstruct [
    :instance_id,
    :transport,
    :failure_threshold,
    :base_recovery_timeout,
    :success_threshold,
    :category_thresholds,
    :category_recovery_timeouts,
    :state,
    :failure_count,
    :last_failure_time,
    :success_count,
    :config,
    inflight_count: 0,
    half_open_max_inflight: 1,
    opened_by_category: nil,
    recovery_timer_ref: nil,
    last_open_error: nil,
    consecutive_open_count: 0,
    max_recovery_timeout: 600_000,
    recovery_deadline_ms: nil,
    effective_recovery_delay: nil,
    recovery_timer_gen: 0,
    transition_generation: 0,
    process_epoch: nil,
    ready?: false,
    control_health: :healthy,
    control_ring_capacity: 64,
    control_audit_interval_ms: 1_000,
    control_audit_timer_ref: nil,
    shared_mode: false,
    inflight_attempts: %{}
  ]

  @type transport :: :http | :ws
  @type breaker_id :: {String.t(), transport()}
  @type breaker_state :: :closed | :open | :half_open
  @type state_t :: %__MODULE__{
          instance_id: String.t(),
          transport: transport(),
          failure_threshold: non_neg_integer(),
          base_recovery_timeout: non_neg_integer(),
          success_threshold: non_neg_integer(),
          state: breaker_state(),
          failure_count: non_neg_integer(),
          last_failure_time: integer() | nil,
          success_count: non_neg_integer(),
          config: map(),
          recovery_deadline_ms: integer() | nil,
          effective_recovery_delay: non_neg_integer() | nil,
          recovery_timer_gen: non_neg_integer(),
          transition_generation: non_neg_integer(),
          shared_mode: boolean()
        }

  @doc """
  Starts a circuit breaker for a provider instance.
  """
  @spec start_link({breaker_id(), map()}) :: GenServer.on_start()
  def start_link({id, config}) do
    GenServer.start_link(__MODULE__, {id, config}, name: via_name(id))
  end

  @doc """
  Attempts to execute a function guarded by the circuit breaker.

  The timeout bounds both admission and function execution. Admitted work runs
  in one linked task and is terminated if the deadline expires.

  Returns an explicit execution envelope that separates circuit breaker
  concerns from function results:

  - `{:executed, fun_result}` - Function was executed. `fun_result` is whatever
    the wrapped function returned (which could itself be an error tuple).

  - `{:rejected, reason}` - Circuit breaker prevented execution.

  ## Rejection Reasons

  - `:circuit_open` - Circuit is open due to failures
  - `:half_open_busy` - Circuit is half-open but at max inflight capacity
  - `:admission_timeout` - The admission or execution deadline expired
  - `:admission_unavailable` - Snapshot or live ready owner is unavailable
  """
  @typedoc "Reasons why the circuit breaker rejected execution"
  @type rejection_reason ::
          :circuit_open | :half_open_busy | :admission_timeout | :admission_unavailable

  @typedoc "Result of a circuit breaker call - separates execution status from function result"
  @type call_result(result) :: {:executed, result} | {:rejected, rejection_reason()}

  @spec call(breaker_id(), (-> result), non_neg_integer()) :: call_result(result)
        when result: term()
  def call({instance_id, transport} = id, fun, timeout \\ 30_000) do
    deadline_us = System.monotonic_time(:microsecond) + timeout * 1_000
    decision = admit(id, deadline_us)

    case decision do
      {:ok, receipt} ->
        execute_admitted_call(receipt, fun, deadline_us)

      {:error, :circuit_open} ->
        {:rejected, :circuit_open}

      {:error, :half_open_busy} ->
        {:rejected, :half_open_busy}

      {:error, :admission_timeout} ->
        {:rejected, :admission_timeout}

      {:error, :admission_unavailable} ->
        Logger.warning("Circuit breaker admission unavailable",
          instance_id: instance_id,
          transport: transport
        )

        {:rejected, :admission_unavailable}
    end
  end

  @doc false
  @spec admit(breaker_id(), integer()) ::
          {:ok, AdmissionReceipt.t()} | {:error, rejection_reason()}
  def admit(id, deadline_us) when is_integer(deadline_us) do
    case Admission.check(id, deadline_us) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, reason} -> {:error, reason}
      {:exceptional, snapshot} -> admit_exceptional(snapshot, deadline_us)
    end
  end

  defp admit_exceptional(snapshot, deadline_us) do
    now_us = System.monotonic_time(:microsecond)

    if now_us >= deadline_us do
      {:error, :admission_timeout}
    else
      token = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      timeout_ms = max(div(deadline_us - now_us + 999, 1_000), 1)

      request =
        {:admit_exceptional, token, self(), snapshot.generation, snapshot.epoch, deadline_us}

      try do
        GenServer.call(snapshot.owner_pid, request, timeout_ms)
      catch
        :exit, {:timeout, _} ->
          GenServer.cast(snapshot.owner_pid, {:release, token})
          GenServer.cast(via_name(snapshot.breaker_id), {:release, token})
          {:error, :admission_timeout}

        :exit, _reason ->
          {:error, :admission_unavailable}
      end
    end
  end

  @doc false
  @spec activate_attempt(AdmissionReceipt.t(), pid()) :: :ok | {:error, :stale}
  def activate_attempt(%AdmissionReceipt{kind: :closed}, _caller_pid), do: :ok

  def activate_attempt(%AdmissionReceipt{kind: :half_open} = receipt, caller_pid)
      when is_pid(caller_pid) do
    case :ets.lookup(Storage.lease_table(), receipt.breaker_id) do
      [
        {breaker_id,
         %{
           token: token,
           owner_pid: ^caller_pid,
           generation: generation,
           epoch: epoch,
           claimed?: false
         } = lease}
      ]
      when breaker_id == receipt.breaker_id and token == receipt.token and
             generation == receipt.generation and epoch == receipt.epoch ->
        activated = %{lease | claimed?: true}

        case :ets.select_replace(
               Storage.lease_table(),
               [{{breaker_id, lease}, [], [{:const, {breaker_id, activated}}]}]
             ) do
          1 -> :ok
          0 -> {:error, :stale}
        end

      _other ->
        {:error, :stale}
    end
  rescue
    ArgumentError -> {:error, :stale}
  end

  @doc false
  @spec report_closed(AdmissionReceipt.t(), term()) :: :ok | {:error, :saturated | :stale}
  def report_closed(%AdmissionReceipt{kind: :closed} = receipt, result) do
    ControlRing.enqueue(receipt, control_signal(result, receipt.breaker_id))
  end

  @doc false
  @spec report_half_open(AdmissionReceipt.t(), term()) :: :ok
  def report_half_open(%AdmissionReceipt{kind: :half_open} = receipt, result) do
    GenServer.cast(
      via_name(receipt.breaker_id),
      {:report, receipt.token, receipt.generation, receipt.epoch, result}
    )
  end

  @doc false
  @spec report_canonical(AdmissionReceipt.t(), AttemptTerminal.t(), ExecutionProjector.t()) ::
          :ok | {:error, :saturated | :stale}
  def report_canonical(
        %AdmissionReceipt{kind: :closed} = receipt,
        fact,
        %ExecutionProjector{} = projection
      ) do
    with {:ok, route_generation} <- current_fact_generation(fact),
         signal when signal != :neutral <- canonical_control_signal(fact, projection) do
      ControlRing.enqueue(receipt, {:route_generation, route_generation, signal})
    else
      _neutral_or_stale -> :ok
    end
  end

  def report_canonical(
        %AdmissionReceipt{kind: :half_open} = receipt,
        fact,
        %ExecutionProjector{} = projection
      ) do
    case {current_fact_generation(fact), canonical_control_signal(fact, projection)} do
      {{:ok, _route_generation}, :neutral} ->
        release_half_open(receipt)

      {{:ok, route_generation}, signal} ->
        GenServer.cast(
          via_name(receipt.breaker_id),
          {:report_signal, receipt.token, receipt.generation, receipt.epoch,
           {:route_generation, route_generation, signal}}
        )

      {:stale, _signal} ->
        release_half_open(receipt)
    end
  end

  @doc false
  @spec release_half_open(AdmissionReceipt.t()) :: :ok
  def release_half_open(%AdmissionReceipt{kind: :half_open} = receipt) do
    GenServer.cast(
      via_name(receipt.breaker_id),
      {:release, receipt.token, receipt.generation, receipt.epoch}
    )
  end

  @doc false
  @spec abandon_unclaimed(AdmissionReceipt.t(), pid()) :: :ok
  def abandon_unclaimed(%AdmissionReceipt{kind: :half_open} = receipt, caller_pid) do
    delete_unclaimed_lease(receipt, caller_pid)

    GenServer.cast(
      via_name(receipt.breaker_id),
      {:abandon_unclaimed, receipt.token, receipt.generation, receipt.epoch, caller_pid}
    )
  end

  defp execute_admitted_call(receipt, fun, deadline_us) do
    case activate_attempt(receipt, self()) do
      :ok ->
        if System.monotonic_time(:microsecond) < deadline_us do
          task = Task.async(fn -> execute_call_before_deadline(fun, deadline_us) end)
          finish_admitted_call(receipt, task, deadline_us)
        else
          reject_expired_call(receipt)
        end

      {:error, :stale} ->
        abandon_unclaimed(receipt, self())
        {:rejected, :admission_unavailable}
    end
  end

  defp finish_admitted_call(receipt, task, deadline_us) do
    case Task.yield(task, remaining_call_timeout_ms(deadline_us)) do
      {:ok, {:completed, completed_at_us, result}} when completed_at_us < deadline_us ->
        unlink_and_flush_exit(task.pid)
        report_call_receipt(receipt, result)
        {:executed, result}

      {:exit, reason} ->
        unlink_and_flush_exit(task.pid)
        result = {:exception, {:exit, reason, []}}
        report_call_receipt(receipt, result)
        {:executed, result}

      _late_or_missing ->
        _ = Task.shutdown(task, :brutal_kill)
        unlink_and_flush_exit(task.pid)
        reject_expired_call(receipt)
    end
  end

  defp execute_call_before_deadline(fun, deadline_us) do
    if System.monotonic_time(:microsecond) < deadline_us do
      result = execute_call_fun(fun)
      {:completed, System.monotonic_time(:microsecond), result}
    else
      :deadline_expired
    end
  end

  defp reject_expired_call(receipt) do
    release_call_receipt(receipt)
    {:rejected, :admission_timeout}
  end

  defp remaining_call_timeout_ms(deadline_us) do
    remaining_us = deadline_us - System.monotonic_time(:microsecond)
    if remaining_us > 0, do: div(remaining_us + 999, 1_000), else: 0
  end

  defp execute_call_fun(fun) do
    fun.()
  catch
    kind, error -> {:exception, {kind, error, __STACKTRACE__}}
  end

  defp unlink_and_flush_exit(pid) do
    Process.unlink(pid)

    receive do
      {:EXIT, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp report_call_receipt(%AdmissionReceipt{kind: :closed} = receipt, result),
    do: report_closed(receipt, result)

  defp report_call_receipt(%AdmissionReceipt{kind: :half_open} = receipt, result),
    do: report_half_open(receipt, result)

  defp release_call_receipt(%AdmissionReceipt{kind: :closed}), do: :ok

  defp release_call_receipt(%AdmissionReceipt{kind: :half_open} = receipt),
    do: release_half_open(receipt)

  @state_timeout 2_000

  @doc """
  Gets the current state of the circuit breaker.
  """
  @spec get_state(breaker_id()) ::
          %{
            instance_id: String.t(),
            transport: transport(),
            state: breaker_state(),
            failure_count: non_neg_integer(),
            success_count: non_neg_integer(),
            last_failure_time: integer() | nil
          }
          | {:error, term()}
  def get_state(id) do
    GenServer.call(via_name(id), :get_state, @state_timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("Timeout getting circuit breaker state for #{inspect(id)}")
      {:error, :timeout}

    :exit, {:noproc, _} ->
      {:error, :not_found}
  end

  @doc """
  Manually opens the circuit breaker.
  """
  @spec open(breaker_id()) :: :ok
  def open(breaker_id) do
    GenServer.cast(via_name(breaker_id), :open)
  end

  @doc """
  Manually closes the circuit breaker.
  """
  @spec close(breaker_id()) :: :ok
  def close(breaker_id) do
    GenServer.cast(via_name(breaker_id), :close)
  end

  @doc """
  Gets the time remaining until circuit recovery attempt (in milliseconds).
  Returns nil if circuit is not open or if recovery should be attempted immediately.
  """
  @spec get_recovery_time_remaining(breaker_id()) :: non_neg_integer() | nil
  def get_recovery_time_remaining(breaker_id) do
    case get_state(breaker_id) do
      %{state: :open} ->
        try do
          case GenServer.call(via_name(breaker_id), :get_recovery_timeout, @state_timeout) do
            {:ok, remaining} -> remaining
            _ -> nil
          end
        catch
          :exit, _ -> nil
        end

      {:error, _reason} ->
        nil

      _ ->
        nil
    end
  end

  @doc """
  Accepts a legacy external health signal without changing circuit state.

  Recovery authority belongs to the cooldown/probation transition and accepted
  current-epoch half-open lease outcomes.
  """
  @spec signal_recovery(breaker_id()) :: :ok | {:error, :not_found}
  def signal_recovery(id) do
    case safe_whereis(via_name(id)) do
      nil -> {:error, :not_found}
      _pid -> :ok
    end
  end

  @doc """
  Fire-and-forget compatibility form of `signal_recovery/1`.
  """
  @spec signal_recovery_cast(breaker_id()) :: :ok
  def signal_recovery_cast(cb_id) do
    _ = safe_whereis(via_name(cb_id))
    :ok
  end

  @doc """
  Record a failed operation for the circuit breaker (async).
  """
  @spec record_failure(breaker_id(), term()) :: :ok | {:error, :not_found}
  def record_failure(id, reason \\ :failure) do
    case safe_whereis(via_name(id)) do
      nil ->
        {:error, :not_found}

      pid ->
        GenServer.cast(pid, {:report_external, {:error, reason}})
        :ok
    end
  end

  @doc false
  @spec report_external_bounded(breaker_id(), term()) ::
          :ok | {:error, :saturated | :stale}
  def report_external_bounded(id, result) do
    case Snapshot.lookup(id) do
      {:ok, snapshot} ->
        receipt = %AdmissionReceipt{
          breaker_id: id,
          kind: :closed,
          generation: snapshot.generation,
          epoch: snapshot.epoch,
          owner_pid: self()
        }

        ControlRing.enqueue(receipt, control_signal(result, id))

      :missing ->
        {:error, :stale}
    end
  end

  @doc """
  Record a failed operation for the circuit breaker (synchronous).
  Returns the circuit state after recording the failure.
  """
  @spec record_failure_sync(breaker_id(), term(), timeout()) ::
          {:ok, :closed | :open | :half_open} | {:error, :not_found | :timeout}
  def record_failure_sync(id, reason \\ :failure, timeout \\ 5_000) do
    case safe_whereis(via_name(id)) do
      nil ->
        {:error, :not_found}

      pid ->
        try do
          state = GenServer.call(pid, {:report_external_sync, {:error, reason}}, timeout)
          {:ok, state}
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          :exit, {:noproc, _} -> {:error, :not_found}
          :exit, _ -> {:error, :not_found}
        end
    end
  end

  @doc """
  Resolves a GenServer name without raising when its registry is unavailable.
  """
  @spec safe_whereis(GenServer.name()) :: pid() | nil
  def safe_whereis(name) do
    GenServer.whereis(name)
  rescue
    ArgumentError -> nil
  catch
    :exit, _ -> nil
  end

  # GenServer callbacks

  @impl true
  def init({{instance_id, transport}, config}) when is_binary(instance_id) do
    do_init(instance_id, transport, config)
  end

  defp do_init(instance_id, transport, config) do
    default_category_thresholds = %{
      server_error: 5,
      network_error: 3,
      timeout: 2,
      auth_error: 3
    }

    category_thresholds =
      Map.get(config, :category_thresholds, %{})
      |> Map.merge(default_category_thresholds, fn _k, v1, _v2 -> v1 end)

    default_category_recovery_timeouts = %{
      auth_error: 10_000
    }

    category_recovery_timeouts =
      Map.get(config, :category_recovery_timeouts, %{})
      |> Map.merge(default_category_recovery_timeouts, fn _k, v1, _v2 -> v1 end)

    half_open_max_inflight = 1

    previous_snapshot =
      case Snapshot.lookup({instance_id, transport}) do
        {:ok, snapshot} -> snapshot
        :missing -> nil
      end

    previous_control? = :ets.member(Storage.control_meta_table(), {instance_id, transport})

    now_us = System.monotonic_time(:microsecond)

    {initial_state, transition_generation, control_health, recovery_deadline_ms} =
      case {previous_snapshot, previous_control?} do
        {nil, false} ->
          {:closed, 1, :healthy, nil}

        {nil, true} ->
          {:half_open, 1, :degraded, nil}

        {%Snapshot{state: :open, recovery_deadline_us: deadline_us, generation: generation}, _}
        when is_integer(deadline_us) and deadline_us > now_us ->
          {:open, generation + 1, :degraded, div(deadline_us + 999, 1_000)}

        {%Snapshot{generation: generation}, _control?} ->
          {:half_open, generation + 1, :degraded, nil}
      end

    state = %__MODULE__{
      instance_id: instance_id,
      transport: transport,
      failure_threshold: Map.get(config, :failure_threshold, 5),
      base_recovery_timeout: Map.get(config, :recovery_timeout, 60_000),
      success_threshold: Map.get(config, :success_threshold, 2),
      category_thresholds: category_thresholds,
      category_recovery_timeouts: category_recovery_timeouts,
      half_open_max_inflight: half_open_max_inflight,
      inflight_count: 0,
      state: initial_state,
      failure_count: 0,
      last_failure_time: nil,
      success_count: 0,
      config: config,
      max_recovery_timeout: Map.get(config, :max_recovery_timeout, 600_000),
      transition_generation: transition_generation,
      process_epoch: System.unique_integer([:positive, :monotonic]),
      ready?: true,
      control_health: control_health,
      control_ring_capacity: ControlRing.capacity(Map.get(config, :control_ring_capacity, 64)),
      control_audit_interval_ms:
        control_audit_interval(Map.get(config, :control_audit_interval_ms, 1_000)),
      recovery_deadline_ms: recovery_deadline_ms,
      shared_mode: Map.get(config, :shared_mode, false),
      inflight_attempts: %{}
    }

    state = state |> recover_persisted_lease() |> restore_recovery_timer()
    initialize_control_ring(state)
    state = schedule_control_audit(state)
    write_ets_state(state)

    {:ok, state, {:continue, :reconcile_persisted_lease}}
  end

  @impl true
  def handle_continue(:reconcile_persisted_lease, state) do
    breaker_id = {state.instance_id, state.transport}

    new_state =
      Enum.reduce(state.inflight_attempts, state, fn {token, _attempt}, current_state ->
        case :ets.lookup(Storage.lease_table(), breaker_id) do
          [{^breaker_id, %{token: ^token}}] -> current_state
          _ -> apply_attempt_release(current_state, token)
        end
      end)

    write_ets_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(
        {:admit_exceptional, token, owner_pid, expected_generation, expected_epoch, deadline_us},
        _from,
        state
      ) do
    now_us = System.monotonic_time(:microsecond)

    cond do
      now_us >= deadline_us ->
        {:reply, {:error, :admission_timeout}, state}

      expected_epoch != state.process_epoch or
          expected_generation != state.transition_generation ->
        {:reply, {:error, :admission_unavailable}, state}

      state.state == :open and not recovery_eligible?(state, now_us) ->
        {:reply, {:error, :circuit_open}, state}

      state.state == :half_open and state.inflight_count >= state.half_open_max_inflight ->
        {:reply, {:error, :half_open_busy}, state}

      state.state == :closed and state.control_health != :degraded ->
        {:reply, {:error, :admission_unavailable}, state}

      true ->
        admitted_state = prepare_exceptional_generation(state)

        case persist_exceptional_lease(admitted_state, token, owner_pid, deadline_us) do
          {:ok, receipt, new_state} ->
            write_ets_state(new_state)
            {:reply, {:ok, receipt}, new_state}

          :busy ->
            {:reply, {:error, :half_open_busy}, state}
        end
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    status = %{
      instance_id: state.instance_id,
      transport: state.transport,
      state: state.state,
      failure_count: state.failure_count,
      success_count: state.success_count,
      last_failure_time: state.last_failure_time,
      last_open_error: state.last_open_error
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:get_recovery_timeout, _from, state) do
    remaining =
      case state.recovery_deadline_ms do
        nil -> 0
        deadline -> max(0, deadline - System.monotonic_time(:millisecond))
      end

    {:reply, {:ok, remaining}, state}
  end

  @impl true
  def handle_call({:report_external_sync, {:ok, _result}}, _from, state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_call({:report_external_sync, outcome}, _from, state) do
    new_state = classify_and_update_state_for_report(outcome, state)
    {:reply, new_state.state, new_state}
  end

  @impl true
  def handle_cast({:report, token, generation, epoch, result}, state) do
    new_state = apply_attempt_report(state, token, generation, epoch, result)
    write_ets_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:report_signal, token, generation, epoch, signal}, state) do
    new_state = apply_attempt_signal(state, token, generation, epoch, signal)
    write_ets_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:release, token, generation, epoch}, state) do
    new_state = apply_attempt_release(state, token, generation, epoch)
    write_ets_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:abandon_unclaimed, token, generation, epoch, caller_pid}, state) do
    new_state = abandon_unclaimed_attempt(state, token, generation, epoch, caller_pid)
    write_ets_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:release, token}, state) do
    new_state = apply_attempt_release(state, token)
    write_ets_state(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:report_external, {:ok, _result}}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:report_external, outcome}, state) do
    new_state = classify_and_update_state_for_report(outcome, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:open, state) do
    cancel_recovery_timer(state.recovery_timer_ref)
    delay = state.base_recovery_timeout
    delay_with_jitter = add_jitter(delay)
    new_gen = state.recovery_timer_gen + 1
    now = System.monotonic_time(:millisecond)
    timer_ref = schedule_recovery_timer(delay_with_jitter, new_gen)

    new_state = %{
      state
      | state: :open,
        last_failure_time: now,
        inflight_count: 0,
        recovery_timer_ref: timer_ref,
        recovery_timer_gen: new_gen,
        transition_generation: state.transition_generation + 1,
        recovery_deadline_ms: now + delay_with_jitter,
        effective_recovery_delay: delay
    }

    write_ets_state(new_state)

    :telemetry.execute([:lasso, :circuit_breaker, :open], %{count: 1}, %{
      instance_id: state.instance_id,
      transport: state.transport,
      from_state: state.state,
      to_state: :open,
      reason: :manual_open
    })

    publish_circuit_event(new_state, state.state, :open, :manual_open)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:close, state) do
    cancel_recovery_timer(state.recovery_timer_ref)
    acknowledge_control_degradation(state)

    new_state = %{
      state
      | state: :closed,
        failure_count: 0,
        success_count: 0,
        inflight_count: 0,
        last_failure_time: nil,
        opened_by_category: nil,
        recovery_timer_ref: nil,
        last_open_error: nil,
        consecutive_open_count: 0,
        recovery_deadline_ms: nil,
        effective_recovery_delay: nil,
        transition_generation: state.transition_generation + 1,
        control_health: :healthy
    }

    write_ets_state(new_state)

    :telemetry.execute([:lasso, :circuit_breaker, :close], %{count: 1}, %{
      instance_id: state.instance_id,
      transport: state.transport,
      from_state: state.state,
      to_state: :closed,
      reason: :manual_close
    })

    publish_circuit_event(new_state, state.state, :closed, :manual_close)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(
        {:breaker_control_ready, breaker_id, generation, epoch},
        %{instance_id: instance_id, transport: transport} = state
      )
      when breaker_id == {instance_id, transport} do
    new_state = drain_control(state, breaker_id, generation, epoch)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:breaker_control_audit, state) do
    breaker_id = {state.instance_id, state.transport}
    generation = state.transition_generation
    epoch = state.process_epoch

    new_state =
      if ControlRing.audit_required?(breaker_id, generation, epoch),
        do: drain_control(state, breaker_id, generation, epoch),
        else: state

    {:noreply, schedule_control_audit(new_state)}
  end

  @impl true
  def handle_info({:emit_breaker_transition, event, metadata}, state)
      when is_list(event) and is_map(metadata) do
    :telemetry.execute(event, %{count: 1}, metadata)
    {:noreply, state}
  end

  @impl true
  def handle_info({:attempt_proactive_recovery, gen}, state)
      when gen == state.recovery_timer_gen do
    case state.state do
      :open ->
        new_state = %{
          state
          | state: :half_open,
            success_count: 0,
            inflight_count: 0,
            recovery_timer_ref: nil,
            transition_generation: state.transition_generation + 1
        }

        write_ets_state(new_state)

        :telemetry.execute([:lasso, :circuit_breaker, :proactive_recovery], %{count: 1}, %{
          instance_id: state.instance_id,
          transport: state.transport,
          from_state: :open,
          to_state: :half_open,
          reason: :proactive_recovery,
          consecutive_open_count: state.consecutive_open_count
        })

        publish_circuit_event(new_state, :open, :half_open, :proactive_recovery)
        {:noreply, new_state}

      _other_state ->
        {:noreply, %{state | recovery_timer_ref: nil}}
    end
  end

  @impl true
  def handle_info({:attempt_proactive_recovery, _stale_gen}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, owner_monitor, :process, owner_pid, _reason}, state) do
    case Enum.find(state.inflight_attempts, fn
           {_token, %{owner_monitor: ^owner_monitor, owner_pid: ^owner_pid}} ->
             true

           _attempt ->
             false
         end) do
      {token, _attempt} ->
        new_state = apply_attempt_release(state, token)
        write_ets_state(new_state)
        {:noreply, new_state}

      nil ->
        {:noreply, state}
    end
  end

  defp drain_control(state, breaker_id, generation, epoch) do
    state = maybe_enter_control_probation(state, generation, epoch)

    signals =
      ControlRing.drain(
        breaker_id,
        state.control_ring_capacity,
        generation,
        epoch
      )

    new_state = Enum.reduce(signals, state, &apply_control_signal(&1, &2, generation, epoch))
    write_ets_state(new_state)
    new_state
  end

  defp schedule_control_audit(state) do
    timer_ref =
      Process.send_after(self(), :breaker_control_audit, state.control_audit_interval_ms)

    %{state | control_audit_timer_ref: timer_ref}
  end

  defp control_audit_interval(value) when is_integer(value) and value > 0,
    do: min(value, 5_000)

  defp control_audit_interval(_value), do: 1_000

  defp recovery_eligible?(state, now_us) do
    is_nil(state.recovery_deadline_ms) or now_us >= state.recovery_deadline_ms * 1_000
  end

  defp prepare_exceptional_generation(%{state: :half_open} = state), do: state

  defp prepare_exceptional_generation(%{state: :open} = state) do
    send(self(), {
      :emit_breaker_transition,
      [:lasso, :circuit_breaker, :half_open],
      %{
        instance_id: state.instance_id,
        transport: state.transport,
        from_state: :open,
        to_state: :half_open,
        reason: :attempt_recovery,
        consecutive_open_count: state.consecutive_open_count
      }
    })

    prepare_probation(state)
  end

  defp prepare_exceptional_generation(state), do: prepare_probation(state)

  defp prepare_probation(state) do
    cancel_recovery_timer(state.recovery_timer_ref)
    acknowledge_control_degradation(state)

    %{
      state
      | state: :half_open,
        success_count: 0,
        inflight_count: 0,
        recovery_timer_ref: nil,
        recovery_timer_gen: state.recovery_timer_gen + 1,
        transition_generation: state.transition_generation + 1,
        control_health: :healthy
    }
  end

  defp persist_exceptional_lease(state, token, owner_pid, deadline_us) do
    breaker_id = {state.instance_id, state.transport}

    lease = %{
      token: token,
      owner_pid: owner_pid,
      generation: state.transition_generation,
      epoch: state.process_epoch,
      claimed?: false
    }

    if :ets.insert_new(Storage.lease_table(), {breaker_id, lease}) do
      owner_monitor = Process.monitor(owner_pid)

      attempt = %{
        admission_state: :half_open,
        transition_generation: state.transition_generation,
        counted_generation: state.transition_generation,
        epoch: state.process_epoch,
        owner_pid: owner_pid,
        owner_monitor: owner_monitor,
        claimed?: false
      }

      new_state = %{
        state
        | inflight_attempts: Map.put(state.inflight_attempts, token, attempt),
          inflight_count: state.inflight_count + 1
      }

      receipt = %AdmissionReceipt{
        breaker_id: breaker_id,
        kind: :half_open,
        generation: state.transition_generation,
        epoch: state.process_epoch,
        owner_pid: self(),
        token: token,
        deadline_us: deadline_us
      }

      {:ok, receipt, new_state}
    else
      :busy
    end
  end

  defp take_attempt(state, token) do
    case Map.pop(state.inflight_attempts, token) do
      {nil, _attempts} ->
        :error

      {attempt, attempts} ->
        demonitor_attempt_owner(attempt)
        delete_persisted_lease({state.instance_id, state.transport}, token)
        {:ok, attempt, %{state | inflight_attempts: attempts}}
    end
  end

  defp demonitor_attempt_owner(%{owner_monitor: owner_monitor})
       when is_reference(owner_monitor) do
    Process.demonitor(owner_monitor, [:flush])
  end

  defp demonitor_attempt_owner(_attempt), do: :ok

  defp delete_persisted_lease(breaker_id, token) do
    case :ets.lookup(Storage.lease_table(), breaker_id) do
      [{^breaker_id, %{token: ^token}}] -> :ets.delete(Storage.lease_table(), breaker_id)
      _ -> :ok
    end
  end

  defp delete_unclaimed_lease(receipt, caller_pid) do
    case :ets.lookup(Storage.lease_table(), receipt.breaker_id) do
      [
        {breaker_id,
         %{
           token: token,
           owner_pid: ^caller_pid,
           generation: generation,
           epoch: epoch,
           claimed?: false
         } = lease}
      ]
      when breaker_id == receipt.breaker_id and token == receipt.token and
             generation == receipt.generation and epoch == receipt.epoch ->
        :ets.select_delete(Storage.lease_table(), [{{breaker_id, lease}, [], [true]}])

      _ ->
        0
    end
  rescue
    ArgumentError -> 0
  end

  defp apply_attempt_report(state, token, generation, epoch, result) do
    if generation == state.transition_generation and epoch == state.process_epoch,
      do: do_apply_attempt_report(state, token, result),
      else: state
  end

  defp do_apply_attempt_report(state, token, result) do
    case take_attempt(state, token) do
      {:ok, attempt, state_without_attempt} ->
        cond do
          neutral_attempt_result?(result) ->
            release_half_open_attempt(state_without_attempt, attempt)

          attempt.transition_generation != state.transition_generation or
              (Map.has_key?(attempt, :epoch) and attempt.epoch != state.process_epoch) ->
            release_half_open_attempt(state_without_attempt, attempt)

          true ->
            result
            |> normalize_transport_result()
            |> classify_and_update_state_for_report(state_without_attempt)
            |> release_half_open_attempt(attempt)
        end

      :error ->
        state
    end
  end

  defp apply_attempt_signal(state, token, generation, epoch, signal) do
    if generation == state.transition_generation and epoch == state.process_epoch do
      case signal do
        {:route_generation, route_generation, routed_signal} ->
          if route_generation == ConfigStore.route_generation() do
            apply_attempt_signal(state, token, generation, epoch, routed_signal)
          else
            apply_attempt_release(state, token)
          end

        :neutral ->
          apply_attempt_release(state, token)

        :success ->
          do_apply_attempt_report(state, token, :ok)

        {:failure, category, breaker_penalty?}
        when is_atom(category) and is_boolean(breaker_penalty?) ->
          error =
            JError.new(-32_000, "Canonical breaker failure",
              category: category,
              retriable?: true,
              breaker_penalty?: breaker_penalty?
            )

          do_apply_attempt_report(state, token, {:error, error})
      end
    else
      release_stale_attempt(state, token, generation, epoch)
    end
  end

  defp neutral_attempt_result?({:error, :unsupported_method, _io_ms}), do: true

  defp neutral_attempt_result?({:error, %JError{category: :local_capacity_rejection}, _io_ms}),
    do: true

  defp neutral_attempt_result?(_result), do: false

  defp apply_attempt_release(state, token) do
    case take_attempt(state, token) do
      {:ok, attempt, state_without_attempt} ->
        release_half_open_attempt(state_without_attempt, attempt)

      :error ->
        state
    end
  end

  defp apply_attempt_release(state, token, generation, epoch) do
    if generation == state.transition_generation and epoch == state.process_epoch,
      do: apply_attempt_release(state, token),
      else: release_stale_attempt(state, token, generation, epoch)
  end

  defp release_stale_attempt(state, token, generation, epoch) do
    case Map.fetch(state.inflight_attempts, token) do
      {:ok, %{transition_generation: ^generation, epoch: ^epoch}} ->
        apply_attempt_release(state, token)

      _ ->
        state
    end
  end

  defp abandon_unclaimed_attempt(state, token, generation, epoch, caller_pid) do
    case Map.fetch(state.inflight_attempts, token) do
      {:ok,
       %{
         transition_generation: ^generation,
         epoch: ^epoch,
         owner_pid: ^caller_pid,
         claimed?: false
       }} ->
        apply_attempt_release(state, token)

      _ ->
        state
    end
  end

  defp release_half_open_attempt(
         %{transition_generation: generation} = state,
         %{admission_state: :half_open, counted_generation: generation}
       ) do
    %{state | inflight_count: max(state.inflight_count - 1, 0)}
  end

  defp release_half_open_attempt(state, _attempt), do: state

  defp normalize_transport_result({:ok, value, _io_ms}), do: {:ok, value}
  defp normalize_transport_result({:error, reason, _io_ms}), do: {:error, reason}
  defp normalize_transport_result({:ok, _value} = ok_tuple), do: ok_tuple
  defp normalize_transport_result({:error, _reason} = error_tuple), do: error_tuple
  defp normalize_transport_result(:ok), do: {:ok, :ok}
  defp normalize_transport_result(other), do: other

  defp control_signal(result, {instance_id, transport}) do
    case normalize_transport_result(result) do
      {:ok, _value} ->
        :success

      {:error, :unsupported_method} ->
        :neutral

      {:error, %JError{category: category}}
      when category in [:local_capacity_rejection, :cancelled] ->
        :neutral

      {:error, %JError{} = error} ->
        if error.retriable?,
          do: {:failure, error.category, error.breaker_penalty?},
          else: :neutral

      {:error, reason} ->
        error = ErrorNormalizer.normalize(reason, instance_id: instance_id, transport: transport)

        if error.retriable?,
          do: {:failure, error.category, error.breaker_penalty?},
          else: :neutral

      {:exception, _details} ->
        {:failure, :internal_error, true}

      _other ->
        {:failure, :internal_error, false}
    end
  end

  defp canonical_control_signal(_fact, %ExecutionProjector{breaker_effect: :none}),
    do: :neutral

  defp canonical_control_signal(_fact, %ExecutionProjector{breaker_effect: :success}),
    do: :success

  defp canonical_control_signal(fact, %ExecutionProjector{breaker_effect: :failure}),
    do: {:failure, canonical_breaker_category(fact), true}

  defp canonical_breaker_category(%AttemptTerminal.Response{error_category: :provider_failure}),
    do: :server_error

  defp canonical_breaker_category(%AttemptTerminal.InvalidResponse{}), do: :protocol_error
  defp canonical_breaker_category(%AttemptTerminal.Deadline{}), do: :timeout

  defp canonical_breaker_category(%AttemptTerminal.TransportFailure{reason: :timeout}),
    do: :timeout

  defp canonical_breaker_category(%AttemptTerminal.TransportFailure{
         reason: reason
       })
       when reason in [:connection, :closed, :tls, :dns],
       do: :network_error

  defp canonical_breaker_category(%AttemptTerminal.TransportFailure{}), do: :server_error
  defp canonical_breaker_category(_fact), do: :server_error

  defp initialize_control_ring(state) do
    ControlRing.initialize(
      {state.instance_id, state.transport},
      state.transition_generation,
      state.process_epoch,
      self(),
      capacity: state.control_ring_capacity
    )
  end

  defp recover_persisted_lease(state) do
    breaker_id = {state.instance_id, state.transport}

    case :ets.lookup(Storage.lease_table(), breaker_id) do
      [
        {^breaker_id,
         lease = %{
           token: token,
           owner_pid: owner_pid,
           generation: generation,
           epoch: epoch
         }}
      ]
      when is_binary(token) and is_pid(owner_pid) and is_integer(generation) and
             is_integer(epoch) ->
        if Process.alive?(owner_pid) do
          owner_monitor = Process.monitor(owner_pid)

          attempt = %{
            admission_state: :half_open,
            transition_generation: generation,
            counted_generation: state.transition_generation,
            epoch: epoch,
            owner_pid: owner_pid,
            owner_monitor: owner_monitor,
            claimed?: Map.get(lease, :claimed?, false)
          }

          %{
            state
            | inflight_attempts: %{token => attempt},
              inflight_count: 1,
              state: :half_open,
              control_health: :degraded
          }
        else
          :ets.delete(Storage.lease_table(), breaker_id)
          state
        end

      [] ->
        state

      [_corrupt] ->
        :ets.delete(Storage.lease_table(), breaker_id)

        :telemetry.execute(
          [:lasso, :circuit_breaker, :lease_corrupt],
          %{count: 1},
          %{breaker_id: breaker_id}
        )

        %{state | state: :half_open, control_health: :degraded}
    end
  end

  defp restore_recovery_timer(%{state: :open, recovery_deadline_ms: deadline_ms} = state)
       when is_integer(deadline_ms) do
    generation = state.recovery_timer_gen + 1
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    %{
      state
      | recovery_timer_gen: generation,
        recovery_timer_ref: schedule_recovery_timer(remaining_ms, generation)
    }
  end

  defp restore_recovery_timer(state), do: state

  defp ensure_control_ring_generation(state) do
    breaker_id = {state.instance_id, state.transport}

    case :ets.lookup(Storage.control_meta_table(), breaker_id) do
      [
        {^breaker_id, generation, epoch, owner_pid, _capacity, _wakeup, _diagnostics, _ring_ref}
      ]
      when generation == state.transition_generation and epoch == state.process_epoch and
             owner_pid == self() ->
        :ok

      _ ->
        initialize_control_ring(state)
    end
  end

  defp maybe_enter_control_probation(state, generation, epoch) do
    case Snapshot.lookup({state.instance_id, state.transport}) do
      {:ok,
       %Snapshot{
         generation: ^generation,
         epoch: ^epoch,
         control_health: :degraded
       }} ->
        probation = %{
          state
          | state: :half_open,
            success_count: 0,
            inflight_count: 0,
            transition_generation: state.transition_generation + 1,
            control_health: :healthy
        }

        initialize_control_ring(probation)
        acknowledge_control_degradation(probation)
        write_ets_state(probation)
        probation

      _ ->
        state
    end
  end

  defp apply_control_signal(_signal, state, generation, epoch)
       when state.transition_generation != generation or state.process_epoch != epoch,
       do: state

  defp apply_control_signal(
         {:route_generation, route_generation, signal},
         state,
         generation,
         epoch
       ) do
    if route_generation == ConfigStore.route_generation(),
      do: apply_control_signal(signal, state, generation, epoch),
      else: state
  end

  defp apply_control_signal(:neutral, state, _generation, _epoch), do: state

  defp apply_control_signal(:success, state, _generation, _epoch) do
    classify_and_update_state_for_report({:ok, :control_success}, state)
  end

  defp apply_control_signal({:failure, category, breaker_penalty?}, state, _generation, _epoch) do
    error =
      JError.new(-32_000, "Bounded breaker control failure",
        category: category,
        retriable?: true,
        breaker_penalty?: breaker_penalty?
      )

    classify_and_update_state_for_report({:error, error}, state)
  end

  defp classify_and_handle_result(result, state) do
    case result do
      {:ok, value} ->
        handle_success(value, state)

      {:error, %JError{retriable?: true} = reason} ->
        if shared_breaker_penalty?(reason, state) do
          handle_failure(reason, state)
        else
          handle_non_breaker_error({:error, reason}, state)
        end

      {:error, %JError{retriable?: false} = reason} ->
        handle_non_breaker_error({:error, reason}, state)

      {:error, reason} ->
        jerr =
          ErrorNormalizer.normalize(reason,
            instance_id: state.instance_id,
            transport: state.transport
          )

        if jerr.retriable? and shared_breaker_penalty?(jerr, state) do
          handle_failure(jerr, state)
        else
          handle_non_breaker_error({:error, jerr}, state)
        end

      other ->
        Logger.error("Circuit breaker received unexpected result shape after normalization",
          shape: inspect(other),
          instance_id: state.instance_id,
          transport: state.transport
        )

        jerr =
          JError.new(-32_000, "Internal error: unexpected circuit breaker result shape",
            category: :internal_error,
            retriable?: false
          )

        handle_failure(jerr, state)
    end
  end

  defp classify_and_update_state_for_report(result, state) do
    case classify_and_handle_result(result, state) do
      {:reply, _reply, new_state} -> new_state
    end
  end

  defp handle_non_breaker_error(error_result, state) do
    if state.state == :open do
      {:reply, {:error, :circuit_open}, state}
    else
      {:reply, error_result, state}
    end
  end

  defp handle_success(result, state) do
    effective_threshold = effective_success_threshold(state)

    case state.state do
      :closed ->
        new_state = %{state | failure_count: 0}
        {:reply, {:ok, result}, new_state}

      :open ->
        cancel_recovery_timer(state.recovery_timer_ref)

        :telemetry.execute([:lasso, :circuit_breaker, :half_open], %{count: 1}, %{
          instance_id: state.instance_id,
          transport: state.transport,
          from_state: :open,
          to_state: :half_open,
          reason: :recovery_attempt,
          consecutive_open_count: state.consecutive_open_count
        })

        if 1 >= effective_threshold do
          reset_to_closed(%{state | recovery_timer_ref: nil}, :open, result)
        else
          new_state = %{
            state
            | state: :half_open,
              success_count: 1,
              failure_count: 0,
              inflight_count: 0,
              recovery_timer_ref: nil,
              transition_generation: state.transition_generation + 1
          }

          publish_circuit_event(new_state, :open, :half_open, :recovery_attempt)
          write_ets_state(new_state)
          {:reply, {:ok, result}, new_state}
        end

      :half_open ->
        new_success_count = state.success_count + 1

        if new_success_count >= effective_threshold do
          reset_to_closed(state, :half_open, result)
        else
          new_state = %{state | success_count: new_success_count}
          {:reply, {:ok, result}, new_state}
        end
    end
  end

  defp reset_to_closed(state, from_state, result) do
    acknowledge_control_degradation(state)

    new_state = %{
      state
      | state: :closed,
        failure_count: 0,
        success_count: 0,
        inflight_count: 0,
        last_failure_time: nil,
        opened_by_category: nil,
        recovery_timer_ref: nil,
        last_open_error: nil,
        consecutive_open_count: 0,
        recovery_deadline_ms: nil,
        effective_recovery_delay: nil,
        transition_generation: state.transition_generation + 1,
        control_health: :healthy
    }

    write_ets_state(new_state)

    :telemetry.execute([:lasso, :circuit_breaker, :close], %{count: 1}, %{
      instance_id: state.instance_id,
      transport: state.transport,
      from_state: from_state,
      to_state: :closed,
      reason: :recovered
    })

    publish_circuit_event(new_state, from_state, :closed, :recovered)
    {:reply, {:ok, result}, new_state}
  end

  defp effective_success_threshold(%{opened_by_category: :rate_limit}), do: 1
  defp effective_success_threshold(state), do: state.success_threshold

  defp handle_failure(error, state) do
    new_failure_count = state.failure_count + 1
    current_time = System.monotonic_time(:millisecond)

    error_category = if is_struct(error, JError), do: error.category, else: :unknown_error
    threshold = Map.get(state.category_thresholds, error_category, state.failure_threshold)

    adjusted_recovery_timeout =
      cond do
        error_category == :rate_limit and is_struct(error, JError) ->
          extract_retry_after(error) || state.base_recovery_timeout

        Map.has_key?(state.category_recovery_timeouts, error_category) ->
          state.category_recovery_timeouts[error_category]

        true ->
          state.base_recovery_timeout
      end

    case state.state do
      :closed ->
        if new_failure_count >= threshold do
          delay = adjusted_recovery_timeout
          delay_with_jitter = add_jitter(delay)
          new_gen = state.recovery_timer_gen + 1
          timer_ref = schedule_recovery_timer(delay_with_jitter, new_gen)

          new_state = %{
            state
            | state: :open,
              failure_count: new_failure_count,
              last_failure_time: current_time,
              inflight_count: 0,
              opened_by_category: error_category,
              recovery_timer_ref: timer_ref,
              recovery_timer_gen: new_gen,
              transition_generation: state.transition_generation + 1,
              recovery_deadline_ms: current_time + delay_with_jitter,
              effective_recovery_delay: delay,
              last_open_error: extract_error_info(error)
          }

          write_ets_state(new_state)
          emit_failure_event(state, error_category)

          :telemetry.execute([:lasso, :circuit_breaker, :open], %{count: 1}, %{
            instance_id: state.instance_id,
            transport: state.transport,
            from_state: :closed,
            to_state: :open,
            reason: :failure_threshold_exceeded,
            error_category: error_category,
            failure_count: new_failure_count,
            recovery_timeout_ms: adjusted_recovery_timeout
          })

          publish_circuit_event(new_state, :closed, :open, :failure_threshold_exceeded, error)
          {:reply, {:error, :circuit_opening}, new_state}
        else
          new_state = %{state | failure_count: new_failure_count, last_failure_time: current_time}
          emit_failure_event(state, error_category)
          {:reply, {:error, error}, new_state}
        end

      :half_open ->
        new_consecutive_open_count = state.consecutive_open_count + 1

        new_state_for_backoff = %{state | consecutive_open_count: new_consecutive_open_count}
        delay = compute_reopen_delay(new_state_for_backoff, error, error_category)
        delay_with_jitter = add_jitter(delay)
        new_gen = state.recovery_timer_gen + 1
        now = System.monotonic_time(:millisecond)
        timer_ref = schedule_recovery_timer(delay_with_jitter, new_gen)

        new_state = %{
          state
          | state: :open,
            failure_count: new_failure_count,
            last_failure_time: current_time,
            success_count: 0,
            inflight_count: 0,
            recovery_timer_ref: timer_ref,
            recovery_timer_gen: new_gen,
            transition_generation: state.transition_generation + 1,
            recovery_deadline_ms: now + delay_with_jitter,
            effective_recovery_delay: delay,
            last_open_error: extract_error_info(error),
            consecutive_open_count: new_consecutive_open_count,
            opened_by_category: error_category
        }

        write_ets_state(new_state)
        emit_failure_event(state, error_category)

        :telemetry.execute([:lasso, :circuit_breaker, :open], %{count: 1}, %{
          instance_id: state.instance_id,
          transport: state.transport,
          from_state: :half_open,
          to_state: :open,
          reason: :reopen_due_to_failure,
          error_category: error_category,
          failure_count: new_failure_count,
          recovery_timeout_ms: delay,
          consecutive_open_count: new_consecutive_open_count
        })

        publish_circuit_event(new_state, :half_open, :open, :reopen_due_to_failure, error)
        {:reply, {:error, :circuit_reopening}, new_state}

      :open ->
        new_state = %{
          state
          | failure_count: new_failure_count,
            last_failure_time: current_time
        }

        emit_failure_event(state, error_category)
        {:reply, {:error, :circuit_open}, new_state}
    end
  end

  defp emit_failure_event(state, error_category) do
    :telemetry.execute(
      [:lasso, :circuit_breaker, :failure],
      %{count: 1},
      %{
        instance_id: state.instance_id,
        transport: state.transport,
        error_category: error_category,
        circuit_state: state.state
      }
    )
  end

  defp compute_reopen_delay(state, error, error_category) do
    explicit_retry_after =
      if error_category == :rate_limit and is_struct(error, JError) do
        extract_retry_after(error)
      end

    if explicit_retry_after do
      min(explicit_retry_after, state.max_recovery_timeout)
    else
      base = state.base_recovery_timeout
      multiplier = trunc(:math.pow(2, min(state.consecutive_open_count, 4)))
      min(base * multiplier, state.max_recovery_timeout)
    end
  end

  defp add_jitter(delay_ms) do
    jitter_ms = :rand.uniform(max(1, div(delay_ms, 20)))
    delay_ms + jitter_ms
  end

  defp schedule_recovery_timer(delay_ms, gen) do
    Process.send_after(self(), {:attempt_proactive_recovery, gen}, delay_ms)
  end

  defp cancel_recovery_timer(nil), do: :ok

  defp cancel_recovery_timer(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  defp write_ets_state(state) do
    ensure_control_ring_generation(state)

    breaker_id = {state.instance_id, state.transport}

    control_health =
      if ControlRing.failure_drop_pending?(
           breaker_id,
           state.transition_generation,
           state.process_epoch
         ),
         do: :degraded,
         else: state.control_health

    :ets.insert(:lasso_instance_state, {
      {:circuit, state.instance_id, state.transport},
      %{
        state: state.state,
        error: state.last_open_error,
        recovery_deadline_ms: state.recovery_deadline_ms
      }
    })

    snapshot = %Snapshot{
      breaker_id: breaker_id,
      state: state.state,
      generation: state.transition_generation,
      epoch: state.process_epoch,
      owner_pid: self(),
      ready?: state.ready?,
      recovery_deadline_us: recovery_deadline_us(state.recovery_deadline_ms),
      half_open_capacity: state.half_open_max_inflight,
      half_open_inflight: state.inflight_count,
      control_health: control_health,
      failure_count: state.failure_count,
      needs_success?: state.failure_count > 0
    }

    snapshot_write_barrier(:before)
    Snapshot.put(snapshot)

    if snapshot.control_health == :healthy and
         ControlRing.failure_drop_pending?(
           breaker_id,
           state.transition_generation,
           state.process_epoch
         ) do
      Snapshot.put(%{snapshot | control_health: :degraded})
    end

    snapshot_write_barrier(:after)
  end

  defp snapshot_write_barrier(:before) do
    case Process.get(:lasso_breaker_snapshot_write_barrier) do
      {observer, before_ref, _after_ref}
      when is_pid(observer) and is_reference(before_ref) ->
        send(observer, {:breaker_snapshot_write_ready, self(), :before, before_ref})

        receive do
          ^before_ref -> :ok
        end

      _none ->
        :ok
    end
  end

  defp snapshot_write_barrier(:after) do
    case Process.delete(:lasso_breaker_snapshot_write_barrier) do
      {observer, _before_ref, after_ref} when is_pid(observer) and is_reference(after_ref) ->
        send(observer, {:breaker_snapshot_write_ready, self(), :after, after_ref})

        receive do
          ^after_ref -> :ok
        end

      _none ->
        :ok
    end
  end

  defp acknowledge_control_degradation(state) do
    _result =
      ControlRing.acknowledge_failure_degradation(
        {state.instance_id, state.transport},
        state.transition_generation,
        state.process_epoch
      )

    :ok
  end

  defp current_fact_generation(%{identity: %{route_generation: route_generation}})
       when is_integer(route_generation) and route_generation >= 0 do
    if route_generation == ConfigStore.route_generation(),
      do: {:ok, route_generation},
      else: :stale
  end

  defp current_fact_generation(_fact), do: :stale

  defp recovery_deadline_us(nil), do: nil
  defp recovery_deadline_us(deadline_ms), do: deadline_ms * 1_000

  defp publish_circuit_event(state, from, to, reason, error \\ nil) do
    error_info =
      case error do
        %JError{code: code, category: category, message: msg} ->
          %{
            error_code: code,
            error_category: category,
            error_message: truncate_error_message(msg)
          }

        _ ->
          nil
      end

    {chain_id, refs} =
      try do
        chain_id =
          case Catalog.get_instance(state.instance_id) do
            {:ok, %{chain_id: id}} when is_integer(id) and id > 0 -> id
            _ -> nil
          end

        refs = Catalog.get_instance_refs(state.instance_id)
        {chain_id, refs}
      rescue
        ArgumentError ->
          Logger.debug(
            "Catalog unavailable for circuit event fan-out (instance: #{state.instance_id})"
          )

          {nil, []}
      end

    if is_integer(chain_id) and chain_id > 0 do
      Enum.each(refs, fn profile ->
        provider_id = Catalog.reverse_lookup_provider_id(profile, chain_id, state.instance_id)

        event =
          {:circuit_breaker_event,
           %{
             ts: System.system_time(:millisecond),
             profile: profile,
             chain: chain_id,
             chain_id: chain_id,
             provider_id: provider_id || state.instance_id,
             instance_id: state.instance_id,
             transport: state.transport,
             from: from,
             to: to,
             reason: reason,
             error: error_info,
             source_node_id: Lasso.Cluster.Topology.get_self_node_id(),
             source_node: node()
           }}

        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          Lasso.Topics.circuit_event(profile, chain_id),
          event
        )
      end)
    end
  end

  defp truncate_error_message(msg) when is_binary(msg) do
    if String.length(msg) > 100 do
      String.slice(msg, 0, 97) <> "..."
    else
      msg
    end
  end

  defp truncate_error_message(other), do: inspect(other) |> truncate_error_message()

  defp extract_retry_after(%JError{data: data}) when is_map(data) do
    Map.get(data, :retry_after_ms) || Map.get(data, "retry_after_ms")
  end

  defp extract_retry_after(_), do: nil

  defp extract_error_info(%JError{code: code, category: category, message: msg}) do
    %{
      code: code,
      category: category,
      message: truncate_error_message(msg)
    }
  end

  defp extract_error_info(_), do: nil

  # Shared circuit breakers should only trip on clearly provider-wide failures.
  # This avoids cross-profile coupling from workload-specific timeout patterns.
  defp shared_breaker_penalty?(%JError{category: :server_error}, %{shared_mode: true}), do: true
  defp shared_breaker_penalty?(%JError{category: :network_error}, %{shared_mode: true}), do: true
  defp shared_breaker_penalty?(%JError{category: :timeout}, %{shared_mode: true}), do: false
  defp shared_breaker_penalty?(%JError{category: :auth_error}, %{shared_mode: true}), do: false

  defp shared_breaker_penalty?(%JError{breaker_penalty?: penalty}, %{shared_mode: true}),
    do: penalty

  defp shared_breaker_penalty?(%JError{breaker_penalty?: penalty}, _state), do: penalty
  defp shared_breaker_penalty?(_, _state), do: false

  @doc """
  Returns the registry name for a provider transport circuit breaker.
  """
  @spec via_name({String.t(), atom()}) :: {:via, Registry, {Lasso.Registry, term()}}
  def via_name({instance_id, transport}) when is_binary(instance_id) do
    {:via, Registry, {Lasso.Registry, {:circuit_breaker, "#{instance_id}:#{transport}"}}}
  end
end

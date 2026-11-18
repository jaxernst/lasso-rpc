defmodule Lasso.BlockSync.Strategies.HttpStrategy do
  @moduledoc """
  HTTP polling strategy for block sync.

  Polls `eth_blockNumber` at a configurable interval and reports block heights
  to the parent Worker. Each poll uses one immutable profile and provider route.

  ## Health Writes

  Each successful poll writes `http_status: :healthy` to `{:health_block_sync, instance_id}`
  in ETS and signals circuit breaker recovery. Failed polls write `http_status` as
  `:degraded` (2+) or `:unhealthy` (5+). This key is exclusively owned by HttpStrategy;
  ProbeCoordinator writes to `{:health_probe, instance_id}` separately.

  ## Circuit Breaker Integration

  Goes through the shared HTTP circuit breaker keyed by `{instance_id, :http}`.
  When the circuit is open, polling is skipped.
  """

  @behaviour Lasso.BlockSync.Strategy

  require Logger

  alias Lasso.BlockSync.{Observation, Registry}
  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.Core.Support.{CircuitBreaker, ErrorClassification}
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.JSONRPC.Quantity
  alias Lasso.Observations.{HeadObservation, HeadReference, HeadSnapshot}
  alias Lasso.Providers.{Catalog, HeadEvidence, InstanceState}
  alias Lasso.RPC.{RequestOptions, RequestPipeline, Response}

  @default_poll_interval_ms 15_000
  @default_timeout_ms 3_000
  @max_initial_stagger_ms 2_000
  @max_consecutive_failures 3
  @degraded_threshold 2
  @unhealthy_threshold 5
  @quota_exhaustion_poll_delay_ms :timer.hours(1)

  defmodule PollPlan do
    @moduledoc false

    @enforce_keys [
      :profile,
      :provider_id,
      :instance_id,
      :chain_id,
      :caller_pid,
      :started_at_us,
      :deadline_us,
      :head_references_at_poll_start
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            profile: String.t(),
            provider_id: String.t(),
            instance_id: String.t(),
            chain_id: pos_integer(),
            caller_pid: pid(),
            started_at_us: integer(),
            deadline_us: integer(),
            head_references_at_poll_start: [HeadReference.t()]
          }
  end

  defmodule PollOutcome do
    @moduledoc false

    @enforce_keys [:result, :completed_at_us, :observed_at_ms]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            result: {:ok, non_neg_integer()} | {:error, term()},
            completed_at_us: integer(),
            observed_at_ms: integer()
          }
  end

  defstruct [
    :instance_id,
    :chain_id,
    :parent,
    :poll_interval_ms,
    :timer_ref,
    :poll_generation,
    :poll_owner_id,
    :poll_owner_pid,
    :poll_owner_ref,
    :poll_plan,
    :poll_runner,
    :route_resolver,
    :head_reference_resolver,
    :consecutive_failures,
    :last_height,
    :last_poll_time
  ]

  @type t :: %__MODULE__{
          instance_id: String.t(),
          chain_id: pos_integer(),
          parent: pid(),
          poll_interval_ms: non_neg_integer(),
          timer_ref: reference() | nil,
          poll_generation: reference() | nil,
          poll_owner_id: reference() | nil,
          poll_owner_pid: pid() | nil,
          poll_owner_ref: reference() | nil,
          poll_plan: PollPlan.t() | nil,
          poll_runner: (PollPlan.t() -> {:ok, non_neg_integer()} | {:error, term()}),
          route_resolver: (String.t(), pos_integer() ->
                             {:ok, String.t(), String.t()} | {:error, term()}),
          head_reference_resolver: (String.t(), pos_integer(), integer() ->
                                      [HeadReference.t()]),
          consecutive_failures: non_neg_integer(),
          last_height: non_neg_integer() | nil,
          last_poll_time: integer() | nil
        }

  ## Strategy Callbacks

  @impl true
  def start(chain_id, instance_id, opts) do
    parent = Keyword.get(opts, :parent, self())
    poll_interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)

    initial_delay_ms =
      case Keyword.get_lazy(opts, :initial_delay_ms, fn ->
             initial_poll_delay_ms(chain_id, instance_id, poll_interval)
           end) do
        delay_ms when is_integer(delay_ms) and delay_ms >= 0 ->
          delay_ms

        invalid ->
          raise ArgumentError, "initial_delay_ms must be non-negative, got: #{inspect(invalid)}"
      end

    state = %__MODULE__{
      instance_id: instance_id,
      chain_id: chain_id,
      parent: parent,
      poll_interval_ms: poll_interval,
      consecutive_failures: 0,
      last_height: nil,
      last_poll_time: nil,
      timer_ref: nil,
      poll_generation: nil,
      poll_owner_id: nil,
      poll_owner_pid: nil,
      poll_owner_ref: nil,
      poll_plan: nil,
      poll_runner: Keyword.get(opts, :poll_runner, &run_poll/1),
      route_resolver: Keyword.get(opts, :route_resolver, &resolve_route/2),
      head_reference_resolver: Keyword.get(opts, :head_reference_resolver, &head_references/3)
    }

    state = schedule_poll(state, initial_delay_ms)

    {:ok, state}
  end

  @impl true
  def stop(%__MODULE__{timer_ref: ref, poll_owner_pid: owner_pid, poll_owner_ref: owner_ref}) do
    if ref, do: Process.cancel_timer(ref)
    if owner_ref, do: Process.demonitor(owner_ref, [:flush])
    if is_pid(owner_pid) and Process.alive?(owner_pid), do: Process.exit(owner_pid, :kill)
    :ok
  end

  @impl true
  def healthy?(%__MODULE__{consecutive_failures: failures}) do
    failures < @max_consecutive_failures
  end

  @impl true
  def source, do: :http

  @impl true
  def get_status(%__MODULE__{} = state) do
    %{
      consecutive_failures: state.consecutive_failures,
      last_height: state.last_height,
      last_poll_time: state.last_poll_time,
      poll_interval_ms: state.poll_interval_ms,
      poll_inflight: is_pid(state.poll_owner_pid),
      healthy: healthy?(state)
    }
  end

  @impl true
  def handle_message(
        {:poll, generation},
        %__MODULE__{poll_generation: generation, poll_owner_pid: nil} = state
      ) do
    state = %{state | timer_ref: nil, poll_generation: nil}
    cooldown = InstanceState.read_rate_limit(state.instance_id, :http).remaining_ms || 0
    delay_ms = max(cooldown, client_observation_delay_ms(state, System.system_time(:millisecond)))

    if delay_ms > 0 do
      {:ok, schedule_poll(state, delay_ms)}
    else
      {:ok, start_poll_owner(state)}
    end
  end

  def handle_message({:poll, _stale_generation}, %__MODULE__{} = state), do: {:ok, state}

  def handle_message(
        {:poll_result, owner_id, owner_pid, result_or_outcome},
        %__MODULE__{
          poll_owner_id: owner_id,
          poll_owner_pid: owner_pid,
          poll_owner_ref: owner_ref,
          poll_plan: plan
        } = state
      ) do
    Process.demonitor(owner_ref, [:flush])
    outcome = normalize_poll_outcome(result_or_outcome)
    next_delay_ms = next_poll_delay_ms(outcome.result, state.poll_interval_ms)

    state =
      state
      |> clear_poll_owner()
      |> apply_poll_result(outcome, plan)
      |> schedule_poll(next_delay_ms)

    {:ok, state}
  end

  def handle_message(
        {:DOWN, owner_ref, :process, owner_pid, reason},
        %__MODULE__{poll_owner_pid: owner_pid, poll_owner_ref: owner_ref, poll_plan: plan} = state
      ) do
    state =
      state
      |> clear_poll_owner()
      |> apply_poll_result({:error, {:poll_owner_exit, reason}}, plan)
      |> schedule_poll(state.poll_interval_ms)

    {:ok, state}
  end

  def handle_message(_other, state) do
    {:ok, state}
  end

  @spec poll_now(t()) :: t()
  def poll_now(%__MODULE__{poll_owner_pid: owner_pid} = state) when is_pid(owner_pid),
    do: state

  def poll_now(%__MODULE__{} = state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    schedule_poll(%{state | timer_ref: nil, poll_generation: nil}, 0)
  end

  @spec set_poll_interval(t(), pos_integer()) :: t()
  def set_poll_interval(%__MODULE__{} = state, interval_ms)
      when is_integer(interval_ms) and interval_ms > 0 do
    state = %{state | poll_interval_ms: interval_ms}

    if state.poll_owner_pid do
      state
    else
      if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
      schedule_poll(state, interval_ms)
    end
  end

  ## Private Functions

  @doc "Remaining routine-poll delay covered by fresh HTTP client evidence."
  @spec client_observation_delay_ms(t(), integer()) :: non_neg_integer()
  def client_observation_delay_ms(%{consecutive_failures: failures}, _now_ms) when failures > 0,
    do: 0

  def client_observation_delay_ms(state, now_ms) do
    case Registry.get_observation(state.chain_id, state.instance_id, :http) do
      {:ok,
       %HeadObservation{
         observed_at_ms: observed_at_ms,
         attributes: %{collection: :client, evidence_freshness_ms: freshness_ms}
       }}
      when is_integer(freshness_ms) and freshness_ms > 0 and observed_at_ms <= now_ms ->
        policy_freshness =
          Observation.stale_after_ms(state.instance_id, state.chain_id, :http)

        max(
          0,
          min(state.poll_interval_ms, min(freshness_ms, policy_freshness)) -
            (now_ms - observed_at_ms)
        )

      _ ->
        0
    end
  end

  defp schedule_poll(state, delay_ms) do
    generation = make_ref()

    ref =
      Process.send_after(
        state.parent,
        {:http_strategy, :poll, state.instance_id, generation},
        delay_ms
      )

    %{state | timer_ref: ref, poll_generation: generation}
  end

  @doc false
  @spec initial_poll_delay_ms(pos_integer(), String.t(), pos_integer()) :: non_neg_integer()
  def initial_poll_delay_ms(chain_id, instance_id, poll_interval_ms)
      when is_integer(chain_id) and chain_id > 0 and is_binary(instance_id) and
             is_integer(poll_interval_ms) and poll_interval_ms > 0 do
    stagger_window_ms = min(poll_interval_ms, @max_initial_stagger_ms)
    :erlang.phash2({chain_id, instance_id}, stagger_window_ms)
  end

  defp start_poll_owner(state) do
    case build_poll_plan(state, state.parent) do
      {:ok, plan} ->
        parent = state.parent
        instance_id = state.instance_id
        owner_id = make_ref()
        runner = state.poll_runner

        {owner_pid, owner_ref} =
          spawn_monitor(fn ->
            result = safely_run_poll(runner, plan)

            outcome = %PollOutcome{
              result: result,
              completed_at_us: System.monotonic_time(:microsecond),
              observed_at_ms: System.system_time(:millisecond)
            }

            send(parent, {:http_strategy, :poll_result, instance_id, owner_id, self(), outcome})
          end)

        %{
          state
          | poll_owner_id: owner_id,
            poll_owner_pid: owner_pid,
            poll_owner_ref: owner_ref,
            poll_plan: plan
        }

      {:error, reason} ->
        state
        |> apply_poll_result({:error, reason}, nil)
        |> schedule_poll(state.poll_interval_ms)
    end
  end

  defp safely_run_poll(runner, plan) do
    runner.(plan)
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp build_poll_plan(state, caller_pid) do
    started_at_us = System.monotonic_time(:microsecond)
    started_at_ms = System.system_time(:millisecond)

    with {:ok, profile, provider_id} <-
           state.route_resolver.(state.instance_id, state.chain_id) do
      {:ok,
       %PollPlan{
         profile: profile,
         provider_id: provider_id,
         instance_id: state.instance_id,
         chain_id: state.chain_id,
         caller_pid: caller_pid,
         started_at_us: started_at_us,
         deadline_us: started_at_us + @default_timeout_ms * 1_000,
         head_references_at_poll_start:
           state.head_reference_resolver.(state.instance_id, state.chain_id, started_at_ms)
       }}
    end
  end

  defp head_references(instance_id, chain_id, captured_at_ms) do
    snapshot = Catalog.snapshot()

    references =
      instance_id
      |> Catalog.get_instance_refs()
      |> Enum.sort()
      |> Enum.flat_map(fn profile ->
        with {:ok, head_snapshot} <- HeadEvidence.snapshot(profile, chain_id, captured_at_ms),
             {:ok, reference} <- HeadSnapshot.reference(head_snapshot),
             true <- valid_reference_time?(reference, captured_at_ms) do
          [%{reference | captured_at_ms: captured_at_ms}]
        else
          _unqualified_or_stale -> []
        end
      end)

    case snapshot do
      %{generation: _generation} ->
        if Catalog.snapshot() == snapshot,
          do: references,
          else: []

      _unavailable ->
        []
    end
  end

  defp valid_reference_time?(%HeadReference{observed_at_ms: nil}, _captured_at_ms), do: true

  defp valid_reference_time?(%HeadReference{observed_at_ms: observed_at_ms}, captured_at_ms),
    do: observed_at_ms <= captured_at_ms

  defp clear_poll_owner(state) do
    %{
      state
      | poll_owner_id: nil,
        poll_owner_pid: nil,
        poll_owner_ref: nil,
        poll_plan: nil
    }
  end

  defp apply_poll_result(state, result, plan) do
    outcome = normalize_poll_outcome(result)

    latency_ms =
      if plan,
        do: max(div(outcome.completed_at_us - plan.started_at_us, 1_000), 0),
        else: 0

    case outcome.result do
      {:ok, height} ->
        {:ok, observation} =
          HeadObservation.http(%{
            chain_id: state.chain_id,
            instance_id: state.instance_id,
            height: height,
            observed_at_ms: outcome.observed_at_ms,
            latency_ms: latency_ms,
            sample_interval_ms: state.poll_interval_ms,
            poll_references: if(plan, do: plan.head_references_at_poll_start, else: [])
          })

        send(state.parent, {:head_observation, observation})
        write_health_success(state.instance_id)
        CircuitBreaker.signal_recovery_cast({state.instance_id, :http})

        new_state = %{
          state
          | consecutive_failures: 0,
            last_height: height,
            last_poll_time: outcome.observed_at_ms
        }

        if state.consecutive_failures >= @max_consecutive_failures do
          send(state.parent, {:status, state.instance_id, :http, :healthy})
        end

        new_state

      {:error, reason} ->
        state
        |> apply_poll_error(reason)
        |> Map.put(:last_poll_time, outcome.observed_at_ms)
    end
  end

  defp normalize_poll_outcome(%PollOutcome{} = outcome), do: outcome

  defp normalize_poll_outcome(result) do
    %PollOutcome{
      result: result,
      completed_at_us: System.monotonic_time(:microsecond),
      observed_at_ms: System.system_time(:millisecond)
    }
  end

  defp apply_poll_error(state, %JError{data: %{reason: :upstream_request_budget_exhausted}}),
    do: state

  defp apply_poll_error(state, %JError{category: category} = reason) do
    if ErrorClassification.provider_health_failure?(category) do
      apply_health_failure(state, reason)
    else
      if category == :rate_limit do
        InstanceState.record_rate_limit(
          state.instance_id,
          :http,
          rate_limit_ttl_ms(reason, state.poll_interval_ms)
        )
      end

      write_health_success(state.instance_id)
      maybe_signal_recovery(state)
      %{state | consecutive_failures: 0}
    end
  end

  defp apply_poll_error(state, reason), do: apply_health_failure(state, reason)

  defp apply_health_failure(state, reason) do
    failures = state.consecutive_failures + 1
    write_health_failure(state.instance_id, failures, reason)

    if failures == @max_consecutive_failures do
      Logger.warning("HTTP polling degraded",
        chain_id: state.chain_id,
        instance_id: state.instance_id,
        consecutive_failures: failures,
        error: inspect(reason)
      )

      send(state.parent, {:status, state.instance_id, :http, :degraded})
    end

    %{state | consecutive_failures: failures}
  end

  defp maybe_signal_recovery(%{consecutive_failures: failures} = state)
       when failures >= @max_consecutive_failures do
    send(state.parent, {:status, state.instance_id, :http, :healthy})
  end

  defp maybe_signal_recovery(_state), do: :ok

  defp rate_limit_ttl_ms(%JError{data: data} = error, poll_interval_ms) do
    retry_after_ms =
      if is_map(data),
        do: Map.get(data, :retry_after_ms) || Map.get(data, "retry_after_ms"),
        else: nil

    floor_ms =
      if ErrorClassification.quota_exhausted?(error.message),
        do: @quota_exhaustion_poll_delay_ms,
        else: poll_interval_ms * 2

    max(valid_retry_after_ms(retry_after_ms), floor_ms)
  end

  defp next_poll_delay_ms({:error, %JError{category: :rate_limit} = error}, poll_interval_ms),
    do: rate_limit_ttl_ms(error, poll_interval_ms)

  defp next_poll_delay_ms(_result, poll_interval_ms), do: poll_interval_ms

  defp valid_retry_after_ms(value) when is_integer(value) and value > 0, do: value
  defp valid_retry_after_ms(_value), do: 30_000

  defp write_health_success(instance_id) do
    :ets.insert(
      :lasso_instance_state,
      {{:health_block_sync, instance_id},
       %{http_status: :healthy, last_health_check: System.system_time(:millisecond)}}
    )
  end

  defp write_health_failure(instance_id, consecutive_failures, _reason) do
    http_status =
      cond do
        consecutive_failures >= @unhealthy_threshold -> :unhealthy
        consecutive_failures >= @degraded_threshold -> :degraded
        true -> :healthy
      end

    :ets.insert(
      :lasso_instance_state,
      {{:health_block_sync, instance_id},
       %{http_status: http_status, last_health_check: System.system_time(:millisecond)}}
    )
  end

  defp run_poll(%PollPlan{} = plan) do
    timeout_ms = remaining_timeout_ms(plan.deadline_us)

    if timeout_ms == 0 do
      {:error, :deadline_exhausted}
    else
      scope =
        if plan.caller_pid == self(),
          do: ExecutionScope.local(self(), plan.deadline_us),
          else: ExecutionScope.monitored(self(), plan.caller_pid, plan.deadline_us)

      opts = %RequestOptions{
        profile: plan.profile,
        strategy: :priority,
        provider_override: plan.provider_id,
        transport: :http,
        failover_on_override: false,
        timeout_ms: timeout_ms,
        request_origin: :system,
        request_id: "block-sync:#{plan.instance_id}:#{plan.started_at_us}"
      }

      case RequestPipeline.execute_owned(scope, plan.chain_id, "eth_blockNumber", [], opts) do
        {:ok, response, _ctx} ->
          decode_poll_response(response)

        {:error, reason, _ctx} ->
          {:error, consume_poll_error(reason)}
      end
    end
  end

  defp consume_poll_error(%JError{} = error) do
    Lasso.RPC.Response.Capacity.release(error, :poll_consumed)

    retry_after =
      if is_map(error.data),
        do: Map.get(error.data, :retry_after_ms) || Map.get(error.data, "retry_after_ms")

    summary = JError.summary(error)

    summary =
      if ErrorClassification.quota_exhausted?(error.message),
        do: %{summary | message: "quota exhausted"},
        else: summary

    if is_integer(retry_after) and retry_after > 0,
      do: %{
        summary
        | data: Map.merge(Map.take(error.data || %{}, [:reason]), %{retry_after_ms: retry_after})
      },
      else: summary
  end

  defp consume_poll_error(error), do: error

  @doc false
  @spec decode_poll_response(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  def decode_poll_response(%Response.Success{} = response) do
    Response.Success.consume_capacity(response, :block_sync_consumed, &decode_poll_result/1)
  end

  def decode_poll_response(response) do
    decode_poll_result(response)
  end

  defp decode_poll_result(response) do
    with {:ok, result} <- decode_result(response) do
      case Quantity.decode(result) do
        {:ok, height} -> {:ok, height}
        {:error, :invalid_quantity} -> {:error, {:unexpected_result, result}}
      end
    end
  end

  defp decode_result(%Response.Success{} = response), do: Response.Success.decode_result(response)
  defp decode_result(result), do: {:ok, result}

  defp resolve_route(instance_id, chain_id) do
    snapshot = Catalog.snapshot()

    route =
      instance_id
      |> Catalog.get_instance_refs()
      |> Enum.sort()
      |> Enum.find_value(fn profile ->
        case Catalog.reverse_lookup_provider_id(profile, chain_id, instance_id) do
          provider_id when is_binary(provider_id) -> {profile, provider_id}
          _missing -> nil
        end
      end)

    case route do
      {profile, provider_id}
      when not is_nil(snapshot) ->
        if Catalog.snapshot() == snapshot,
          do: {:ok, profile, provider_id},
          else: {:error, :route_changed}

      nil ->
        {:error, :no_provider_id}

      _stale ->
        {:error, :route_changed}
    end
  end

  defp remaining_timeout_ms(deadline_us) do
    max(div(deadline_us - System.monotonic_time(:microsecond), 1_000), 0)
  end
end

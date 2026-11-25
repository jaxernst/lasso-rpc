defmodule Lasso.BlockSync.Strategies.HttpStrategy do
  @moduledoc """
  HTTP head polling for block sync.

  Polls `eth_blockNumber` when its chain's `Lasso.BlockSync.Round` asks and the
  instance's own interval is due, then reports the height to the parent Worker
  and the outcome to the round. Each poll uses one immutable profile and
  provider route and runs in a disposable owner process, so a crash in one
  upstream's request fails only that poll.

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

  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.Core.Support.{CircuitBreaker, ErrorClassification}
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.JSONRPC.Quantity
  alias Lasso.Observations.{HeadObservation, HeadReference, HeadSnapshot}
  alias Lasso.Providers.{Catalog, HeadEvidence, InstanceState}
  alias Lasso.RPC.{RequestOptions, RequestPipeline, Response}

  @default_poll_interval_ms 15_000
  @default_timeout_ms 3_000
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
    defstruct @enforce_keys ++ [:answer_to]

    @type t :: %__MODULE__{
            profile: String.t(),
            provider_id: String.t(),
            instance_id: String.t(),
            chain_id: pos_integer(),
            caller_pid: pid(),
            started_at_us: integer(),
            deadline_us: integer(),
            head_references_at_poll_start: [HeadReference.t()],
            answer_to: {pid(), reference()} | nil
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
    :poll_owner_id,
    :poll_owner_pid,
    :poll_owner_ref,
    :poll_plan,
    :poll_runner,
    :route_resolver,
    :head_reference_resolver,
    :consecutive_failures,
    :last_height,
    :last_poll_time,
    :last_poll_started_ms
  ]

  @type t :: %__MODULE__{
          instance_id: String.t(),
          chain_id: pos_integer(),
          parent: pid(),
          poll_interval_ms: non_neg_integer(),
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
          last_poll_time: integer() | nil,
          last_poll_started_ms: integer() | nil
        }

  ## Strategy Callbacks

  @impl true
  def start(chain_id, instance_id, opts) do
    {:ok,
     %__MODULE__{
       instance_id: instance_id,
       chain_id: chain_id,
       parent: Keyword.get(opts, :parent, self()),
       poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
       consecutive_failures: 0,
       poll_runner: Keyword.get(opts, :poll_runner, &run_poll/1),
       route_resolver: Keyword.get(opts, :route_resolver, &resolve_route/2),
       head_reference_resolver: Keyword.get(opts, :head_reference_resolver, &head_references/3)
     }}
  end

  @impl true
  def stop(%__MODULE__{poll_owner_pid: owner_pid, poll_owner_ref: owner_ref}) do
    if is_pid(owner_pid) do
      monitor = Process.monitor(owner_pid)
      Process.exit(owner_pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, ^owner_pid, _} -> :ok
      end
    end

    if owner_ref, do: Process.demonitor(owner_ref, [:flush])
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
        {:poll_result, owner_id, owner_pid, result_or_outcome},
        %__MODULE__{
          poll_owner_id: owner_id,
          poll_owner_pid: owner_pid,
          poll_owner_ref: owner_ref,
          poll_plan: plan
        } = state
      ) do
    Process.demonitor(owner_ref, [:flush])

    state =
      state
      |> clear_poll_owner()
      |> apply_poll_result(result_or_outcome, plan)

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

    {:ok, state}
  end

  def handle_message(_other, state) do
    {:ok, state}
  end

  @doc """
  Whether a round that ticks every `round_interval_ms` should poll this instance
  now: its own interval falls due within half a round, no rate-limit cooldown
  is running and a rate-limited poll's full interval has passed.
  """
  @spec due?(t(), integer(), non_neg_integer()) :: boolean()
  def due?(%__MODULE__{} = state, now_ms, round_interval_ms) do
    (InstanceState.read_rate_limit(state.instance_id, :http).remaining_ms || 0) == 0 and
      not InstanceState.head_poll_held?(state.instance_id) and
      (is_nil(state.last_poll_started_ms) or
         now_ms - state.last_poll_started_ms >=
           state.poll_interval_ms - div(round_interval_ms, 2))
  end

  @doc """
  Starts a poll unless one is in flight. When `answer_to` names a round, the
  outcome is sent to it as `{:round_answer, ref, instance_id, interval_ms, result}`.
  """
  @spec poll(t(), {pid(), reference()} | nil) :: {:polling | :busy, t()}
  def poll(state, answer_to \\ nil)

  def poll(%__MODULE__{poll_owner_pid: owner_pid} = state, _answer_to) when is_pid(owner_pid),
    do: {:busy, state}

  def poll(%__MODULE__{} = state, answer_to), do: {:polling, start_poll_owner(state, answer_to)}

  @spec set_poll_interval(t(), pos_integer()) :: t()
  def set_poll_interval(%__MODULE__{} = state, interval_ms)
      when is_integer(interval_ms) and interval_ms > 0,
      do: %{state | poll_interval_ms: interval_ms}

  ## Private Functions

  defp start_poll_owner(state, answer_to) do
    state = %{state | last_poll_started_ms: System.system_time(:millisecond)}

    case build_poll_plan(state, state.parent, answer_to) do
      {:ok, plan} ->
        parent = state.parent
        instance_id = state.instance_id
        owner_id = make_ref()
        runner = state.poll_runner
        poll_interval_ms = state.poll_interval_ms

        {owner_pid, owner_ref} =
          spawn_monitor(fn ->
            result = safely_run_poll(runner, plan)
            hold_rate_limited(instance_id, poll_interval_ms, result)

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
        |> apply_poll_result({:error, reason}, %{answer_to: answer_to})
    end
  end

  defp safely_run_poll(runner, plan) do
    runner.(plan)
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp build_poll_plan(state, caller_pid, answer_to) do
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
           state.head_reference_resolver.(state.instance_id, state.chain_id, started_at_ms),
         answer_to: answer_to
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
    answer_round(state, plan, outcome.result)

    latency_ms =
      case plan do
        %PollPlan{started_at_us: started_at_us} ->
          max(div(outcome.completed_at_us - started_at_us, 1_000), 0)

        _no_plan ->
          0
      end

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
            poll_references: Map.get(plan, :head_references_at_poll_start, [])
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

  defp answer_round(state, %{answer_to: {round_pid, ref}}, result) do
    sample =
      case result do
        {:ok, height} -> {:ok, height}
        {:error, _reason} -> :error
      end

    send(round_pid, {:round_answer, ref, state.instance_id, state.poll_interval_ms, sample})
  end

  defp answer_round(_state, _plan, _result), do: :ok

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

  defp rate_limit_ttl_ms(%JError{data: data} = error) do
    retry_after_ms =
      if is_map(data),
        do: Map.get(data, :retry_after_ms) || Map.get(data, "retry_after_ms"),
        else: nil

    ttl_ms = valid_retry_after_ms(retry_after_ms)

    if ErrorClassification.quota_exhausted?(error.message),
      do: max(ttl_ms, @quota_exhaustion_poll_delay_ms),
      else: ttl_ms
  end

  # The poll's owner records the routing cooldown and holds the next poll for at
  # least a full interval before the worker sees the result, so both survive a
  # worker that dies first. The route may serve again once its cooldown ends.
  defp hold_rate_limited(
         _instance_id,
         _interval_ms,
         {:error, %JError{data: %{reason: :upstream_request_budget_exhausted}}}
       ),
       do: :ok

  defp hold_rate_limited(
         instance_id,
         interval_ms,
         {:error, %JError{category: :rate_limit} = error}
       ) do
    ttl_ms = rate_limit_ttl_ms(error)
    InstanceState.record_rate_limit(instance_id, :http, ttl_ms)
    InstanceState.hold_head_poll(instance_id, max(ttl_ms, interval_ms))
  end

  defp hold_rate_limited(_instance_id, _interval_ms, _result), do: :ok

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

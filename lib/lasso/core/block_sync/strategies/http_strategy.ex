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

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.{RequestOptions, RequestPipeline, Response}

  @default_poll_interval_ms 15_000
  @default_timeout_ms 3_000
  @max_initial_stagger_ms 2_000
  @max_consecutive_failures 3
  @degraded_threshold 2
  @unhealthy_threshold 5

  defmodule PollPlan do
    @moduledoc false

    @enforce_keys [
      :profile,
      :provider_id,
      :instance_id,
      :chain_id,
      :caller_pid,
      :started_at_us,
      :deadline_us
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            profile: String.t(),
            provider_id: String.t(),
            instance_id: String.t(),
            chain_id: pos_integer(),
            caller_pid: pid(),
            started_at_us: integer(),
            deadline_us: integer()
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
      route_resolver: Keyword.get(opts, :route_resolver, &resolve_route/2)
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
    {:ok, start_poll_owner(%{state | timer_ref: nil, poll_generation: nil})}
  end

  def handle_message({:poll, _stale_generation}, %__MODULE__{} = state), do: {:ok, state}

  def handle_message(
        {:poll_result, owner_id, owner_pid, result},
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
      |> apply_poll_result(result, plan)
      |> schedule_poll(state.poll_interval_ms)

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
            send(parent, {:http_strategy, :poll_result, instance_id, owner_id, self(), result})
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
         deadline_us: started_at_us + @default_timeout_ms * 1_000
       }}
    end
  end

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
    latency_ms =
      if plan,
        do: max(div(System.monotonic_time(:microsecond) - plan.started_at_us, 1_000), 0),
        else: 0

    case result do
      {:ok, height} ->
        send(state.parent, {:block_height, state.instance_id, height, %{latency_ms: latency_ms}})
        write_health_success(state.instance_id)
        CircuitBreaker.signal_recovery_cast({state.instance_id, :http})

        new_state = %{
          state
          | consecutive_failures: 0,
            last_height: height,
            last_poll_time: System.system_time(:millisecond)
        }

        if state.consecutive_failures >= @max_consecutive_failures do
          send(state.parent, {:status, state.instance_id, :http, :healthy})
        end

        new_state

      {:error, reason} ->
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

        %{
          state
          | consecutive_failures: failures,
            last_poll_time: System.system_time(:millisecond)
        }
    end
  end

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
        {:ok, response, _ctx} -> decode_poll_response(response)
        {:error, reason, _ctx} -> {:error, reason}
      end
    end
  end

  @doc false
  @spec decode_poll_response(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  def decode_poll_response(response) do
    with {:ok, result} <- decode_result(response) do
      case result do
        "0x" <> hex -> {:ok, String.to_integer(hex, 16)}
        other -> {:error, {:unexpected_result, other}}
      end
    end
  end

  defp decode_result(%Response.Success{} = response), do: Response.Success.decode_result(response)
  defp decode_result(result), do: {:ok, result}

  defp resolve_route(instance_id, chain_id) do
    snapshot = Catalog.snapshot()
    current_generation = ConfigStore.route_generation()

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
      when not is_nil(snapshot) and snapshot.generation == current_generation ->
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

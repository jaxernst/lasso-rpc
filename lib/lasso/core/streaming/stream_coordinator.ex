defmodule Lasso.Core.Streaming.StreamCoordinator do
  @moduledoc """
  Per-key coordinator that owns continuity (markers, dedupe) and orchestrates failover.

  Receives upstream events from UpstreamSubscriptionPool and provider health signals.
  Establishes a replacement before bounded replay and merges buffered live events
  through the stream dedupe state. Exhausted recovery terminates downstream
  subscriptions instead of silently continuing an incomplete stream.
  """

  use GenServer
  require Logger

  alias Lasso.Core.Support.{ContinuityPolicy, GapFiller}
  alias Lasso.Events.Subscription
  alias Lasso.Providers.Catalog

  alias Lasso.RPC.Selection

  alias Lasso.Core.Streaming.{
    ClientSubscriptionRegistry,
    StreamState
  }

  defmodule BackfillContext do
    @moduledoc false
    defstruct [
      :profile,
      :chain_id,
      :max_backfill,
      :backfill_timeout,
      :continuity_policy,
      :excluded_providers,
      :plan
    ]

    @type t :: %__MODULE__{
            profile: String.t(),
            chain_id: pos_integer(),
            max_backfill: non_neg_integer(),
            backfill_timeout: non_neg_integer(),
            continuity_policy: atom(),
            excluded_providers: [String.t()],
            plan: GapFiller.Plan.t()
          }
  end

  @type key :: {:newHeads} | {:logs, map()}

  # Circuit breaker defaults
  @default_max_failover_attempts 3
  @max_dynamic_failover_attempts 11
  @failover_cooldown_ms 5_000
  @max_event_buffer 100
  @degraded_mode_retry_delay_ms 60_000
  @default_recovery_timeout_ms 30_000

  @spec start_link({String.t(), pos_integer(), term(), keyword()}) :: GenServer.on_start()
  def start_link({profile, chain_id, key, opts})
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.start_link(__MODULE__, {profile, chain_id, key, opts},
      name: via(profile, chain_id, key)
    )
  end

  @spec via(String.t(), pos_integer(), term()) :: {:via, Registry, {atom(), tuple()}}
  def via(profile, chain_id, key)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    {:via, Registry, {Lasso.Registry, {:stream_coordinator, profile, chain_id, key}}}
  end

  # API called by UpstreamSubscriptionPool

  @spec upstream_event(
          String.t(),
          pos_integer(),
          term(),
          String.t(),
          String.t() | nil,
          term(),
          integer()
        ) ::
          :ok
  def upstream_event(profile, chain_id, key, provider_id, upstream_id, payload, received_at)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.cast(
      via(profile, chain_id, key),
      {:upstream_event, provider_id, upstream_id, payload, received_at}
    )
  end

  @spec provider_unhealthy(String.t(), pos_integer(), term(), String.t(), String.t() | nil) :: :ok
  def provider_unhealthy(profile, chain_id, key, failed_id, proposed_new_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    GenServer.cast(via(profile, chain_id, key), {:provider_unhealthy, failed_id, proposed_new_id})
  end

  @spec upstream_established(String.t(), pos_integer(), term(), String.t()) :: :ok
  def upstream_established(profile, chain_id, key, provider_id)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 and
             is_binary(provider_id) do
    GenServer.cast(via(profile, chain_id, key), {:upstream_established, provider_id})
  end

  # GenServer callbacks

  @impl true
  def init({profile, chain_id, key, opts}) do
    state = %{
      profile: profile,
      chain_id: chain_id,
      key: key,
      primary_provider_id: Keyword.get(opts, :primary_provider_id),
      state:
        StreamState.new(
          dedupe_max_items: Keyword.get(opts, :dedupe_max_items, 256),
          dedupe_max_age_ms: Keyword.get(opts, :dedupe_max_age_ms, 30_000)
        ),
      # Backfill config
      max_backfill_blocks: Keyword.get(opts, :max_backfill_blocks, 32),
      backfill_timeout: Keyword.get(opts, :backfill_timeout, 30_000),
      continuity_policy: Keyword.get(opts, :continuity_policy, :strict_abort),
      backfill_requester:
        Keyword.get(opts, :backfill_requester, &Lasso.RPC.RequestPipeline.execute_owned/5),
      backfill_provider_selector:
        Keyword.get(opts, :backfill_provider_selector, &pick_best_http_provider/3),
      replacement_requester:
        Keyword.get(opts, :replacement_requester, &request_pool_replacement/5),
      # Failover state machine
      failover_status: :active,
      failover_context: nil,
      failover_history: [],
      max_failover_attempts: Keyword.get(opts, :max_failover_attempts),
      failover_cooldown_ms: Keyword.get(opts, :failover_cooldown_ms, @failover_cooldown_ms),
      max_event_buffer: Keyword.get(opts, :max_event_buffer, @max_event_buffer),
      recovery_timeout_ms: Keyword.get(opts, :recovery_timeout_ms, @default_recovery_timeout_ms),
      recovery_deadline_us: nil
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_backfill_owner(state)
    :ok
  end

  @impl true
  def handle_cast({:upstream_event, provider_id, _upstream_id, payload, _received_at}, state) do
    case state.failover_status do
      :active ->
        if is_nil(state.primary_provider_id) or provider_id == state.primary_provider_id do
          process_event_normal(state, payload)
        else
          drop_stale_provider_event(state, provider_id)
        end

      :backfilling ->
        if provider_id == state.failover_context.new_provider_id do
          buffer_event(state, payload)
        else
          drop_stale_provider_event(state, provider_id)
        end

      :switching ->
        if provider_id == state.failover_context.new_provider_id do
          buffer_event(state, payload)
        else
          drop_stale_provider_event(state, provider_id)
        end

      :degraded ->
        # Circuit breaker triggered, drop events
        :telemetry.execute(
          [:lasso, :stream, :dropped_event],
          %{count: 1},
          %{chain_id: state.chain_id, reason: :degraded_mode}
        )

        # Info level (not debug) so degraded-mode drops are visible to ops
        # without enabling debug logging globally. Bounded volume since the
        # coordinator stays in :degraded with retry-cooldown gating.
        Logger.info("Dropping event in degraded mode",
          chain_id: state.chain_id,
          profile: state.profile,
          key: inspect(state.key)
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:provider_unhealthy, failed_id, proposed_new_id}, state) do
    if state.failover_status == :active do
      initiate_failover(state, failed_id, proposed_new_id)
    else
      Logger.warning("Ignoring provider_unhealthy signal during active failover",
        chain_id: state.chain_id,
        key: inspect(state.key),
        current_status: state.failover_status
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:upstream_established, provider_id}, %{failover_status: :active} = state) do
    {:noreply, %{state | primary_provider_id: provider_id}}
  end

  def handle_cast({:upstream_established, _provider_id}, state), do: {:noreply, state}

  # Subscription confirmation from Pool
  @impl true
  def handle_info({:subscription_confirmed, provider_id, upstream_id}, state) do
    if state.failover_status == :switching do
      start_backfill_after_replacement(state, provider_id, upstream_id)
    else
      Logger.warning("Unexpected subscription_confirmed in status #{state.failover_status}",
        chain_id: state.chain_id,
        key: inspect(state.key)
      )

      {:noreply, state}
    end
  end

  # Subscription failure from Pool
  @impl true
  def handle_info({:subscription_failed, reason}, state) do
    if state.failover_status == :switching do
      handle_resubscribe_failure(state, reason)
    else
      Logger.warning("Unexpected subscription_failed in status #{state.failover_status}",
        chain_id: state.chain_id,
        key: inspect(state.key)
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:backfill_event, owner_id, owner_pid, _provider_id, payload, _received_at},
        %{failover_status: :backfilling, failover_context: context} = state
      )
      when context.backfill_owner_id == owner_id and context.backfill_owner_pid == owner_pid do
    buffer_event(state, payload)
  end

  def handle_info({:backfill_event, _owner_id, _owner_pid, _provider_id, _payload, _at}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:backfill_result, owner_id, owner_pid, result},
        %{failover_status: :backfilling, failover_context: context} = state
      )
      when context.backfill_owner_id == owner_id and context.backfill_owner_pid == owner_pid do
    Process.demonitor(context.backfill_owner_ref, [:flush])

    case result do
      :ok -> complete_failover(state, context.new_provider_id, nil)
      {:error, reason} -> handle_backfill_failure(state, reason)
    end
  end

  def handle_info({:backfill_result, _owner_id, _owner_pid, _result}, state),
    do: {:noreply, state}

  @impl true
  def handle_info({ref, :backfill_complete}, state) when is_reference(ref),
    do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    if state.failover_context &&
         Map.get(state.failover_context, :backfill_owner_ref) == ref &&
         Map.get(state.failover_context, :backfill_owner_pid) == pid do
      Logger.error("Backfill owner crashed: #{inspect(reason)}",
        chain_id: state.chain_id,
        key: inspect(state.key)
      )

      handle_backfill_failure(state, reason)
    else
      {:noreply, state}
    end
  end

  # Retry from degraded mode
  @impl true
  def handle_info(:retry_from_degraded, state) do
    if state.failover_status == :degraded do
      Logger.info("Retrying failover from degraded mode",
        chain_id: state.chain_id,
        key: inspect(state.key)
      )

      # Clear history and try again with priority selection
      case pick_next_provider(state, []) do
        {:ok, provider_id} ->
          new_state = %{state | failover_status: :active, failover_history: []}
          initiate_failover(new_state, nil, provider_id)

        {:error, _} ->
          # Still no providers, retry after delay
          Process.send_after(self(), :retry_from_degraded, @degraded_mode_retry_delay_ms)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:failover_deadline, deadline_us}, state) do
    if state.recovery_deadline_us == deadline_us and
         state.failover_status in [:switching, :backfilling] do
      enter_degraded_mode(state, failover_budget(state))
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Internal implementation

  defp process_event_normal(state, payload) do
    case subscription_key(state.key) do
      {:newHeads} ->
        case StreamState.ingest_new_head(state.state, payload) do
          {stream_state, :emit} ->
            ClientSubscriptionRegistry.dispatch(state.profile, state.chain_id, state.key, payload)
            {:noreply, %{state | state: stream_state}}

          {stream_state, :skip} ->
            {:noreply, %{state | state: stream_state}}
        end

      {:logs, _filter} ->
        case StreamState.ingest_log(state.state, payload) do
          {stream_state, :emit} ->
            ClientSubscriptionRegistry.dispatch(state.profile, state.chain_id, state.key, payload)
            {:noreply, %{state | state: stream_state}}

          {stream_state, :skip} ->
            {:noreply, %{state | state: stream_state}}
        end
    end
  end

  defp buffer_event(state, payload) do
    if state.failover_context do
      buffer = state.failover_context.event_buffer
      buffer_count = Map.get(state.failover_context, :event_buffer_count, length(buffer))

      if buffer_count < state.max_event_buffer do
        updated_context =
          state.failover_context
          |> Map.put(:event_buffer, [payload | buffer])
          |> Map.put(:event_buffer_count, buffer_count + 1)

        {:noreply, %{state | failover_context: updated_context}}
      else
        Logger.error("Event buffer full (#{state.max_event_buffer}), entering degraded mode",
          chain_id: state.chain_id,
          key: inspect(state.key)
        )

        :telemetry.execute(
          [:lasso, :stream, :event_buffer_overflow],
          %{count: 1},
          %{chain_id: state.chain_id, profile: state.profile, key: inspect(state.key)}
        )

        enter_degraded_mode(state, failover_budget(state))
      end
    else
      {:noreply, state}
    end
  end

  defp drop_stale_provider_event(state, provider_id) do
    :telemetry.execute(
      [:lasso, :stream, :dropped_event],
      %{count: 1},
      %{
        chain_id: state.chain_id,
        reason: :stale_provider,
        provider_id: provider_id,
        primary_provider_id: state.primary_provider_id
      }
    )

    {:noreply, state}
  end

  # Standard failover initiation with empty buffer
  defp initiate_failover(state, old_provider_id, new_provider_id) do
    deadline_us =
      System.monotonic_time(:microsecond) + state.recovery_timeout_ms * 1_000

    state = %{state | recovery_deadline_us: deadline_us}

    if is_binary(new_provider_id) do
      initiate_failover_with_buffer(state, old_provider_id, new_provider_id, [])
    else
      enter_degraded_mode(state, failover_budget(state))
    end
  end

  # Failover initiation with preserved buffer (used during cascade)
  defp initiate_failover_with_buffer(state, old_provider_id, new_provider_id, initial_buffer) do
    Logger.info("Initiating failover: #{old_provider_id} -> #{new_provider_id}",
      chain_id: state.chain_id,
      key: inspect(state.key)
    )

    # Check circuit breaker
    recent_failures = count_recent_failures(state.failover_history, state.failover_cooldown_ms)

    budget = failover_budget(state)
    max_failover_attempts = budget.attempts

    if recent_failures >= max_failover_attempts do
      Logger.error(
        "Circuit breaker triggered: #{recent_failures}/#{max_failover_attempts} attempts in #{state.failover_cooldown_ms}ms",
        chain_id: state.chain_id,
        key: inspect(state.key)
      )

      enter_degraded_mode(state, budget)
    else
      excluded_providers = [old_provider_id, new_provider_id] |> Enum.reject(&is_nil/1)

      case state.backfill_provider_selector.(state.profile, state.chain_id, excluded_providers) do
        {:ok, http_provider} ->
          start_replacement(
            state,
            old_provider_id,
            new_provider_id,
            http_provider,
            initial_buffer,
            recent_failures,
            budget
          )

        {:error, reason} ->
          Logger.error("Unable to select an HTTP provider for backfill: #{inspect(reason)}",
            chain_id: state.chain_id,
            key: inspect(state.key)
          )

          enter_degraded_mode(state, budget)
      end
    end
  end

  defp start_replacement(
         state,
         old_provider_id,
         new_provider_id,
         http_provider,
         initial_buffer,
         recent_failures,
         budget
       ) do
    started_at_us = System.monotonic_time(:microsecond)
    remaining_ms = recovery_remaining_ms(state.recovery_deadline_us)

    Process.send_after(
      self(),
      {:failover_deadline, state.recovery_deadline_us},
      remaining_ms
    )

    plan =
      GapFiller.Plan.new(
        state.profile,
        state.chain_id,
        http_provider,
        self(),
        min(state.backfill_timeout, remaining_ms),
        started_at_us: started_at_us,
        requester: state.backfill_requester
      )

    backfill_ctx = %BackfillContext{
      profile: state.profile,
      chain_id: state.chain_id,
      max_backfill: state.max_backfill_blocks,
      backfill_timeout: state.backfill_timeout,
      continuity_policy: state.continuity_policy,
      excluded_providers: [old_provider_id, new_provider_id],
      plan: plan
    }

    continuity_marker = continuity_marker(state.state, state.key)

    failover_context = %{
      old_provider_id: old_provider_id,
      new_provider_id: new_provider_id,
      http_provider_id: http_provider,
      backfill_owner_id: nil,
      backfill_owner_pid: nil,
      backfill_owner_ref: nil,
      backfill_task_ref: nil,
      backfill_plan: plan,
      backfill_context: backfill_ctx,
      continuity_marker: continuity_marker,
      started_at: div(started_at_us, 1_000),
      event_buffer: initial_buffer,
      event_buffer_count: length(initial_buffer),
      attempt_count: recent_failures + 1
    }

    new_history =
      if old_provider_id do
        [
          %{provider_id: old_provider_id, failed_at: System.monotonic_time(:millisecond)}
          | state.failover_history
        ]
      else
        state.failover_history
      end

    telemetry_failover_initiated(
      state.chain_id,
      state.key,
      old_provider_id,
      new_provider_id,
      recent_failures,
      budget
    )

    broadcast_subscription_event(state, %Subscription.Failover{
      ts: System.system_time(:millisecond),
      chain_id: state.chain_id,
      subscription_type: Subscription.subscription_type(state.key),
      from_provider_id: old_provider_id,
      to_provider_id: new_provider_id
    })

    state.replacement_requester.(
      state.profile,
      state.chain_id,
      state.key,
      new_provider_id,
      self()
    )

    telemetry_resubscribe_initiated(state.chain_id, state.key, new_provider_id)

    {:noreply,
     %{
       state
       | failover_status: :switching,
         failover_context: failover_context,
         failover_history: new_history
     }}
  end

  defp start_backfill_after_replacement(state, provider_id, _upstream_id) do
    context = state.failover_context
    owner_id = make_ref()
    coordinator_pid = self()
    key = state.key

    {owner_pid, owner_ref} =
      spawn_monitor(fn ->
        result =
          safely_execute_backfill(
            context.backfill_context,
            key,
            context.continuity_marker,
            owner_id
          )

        send(coordinator_pid, {:backfill_result, owner_id, self(), result})
      end)

    updated_context = %{
      context
      | new_provider_id: provider_id,
        backfill_owner_id: owner_id,
        backfill_owner_pid: owner_pid,
        backfill_owner_ref: owner_ref,
        backfill_task_ref: owner_ref
    }

    {:noreply, %{state | failover_status: :backfilling, failover_context: updated_context}}
  end

  defp safely_execute_backfill(ctx, key, continuity_marker, owner_id) do
    execute_backfill(ctx, key, continuity_marker, owner_id)
  rescue
    error ->
      Logger.error("Backfill error: #{inspect(error)}",
        chain_id: ctx.chain_id,
        key: inspect(key)
      )

      {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp execute_backfill(ctx, key, continuity_marker, owner_id) do
    case subscription_key(key) do
      {:newHeads} ->
        backfill_blocks(ctx, key, continuity_marker, owner_id)

      {:logs, filter} ->
        backfill_logs(ctx, key, filter, continuity_marker, owner_id)
    end
  end

  defp backfill_blocks(ctx, key, last, owner_id) do
    with {:ok, head} <- GapFiller.fetch_head(ctx.plan) do
      case continuity_range(last, head, ctx.max_backfill, ctx.continuity_policy) do
        {:none} ->
          :ok

        {:range, from_n, to_n} ->
          backfill_block_range(ctx, key, from_n, to_n, owner_id)

        {:exceeded, from_n, to_n} ->
          Logger.warning("Gap exceeds max_backfill_blocks: #{from_n}-#{to_n}",
            chain_id: ctx.chain_id,
            key: inspect(key)
          )

          if ctx.continuity_policy == :best_effort,
            do: backfill_block_range(ctx, key, from_n, to_n, owner_id),
            else: {:error, :gap_exceeded}
      end
    end
  end

  defp backfill_block_range(ctx, key, from_n, to_n, owner_id) do
    provider_id = ctx.plan.provider_id

    case GapFiller.ensure_blocks(ctx.plan, from_n, to_n) do
      {:ok, blocks} ->
        emit_backfill_events(ctx.plan, owner_id, provider_id, blocks)
        :ok

      {:error, reason} ->
        Logger.error("Block backfill failed: #{inspect(reason)}",
          chain_id: ctx.chain_id,
          key: inspect(key)
        )

        {:error, reason}
    end
  end

  defp backfill_logs(ctx, key, filter, last, owner_id) do
    with {:ok, head} <- GapFiller.fetch_head(ctx.plan) do
      case continuity_range(last, head, ctx.max_backfill, ctx.continuity_policy) do
        {:none} ->
          :ok

        {:range, from_n, to_n} ->
          backfill_log_range(ctx, key, filter, from_n, to_n, owner_id)

        {:exceeded, from_n, to_n} ->
          Logger.warning("Gap exceeds max_backfill_blocks: #{from_n}-#{to_n}",
            chain_id: ctx.chain_id,
            key: inspect(key)
          )

          if ctx.continuity_policy == :strict_abort,
            do: {:error, :gap_exceeded},
            else: backfill_log_range(ctx, key, filter, from_n, to_n, owner_id)
      end
    end
  end

  defp backfill_log_range(ctx, key, filter, from_n, to_n, owner_id) do
    provider_id = ctx.plan.provider_id

    case GapFiller.ensure_logs(ctx.plan, filter, from_n, to_n) do
      {:ok, logs} ->
        emit_backfill_events(ctx.plan, owner_id, provider_id, logs)
        :ok

      {:error, reason} ->
        Logger.error("Log backfill failed: #{inspect(reason)}",
          chain_id: ctx.chain_id,
          key: inspect(key)
        )

        {:error, reason}
    end
  end

  defp emit_backfill_events(plan, owner_id, provider_id, events) do
    Enum.each(events, fn event ->
      send(
        plan.caller_pid,
        {:backfill_event, owner_id, self(), provider_id, event,
         System.monotonic_time(:millisecond)}
      )
    end)
  end

  defp complete_failover(state, provider_id, _upstream_id) do
    Logger.info("Failover complete: now on provider #{provider_id}",
      chain_id: state.chain_id,
      key: inspect(state.key)
    )

    # Drain buffered events through dedupe
    new_state = drain_event_buffer(state)

    # Update primary provider
    final_state = %{
      new_state
      | primary_provider_id: provider_id,
        failover_status: :active,
        failover_context: nil,
        failover_history: [],
        recovery_deadline_us: nil
    }

    duration_ms = System.monotonic_time(:millisecond) - state.failover_context.started_at
    telemetry_failover_completed(final_state.chain_id, final_state.key, duration_ms)

    {:noreply, final_state}
  end

  defp drain_event_buffer(state) do
    if state.failover_context && state.failover_context.event_buffer != [] do
      Logger.debug(
        "Draining #{length(state.failover_context.event_buffer)} buffered events",
        chain_id: state.chain_id,
        key: inspect(state.key)
      )

      # Sort deterministically before deduping
      ordered_buffer =
        case subscription_key(state.key) do
          {:newHeads} ->
            state.failover_context.event_buffer
            |> Enum.reverse()
            |> Enum.sort_by(fn payload ->
              decode_hex(Map.get(payload, "number", "0x0"))
            end)

          {:logs, _filter} ->
            state.failover_context.event_buffer
            |> Enum.reverse()
            |> Enum.sort_by(fn log ->
              {decode_hex(Map.get(log, "blockNumber", "0x0")),
               decode_hex(Map.get(log, "transactionIndex", "0x0")),
               decode_hex(Map.get(log, "logIndex", "0x0")),
               Map.get(log, "removed", false) == true}
            end)
        end

      Enum.reduce(ordered_buffer, state, fn payload, acc ->
        case subscription_key(acc.key) do
          {:newHeads} ->
            case StreamState.ingest_new_head(acc.state, payload) do
              {stream_state, :emit} ->
                ClientSubscriptionRegistry.dispatch(acc.profile, acc.chain_id, acc.key, payload)
                %{acc | state: stream_state}

              {stream_state, :skip} ->
                %{acc | state: stream_state}
            end

          {:logs, _filter} ->
            case StreamState.ingest_log(acc.state, payload) do
              {stream_state, :emit} ->
                ClientSubscriptionRegistry.dispatch(acc.profile, acc.chain_id, acc.key, payload)
                %{acc | state: stream_state}

              {stream_state, :skip} ->
                %{acc | state: stream_state}
            end
        end
      end)
    else
      state
    end
  end

  defp handle_resubscribe_failure(state, reason) do
    Logger.error("Resubscription failed: #{inspect(reason)}",
      chain_id: state.chain_id,
      key: inspect(state.key)
    )

    # Check if we should cascade to another provider
    recent_failures = count_recent_failures(state.failover_history, state.failover_cooldown_ms)

    budget = failover_budget(state)
    max_failover_attempts = budget.attempts

    if recent_failures >= max_failover_attempts do
      Logger.error("Max failover attempts reached, entering degraded mode",
        chain_id: state.chain_id,
        key: inspect(state.key)
      )

      enter_degraded_mode(state, budget)
    else
      # Try next provider, excluding all previously failed providers
      excluded =
        [
          state.failover_context.new_provider_id
          | Enum.map(state.failover_history, & &1.provider_id)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      case pick_next_provider(state, excluded, include_half_open: false) do
        {:ok, next_provider_id} ->
          Logger.info("Cascading to next provider: #{next_provider_id}",
            chain_id: state.chain_id,
            key: inspect(state.key)
          )

          # Preserve event buffer from failed attempt when cascading
          # This prevents losing buffered events during multi-provider failover
          preserved_buffer = state.failover_context.event_buffer

          # Reset to active and re-initiate, but pass preserved buffer
          reset_state = %{state | failover_status: :active, failover_context: nil}

          initiate_failover_with_buffer(
            reset_state,
            state.failover_context.new_provider_id,
            next_provider_id,
            preserved_buffer
          )

        {:error, :no_providers} ->
          Logger.error("No more providers available",
            chain_id: state.chain_id,
            key: inspect(state.key)
          )

          enter_degraded_mode(state, budget)
      end
    end
  end

  defp handle_backfill_failure(state, _reason) do
    Logger.error("Backfill task failed",
      chain_id: state.chain_id,
      key: inspect(state.key)
    )

    # Treat as resubscribe failure
    handle_resubscribe_failure(state, :backfill_failed)
  end

  defp enter_degraded_mode(state, budget) do
    cancel_backfill_owner(state)

    ClientSubscriptionRegistry.terminate(
      state.profile,
      state.chain_id,
      state.key,
      :continuity_exhausted
    )

    tried_providers =
      state.failover_history
      |> Enum.map(& &1.provider_id)
      |> Enum.uniq()

    last_error =
      case state.failover_history do
        [%{reason: reason} | _] -> reason
        _ -> nil
      end

    Logger.error("Entering degraded mode — dropping events until retry",
      chain_id: state.chain_id,
      profile: state.profile,
      key: inspect(state.key),
      attempts: length(state.failover_history),
      attempts_budget: budget.attempts,
      tried_providers: inspect(tried_providers),
      last_error: inspect(last_error),
      retry_delay_ms: @degraded_mode_retry_delay_ms
    )

    # Schedule retry after cooldown
    Process.send_after(self(), :retry_from_degraded, @degraded_mode_retry_delay_ms)

    telemetry_failover_degraded(state.chain_id, state.key, budget)

    {:noreply,
     %{
       state
       | failover_status: :degraded,
         failover_context: nil,
         failover_history: [],
         recovery_deadline_us: nil
     }}
  end

  defp count_recent_failures(history, window_ms) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms

    Enum.count(history, fn entry -> entry.failed_at > cutoff end)
  end

  defp pick_next_provider(state, excluded, opts \\ []) do
    include_half_open = Keyword.get(opts, :include_half_open, true)

    case Selection.select_provider(
           state.profile,
           state.chain_id,
           "eth_subscribe",
           strategy: :priority,
           protocol: :ws,
           include_half_open: include_half_open,
           exclude: excluded,
           requires_subscribe_new_heads: subscription_key(state.key) == {:newHeads}
         ) do
      {:ok, provider_id} -> {:ok, provider_id}
      _ -> {:error, :no_providers}
    end
  end

  defp subscription_key({:route, _route, key}), do: key
  defp subscription_key(key), do: key

  defp continuity_marker(stream_state, key) do
    case subscription_key(key) do
      {:newHeads} ->
        StreamState.last_block_num(stream_state)

      {:logs, _filter} ->
        StreamState.last_log_block(stream_state) || StreamState.last_block_num(stream_state)
    end
  end

  defp continuity_range(last_seen, head, max_backfill, policy) when is_integer(last_seen) do
    ContinuityPolicy.needed_block_range(last_seen - 1, head, max_backfill + 1, policy)
  end

  defp continuity_range(last_seen, head, max_backfill, policy) do
    ContinuityPolicy.needed_block_range(last_seen, head, max_backfill, policy)
  end

  defp failover_budget(%{max_failover_attempts: override})
       when is_integer(override) and override > 0,
       do: %{attempts: override, provider_count: nil, source: :override}

  defp failover_budget(state) do
    provider_count = ws_provider_count(state.profile, state.chain_id)

    if provider_count > 0 do
      attempts = min(provider_count * 2 + 1, @max_dynamic_failover_attempts)
      %{attempts: attempts, provider_count: provider_count, source: :dynamic}
    else
      %{
        attempts: @default_max_failover_attempts,
        provider_count: provider_count,
        source: :default
      }
    end
  end

  defp ws_provider_count(profile, chain_id) do
    profile
    |> Catalog.get_profile_providers(chain_id)
    |> Enum.count(fn %{instance_id: instance_id} -> ws_instance?(instance_id) end)
  end

  defp ws_instance?(instance_id) do
    case Catalog.get_instance(instance_id) do
      {:ok, %{ws_url: ws_url}} when is_binary(ws_url) -> true
      _ -> false
    end
  end

  defp pick_best_http_provider(profile, chain_id, excluded) do
    case Selection.select_provider(
           profile,
           chain_id,
           "eth_getBlockByNumber",
           strategy: :fastest,
           protocol: :http,
           exclude: excluded
         ) do
      {:ok, provider_id} ->
        {:ok, provider_id}

      _ ->
        {:error, :no_http_provider}
    end
  end

  defp request_pool_replacement(profile, chain_id, key, provider_id, coordinator_pid) do
    pool_ref = Lasso.Core.Streaming.UpstreamSubscriptionPool.via(profile, chain_id)
    GenServer.cast(pool_ref, {:resubscribe, key, provider_id, coordinator_pid})
  end

  defp decode_hex(nil), do: 0
  defp decode_hex("0x" <> rest), do: String.to_integer(rest, 16)
  defp decode_hex(num) when is_integer(num), do: num
  defp decode_hex(_), do: 0

  defp recovery_remaining_ms(deadline_us) do
    max(div(deadline_us - System.monotonic_time(:microsecond) + 999, 1_000), 0)
  end

  defp cancel_backfill_owner(%{failover_context: context}) when is_map(context) do
    owner_ref = Map.get(context, :backfill_owner_ref)
    owner_pid = Map.get(context, :backfill_owner_pid)

    if is_reference(owner_ref), do: Process.demonitor(owner_ref, [:flush])
    if is_pid(owner_pid) and Process.alive?(owner_pid), do: Process.exit(owner_pid, :kill)
    :ok
  end

  defp cancel_backfill_owner(_state), do: :ok

  # Telemetry helpers

  defp broadcast_subscription_event(state, event) do
    topic = Lasso.Topics.subscription_event(state.profile, state.chain_id)
    Phoenix.PubSub.broadcast(Lasso.PubSub, topic, event)
  end

  defp telemetry_failover_initiated(chain_id, key, old_id, new_id, recent_failures, budget) do
    :telemetry.execute([:lasso, :subs, :failover, :initiated], %{count: 1}, %{
      chain_id: chain_id,
      key: inspect(key),
      old_provider: inspect(old_id),
      new_provider: inspect(new_id),
      recent_failures: recent_failures,
      failover_budget: budget.attempts,
      provider_count: budget.provider_count,
      budget_source: budget.source
    })
  end

  defp telemetry_resubscribe_initiated(chain_id, key, provider_id) do
    :telemetry.execute([:lasso, :subs, :failover, :resubscribe_initiated], %{count: 1}, %{
      chain_id: chain_id,
      key: inspect(key),
      provider_id: provider_id
    })
  end

  defp telemetry_failover_completed(chain_id, key, duration_ms) do
    :telemetry.execute([:lasso, :subs, :failover, :completed], %{duration_ms: duration_ms}, %{
      chain_id: chain_id,
      key: inspect(key)
    })
  end

  defp telemetry_failover_degraded(chain_id, key, budget) do
    :telemetry.execute([:lasso, :subs, :failover, :degraded], %{count: 1}, %{
      chain_id: chain_id,
      key: inspect(key),
      failover_budget: budget.attempts,
      provider_count: budget.provider_count,
      budget_source: budget.source
    })
  end
end

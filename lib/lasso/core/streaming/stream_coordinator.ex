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

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.{ContinuityPolicy, GapFiller}
  alias Lasso.Events.Subscription
  alias Lasso.Providers.Catalog

  alias Lasso.RPC.Selection

  alias Lasso.Core.Streaming.{
    ClientSubscriptionRegistry,
    ContinuityBudget,
    Ingress,
    ReplayWindow,
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
      :allow_head_regression,
      :minimum_head,
      :excluded_providers,
      :plan
    ]

    @type t :: %__MODULE__{
            profile: String.t(),
            chain_id: pos_integer(),
            max_backfill: non_neg_integer(),
            backfill_timeout: non_neg_integer(),
            continuity_policy: atom(),
            allow_head_regression: boolean(),
            minimum_head: non_neg_integer() | nil,
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
  @default_max_event_bytes 4 * 1_024 * 1_024
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
          :ok | {:error, atom()}
  def upstream_event(profile, chain_id, key, provider_id, upstream_id, payload, received_at)
      when is_binary(profile) and is_integer(chain_id) and chain_id > 0 do
    Ingress.send(
      via(profile, chain_id, key),
      {:upstream_event, provider_id, upstream_id, payload, received_at},
      :cast
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
    opts = profile_failover_options(profile, chain_id, opts)
    max_backfill_blocks = Keyword.get(opts, :max_backfill_blocks, 32)

    state = %{
      profile: profile,
      chain_id: chain_id,
      key: key,
      primary_provider_id: Keyword.get(opts, :primary_provider_id),
      state:
        StreamState.new(
          dedupe_max_items: Keyword.get(opts, :dedupe_max_items, 256),
          dedupe_max_age_ms: Keyword.get(opts, :dedupe_max_age_ms, 30_000),
          history_blocks: max_backfill_blocks,
          history_max_items: Keyword.get(opts, :history_max_items, 4_096)
        ),
      # Backfill config
      max_backfill_blocks: max_backfill_blocks,
      backfill_timeout: Keyword.get(opts, :backfill_timeout, 30_000),
      continuity_policy: Keyword.get(opts, :continuity_policy, :strict_abort),
      backfill_requester:
        Keyword.get(opts, :backfill_requester, &Lasso.RPC.RequestPipeline.execute_owned/5),
      backfill_provider_selector:
        Keyword.get(opts, :backfill_provider_selector, &pick_best_http_provider/3),
      live_backfill_provider_selector:
        Keyword.get(
          opts,
          :live_backfill_provider_selector,
          Keyword.get(opts, :backfill_provider_selector, &pick_backfill_http_provider/4)
        ),
      replacement_requester:
        Keyword.get(opts, :replacement_requester, &request_pool_replacement/5),
      # Failover state machine
      failover_status: :active,
      failover_context: nil,
      failover_history: [],
      max_failover_attempts: Keyword.get(opts, :max_failover_attempts),
      failover_cooldown_ms: Keyword.get(opts, :failover_cooldown_ms, @failover_cooldown_ms),
      max_event_buffer:
        Keyword.get(opts, :max_event_buffer, max(@max_event_buffer, max_backfill_blocks + 1)),
      max_replay_buffer:
        Keyword.get(
          opts,
          :max_replay_buffer,
          max(Keyword.get(opts, :history_max_items, 4_096), max_backfill_blocks + 1)
        ),
      max_event_bytes:
        Keyword.get(
          opts,
          :max_event_bytes,
          Application.get_env(
            :lasso,
            :websocket_continuity_event_byte_limit,
            @default_max_event_bytes
          )
        ),
      continuity_budget: Keyword.get(opts, :continuity_budget, ContinuityBudget),
      recovery_timeout_ms: Keyword.get(opts, :recovery_timeout_ms, @default_recovery_timeout_ms),
      recovery_deadline_us: nil,
      recovery_started_at_ms: nil,
      recovery_attempts: 0
    }

    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_backfill_owner(state)
    ContinuityBudget.release_owner(state.continuity_budget)
    :ok
  end

  @impl true
  def handle_cast({:stream_ingress, token, message}, state) do
    Ingress.consume(token, fn -> handle_cast(message, state) end)
  end

  def handle_cast({:upstream_event, provider_id, _upstream_id, payload, _received_at}, state) do
    case state.failover_status do
      :active ->
        if is_nil(state.primary_provider_id) or provider_id == state.primary_provider_id do
          process_event_normal(state, provider_id, payload)
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
  def handle_info({:stream_ingress, token, message}, state) do
    Ingress.consume(token, fn -> handle_info(message, state) end)
  end

  def handle_info(
        {:backfill_event, owner_id, owner_pid, _provider_id, payload, _received_at, event_ref},
        %{failover_status: :backfilling, failover_context: context} = state
      )
      when context.backfill_owner_id == owner_id and context.backfill_owner_pid == owner_pid do
    {:noreply, next_state} = result = buffer_replay_event(state, payload)

    outcome =
      if next_state.failover_status == :backfilling,
        do: :ok,
        else: {:error, :continuity_exhausted}

    send(owner_pid, {:backfill_event_ack, event_ref, outcome})
    result
  end

  def handle_info(
        {:backfill_event, _owner_id, owner_pid, _provider_id, _payload, _at, event_ref},
        state
      ) do
    send(owner_pid, {:backfill_event_ack, event_ref, {:error, :stale_backfill}})
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

  defp process_event_normal(state, provider_id, payload) do
    case subscription_key(state.key) do
      {:newHeads} ->
        case StreamState.new_head_continuity(state.state, payload) do
          :continuous ->
            ingest_new_head(state, payload)

          :duplicate ->
            {:noreply, state}

          {:discontinuous, details} ->
            initiate_live_reorg_repair(state, provider_id, payload, details)

          {:error, :invalid_header} ->
            continuity_resource_exhausted(
              state,
              :invalid_header,
              StreamState.event_bytes(payload)
            )
        end

      {:logs, _filter} ->
        case StreamState.log_continuity(state.state, payload) do
          :continuous ->
            ingest_log(state, payload)

          {:discontinuous, details} ->
            initiate_live_reorg_repair(state, provider_id, payload, details)

          {:error, :invalid_log} ->
            continuity_resource_exhausted(state, :invalid_log, StreamState.event_bytes(payload))
        end
    end
  end

  defp ingest_new_head(state, payload) do
    case StreamState.ingest_new_head(state.state, payload) do
      {stream_state, :emit} ->
        retain_and_dispatch(state, stream_state, payload)

      {stream_state, :skip} ->
        {:noreply, %{state | state: stream_state}}
    end
  end

  defp ingest_log(state, payload) do
    case StreamState.ingest_log(state.state, payload) do
      {stream_state, :emit} ->
        retain_and_dispatch(state, stream_state, payload)

      {stream_state, :skip} ->
        {:noreply, %{state | state: stream_state}}
    end
  end

  defp reserve_retained_bytes(state, stream_state, buffered_bytes) do
    ContinuityBudget.set_stream_bytes(
      state.continuity_budget,
      self(),
      StreamState.retained_bytes(stream_state) + buffered_bytes
    )
  end

  defp buffer_event(state, payload) do
    buffer_recovery_event(state, payload, :live)
  end

  defp buffer_replay_event(state, payload) do
    buffer_recovery_event(state, payload, :replay)
  end

  defp buffer_recovery_event(state, payload, kind) do
    if state.failover_context do
      context = state.failover_context
      live_buffer = context.event_buffer
      replay_buffer = Map.get(context, :replay_buffer, [])
      live_count = Map.get(context, :event_buffer_count, length(live_buffer))
      replay_count = Map.get(context, :replay_buffer_count, length(replay_buffer))

      live_bytes = Map.get(context, :event_buffer_bytes, event_buffer_bytes(live_buffer))

      replay_bytes =
        Map.get(context, :replay_buffer_bytes, event_buffer_bytes(replay_buffer))

      payload_bytes = StreamState.event_bytes(payload)

      retained_bytes =
        StreamState.retained_bytes(state.state) + live_bytes + replay_bytes + payload_bytes

      cond do
        payload_bytes > state.max_event_bytes ->
          continuity_resource_exhausted(state, :event_too_large, payload_bytes)

        recovery_buffer_full?(state, kind, live_count, replay_count) ->
          buffer_limit = recovery_buffer_limit(state, kind)

          Logger.error("Event buffer full, entering degraded mode",
            chain_id: state.chain_id,
            key: inspect(state.key),
            buffer_kind: kind,
            buffer_limit: buffer_limit
          )

          :telemetry.execute(
            [:lasso, :stream, :event_buffer_overflow],
            %{count: 1},
            %{
              chain_id: state.chain_id,
              profile: state.profile,
              key: inspect(state.key),
              buffer_kind: kind,
              buffer_limit: buffer_limit
            }
          )

          enter_degraded_mode(state, failover_budget(state))

        true ->
          case reserve_retained_bytes(
                 state,
                 state.state,
                 live_bytes + replay_bytes + payload_bytes
               ) do
            :ok ->
              updated_context = put_recovery_event(context, kind, payload, payload_bytes)

              {:noreply, %{state | failover_context: updated_context}}

            {:error, reason} ->
              continuity_resource_exhausted(state, reason, retained_bytes)
          end
      end
    else
      {:noreply, state}
    end
  end

  defp put_recovery_event(context, :live, payload, payload_bytes) do
    count = Map.get(context, :event_buffer_count, length(context.event_buffer))
    bytes = Map.get(context, :event_buffer_bytes, event_buffer_bytes(context.event_buffer))

    context
    |> Map.put(:event_buffer, [payload | context.event_buffer])
    |> Map.put(:event_buffer_count, count + 1)
    |> Map.put(:event_buffer_bytes, bytes + payload_bytes)
  end

  defp put_recovery_event(context, :replay, payload, payload_bytes) do
    context
    |> Map.put(:replay_buffer, [payload | Map.get(context, :replay_buffer, [])])
    |> Map.update(:replay_buffer_count, 1, &(&1 + 1))
    |> Map.update(:replay_buffer_bytes, payload_bytes, &(&1 + payload_bytes))
  end

  defp recovery_buffer_full?(state, :live, live_count, _replay_count),
    do: live_count >= state.max_event_buffer

  defp recovery_buffer_full?(state, :replay, _live_count, replay_count),
    do: replay_count >= state.max_replay_buffer

  defp recovery_buffer_limit(state, :live), do: state.max_event_buffer
  defp recovery_buffer_limit(state, :replay), do: state.max_replay_buffer

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
    state = refresh_failover_config(state)

    deadline_us =
      System.monotonic_time(:microsecond) + state.recovery_timeout_ms * 1_000

    state = %{
      state
      | recovery_deadline_us: deadline_us,
        recovery_started_at_ms: System.monotonic_time(:millisecond),
        recovery_attempts: 0
    }

    if is_binary(new_provider_id) do
      initiate_failover_with_buffer(state, old_provider_id, new_provider_id, [])
    else
      enter_degraded_mode(state, failover_budget(state))
    end
  end

  defp profile_failover_options(profile, chain_id, opts) do
    case ConfigStore.get_chain(profile, chain_id) do
      {:ok, %{websocket: %{failover: config}} = chain} ->
        opts
        |> Keyword.put(
          :max_backfill_blocks,
          ReplayWindow.effective_blocks(
            config.max_backfill_blocks,
            chain.block_time_ms,
            config.backfill_timeout_ms
          )
        )
        |> Keyword.put(:backfill_timeout, config.backfill_timeout_ms)

      _ ->
        opts
    end
  end

  defp refresh_failover_config(state) do
    opts =
      profile_failover_options(state.profile, state.chain_id,
        max_backfill_blocks: state.max_backfill_blocks,
        backfill_timeout: state.backfill_timeout
      )

    %{
      state
      | max_backfill_blocks: opts[:max_backfill_blocks],
        backfill_timeout: opts[:backfill_timeout],
        state: %{state.state | history_blocks: opts[:max_backfill_blocks]}
    }
  end

  defp initiate_live_reorg_repair(state, provider_id, payload, details) when is_map(payload) do
    initiate_live_reorg_repair(state, provider_id, [payload], details)
  end

  defp initiate_live_reorg_repair(state, provider_id, pending_events, details) do
    state = if state.failover_status == :active, do: refresh_failover_config(state), else: state
    recovery_budget = failover_budget(state)
    recovery_attempts = state.recovery_attempts + 1
    pending_bytes = event_buffer_bytes(pending_events)
    retained_bytes = StreamState.retained_bytes(state.state) + pending_bytes
    preferred_provider_id = state.primary_provider_id || provider_id

    state = %{
      state
      | recovery_attempts: recovery_attempts,
        recovery_started_at_ms:
          state.recovery_started_at_ms || System.monotonic_time(:millisecond)
    }

    cond do
      recovery_attempts > recovery_budget.attempts ->
        Logger.error("Connected reorg repair attempt budget exhausted",
          chain_id: state.chain_id,
          key: inspect(state.key),
          attempts: recovery_attempts,
          attempts_budget: recovery_budget.attempts
        )

        enter_degraded_mode(state, recovery_budget)

      length(pending_events) > state.max_event_buffer ->
        continuity_resource_exhausted(state, :event_buffer_overflow, retained_bytes)

      Enum.any?(pending_events, &(StreamState.event_bytes(&1) > state.max_event_bytes)) ->
        continuity_resource_exhausted(state, :event_too_large, retained_bytes)

      true ->
        case reserve_retained_bytes(state, state.state, pending_bytes) do
          :ok ->
            start_live_reorg_with_provider(
              state,
              preferred_provider_id,
              pending_events,
              pending_bytes,
              details
            )

          {:error, reason} ->
            continuity_resource_exhausted(state, reason, retained_bytes)
        end
    end
  end

  defp start_live_reorg_with_provider(
         state,
         preferred_provider_id,
         pending_events,
         pending_bytes,
         details
       ) do
    case select_backfill_provider(
           state.live_backfill_provider_selector,
           state.profile,
           state.chain_id,
           preferred_provider_id,
           []
         ) do
      {:ok, http_provider} ->
        start_live_reorg_backfill(
          state,
          preferred_provider_id,
          http_provider,
          pending_events,
          pending_bytes,
          details
        )

      {:error, reason} ->
        failover_uncertified_live_provider(
          state,
          preferred_provider_id,
          pending_events,
          pending_bytes,
          reason
        )
    end
  end

  defp failover_uncertified_live_provider(
         state,
         provider_id,
         pending_events,
         _pending_bytes,
         reason
       ) do
    Logger.error("Live WebSocket provider cannot supply canonical HTTP reconciliation",
      chain_id: state.chain_id,
      key: inspect(state.key),
      provider_id: provider_id,
      reason: inspect(reason)
    )

    case pick_next_provider(state, [provider_id], include_half_open: false) do
      {:ok, next_provider_id} ->
        started_at_ms = state.recovery_started_at_ms || System.monotonic_time(:millisecond)

        deadline_us =
          state.recovery_deadline_us ||
            System.monotonic_time(:microsecond) + state.recovery_timeout_ms * 1_000

        state = %{
          state
          | recovery_deadline_us: deadline_us,
            recovery_started_at_ms: started_at_ms
        }

        initiate_failover_with_buffer(
          state,
          provider_id,
          next_provider_id,
          Enum.reverse(pending_events)
        )

      {:error, :no_providers} ->
        enter_degraded_mode(state, failover_budget(state))
    end
  end

  defp start_live_reorg_backfill(
         state,
         provider_id,
         http_provider,
         pending_events,
         pending_bytes,
         details
       ) do
    started_at_us = System.monotonic_time(:microsecond)

    deadline_us =
      state.recovery_deadline_us || started_at_us + state.recovery_timeout_ms * 1_000

    remaining_ms = recovery_remaining_ms(deadline_us)

    if remaining_ms > 0 do
      Process.send_after(self(), {:failover_deadline, deadline_us}, remaining_ms)

      plan =
        GapFiller.Plan.new(
          state.profile,
          state.chain_id,
          http_provider,
          self(),
          min(state.backfill_timeout, remaining_ms),
          deadline_us: deadline_us,
          requester: state.backfill_requester
        )

      backfill_context = %BackfillContext{
        profile: state.profile,
        chain_id: state.chain_id,
        max_backfill: state.max_backfill_blocks,
        backfill_timeout: state.backfill_timeout,
        continuity_policy: state.continuity_policy,
        excluded_providers: [http_provider],
        allow_head_regression: true,
        minimum_head: max_pending_head(pending_events),
        plan: plan
      }

      context = %{
        old_provider_id: provider_id,
        new_provider_id: provider_id,
        http_provider_id: http_provider,
        backfill_owner_id: nil,
        backfill_owner_pid: nil,
        backfill_owner_ref: nil,
        backfill_task_ref: nil,
        backfill_plan: plan,
        backfill_context: backfill_context,
        continuity_marker: continuity_marker(state.state, state.key),
        continuity_snapshot: StreamState.continuity_snapshot(state.state),
        started_at: div(started_at_us, 1_000),
        event_buffer: Enum.reverse(pending_events),
        event_buffer_count: length(pending_events),
        event_buffer_bytes: pending_bytes,
        initial_live_event_count: length(pending_events),
        replay_buffer: [],
        replay_buffer_count: 0,
        replay_buffer_bytes: 0,
        recovery_kind: :live_reorg,
        attempt_count: 1
      }

      telemetry_live_reorg_started(
        state.profile,
        state.chain_id,
        state.key,
        provider_id,
        http_provider,
        details
      )

      state
      |> Map.put(:failover_status, :backfilling)
      |> Map.put(:failover_context, context)
      |> Map.put(:recovery_deadline_us, deadline_us)
      |> start_backfill_after_replacement(provider_id, nil)
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

      case select_backfill_provider(
             state.backfill_provider_selector,
             state.profile,
             state.chain_id,
             new_provider_id,
             excluded_providers
           ) do
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
      allow_head_regression: false,
      minimum_head: nil,
      excluded_providers: [old_provider_id, new_provider_id],
      plan: plan
    }

    continuity_marker = continuity_marker(state.state, state.key)
    continuity_snapshot = StreamState.continuity_snapshot(state.state)

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
      continuity_snapshot: continuity_snapshot,
      started_at: div(started_at_us, 1_000),
      event_buffer: initial_buffer,
      event_buffer_count: length(initial_buffer),
      event_buffer_bytes: event_buffer_bytes(initial_buffer),
      initial_live_event_count: length(initial_buffer),
      replay_buffer: [],
      replay_buffer_count: 0,
      replay_buffer_bytes: 0,
      recovery_kind: :failover,
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
            context.continuity_snapshot,
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

  defp safely_execute_backfill(ctx, key, continuity_marker, continuity_snapshot, owner_id) do
    execute_backfill(ctx, key, continuity_marker, continuity_snapshot, owner_id)
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

  defp execute_backfill(ctx, key, continuity_marker, continuity_snapshot, owner_id) do
    case subscription_key(key) do
      {:newHeads} ->
        backfill_blocks(ctx, key, continuity_marker, continuity_snapshot, owner_id)

      {:logs, filter} ->
        backfill_logs(ctx, key, filter, continuity_marker, continuity_snapshot, owner_id)
    end
  end

  defp backfill_blocks(ctx, key, last, snapshot, owner_id) do
    with {:ok, head} <- GapFiller.fetch_head(ctx.plan),
         :ok <- ensure_minimum_head(head, ctx.minimum_head) do
      case continuity_range(last, head, ctx.max_backfill, ctx.continuity_policy) do
        {:none} ->
          :ok

        {:regressed, _last_seen, observed_head} when ctx.allow_head_regression ->
          backfill_canonical_blocks(
            ctx,
            key,
            snapshot,
            observed_head,
            observed_head,
            owner_id,
            allow_observation_boundary: true
          )

        {:regressed, last_seen, observed_head} ->
          Logger.error("Backfill source head regressed below the delivered stream",
            chain_id: ctx.chain_id,
            key: inspect(key),
            last_seen: last_seen,
            observed_head: observed_head
          )

          {:error, :head_regressed}

        {:range, from_n, to_n} ->
          backfill_canonical_blocks(ctx, key, snapshot, from_n, to_n, owner_id,
            allow_observation_boundary: ctx.allow_head_regression
          )

        {:exceeded, from_n, to_n} ->
          Logger.warning("Gap exceeds max_backfill_blocks: #{from_n}-#{to_n}",
            chain_id: ctx.chain_id,
            key: inspect(key)
          )

          if ctx.continuity_policy == :best_effort,
            do:
              backfill_canonical_blocks(ctx, key, snapshot, from_n, to_n, owner_id,
                allow_observation_boundary: ctx.allow_head_regression
              ),
            else: {:error, :gap_exceeded}
      end
    end
  end

  defp ensure_minimum_head(_head, nil), do: :ok
  defp ensure_minimum_head(head, minimum_head) when head >= minimum_head, do: :ok
  defp ensure_minimum_head(_head, _minimum_head), do: {:error, :source_behind_observed_head}

  defp backfill_canonical_blocks(ctx, key, snapshot, from_n, to_n, owner_id, opts) do
    history = Map.get(snapshot, :head_history, %{})
    allow_observation_boundary = Keyword.fetch!(opts, :allow_observation_boundary)

    with {:ok, ancestor, probed} <-
           find_common_ancestor(
             ctx.plan,
             history,
             from_n,
             ctx.max_backfill,
             allow_observation_boundary
           ),
         replay_from = max(ancestor + 1, from_n),
         {:ok, blocks} <- fetch_unprobed_blocks(ctx.plan, probed, replay_from, to_n) do
      blocks =
        blocks
        |> Map.values()
        |> Enum.sort_by(&decode_hex(Map.get(&1, "number", "0x0")))

      with :ok <- validate_canonical_branch(blocks) do
        emit_backfill_events(ctx.plan, owner_id, ctx.plan.provider_id, blocks)
      end
    else
      {:error, reason} ->
        Logger.error("Block ancestry reconciliation failed: #{inspect(reason)}",
          chain_id: ctx.chain_id,
          key: inspect(key)
        )

        {:error, reason}
    end
  end

  defp find_common_ancestor(
         plan,
         history,
         from_n,
         max_backfill,
         allow_observation_boundary
       ) do
    lower_bound = max(from_n - max_backfill + 1, 0)

    find_common_ancestor(
      plan,
      history,
      from_n,
      lower_bound,
      %{},
      max_backfill,
      allow_observation_boundary
    )
  end

  defp find_common_ancestor(
         _plan,
         history,
         number,
         lower_bound,
         probed,
         max_backfill,
         allow_observation_boundary
       )
       when number < lower_bound do
    if map_size(history) <= 1 or
         (allow_observation_boundary and
            initial_observation_window?(history, max_backfill)) do
      {:ok, earliest_observed_height(history, lower_bound) - 1, probed}
    else
      {:error, :reorg_horizon_exceeded}
    end
  end

  defp find_common_ancestor(
         plan,
         history,
         number,
         lower_bound,
         probed,
         max_backfill,
         allow_observation_boundary
       ) do
    case Map.fetch(history, number) do
      {:ok, retained} ->
        with {:ok, [canonical]} <- GapFiller.ensure_blocks(plan, number, number) do
          probed = Map.put(probed, number, canonical)

          if Map.get(retained, "hash") == Map.get(canonical, "hash") do
            {:ok, number, probed}
          else
            find_common_ancestor(
              plan,
              history,
              number - 1,
              lower_bound,
              probed,
              max_backfill,
              allow_observation_boundary
            )
          end
        end

      :error ->
        case match_retained_parent(
               plan,
               history,
               number,
               max_backfill,
               allow_observation_boundary
             ) do
          :match ->
            {:ok, number, probed}

          :miss ->
            find_common_ancestor(
              plan,
              history,
              number - 1,
              lower_bound,
              probed,
              max_backfill,
              allow_observation_boundary
            )

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp match_retained_parent(
         plan,
         history,
         number,
         max_backfill,
         allow_observation_boundary
       ) do
    earliest = earliest_observed_height(history, number + 1)

    with false <- allow_observation_boundary,
         true <- map_size(history) > 1,
         true <- number == earliest - 1,
         true <- initial_observation_window?(history, max_backfill),
         %{"parentHash" => parent_hash} when is_binary(parent_hash) <- Map.get(history, earliest),
         {:ok, [canonical]} <- GapFiller.ensure_blocks(plan, number, number) do
      if Map.get(canonical, "hash") == parent_hash, do: :match, else: :miss
    else
      {:error, _reason} = error -> error
      _other -> :miss
    end
  end

  defp initial_observation_window?(history, max_backfill) when map_size(history) < max_backfill do
    heights = history |> Map.keys() |> Enum.sort()

    case heights do
      [] -> false
      [first | _] -> heights == Enum.to_list(first..List.last(heights))
    end
  end

  defp initial_observation_window?(_history, _max_backfill), do: false

  defp earliest_observed_height(history, fallback) do
    history
    |> Map.keys()
    |> Enum.min(fn -> fallback end)
  end

  defp fetch_unprobed_blocks(_plan, probed, from_n, to_n) when from_n > to_n,
    do: {:ok, probed}

  defp fetch_unprobed_blocks(plan, probed, from_n, to_n) do
    Enum.reduce_while(from_n..to_n, {:ok, probed}, fn number, {:ok, blocks} ->
      if Map.has_key?(blocks, number) do
        {:cont, {:ok, blocks}}
      else
        case GapFiller.ensure_blocks(plan, number, number) do
          {:ok, [block]} -> {:cont, {:ok, Map.put(blocks, number, block)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp validate_canonical_branch([]), do: :ok

  defp validate_canonical_branch([first | rest]) do
    with {:ok, first_number, first_hash} <- canonical_header_identity(first) do
      Enum.reduce_while(rest, {:ok, first_number, first_hash}, fn block,
                                                                  {:ok, previous_number,
                                                                   previous_hash} ->
        with {:ok, number, hash} <- canonical_header_identity(block),
             true <- number == previous_number + 1,
             true <- Map.get(block, "parentHash") == previous_hash do
          {:cont, {:ok, number, hash}}
        else
          _ -> {:halt, {:error, :inconsistent_canonical_branch}}
        end
      end)
      |> case do
        {:ok, _number, _hash} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  defp canonical_header_identity(block) do
    case {decode_hex(Map.get(block, "number")), Map.get(block, "hash")} do
      {number, hash} when is_integer(number) and is_binary(hash) -> {:ok, number, hash}
      _ -> {:error, :invalid_canonical_header}
    end
  end

  defp backfill_logs(ctx, key, filter, last, snapshot, owner_id) do
    with :ok <- ensure_history_complete(snapshot),
         {:ok, head} <- GapFiller.fetch_head(ctx.plan) do
      case continuity_range(last, head, ctx.max_backfill, ctx.continuity_policy) do
        {:none} ->
          :ok

        {:regressed, last_seen, observed_head} ->
          Logger.error("Backfill source head regressed below the delivered stream",
            chain_id: ctx.chain_id,
            key: inspect(key),
            last_seen: last_seen,
            observed_head: observed_head
          )

          {:error, :head_regressed}

        {:range, from_n, to_n} ->
          backfill_log_range(ctx, key, filter, snapshot, from_n, to_n, owner_id)

        {:exceeded, from_n, to_n} ->
          Logger.warning("Gap exceeds max_backfill_blocks: #{from_n}-#{to_n}",
            chain_id: ctx.chain_id,
            key: inspect(key)
          )

          if ctx.continuity_policy == :strict_abort,
            do: {:error, :gap_exceeded},
            else: backfill_log_range(ctx, key, filter, snapshot, from_n, to_n, owner_id)
      end
    end
  end

  defp ensure_history_complete(%{history_overflowed: true}), do: {:error, :history_overflow}
  defp ensure_history_complete(_snapshot), do: :ok

  defp backfill_log_range(ctx, key, filter, snapshot, from_n, to_n, owner_id) do
    provider_id = ctx.plan.provider_id
    retained_logs = Map.get(snapshot, :logs, [])

    with {:ok, orphaned_logs} <- find_orphaned_logs(ctx.plan, retained_logs),
         replay_from <- replay_from_for_logs(orphaned_logs, from_n),
         {:ok, logs} <- GapFiller.ensure_logs(ctx.plan, filter, replay_from, to_n) do
      removals = Enum.map(orphaned_logs, &Map.put(&1, "removed", true))
      emit_backfill_events(ctx.plan, owner_id, provider_id, removals ++ logs)
    else
      {:error, reason} ->
        Logger.error("Log backfill failed: #{inspect(reason)}",
          chain_id: ctx.chain_id,
          key: inspect(key)
        )

        {:error, reason}
    end
  end

  defp find_orphaned_logs(plan, retained_logs) do
    retained_logs
    |> Enum.group_by(&decode_hex(Map.get(&1, "blockNumber", "0x0")))
    |> Enum.sort_by(fn {number, _logs} -> number end, :desc)
    |> Enum.reduce_while({:ok, []}, fn {number, logs}, {:ok, orphaned} ->
      case GapFiller.ensure_blocks(plan, number, number) do
        {:ok, [canonical]} ->
          canonical_hash = Map.get(canonical, "hash")
          at_height = Enum.filter(logs, &(Map.get(&1, "blockHash") != canonical_hash))
          {:cont, {:ok, at_height ++ orphaned}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp replay_from_for_logs([], from_n), do: from_n

  defp replay_from_for_logs(orphaned_logs, from_n) do
    orphaned_logs
    |> Enum.map(&decode_hex(Map.get(&1, "blockNumber", "0x0")))
    |> Enum.min()
    |> min(from_n)
  end

  defp emit_backfill_events(plan, owner_id, provider_id, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      event_ref = make_ref()

      delivery =
        Ingress.send(
          plan.caller_pid,
          {:backfill_event, owner_id, self(), provider_id, event,
           System.monotonic_time(:millisecond), event_ref}
        )

      if delivery != :ok,
        do: send(self(), {:backfill_event_ack, event_ref, {:error, :ingress_exhausted}})

      receive do
        {:backfill_event_ack, ^event_ref, :ok} ->
          {:cont, :ok}

        {:backfill_event_ack, ^event_ref, {:error, reason}} ->
          {:halt, {:error, reason}}
      after
        max(div(plan.deadline_us - System.monotonic_time(:microsecond) + 999, 1_000), 0) ->
          {:halt, {:error, :backfill_delivery_timeout}}
      end
    end)
  end

  defp complete_failover(state, provider_id, _upstream_id) do
    recovery_kind = Map.get(state.failover_context, :recovery_kind, :failover)

    Logger.info("WebSocket continuity recovery complete",
      chain_id: state.chain_id,
      key: inspect(state.key),
      provider_id: provider_id,
      recovery_kind: recovery_kind
    )

    case drain_event_buffer(state) do
      {:ok, new_state} ->
        final_state = %{
          new_state
          | primary_provider_id: provider_id,
            failover_status: :active,
            failover_context: nil,
            failover_history: [],
            recovery_deadline_us: nil,
            recovery_started_at_ms: nil,
            recovery_attempts: 0
        }

        duration_ms =
          System.monotonic_time(:millisecond) -
            (state.recovery_started_at_ms || state.failover_context.started_at)

        telemetry_recovery_completed(
          recovery_kind,
          final_state.profile,
          final_state.chain_id,
          final_state.key,
          duration_ms
        )

        {:noreply, final_state}

      {:repair, new_state, pending_events, details} ->
        restart_state = %{
          new_state
          | primary_provider_id: provider_id,
            failover_status: :active,
            failover_context: nil
        }

        initiate_live_reorg_repair(restart_state, provider_id, pending_events, details)

      {:error, reason, retained_bytes} ->
        continuity_resource_exhausted(state, reason, retained_bytes)
    end
  end

  defp drain_event_buffer(state) do
    context = state.failover_context || %{}
    live_buffer = context |> Map.get(:event_buffer, []) |> Enum.reverse()
    replay_buffer = context |> Map.get(:replay_buffer, []) |> Enum.reverse()

    Logger.debug("Draining WebSocket continuity buffers",
      chain_id: state.chain_id,
      key: inspect(state.key),
      replay_events: length(replay_buffer),
      live_events: length(live_buffer)
    )

    result =
      case subscription_key(state.key) do
        {:newHeads} ->
          drain_head_buffers(state, replay_buffer, live_buffer, context)

        {:logs, _filter} ->
          drain_log_buffers(state, replay_buffer, live_buffer)
      end

    case result do
      {:ok, new_state} -> admit_drained_state(new_state)
      {:repair, _new_state, _pending_events, _details} = repair -> repair
      {:error, reason, retained_bytes} -> {:error, reason, retained_bytes}
    end
  catch
    {:stream_ingress_exhausted, reason} ->
      {:error, reason, StreamState.retained_bytes(state.state)}
  end

  defp drain_head_buffers(state, replay_buffer, live_buffer, context) do
    replay_buffer =
      Enum.sort_by(replay_buffer, &decode_hex(Map.get(&1, "number", "0x0")))

    stream_state =
      Enum.reduce(replay_buffer, state.state, &ingest_and_dispatch_head(&2, &1, state))

    initial_count = Map.get(context, :initial_live_event_count, 0)
    {pre_reconciliation, concurrent} = Enum.split(live_buffer, initial_count)

    with {:ok, stream_state} <-
           merge_live_heads(stream_state, pre_reconciliation, state, :http_observed),
         {:ok, stream_state} <- merge_live_heads(stream_state, concurrent, state, :concurrent) do
      {:ok, %{state | state: stream_state}}
    else
      {:repair, stream_state, pending_events, details} ->
        {:repair, %{state | state: stream_state}, pending_events, details}

      {:error, reason, stream_state} ->
        {:error, reason, StreamState.retained_bytes(stream_state)}
    end
  end

  defp merge_live_heads(stream_state, [], _state, _phase), do: {:ok, stream_state}

  defp merge_live_heads(stream_state, [payload | rest], state, phase) do
    case StreamState.new_head_continuity(stream_state, payload) do
      :continuous ->
        stream_state
        |> ingest_and_dispatch_head(payload, state)
        |> merge_live_heads(rest, state, phase)

      :duplicate ->
        merge_live_heads(stream_state, rest, state, phase)

      {:discontinuous, details}
      when phase == :http_observed and details.observed_number <= details.latest_number ->
        telemetry_stale_reorg_head_dropped(state.profile, state.chain_id, state.key, details)
        merge_live_heads(stream_state, rest, state, phase)

      {:discontinuous, details} ->
        {:repair, stream_state, [payload | rest], details}

      {:error, :invalid_header} ->
        {:error, :invalid_header, stream_state}
    end
  end

  defp ingest_and_dispatch_head(stream_state, payload, state) do
    case StreamState.ingest_new_head(stream_state, payload) do
      {next_stream_state, :emit} ->
        dispatch_buffered_event(state, payload)
        next_stream_state

      {next_stream_state, :skip} ->
        next_stream_state
    end
  end

  defp drain_log_buffers(state, replay_buffer, live_buffer) do
    stream_state =
      replay_buffer
      |> Kernel.++(live_buffer)
      |> order_recovery_logs()
      |> Enum.reduce(state.state, fn payload, stream_state ->
        case StreamState.ingest_log(stream_state, payload) do
          {next_stream_state, :emit} ->
            dispatch_buffered_event(state, payload)
            next_stream_state

          {next_stream_state, :skip} ->
            next_stream_state
        end
      end)

    {:ok, %{state | state: stream_state}}
  end

  defp order_recovery_logs(events) do
    {rollbacks, additions} =
      events
      |> Enum.group_by(&log_identity/1)
      |> Enum.map(fn {_identity, lifecycle} ->
        {trailing_additions, rollback} =
          lifecycle
          |> Enum.reverse()
          |> Enum.split_while(&(Map.get(&1, "removed", false) != true))

        {Enum.reverse(rollback), Enum.reverse(trailing_additions)}
      end)
      |> Enum.unzip()

    rollback_events =
      rollbacks
      |> Enum.reject(&(&1 == []))
      |> Enum.sort_by(&log_order_key(hd(&1)))
      |> List.flatten()

    final_additions = additions |> List.flatten() |> Enum.sort_by(&log_order_key/1)
    rollback_events ++ final_additions
  end

  defp log_order_key(log) do
    {decode_hex(Map.get(log, "blockNumber", "0x0")),
     decode_hex(Map.get(log, "transactionIndex", "0x0")),
     decode_hex(Map.get(log, "logIndex", "0x0")), log_identity(log)}
  end

  defp log_identity(log) do
    {Map.get(log, "blockHash"), Map.get(log, "transactionHash"), Map.get(log, "logIndex")}
  end

  defp dispatch_buffered_event(state, payload) do
    case ClientSubscriptionRegistry.dispatch(state.profile, state.chain_id, state.key, payload) do
      :ok -> :ok
      {:error, reason} -> throw({:stream_ingress_exhausted, reason})
    end
  end

  defp admit_drained_state(state) do
    retained_bytes = StreamState.retained_bytes(state.state)

    case reserve_retained_bytes(state, state.state, 0) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, retained_bytes}
    end
  end

  defp retain_and_dispatch(state, stream_state, payload) do
    payload_bytes = StreamState.event_bytes(payload)
    retained_bytes = StreamState.retained_bytes(stream_state)

    if payload_bytes > state.max_event_bytes do
      continuity_resource_exhausted(state, :event_too_large, payload_bytes)
    else
      case reserve_retained_bytes(state, stream_state, 0) do
        :ok ->
          case ClientSubscriptionRegistry.dispatch(
                 state.profile,
                 state.chain_id,
                 state.key,
                 payload
               ) do
            :ok -> {:noreply, %{state | state: stream_state}}
            {:error, reason} -> continuity_resource_exhausted(state, reason, retained_bytes)
          end

        {:error, reason} ->
          continuity_resource_exhausted(state, reason, retained_bytes)
      end
    end
  end

  defp continuity_resource_exhausted(state, reason, retained_bytes) do
    :telemetry.execute(
      [:lasso, :stream, :continuity_resource_exhausted],
      %{count: 1, retained_bytes: retained_bytes},
      %{
        chain_id: state.chain_id,
        profile: state.profile,
        subscription_type: Subscription.subscription_type(state.key),
        reason: reason,
        limit_bytes: continuity_limit(state, reason)
      }
    )

    Logger.error("WebSocket continuity resource bound exhausted",
      chain_id: state.chain_id,
      profile: state.profile,
      key: inspect(state.key),
      reason: reason,
      retained_bytes: retained_bytes
    )

    enter_degraded_mode(state, failover_budget(state))
  end

  defp event_buffer_bytes(buffer) do
    Enum.reduce(buffer, 0, fn payload, bytes -> bytes + StreamState.event_bytes(payload) end)
  end

  defp max_pending_head(events) do
    events
    |> Enum.map(fn event ->
      event
      |> Map.get("number", Map.get(event, "blockNumber", "0x0"))
      |> decode_hex()
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp continuity_limit(state, :event_too_large), do: state.max_event_bytes

  defp continuity_limit(state, reason) when reason in [:node_limit, :stream_limit] do
    stats = ContinuityBudget.stats(state.continuity_budget)
    Map.get(stats, reason, 0)
  end

  defp continuity_limit(_state, _reason), do: 0

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
    ContinuityBudget.release_owner(state.continuity_budget)

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
         state: StreamState.clear(state.state),
         failover_context: nil,
         failover_history: [],
         recovery_deadline_us: nil,
         recovery_started_at_ms: nil,
         recovery_attempts: 0
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

  defp continuity_range(last_seen, head, _max_backfill, _policy)
       when is_integer(last_seen) and head < last_seen do
    {:regressed, last_seen, head}
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

  defp select_backfill_provider(selector, profile, chain_id, preferred, excluded) do
    case :erlang.fun_info(selector, :arity) do
      {:arity, 4} -> selector.(profile, chain_id, preferred, excluded -- [preferred])
      {:arity, 3} -> selector.(profile, chain_id, excluded)
    end
  end

  # Disconnected failover retains Core's independent HTTP fallback. A live
  # reorg uses the source provider's own HTTP endpoint to certify its branch.
  defp pick_best_http_provider(profile, chain_id, excluded) do
    case Selection.select_provider(
           profile,
           chain_id,
           "eth_getBlockByNumber",
           strategy: :fastest,
           protocol: :http,
           exclude: excluded
         ) do
      {:ok, provider_id} -> {:ok, provider_id}
      _ -> {:error, :no_http_provider}
    end
  end

  @doc false
  @spec pick_backfill_http_provider(String.t(), pos_integer(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, :no_http_provider}
  def pick_backfill_http_provider(profile, chain_id, preferred, excluded) do
    with false <- preferred in excluded,
         instance_id when is_binary(instance_id) <-
           Catalog.lookup_instance_id(profile, chain_id, preferred),
         {:ok, %{url: url}} when is_binary(url) <- Catalog.get_instance(instance_id) do
      {:ok, preferred}
    else
      _ -> {:error, :no_http_provider}
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

  defp telemetry_recovery_completed(:live_reorg, profile, chain_id, key, duration_ms) do
    :telemetry.execute(
      [:lasso, :subs, :reorg_repair, :completed],
      %{duration_ms: duration_ms},
      %{profile: profile, chain_id: chain_id, key: inspect(key)}
    )
  end

  defp telemetry_recovery_completed(_kind, _profile, chain_id, key, duration_ms) do
    telemetry_failover_completed(chain_id, key, duration_ms)
  end

  defp telemetry_live_reorg_started(
         profile,
         chain_id,
         key,
         provider_id,
         http_provider,
         details
       ) do
    :telemetry.execute([:lasso, :subs, :reorg_repair, :started], %{count: 1}, %{
      profile: profile,
      chain_id: chain_id,
      key: inspect(key),
      provider_id: provider_id,
      http_provider_id: http_provider,
      latest_number: details.latest_number,
      observed_number: details.observed_number
    })
  end

  defp telemetry_stale_reorg_head_dropped(profile, chain_id, key, details) do
    :telemetry.execute([:lasso, :subs, :reorg_repair, :stale_head_dropped], %{count: 1}, %{
      profile: profile,
      chain_id: chain_id,
      key: inspect(key),
      latest_number: details.latest_number,
      observed_number: details.observed_number
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

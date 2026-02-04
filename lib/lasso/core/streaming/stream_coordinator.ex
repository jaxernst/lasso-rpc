defmodule Lasso.Core.Streaming.StreamCoordinator do
  @moduledoc """
  Per-key coordinator that owns continuity (markers, dedupe) and orchestrates failover.

  Receives upstream events from UpstreamSubscriptionPool and provider health signals.
  Orchestrates failover with synchronous transitions: :active -> :backfilling -> :switching -> :active.
  Ensures gap-free, duplicate-free event delivery with automatic provider failover.
  """

  use GenServer
  require Logger

  alias Lasso.Core.Support.{ContinuityPolicy, GapFiller}

  alias Lasso.RPC.{
    ChainState,
    RequestOptions,
    Selection
  }

  alias Lasso.Core.Streaming.{
    ClientSubscriptionRegistry,
    StreamState
  }

  defmodule BackfillContext do
    @moduledoc false
    defstruct [
      :profile,
      :chain,
      :max_backfill,
      :backfill_timeout,
      :continuity_policy,
      :excluded_providers
    ]

    @type t :: %__MODULE__{
            profile: String.t(),
            chain: String.t(),
            max_backfill: non_neg_integer(),
            backfill_timeout: non_neg_integer(),
            continuity_policy: atom(),
            excluded_providers: [String.t()]
          }
  end

  @type key :: {:newHeads} | {:logs, map()}

  # Circuit breaker defaults
  @max_failover_attempts 3
  @failover_cooldown_ms 5_000
  @max_event_buffer 100
  @degraded_mode_retry_delay_ms 30_000

  @spec start_link({String.t(), String.t(), term(), keyword()}) :: GenServer.on_start()
  def start_link({profile, chain, key, opts})
      when is_binary(profile) and is_binary(chain) do
    GenServer.start_link(__MODULE__, {profile, chain, key, opts}, name: via(profile, chain, key))
  end

  @spec via(String.t(), String.t(), term()) :: {:via, Registry, {atom(), tuple()}}
  def via(profile, chain, key) when is_binary(profile) and is_binary(chain) do
    {:via, Registry, {Lasso.Registry, {:stream_coordinator, profile, chain, key}}}
  end

  # API called by UpstreamSubscriptionPool

  @spec upstream_event(
          String.t(),
          String.t(),
          term(),
          String.t(),
          String.t() | nil,
          term(),
          integer()
        ) ::
          :ok
  def upstream_event(profile, chain, key, provider_id, upstream_id, payload, received_at)
      when is_binary(profile) and is_binary(chain) do
    GenServer.cast(
      via(profile, chain, key),
      {:upstream_event, provider_id, upstream_id, payload, received_at}
    )
  end

  @spec provider_unhealthy(String.t(), String.t(), term(), String.t(), String.t()) :: :ok
  def provider_unhealthy(profile, chain, key, failed_id, proposed_new_id)
      when is_binary(profile) and is_binary(chain) do
    GenServer.cast(via(profile, chain, key), {:provider_unhealthy, failed_id, proposed_new_id})
  end

  # GenServer callbacks

  @impl true
  def init({profile, chain, key, opts}) do
    state = %{
      profile: profile,
      chain: chain,
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
      continuity_policy: Keyword.get(opts, :continuity_policy, :best_effort),
      # Failover state machine
      failover_status: :active,
      failover_context: nil,
      failover_history: [],
      max_failover_attempts: Keyword.get(opts, :max_failover_attempts, @max_failover_attempts),
      failover_cooldown_ms: Keyword.get(opts, :failover_cooldown_ms, @failover_cooldown_ms),
      max_event_buffer: Keyword.get(opts, :max_event_buffer, @max_event_buffer)
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:upstream_event, _provider_id, _upstream_id, payload, _received_at}, state) do
    case state.failover_status do
      :active ->
        # Normal processing path
        process_event_normal(state, payload)

      :backfilling ->
        # Buffer events during backfill
        buffer_event(state, payload)

      :switching ->
        # Buffer events during subscription switch
        buffer_event(state, payload)

      :degraded ->
        # Circuit breaker triggered, drop events
        # Emit telemetry for production visibility (metrics)
        :telemetry.execute(
          [:lasso, :stream, :dropped_event],
          %{count: 1},
          %{chain: state.chain, reason: :degraded_mode}
        )

        # Downgrade to DEBUG (filtered in production)
        Logger.debug("Dropping event in degraded mode",
          chain: state.chain,
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
        chain: state.chain,
        key: inspect(state.key),
        current_status: state.failover_status
      )

      {:noreply, state}
    end
  end

  # Subscription confirmation from Pool
  @impl true
  def handle_info({:subscription_confirmed, provider_id, upstream_id}, state) do
    if state.failover_status == :switching do
      complete_failover(state, provider_id, upstream_id)
    else
      Logger.warning("Unexpected subscription_confirmed in status #{state.failover_status}",
        chain: state.chain,
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
        chain: state.chain,
        key: inspect(state.key)
      )

      {:noreply, state}
    end
  end

  # Backfill task completion
  @impl true
  def handle_info({ref, :backfill_complete}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    if state.failover_status == :backfilling do
      transition_to_switching(state)
    else
      {:noreply, state}
    end
  end

  # Backfill task crashed
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if state.failover_context && state.failover_context.backfill_task_ref == ref do
      Logger.error("Backfill task crashed: #{inspect(reason)}",
        chain: state.chain,
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
        chain: state.chain,
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
  def handle_info(_msg, state), do: {:noreply, state}

  # Internal implementation

  defp process_event_normal(state, payload) do
    case state.key do
      {:newHeads} ->
        case StreamState.ingest_new_head(state.state, payload) do
          {stream_state, :emit} ->
            ClientSubscriptionRegistry.dispatch(state.profile, state.chain, state.key, payload)
            {:noreply, %{state | state: stream_state}}

          {stream_state, :skip} ->
            {:noreply, %{state | state: stream_state}}
        end

      {:logs, _filter} ->
        case StreamState.ingest_log(state.state, payload) do
          {stream_state, :emit} ->
            ClientSubscriptionRegistry.dispatch(state.profile, state.chain, state.key, payload)
            {:noreply, %{state | state: stream_state}}

          {stream_state, :skip} ->
            {:noreply, %{state | state: stream_state}}
        end
    end
  end

  defp buffer_event(state, payload) do
    if state.failover_context do
      buffer = state.failover_context.event_buffer

      if length(buffer) < state.max_event_buffer do
        updated_context = %{state.failover_context | event_buffer: buffer ++ [payload]}
        {:noreply, %{state | failover_context: updated_context}}
      else
        Logger.warning("Event buffer full (#{state.max_event_buffer}), dropping oldest event",
          chain: state.chain,
          key: inspect(state.key)
        )

        # Drop oldest, keep newest
        updated_buffer = Enum.drop(buffer, 1) ++ [payload]
        updated_context = %{state.failover_context | event_buffer: updated_buffer}
        {:noreply, %{state | failover_context: updated_context}}
      end
    else
      {:noreply, state}
    end
  end

  # Standard failover initiation with empty buffer
  defp initiate_failover(state, old_provider_id, new_provider_id) do
    initiate_failover_with_buffer(state, old_provider_id, new_provider_id, [])
  end

  # Failover initiation with preserved buffer (used during cascade)
  defp initiate_failover_with_buffer(state, old_provider_id, new_provider_id, initial_buffer) do
    Logger.info("Initiating failover: #{old_provider_id} -> #{new_provider_id}",
      chain: state.chain,
      key: inspect(state.key)
    )

    # Check circuit breaker
    recent_failures = count_recent_failures(state.failover_history, state.failover_cooldown_ms)

    if recent_failures >= state.max_failover_attempts do
      Logger.error(
        "Circuit breaker triggered: #{recent_failures} attempts in #{state.failover_cooldown_ms}ms",
        chain: state.chain,
        key: inspect(state.key)
      )

      enter_degraded_mode(state)
    else
      # Start backfill task
      profile = state.profile
      chain = state.chain
      key = state.key
      max_backfill = state.max_backfill_blocks
      backfill_timeout = state.backfill_timeout
      continuity_policy = state.continuity_policy
      stream_state = state.state

      backfill_ctx = %BackfillContext{
        profile: profile,
        chain: chain,
        max_backfill: max_backfill,
        backfill_timeout: backfill_timeout,
        continuity_policy: continuity_policy,
        excluded_providers: [old_provider_id, new_provider_id]
      }

      task =
        Task.async(fn ->
          execute_backfill(backfill_ctx, key, new_provider_id, stream_state)
          :backfill_complete
        end)

      failover_context = %{
        old_provider_id: old_provider_id,
        new_provider_id: new_provider_id,
        backfill_task_ref: task.ref,
        started_at: System.monotonic_time(:millisecond),
        # Preserve events from previous cascade attempt
        event_buffer: initial_buffer,
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

      telemetry_failover_initiated(state.chain, state.key, old_provider_id, new_provider_id)

      {:noreply,
       %{
         state
         | failover_status: :backfilling,
           failover_context: failover_context,
           failover_history: new_history
       }}
    end
  end

  defp execute_backfill(ctx, key, new_provider_id, stream_state) do
    case key do
      {:newHeads} ->
        backfill_blocks(ctx, key, new_provider_id, stream_state)

      {:logs, filter} ->
        backfill_logs(ctx, key, filter, new_provider_id, stream_state)
    end
  rescue
    e ->
      Logger.error("Backfill error: #{inspect(e)}", chain: ctx.chain, key: inspect(key))
      :error
  end

  defp backfill_blocks(ctx, key, _new_ws_provider_id, stream_state) do
    last = StreamState.last_block_num(stream_state)

    # Use decoupled HTTP provider selection for backfill
    http_provider = pick_best_http_provider(ctx.profile, ctx.chain, ctx.excluded_providers)
    head = fetch_head(ctx.chain, http_provider)

    case ContinuityPolicy.needed_block_range(
           last,
           head,
           ctx.max_backfill,
           ctx.continuity_policy
         ) do
      {:none} ->
        :ok

      {:range, from_n, to_n} ->
        telemetry_backfill_started(ctx.chain, from_n, to_n, http_provider)

        {:ok, blocks} =
          GapFiller.ensure_blocks(ctx.chain, http_provider, from_n, to_n,
            timeout_ms: ctx.backfill_timeout
          )

        # Send blocks to coordinator via cast
        coordinator_pid = via(ctx.profile, ctx.chain, key)

        Enum.each(blocks, fn block ->
          GenServer.cast(
            coordinator_pid,
            {:upstream_event, http_provider, nil, block, System.monotonic_time(:millisecond)}
          )
        end)

        telemetry_backfill_completed(ctx.chain, from_n, to_n, length(blocks))
        :ok

      {:exceeded, from_n, to_n} ->
        Logger.warning("Gap exceeds max_backfill_blocks: #{from_n}-#{to_n}",
          chain: ctx.chain,
          key: inspect(key)
        )

        case ctx.continuity_policy do
          :best_effort ->
            # Fill what we can
            telemetry_backfill_started(ctx.chain, from_n, to_n, http_provider)

            {:ok, blocks} =
              GapFiller.ensure_blocks(ctx.chain, http_provider, from_n, to_n,
                timeout_ms: ctx.backfill_timeout
              )

            coordinator_pid = via(ctx.profile, ctx.chain, key)

            Enum.each(blocks, fn block ->
              GenServer.cast(
                coordinator_pid,
                {:upstream_event, http_provider, nil, block, System.monotonic_time(:millisecond)}
              )
            end)

            telemetry_backfill_completed(ctx.chain, from_n, to_n, length(blocks))
            :ok

          :strict_abort ->
            :error
        end
    end
  end

  defp backfill_logs(ctx, key, filter, _new_ws_provider_id, stream_state) do
    last = StreamState.last_log_block(stream_state) || StreamState.last_block_num(stream_state)

    # Use decoupled HTTP provider selection for backfill
    http_provider = pick_best_http_provider(ctx.profile, ctx.chain, ctx.excluded_providers)
    head = fetch_head(ctx.chain, http_provider)

    case ContinuityPolicy.needed_block_range(
           last,
           head,
           ctx.max_backfill,
           ctx.continuity_policy
         ) do
      {:none} ->
        :ok

      {:range, from_n, to_n} ->
        telemetry_backfill_started(ctx.chain, from_n, to_n, http_provider)

        case GapFiller.ensure_logs(ctx.chain, http_provider, filter, from_n, to_n,
               timeout_ms: ctx.backfill_timeout
             ) do
          {:ok, logs} ->
            coordinator_pid = via(ctx.profile, ctx.chain, key)

            Enum.each(logs, fn log ->
              GenServer.cast(
                coordinator_pid,
                {:upstream_event, http_provider, nil, log, System.monotonic_time(:millisecond)}
              )
            end)

            telemetry_backfill_completed(ctx.chain, from_n, to_n, length(logs))
            :ok

          {:error, reason} ->
            Logger.error("Log backfill failed: #{inspect(reason)}")
            :error
        end

      {:exceeded, from_n, to_n} ->
        Logger.warning("Gap exceeds max_backfill_blocks: #{from_n}-#{to_n}",
          chain: ctx.chain,
          key: inspect(key)
        )

        # For logs, best effort fill
        telemetry_backfill_started(ctx.chain, from_n, to_n, http_provider)

        case GapFiller.ensure_logs(ctx.chain, http_provider, filter, from_n, to_n,
               timeout_ms: ctx.backfill_timeout
             ) do
          {:ok, logs} ->
            coordinator_pid = via(ctx.profile, ctx.chain, key)

            Enum.each(logs, fn log ->
              GenServer.cast(
                coordinator_pid,
                {:upstream_event, http_provider, nil, log, System.monotonic_time(:millisecond)}
              )
            end)

            telemetry_backfill_completed(ctx.chain, from_n, to_n, length(logs))
            :ok

          {:error, reason} ->
            Logger.error("Log backfill failed: #{inspect(reason)}")
            :error
        end
    end
  end

  defp transition_to_switching(state) do
    Logger.info("Backfill complete, transitioning to :switching",
      chain: state.chain,
      key: inspect(state.key)
    )

    # Request resubscription from Pool
    pool_ref = Lasso.Core.Streaming.UpstreamSubscriptionPool.via(state.profile, state.chain)

    GenServer.cast(
      pool_ref,
      {:resubscribe, state.key, state.failover_context.new_provider_id, self()}
    )

    telemetry_resubscribe_initiated(
      state.chain,
      state.key,
      state.failover_context.new_provider_id
    )

    {:noreply, %{state | failover_status: :switching}}
  end

  defp complete_failover(state, provider_id, _upstream_id) do
    Logger.info("Failover complete: now on provider #{provider_id}",
      chain: state.chain,
      key: inspect(state.key)
    )

    # Drain buffered events through dedupe
    new_state = drain_event_buffer(state)

    # Update primary provider
    final_state = %{
      new_state
      | primary_provider_id: provider_id,
        failover_status: :active,
        failover_context: nil
    }

    duration_ms = System.monotonic_time(:millisecond) - state.failover_context.started_at
    telemetry_failover_completed(final_state.chain, final_state.key, duration_ms)

    {:noreply, final_state}
  end

  defp drain_event_buffer(state) do
    if state.failover_context && length(state.failover_context.event_buffer) > 0 do
      Logger.debug(
        "Draining #{length(state.failover_context.event_buffer)} buffered events",
        chain: state.chain,
        key: inspect(state.key)
      )

      # Sort deterministically before deduping
      ordered_buffer =
        case state.key do
          {:newHeads} ->
            Enum.sort_by(state.failover_context.event_buffer, fn payload ->
              decode_hex(Map.get(payload, "number", "0x0"))
            end)

          {:logs, _filter} ->
            Enum.sort_by(state.failover_context.event_buffer, fn log ->
              {decode_hex(Map.get(log, "blockNumber", "0x0")),
               decode_hex(Map.get(log, "transactionIndex", "0x0")),
               decode_hex(Map.get(log, "logIndex", "0x0"))}
            end)
        end

      Enum.reduce(ordered_buffer, state, fn payload, acc ->
        case acc.key do
          {:newHeads} ->
            case StreamState.ingest_new_head(acc.state, payload) do
              {stream_state, :emit} ->
                ClientSubscriptionRegistry.dispatch(acc.profile, acc.chain, acc.key, payload)
                %{acc | state: stream_state}

              {stream_state, :skip} ->
                %{acc | state: stream_state}
            end

          {:logs, _filter} ->
            case StreamState.ingest_log(acc.state, payload) do
              {stream_state, :emit} ->
                ClientSubscriptionRegistry.dispatch(acc.profile, acc.chain, acc.key, payload)
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
      chain: state.chain,
      key: inspect(state.key)
    )

    # Check if we should cascade to another provider
    recent_failures = count_recent_failures(state.failover_history, state.failover_cooldown_ms)

    if recent_failures >= state.max_failover_attempts do
      Logger.error("Max failover attempts reached, entering degraded mode",
        chain: state.chain,
        key: inspect(state.key)
      )

      enter_degraded_mode(state)
    else
      # Try next provider
      excluded = [
        state.failover_context.old_provider_id,
        state.failover_context.new_provider_id
      ]

      case pick_next_provider(state, excluded) do
        {:ok, next_provider_id} ->
          Logger.info("Cascading to next provider: #{next_provider_id}",
            chain: state.chain,
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
            chain: state.chain,
            key: inspect(state.key)
          )

          enter_degraded_mode(state)
      end
    end
  end

  defp handle_backfill_failure(state, _reason) do
    Logger.error("Backfill task failed",
      chain: state.chain,
      key: inspect(state.key)
    )

    # Treat as resubscribe failure
    handle_resubscribe_failure(state, :backfill_failed)
  end

  defp enter_degraded_mode(state) do
    Logger.error("Entering degraded mode",
      chain: state.chain,
      key: inspect(state.key)
    )

    # Schedule retry after cooldown
    Process.send_after(self(), :retry_from_degraded, @degraded_mode_retry_delay_ms)

    telemetry_failover_degraded(state.chain, state.key)

    {:noreply,
     %{
       state
       | failover_status: :degraded,
         failover_context: nil
     }}
  end

  defp count_recent_failures(history, window_ms) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - window_ms

    Enum.count(history, fn entry -> entry.failed_at > cutoff end)
  end

  defp pick_next_provider(state, excluded) do
    case Selection.select_provider(
           state.profile,
           state.chain,
           "eth_subscribe",
           strategy: :priority,
           protocol: :ws,
           exclude: excluded
         ) do
      {:ok, provider_id} -> {:ok, provider_id}
      _ -> {:error, :no_providers}
    end
  end

  defp pick_best_http_provider(profile, chain, excluded) do
    # Select best available HTTP provider for backfill (decoupled from WS selection)
    case Selection.select_provider(
           profile,
           chain,
           "eth_getBlockByNumber",
           strategy: :fastest,
           protocol: :http,
           exclude: excluded
         ) do
      {:ok, provider_id} -> provider_id
      _ -> List.first(excluded) || "default"
    end
  end

  defp fetch_head(chain, _provider_id) do
    # Use consensus height for fast failover (<1ms vs 200-500ms)
    case ChainState.consensus_height(chain) do
      {:ok, height} ->
        Logger.debug("Using consensus height for failover gap calculation",
          chain: chain,
          height: height
        )

        height

      {:error, reason} ->
        Logger.warning("Consensus unavailable during failover, using blocking request",
          chain: chain,
          reason: reason
        )

        # Fallback to blocking HTTP request if consensus unavailable
        fetch_head_blocking(chain)
    end
  end

  defp fetch_head_blocking(chain) do
    # Original blocking implementation as fallback
    case Lasso.RPC.RequestPipeline.execute_via_channels(
           chain,
           "eth_blockNumber",
           [],
           %RequestOptions{
             strategy: :priority,
             failover_on_override: false,
             timeout_ms: 3_000
           }
         ) do
      {:ok, "0x" <> _ = hex, _ctx} ->
        String.to_integer(String.trim_leading(hex, "0x"), 16)

      _ ->
        0
    end
  end

  defp decode_hex(nil), do: 0
  defp decode_hex("0x" <> rest), do: String.to_integer(rest, 16)
  defp decode_hex(num) when is_integer(num), do: num
  defp decode_hex(_), do: 0

  # Telemetry helpers

  defp telemetry_failover_initiated(chain, key, old_id, new_id) do
    :telemetry.execute([:lasso, :subs, :failover, :initiated], %{count: 1}, %{
      chain: chain,
      key: inspect(key),
      old_provider: inspect(old_id),
      new_provider: inspect(new_id)
    })
  end

  defp telemetry_backfill_started(chain, from_n, to_n, provider_id) do
    :telemetry.execute(
      [:lasso, :subs, :failover, :backfill_started],
      %{count: to_n - from_n + 1},
      %{
        chain: chain,
        provider_id: provider_id,
        from_block: from_n,
        to_block: to_n
      }
    )
  end

  defp telemetry_backfill_completed(chain, from_n, to_n, fetched_count) do
    :telemetry.execute(
      [:lasso, :subs, :failover, :backfill_completed],
      %{count: fetched_count},
      %{
        chain: chain,
        from_block: from_n,
        to_block: to_n
      }
    )
  end

  defp telemetry_resubscribe_initiated(chain, key, provider_id) do
    :telemetry.execute([:lasso, :subs, :failover, :resubscribe_initiated], %{count: 1}, %{
      chain: chain,
      key: inspect(key),
      provider_id: provider_id
    })
  end

  defp telemetry_failover_completed(chain, key, duration_ms) do
    :telemetry.execute([:lasso, :subs, :failover, :completed], %{duration_ms: duration_ms}, %{
      chain: chain,
      key: inspect(key)
    })
  end

  defp telemetry_failover_degraded(chain, key) do
    :telemetry.execute([:lasso, :subs, :failover, :degraded], %{count: 1}, %{
      chain: chain,
      key: inspect(key)
    })
  end
end

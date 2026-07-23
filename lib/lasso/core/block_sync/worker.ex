defmodule Lasso.BlockSync.Worker do
  @moduledoc """
  Per-instance GenServer that orchestrates block sync strategies.

  Each unique provider instance gets one Worker that:
  1. Always runs HTTP polling for reliable block height tracking
  2. Optionally runs WS subscription for real-time updates
  3. Reports heights to BlockSync.Registry
  4. Fan-out broadcasts to all profiles referencing this instance

  ## State Machine

  The Worker operates in one of two modes:
  - `:http_only` - HTTP polling only (WS unavailable or disabled)
  - `:http_with_ws` - HTTP polling + WS subscription (real-time layer)

  ## WS-Aware Polling

  When WS subscription is active, HTTP polling interval is reduced (3x normal)
  to conserve RPC usage while maintaining connection warmth and WS liveness
  detection. Normal interval is restored when WS degrades or disconnects.
  """

  use GenServer
  require Logger

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.BlockSync.Strategies.{HttpStrategy, WsStrategy}
  alias Lasso.Config.{ChainConfig, ConfigStore, MonitoringDefaults}
  alias Lasso.Providers.{Catalog, RestartCounter}

  @reconnect_delay_ms 5_000
  @ws_active_poll_multiplier 3

  @type mode :: :http_only | :http_with_ws
  @type config :: %{
          subscribe_new_heads: boolean(),
          poll_interval_ms: pos_integer(),
          ws_active_poll_interval_ms: pos_integer(),
          staleness_threshold_ms: pos_integer()
        }

  @type auth_scope :: :system

  @type t :: %__MODULE__{
          chain_id: pos_integer(),
          instance_id: String.t(),
          mode: mode() | nil,
          ws_strategy: pid() | nil,
          http_strategy: pid() | nil,
          config: config(),
          ws_retry_count: non_neg_integer(),
          http_reduced: boolean(),
          auth_scope: auth_scope() | nil,
          last_emitted_coalesced: tuple() | nil,
          start_timer_ref: reference() | nil,
          restart_count_cleared: boolean()
        }

  defstruct [
    :chain_id,
    :instance_id,
    :mode,
    :ws_strategy,
    :http_strategy,
    :config,
    :auth_scope,
    :last_emitted_coalesced,
    :start_timer_ref,
    ws_retry_count: 0,
    http_reduced: false,
    restart_count_cleared: false
  ]

  ## Client API

  @spec start_link({pos_integer(), String.t()}) :: GenServer.on_start()
  def start_link({chain_id, instance_id})
      when is_integer(chain_id) and chain_id > 0 and is_binary(instance_id) do
    GenServer.start_link(__MODULE__, {chain_id, instance_id}, name: via(chain_id, instance_id))
  end

  @spec via(pos_integer(), String.t()) :: {:via, Registry, {atom(), tuple()}}
  def via(chain_id, instance_id) when is_integer(chain_id) and is_binary(instance_id) do
    {:via, Registry, {Lasso.Registry, {:block_sync_worker, chain_id, instance_id}}}
  end

  @spec get_status(pos_integer(), String.t()) :: map() | {:error, :not_running}
  def get_status(chain_id, instance_id)
      when is_integer(chain_id) and chain_id > 0 and is_binary(instance_id) do
    GenServer.call(via(chain_id, instance_id), :get_status)
  catch
    :exit, _ -> {:error, :not_running}
  end

  ## GenServer Callbacks

  @impl true
  def init({chain_id, instance_id}) do
    state = %__MODULE__{
      chain_id: chain_id,
      instance_id: instance_id,
      mode: nil,
      ws_strategy: nil,
      http_strategy: nil,
      config: nil,
      auth_scope: nil,
      last_emitted_coalesced: nil,
      start_timer_ref: nil,
      ws_retry_count: 0,
      http_reduced: false,
      restart_count_cleared: false
    }

    {:ok, state, {:continue, :deferred_start}}
  end

  @impl true
  def handle_continue(:deferred_start, state) do
    Phoenix.PubSub.subscribe(
      Lasso.PubSub,
      Lasso.Topics.instance_config_updated(state.instance_id)
    )

    Phoenix.PubSub.subscribe(Lasso.PubSub, Lasso.Topics.ws_conn_instance(state.instance_id))

    Phoenix.PubSub.subscribe(
      Lasso.PubSub,
      Lasso.Topics.instance_sub_manager_restarted(state.chain_id)
    )

    {config, auth_scope, last_emitted_coalesced} =
      load_config_with_telemetry(state.instance_id, state.chain_id, nil, nil)

    state = %{
      state
      | config: config,
        auth_scope: auth_scope,
        last_emitted_coalesced: last_emitted_coalesced
    }

    backoff = RestartCounter.backoff_for(RestartCounter.bump({:block_sync, state.instance_id}))
    start_timer_ref = Process.send_after(self(), :start_strategies, backoff)
    state = %{state | start_timer_ref: start_timer_ref}

    Logger.debug("BlockSync.Worker started",
      chain_id: state.chain_id,
      instance_id: state.instance_id,
      subscribe_new_heads: config.subscribe_new_heads,
      start_backoff_ms: backoff
    )

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      mode: state.mode,
      ws_status: if(state.ws_strategy, do: WsStrategy.get_status(state.ws_strategy), else: nil),
      http_status:
        if(state.http_strategy, do: HttpStrategy.get_status(state.http_strategy), else: nil),
      config: state.config,
      http_reduced: state.http_reduced
    }

    {:reply, {:ok, status}, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.start_timer_ref, do: Process.cancel_timer(state.start_timer_ref)

    # Release strategy resources on supervised shutdown (auth rotation,
    # provider removal, profile suspension). Without this, WS subscriptions
    # leak on the InstanceSubscriptionManager and pending HTTP poll timers
    # remain associated with a dead pid (cosmetically benign but obscures
    # the supervision tree's reaper accounting).
    if state.ws_strategy, do: WsStrategy.stop(state.ws_strategy)
    if state.http_strategy, do: HttpStrategy.stop(state.http_strategy)
    :ok
  end

  @impl true
  def handle_info(:instance_config_updated, state) do
    {new_config, auth_scope, last_emitted_coalesced} =
      load_config_with_telemetry(
        state.instance_id,
        state.chain_id,
        state.auth_scope,
        state.last_emitted_coalesced
      )

    state =
      state
      |> Map.put(:auth_scope, auth_scope)
      |> Map.put(:last_emitted_coalesced, last_emitted_coalesced)
      |> apply_config_reload(new_config)

    {:noreply, state}
  end

  @impl true
  def handle_info(:start_strategies, state) do
    state = %{state | start_timer_ref: nil}
    state = start_strategies(state)
    {:noreply, state}
  end

  # Block height reports from strategies
  def handle_info({:block_height, instance_id, height, metadata}, state)
      when instance_id == state.instance_id do
    source = if metadata[:latency_ms], do: :http, else: :ws

    BlockSyncRegistry.put_height(state.chain_id, instance_id, height, source, metadata)
    broadcast_height_update(state, height, source)

    state = maybe_clear_restart_count(state)
    {:noreply, state}
  end

  # Status changes from strategies
  def handle_info({:status, instance_id, transport, status}, state)
      when instance_id == state.instance_id do
    state = handle_strategy_status(state, transport, status)
    {:noreply, state}
  end

  # HTTP strategy poll timer
  def handle_info({:http_strategy, :poll, instance_id, generation}, state)
      when instance_id == state.instance_id and state.http_strategy != nil do
    {:ok, new_http_state} = HttpStrategy.handle_message({:poll, generation}, state.http_strategy)
    {:noreply, %{state | http_strategy: new_http_state}}
  end

  def handle_info({:http_strategy, :poll, instance_id, _generation}, state)
      when instance_id == state.instance_id and state.http_strategy == nil do
    {:noreply, state}
  end

  # WS strategy staleness check timer
  def handle_info({:ws_strategy, :check_staleness, instance_id}, state)
      when instance_id == state.instance_id and state.ws_strategy != nil do
    {:ok, new_ws_state} = WsStrategy.handle_message(:check_staleness, state.ws_strategy)
    {:noreply, %{state | ws_strategy: new_ws_state}}
  end

  def handle_info({:ws_strategy, :check_staleness, instance_id}, state)
      when instance_id == state.instance_id and state.ws_strategy == nil do
    {:noreply, state}
  end

  # newHeads events from InstanceSubscriptionManager via InstanceSubscriptionRegistry
  def handle_info(
        {:instance_subscription_event, instance_id, {:newHeads}, payload, _received_at},
        state
      )
      when instance_id == state.instance_id and state.ws_strategy != nil and is_map(payload) do
    new_ws_state = WsStrategy.handle_new_head(state.ws_strategy, payload)
    {:noreply, %{state | ws_strategy: new_ws_state}}
  end

  def handle_info(
        {:instance_subscription_event, instance_id, {:newHeads}, _payload, _received_at},
        state
      )
      when instance_id == state.instance_id do
    {:noreply, state}
  end

  # Subscription invalidation
  def handle_info(
        {:instance_subscription_invalidated, instance_id, {:newHeads}, reason},
        state
      )
      when instance_id == state.instance_id and state.ws_strategy != nil do
    new_ws_state = WsStrategy.handle_invalidation(state.ws_strategy, reason)
    {:noreply, %{state | ws_strategy: new_ws_state}}
  end

  # WS reconnected
  def handle_info({:ws_connected, instance_id, _connection_id}, state)
      when instance_id == state.instance_id do
    state = handle_ws_reconnected(state)
    {:noreply, state}
  end

  # WS disconnected
  def handle_info({:ws_disconnected, instance_id, _error}, state)
      when instance_id == state.instance_id do
    state = handle_ws_disconnected(state)
    {:noreply, state}
  end

  def handle_info({:ws_closed, instance_id, _code, _error}, state)
      when instance_id == state.instance_id do
    state = handle_ws_disconnected(state)
    {:noreply, state}
  end

  # Manager restart - re-establish WS subscription if the restarted manager is ours
  def handle_info({:instance_sub_manager_restarted, instance_id}, state)
      when instance_id == state.instance_id do
    state = handle_manager_restarted(state)
    {:noreply, state}
  end

  # Ignore restarts for other instances on the same chain
  def handle_info({:instance_sub_manager_restarted, _other_instance_id}, state) do
    {:noreply, state}
  end

  # WS reconnect attempt timer
  def handle_info(:attempt_ws_reconnect, state) do
    state = attempt_ws_reconnect(state)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  # First successful block-height after a (re)start clears the
  # restart counter so a worker that runs healthy for any meaningful
  # interval no longer carries crash-loop debt. A worker that crashes
  # between handle_continue and the first :block_height keeps its
  # count — that's the desired flapping signal.
  defp maybe_clear_restart_count(%{restart_count_cleared: true} = state), do: state

  defp maybe_clear_restart_count(state) do
    RestartCounter.clear({:block_sync, state.instance_id})
    %{state | restart_count_cleared: true}
  end

  defp broadcast_height_update(state, height, source) do
    profiles = Catalog.get_instance_refs(state.instance_id)
    timestamp = System.system_time(:millisecond)

    for profile <- profiles do
      provider_id =
        Catalog.reverse_lookup_provider_id(profile, state.chain_id, state.instance_id) ||
          state.instance_id

      provider_key = {profile, provider_id}
      msg = {:block_height_update, provider_key, height, source, timestamp}

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        Lasso.Topics.block_sync(profile, state.chain_id),
        msg
      )

      sync_msg = %{chain_id: state.chain_id, provider_id: provider_id, block_height: height}
      Phoenix.PubSub.broadcast(Lasso.PubSub, Lasso.Topics.sync_updates(profile), sync_msg)
    end
  end

  defp load_config_with_telemetry(instance_id, chain_id, existing_auth_scope, last_emitted) do
    config = load_config(instance_id, chain_id)
    refs = Catalog.get_instance_refs(instance_id)
    auth_scope = existing_auth_scope || compute_auth_scope(refs)

    ref_configs =
      refs
      |> Enum.map(fn ref -> ConfigStore.get_chain(ref, chain_id) end)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, cc} -> cc end)

    ref_count = length(refs)
    ref_count_with_config = length(ref_configs)

    poll_intervals =
      Enum.map(ref_configs, & &1.monitoring.probe_interval_ms)

    coalesced_tuple =
      {config.poll_interval_ms, config.staleness_threshold_ms, config.subscribe_new_heads,
       Map.get(config, :max_backfill_blocks), Map.get(config, :backfill_timeout_ms)}

    new_last_emitted =
      if coalesced_tuple != last_emitted do
        {p50, p99} = percentiles(poll_intervals)

        :telemetry.execute(
          [:lasso, :block_sync, :worker, :coalesced_config],
          %{
            coalesced_poll_interval_ms: config.poll_interval_ms,
            ref_count: ref_count,
            ref_count_with_config: ref_count_with_config,
            poll_interval_p50_ms: p50,
            poll_interval_p99_ms: p99
          },
          %{
            instance_id: instance_id,
            chain_id: chain_id,
            auth_scope: auth_scope
          }
        )

        coalesced_tuple
      else
        last_emitted
      end

    {config, auth_scope, new_last_emitted}
  end

  @doc "Loads and coalesces block-sync configuration for an instance."
  @spec load_config(String.t(), pos_integer()) :: map()
  def load_config(instance_id, chain_id) do
    refs = Catalog.get_instance_refs(instance_id)
    has_ws = instance_has_ws?(instance_id)

    ref_configs =
      refs
      |> Enum.map(fn ref -> {ref, ConfigStore.get_chain(ref, chain_id)} end)
      |> Enum.filter(fn {_, result} -> match?({:ok, _}, result) end)
      |> Enum.map(fn {ref, {:ok, cc}} -> {ref, cc} end)

    case ref_configs do
      [] -> default_config(instance_id, has_ws)
      _ -> coalesce_config(ref_configs, instance_id, chain_id, has_ws)
    end
  end

  @doc "Builds default block-sync configuration for an instance."
  @spec default_config(String.t(), boolean()) :: map()
  def default_config(instance_id, has_ws) do
    block_time_ms = instance_block_time_ms(instance_id)
    poll_interval_ms = MonitoringDefaults.default_probe_interval_ms(block_time_ms)

    %{
      subscribe_new_heads: has_ws,
      poll_interval_ms: poll_interval_ms,
      ws_active_poll_interval_ms: poll_interval_ms * @ws_active_poll_multiplier,
      staleness_threshold_ms: 35_000,
      max_backfill_blocks: nil,
      backfill_timeout_ms: nil
    }
  end

  @doc "Coalesces block-sync configuration across profile references."
  @spec coalesce_config([{term(), term()}], String.t(), pos_integer(), boolean()) :: map()
  def coalesce_config(ref_configs, instance_id, chain_id, has_ws) do
    poll_interval_ms =
      ref_configs
      |> Enum.map(fn {_, cc} -> cc.monitoring.probe_interval_ms end)
      |> Enum.min()

    staleness_threshold_ms =
      ref_configs
      |> Enum.map(fn {_, cc} -> cc.websocket.new_heads_timeout_ms end)
      |> Enum.max()

    subscribe_new_heads =
      Enum.any?(ref_configs, fn {ref, cc} ->
        resolve_subscribe_new_heads(cc, ref, chain_id, instance_id)
      end)

    max_backfill_blocks =
      ref_configs
      |> Enum.map(fn {_, cc} ->
        get_in(cc, [
          Access.key(:websocket),
          Access.key(:failover),
          Access.key(:max_backfill_blocks)
        ])
      end)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        values -> Enum.min(values)
      end

    backfill_timeout_ms =
      ref_configs
      |> Enum.map(fn {_, cc} ->
        get_in(cc, [
          Access.key(:websocket),
          Access.key(:failover),
          Access.key(:backfill_timeout_ms)
        ])
      end)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> nil
        values -> Enum.min(values)
      end

    %{
      subscribe_new_heads: subscribe_new_heads and has_ws,
      poll_interval_ms: poll_interval_ms,
      ws_active_poll_interval_ms: poll_interval_ms * @ws_active_poll_multiplier,
      staleness_threshold_ms: staleness_threshold_ms,
      max_backfill_blocks: max_backfill_blocks,
      backfill_timeout_ms: backfill_timeout_ms
    }
  end

  defp instance_block_time_ms(instance_id) do
    case Catalog.get_instance(instance_id) do
      {:ok, %{block_time_ms: bt}} when is_integer(bt) and bt > 0 -> bt
      _ -> nil
    end
  end

  defp compute_auth_scope(_refs), do: :system

  defp percentiles([] = _values) do
    default_ms = MonitoringDefaults.default_probe_interval_ms(nil)
    {default_ms, default_ms}
  end

  defp percentiles(values) do
    sorted = Enum.sort(values)
    n = length(sorted)

    p50 = Enum.at(sorted, div(n - 1, 2))
    p99 = Enum.at(sorted, round((n - 1) * 0.99))

    {p50, p99}
  end

  defp instance_has_ws?(instance_id) do
    case Catalog.get_instance(instance_id) do
      {:ok, inst} -> is_binary(Map.get(inst, :ws_url))
      _ -> false
    end
  end

  defp resolve_subscribe_new_heads(chain_config, profile, chain_id, instance_id) do
    provider_id = Catalog.reverse_lookup_provider_id(profile, chain_id, instance_id)

    if provider_id do
      case ChainConfig.get_provider_by_id(chain_config, provider_id) do
        {:ok, provider} -> ChainConfig.should_subscribe_new_heads?(chain_config, provider)
        {:error, _} -> chain_config.websocket.subscribe_new_heads
      end
    else
      chain_config.websocket.subscribe_new_heads
    end
  end

  defp apply_config_reload(state, new_config) do
    old_config = state.config
    old_subscribe = old_config.subscribe_new_heads
    new_subscribe = new_config.subscribe_new_heads

    state = %{state | config: new_config}

    state =
      cond do
        old_subscribe and not new_subscribe ->
          Logger.info("Config reload: subscribe_new_heads disabled, tearing down WS subscription",
            chain_id: state.chain_id,
            instance_id: state.instance_id
          )

          state = teardown_ws_subscription(state)
          restore_http_polling(state)

        not old_subscribe and new_subscribe ->
          Logger.info("Config reload: subscribe_new_heads enabled, establishing WS subscription",
            chain_id: state.chain_id,
            instance_id: state.instance_id
          )

          add_ws_subscription(state)

        true ->
          state
      end

    if state.http_strategy && old_config.poll_interval_ms != new_config.poll_interval_ms do
      new_interval =
        if state.http_reduced,
          do: new_config.ws_active_poll_interval_ms,
          else: new_config.poll_interval_ms

      %{state | http_strategy: HttpStrategy.set_poll_interval(state.http_strategy, new_interval)}
    else
      state
    end
  end

  defp teardown_ws_subscription(%{ws_strategy: nil} = state), do: state

  defp teardown_ws_subscription(state) do
    WsStrategy.stop(state.ws_strategy)
    %{state | ws_strategy: nil, mode: :http_only, ws_retry_count: 0}
  end

  defp start_strategies(state) do
    state = start_http_polling(state)

    if state.config.subscribe_new_heads do
      add_ws_subscription(state)
    else
      state
    end
  end

  defp start_http_polling(state) do
    http_opts = [
      instance_id: state.instance_id,
      parent: self(),
      poll_interval_ms: state.config.poll_interval_ms
    ]

    {:ok, http_state} = HttpStrategy.start(state.chain_id, state.instance_id, http_opts)

    Logger.debug("HTTP polling started",
      chain_id: state.chain_id,
      instance_id: state.instance_id,
      poll_interval_ms: state.config.poll_interval_ms
    )

    %{state | mode: :http_only, http_strategy: http_state}
  end

  defp add_ws_subscription(state) do
    ws_opts = [
      instance_id: state.instance_id,
      parent: self(),
      staleness_threshold_ms: state.config.staleness_threshold_ms
    ]

    case WsStrategy.start(state.chain_id, state.instance_id, ws_opts) do
      {:ok, ws_state} ->
        %{state | mode: :http_with_ws, ws_strategy: ws_state, ws_retry_count: 0}

      {:error, :connection_unknown} ->
        Logger.debug("WS connection state unknown, will retry shortly",
          chain_id: state.chain_id,
          instance_id: state.instance_id
        )

        Process.send_after(self(), :attempt_ws_reconnect, 1_000)
        state

      {:error, reason} ->
        level = if state.ws_retry_count > 0, do: :debug, else: :warning

        Logger.log(level, "WS subscription failed to start, HTTP polling continues",
          chain_id: state.chain_id,
          instance_id: state.instance_id,
          reason: inspect(reason)
        )

        schedule_ws_reconnect(state.ws_retry_count)
        %{state | ws_retry_count: state.ws_retry_count + 1}
    end
  end

  defp handle_strategy_status(state, :ws, :active) do
    state = maybe_clear_restart_count(state)
    state = %{state | mode: :http_with_ws, ws_retry_count: 0}

    reduce_http_polling(state)
  end

  defp handle_strategy_status(state, :ws, :failed) do
    Logger.debug("WS subscription failed, HTTP polling continues",
      chain_id: state.chain_id,
      instance_id: state.instance_id
    )

    restore_http_polling(state)
  end

  defp handle_strategy_status(state, :ws, status) when status in [:stale, :degraded] do
    Logger.info("WS subscription #{status}, restoring normal HTTP polling",
      chain_id: state.chain_id,
      instance_id: state.instance_id
    )

    restore_http_polling(state)
  end

  defp handle_strategy_status(state, :http, :degraded) do
    Logger.warning("HTTP polling degraded",
      chain_id: state.chain_id,
      instance_id: state.instance_id
    )

    state
  end

  defp handle_strategy_status(state, :http, :healthy) do
    Logger.debug("HTTP polling recovered",
      chain_id: state.chain_id,
      instance_id: state.instance_id
    )

    maybe_clear_restart_count(state)
  end

  defp handle_strategy_status(state, _transport, _status) do
    state
  end

  defp reduce_http_polling(%{http_strategy: nil} = state), do: state
  defp reduce_http_polling(%{http_reduced: true} = state), do: state

  defp reduce_http_polling(state) do
    reduced_interval = state.config.ws_active_poll_interval_ms
    new_http = HttpStrategy.set_poll_interval(state.http_strategy, reduced_interval)

    Logger.debug("HTTP polling reduced (WS active)",
      chain_id: state.chain_id,
      instance_id: state.instance_id,
      poll_interval_ms: reduced_interval
    )

    %{state | http_strategy: new_http, http_reduced: true}
  end

  defp restore_http_polling(%{http_strategy: nil} = state), do: state
  defp restore_http_polling(%{http_reduced: false} = state), do: state

  defp restore_http_polling(state) do
    normal_interval = state.config.poll_interval_ms
    new_http = HttpStrategy.set_poll_interval(state.http_strategy, normal_interval)

    Logger.debug("HTTP polling restored to normal",
      chain_id: state.chain_id,
      instance_id: state.instance_id,
      poll_interval_ms: normal_interval
    )

    %{state | http_strategy: new_http, http_reduced: false}
  end

  defp handle_ws_reconnected(%{mode: nil} = state), do: state

  defp handle_ws_reconnected(state) do
    if state.config.subscribe_new_heads do
      case state.ws_strategy do
        nil ->
          add_ws_subscription(state)

        ws_state ->
          case WsStrategy.resubscribe(ws_state) do
            {:ok, new_ws_state} ->
              %{state | mode: :http_with_ws, ws_strategy: new_ws_state, ws_retry_count: 0}

            {:error, _} ->
              schedule_ws_reconnect(state.ws_retry_count)
              %{state | ws_retry_count: state.ws_retry_count + 1}
          end
      end
    else
      state
    end
  end

  defp handle_ws_disconnected(%{mode: nil} = state), do: state

  defp handle_ws_disconnected(state) do
    if state.ws_strategy do
      Logger.info("WS subscription disconnected, HTTP polling continues",
        chain_id: state.chain_id,
        instance_id: state.instance_id
      )

      schedule_ws_reconnect(state.ws_retry_count)
    end

    restore_http_polling(state)
  end

  defp handle_manager_restarted(state) do
    if state.ws_strategy && state.mode == :http_with_ws do
      case WsStrategy.resubscribe(state.ws_strategy) do
        {:ok, new_ws_state} ->
          %{state | ws_strategy: new_ws_state}

        {:error, _} ->
          schedule_ws_reconnect(state.ws_retry_count)
          %{state | ws_retry_count: state.ws_retry_count + 1}
      end
    else
      state
    end
  end

  defp attempt_ws_reconnect(state) do
    if state.config.subscribe_new_heads and state.ws_strategy == nil do
      ws_opts = [
        instance_id: state.instance_id,
        parent: self(),
        staleness_threshold_ms: state.config.staleness_threshold_ms
      ]

      case WsStrategy.start(state.chain_id, state.instance_id, ws_opts) do
        {:ok, ws_state} ->
          Logger.info("WS subscription reconnected",
            chain_id: state.chain_id,
            instance_id: state.instance_id
          )

          %{state | mode: :http_with_ws, ws_strategy: ws_state, ws_retry_count: 0}

        {:error, reason} ->
          Logger.debug("WS subscription reconnect failed, will retry",
            chain_id: state.chain_id,
            instance_id: state.instance_id,
            reason: inspect(reason),
            retry_count: state.ws_retry_count + 1
          )

          schedule_ws_reconnect(state.ws_retry_count)
          %{state | ws_retry_count: state.ws_retry_count + 1}
      end
    else
      state
    end
  end

  defp schedule_ws_reconnect(retry_count) do
    exponent = min(retry_count, 4)
    delay = min(@reconnect_delay_ms * Bitwise.bsl(1, exponent), 60_000)
    Process.send_after(self(), :attempt_ws_reconnect, delay)
  end
end

defmodule LassoWeb.Dashboard.EventStream do
  @moduledoc """
  Real-time event aggregation and broadcast for dashboard LiveViews.

  Consolidates all dashboard-relevant PubSub subscriptions into a single GenServer per
  profile, eliminating O(chains × dashboards) subscription explosion in favor of O(chains)
  subscriptions per profile with direct process messaging to subscribers.

  ## PubSub Topics Subscribed (per profile)

  Per-chain topics:
  - `circuit:events:{profile}:{chain}` - circuit breaker state changes
  - `block_sync:{profile}:{chain}` - block height updates from probes
  - `provider:events:{profile}:{chain}` - provider health events

  Profile-scoped global topics:
  - `cluster:topology` - cluster membership changes
  - `routing_decision:{profile}` - RPC routing decisions
  - `sync:updates:{profile}` - sync status updates
  - `block_cache:updates:{profile}` - block cache updates

  ## Usage

      {:ok, _pid} = EventStream.ensure_started("default")
      EventStream.subscribe("default")

  ## Messages Sent to Subscribers

  On subscribe (initial state):
  - `{:dashboard_snapshot, %{metrics, circuits, health_counters, cluster, events}}`

  Batched updates (coalesced per 175ms tick):
  - `{:dashboard_batch, %{health, circuit_states, block_states, cluster, metrics, node_ids,
     heartbeat, routing_events, circuit_events, provider_events, subscription_events,
     block_events, sync_updates, block_cache_updates}}`

  All event types are buffered and flushed as a single structured batch per tick.
  Latest-wins coalescing applies to health, circuit_states, block_states, cluster, and metrics.
  List events are accumulated in order. Account filtering applies to routing_events only.
  """

  use GenServer, restart: :transient
  require Logger

  alias Lasso.Cluster.Topology
  alias Lasso.Config.ConfigStore
  alias Lasso.Events.{Provider, RoutingDecision, Subscription}

  @batch_interval_ms 175
  @max_batch_size 100
  @window_duration_ms 60_000
  @max_events_per_key 200
  @cleanup_interval_ms 30_000
  @seen_ids_cleanup_interval_ms 5_000
  @stale_block_height_ms 300_000
  @max_circuit_entries 500
  @max_block_height_entries 500
  @seen_request_id_ttl_ms 120_000
  @max_seen_request_ids 50_000
  @heartbeat_interval_ms 2_000
  @idle_timeout_ms 30_000

  defstruct [
    :profile,
    # Event processing
    event_windows: %{},
    pending_events: [],
    pending_count: 0,
    # Pre-computed metrics
    provider_metrics: %{},
    chain_totals: %{},
    # Circuit and block state
    circuit_states: %{},
    block_heights: %{},
    consensus_heights: %{},
    # Health counters per {provider_id, region}
    health_counters: %{},
    # Cluster state (from Topology)
    cluster_state: %{
      connected: 1,
      responding: 1,
      node_ids: [],
      last_update: 0
    },
    # Subscriber management
    subscribers: MapSet.new(),
    # Account filtering: pid -> account_id (nil = no filter, sees all events)
    subscriber_accounts: %{},
    # Timing
    last_tick: 0,
    last_cleanup: 0,
    last_heartbeat: 0,
    last_seen_ids_cleanup: 0,
    # Deduplication
    seen_request_ids: %{},
    # Tick scheduling - only tick when subscribers exist
    tick_scheduled: false,
    # Idle termination - timer ref for delayed shutdown when no subscribers
    idle_timer_ref: nil,
    # Coalesced pending buffers — flushed as a single batch per tick
    # Latest-wins maps (keyed by identity, only most recent value kept)
    pending_health: %{},
    pending_circuit_states: %{},
    pending_block_states: %{},
    pending_cluster: nil,
    pending_metrics: nil,
    # Accumulated lists
    pending_routing_events: [],
    pending_circuit_events: [],
    pending_provider_events: [],
    pending_subscription_events: [],
    pending_block_events: [],
    pending_node_ids: [],
    pending_sync_updates: [],
    pending_block_cache_updates: [],
    # Flags
    pending_heartbeat: false
  ]

  # Client API

  def start_link(profile) do
    GenServer.start_link(__MODULE__, profile, name: via(profile))
  end

  def child_spec(profile) do
    %{
      id: {__MODULE__, profile},
      start: {__MODULE__, :start_link, [profile]},
      restart: :transient
    }
  end

  defp via(profile) do
    {:via, Registry, {Lasso.Dashboard.StreamRegistry, {:stream, profile}}}
  end

  @doc """
  Ensures an EventStream is running for the given profile.
  """
  def ensure_started(profile) do
    case Registry.lookup(Lasso.Dashboard.StreamRegistry, {:stream, profile}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Lasso.Dashboard.StreamSupervisor,
               {__MODULE__, profile}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  @doc """
  Subscribe the calling process to receive updates.

  ## Options
  - `account_id` - Filter routing events to only show this account's traffic.
    Events with nil account_id are visible to all. Subscribers with nil
    account_id see all events (no filtering).
  """
  def subscribe(profile, account_id \\ nil) do
    case ensure_started(profile) do
      {:ok, pid} ->
        GenServer.cast(pid, {:subscribe, self(), account_id})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Unsubscribe the calling process.
  """
  def unsubscribe(profile) do
    case Registry.lookup(Lasso.Dashboard.StreamRegistry, {:stream, profile}) do
      [{pid, _}] -> GenServer.cast(pid, {:unsubscribe, self()})
      [] -> :ok
    end
  end

  @doc """
  Get current metrics for a specific provider.
  """
  def get_provider_metrics(profile, provider_id) do
    case Registry.lookup(Lasso.Dashboard.StreamRegistry, {:stream, profile}) do
      [{pid, _}] -> GenServer.call(pid, {:get_provider_metrics, provider_id})
      [] -> {:error, :not_running}
    end
  end

  @doc """
  Get all provider metrics.
  """
  def get_all_provider_metrics(profile) do
    case Registry.lookup(Lasso.Dashboard.StreamRegistry, {:stream, profile}) do
      [{pid, _}] -> GenServer.call(pid, :get_all_provider_metrics)
      [] -> {:error, :not_running}
    end
  end

  # Server Implementation

  @impl true
  def init(profile) do
    Logger.info("[EventStream] Starting for profile: #{profile}")

    # Subscribe to topology events (NOT net_kernel directly)
    Phoenix.PubSub.subscribe(Lasso.PubSub, "cluster:topology")

    # Subscribe to routing decisions for this profile
    Phoenix.PubSub.subscribe(Lasso.PubSub, RoutingDecision.topic(profile))

    # Subscribe to circuit and block events for each chain
    chains = ConfigStore.list_chains_for_profile(profile)

    for chain <- chains do
      Phoenix.PubSub.subscribe(Lasso.PubSub, "circuit:events:#{profile}:#{chain}")
      Phoenix.PubSub.subscribe(Lasso.PubSub, "block_sync:#{profile}:#{chain}")
      # Provider health events (Healthy, Unhealthy, WSConnected, etc.)
      Phoenix.PubSub.subscribe(Lasso.PubSub, Provider.topic(profile, chain))
      # Subscription lifecycle events (Established, Failed, Failover, Stale)
      Phoenix.PubSub.subscribe(Lasso.PubSub, Subscription.topic(profile, chain))
    end

    # Profile-scoped global topics
    Phoenix.PubSub.subscribe(Lasso.PubSub, "sync:updates:#{profile}")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "block_cache:updates:#{profile}")

    # Don't start tick timer until subscribers join (lazy ticking)
    now = now()

    {:ok,
     %__MODULE__{
       profile: profile,
       cluster_state: default_cluster_state(),
       last_tick: now,
       last_heartbeat: now - @heartbeat_interval_ms,
       tick_scheduled: false
     }, {:continue, :fetch_cluster_state}}
  end

  @impl true
  def handle_continue(:fetch_cluster_state, state) do
    cluster_state = fetch_cluster_state()
    {:noreply, %{state | cluster_state: cluster_state}}
  end

  # Tick handler — process routing batch, then flush all pending as one message per subscriber
  @impl true
  def handle_info(:tick, state) do
    now = now()
    state = %{state | tick_scheduled: false}

    state =
      state
      |> maybe_process_batch()
      |> maybe_cleanup(now)
      |> maybe_cleanup_seen_request_ids(now)
      |> maybe_set_heartbeat(now)
      |> flush_pending()

    state = schedule_tick(state)
    {:noreply, %{state | last_tick: now}}
  end

  # Routing decisions - batch for efficiency with O(1) dedup check
  @impl true
  def handle_info(%RoutingDecision{} = event, state) do
    # Check dedup first
    if Map.has_key?(state.seen_request_ids, event.request_id) do
      {:noreply, state}
    else
      now = now()

      seen =
        if map_size(state.seen_request_ids) >= @max_seen_request_ids * 1.5 do
          cleanup_seen_request_ids(state.seen_request_ids, now)
        else
          state.seen_request_ids
        end
        |> Map.put(event.request_id, now)

      pending = [event | state.pending_events]
      count = state.pending_count + 1

      # Process immediately if batch is full
      if count >= @max_batch_size do
        state =
          %{state | pending_events: pending, pending_count: count, seen_request_ids: seen}
          |> process_batch()

        {:noreply, state}
      else
        {:noreply,
         %{state | pending_events: pending, pending_count: count, seen_request_ids: seen}}
      end
    end
  end

  # Circuit breaker events - buffer state + raw event for next batch flush
  def handle_info({:circuit_breaker_event, event_data}, state) do
    state = update_circuit_state(state, event_data)
    state = queue_circuit_update(state, event_data)
    state = %{state | pending_circuit_events: [event_data | state.pending_circuit_events]}
    {:noreply, state}
  end

  # Block height updates - buffer when height changes for next batch flush
  def handle_info(
        {:block_height_update, {profile, provider_id}, height, source, timestamp},
        state
      ) do
    node_id = get_node_id_for_source(source, state)

    chain =
      find_chain_for_provider(state, provider_id) ||
        find_chain_from_config(profile, provider_id)

    if chain do
      case update_block_height(state, provider_id, chain, node_id, height, source, timestamp) do
        {:unchanged, state} ->
          {:noreply, state}

        {:changed, state} ->
          state = queue_block_update(state, provider_id, node_id, height, chain)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:provider_health_pulse, %{provider_id: pid, node_id: node_id} = data}, state) do
    key = {pid, node_id}

    health_data = %{
      consecutive_failures: data.consecutive_failures,
      consecutive_successes: data.consecutive_successes,
      ts: data.ts
    }

    current = Map.get(state.health_counters, key)

    if current &&
         current.consecutive_failures == health_data.consecutive_failures &&
         current.consecutive_successes == health_data.consecutive_successes do
      {:noreply, state}
    else
      health_counters = Map.put(state.health_counters, key, health_data)
      pending_health = Map.put(state.pending_health, key, health_data)
      {:noreply, %{state | health_counters: health_counters, pending_health: pending_health}}
    end
  end

  # Topology events - health update
  def handle_info(
        {:topology_event, %{event: :health_update, coverage: coverage, node_ids: node_ids}},
        state
      ) do
    cluster_state = %{
      connected: coverage.connected,
      responding: coverage.responding,
      node_ids: node_ids,
      last_update: now()
    }

    {:noreply, %{state | cluster_state: cluster_state, pending_cluster: cluster_state}}
  end

  # Topology events - node connected/disconnected (coverage and node_ids included)
  def handle_info(
        {:topology_event, %{event: event, coverage: coverage, node_ids: node_ids}},
        state
      )
      when event in [:node_connected, :node_disconnected] do
    cluster_state = %{
      connected: coverage.connected,
      responding: coverage.responding,
      node_ids: node_ids,
      last_update: now()
    }

    {:noreply, %{state | cluster_state: cluster_state, pending_cluster: cluster_state}}
  end

  # Topology events - node ID discovered
  def handle_info(
        {:topology_event,
         %{event: :node_id_discovered, node_info: node_info, node_ids: node_ids}},
        state
      ) do
    cluster_state = %{state.cluster_state | node_ids: node_ids}
    pending_node_ids = [node_info.node_id | state.pending_node_ids]

    {:noreply,
     %{
       state
       | cluster_state: cluster_state,
         pending_cluster: cluster_state,
         pending_node_ids: pending_node_ids
     }}
  end

  # Ignore other topology events
  def handle_info({:topology_event, _}, state) do
    {:noreply, state}
  end

  # Provider health events - buffer for next batch flush
  def handle_info(evt, state)
      when is_struct(evt, Lasso.Events.Provider.Healthy) or
             is_struct(evt, Lasso.Events.Provider.Unhealthy) or
             is_struct(evt, Lasso.Events.Provider.HealthCheckFailed) or
             is_struct(evt, Lasso.Events.Provider.WSConnected) or
             is_struct(evt, Lasso.Events.Provider.WSClosed) or
             is_struct(evt, Lasso.Events.Provider.WSDisconnected) do
    {:noreply, %{state | pending_provider_events: [evt | state.pending_provider_events]}}
  end

  # Subscription lifecycle events - buffer for next batch flush
  def handle_info(evt, state)
      when is_struct(evt, Subscription.Established) or
             is_struct(evt, Subscription.Failed) or
             is_struct(evt, Subscription.Failover) or
             is_struct(evt, Subscription.Stale) do
    {:noreply, %{state | pending_subscription_events: [evt | state.pending_subscription_events]}}
  end

  # Sync updates - buffer for next batch flush
  def handle_info(%{chain: _, provider_id: _, block_height: _} = evt, state) do
    {:noreply, %{state | pending_sync_updates: [evt | state.pending_sync_updates]}}
  end

  # Block cache updates - buffer for next batch flush
  def handle_info(%{type: :block_update, provider_id: _} = evt, state) do
    {:noreply, %{state | pending_block_cache_updates: [evt | state.pending_block_cache_updates]}}
  end

  # Subscriber died
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    new_accounts = Map.delete(state.subscriber_accounts, pid)

    state = %{state | subscribers: new_subscribers, subscriber_accounts: new_accounts}

    state =
      if MapSet.size(new_subscribers) == 0 do
        schedule_idle_termination(state)
      else
        state
      end

    {:noreply, state}
  end

  # Idle termination check - terminate if still no subscribers
  def handle_info(:check_idle_termination, state) do
    if MapSet.size(state.subscribers) == 0 do
      Logger.info("[EventStream] No subscribers for #{state.profile}, terminating")
      {:stop, :normal, state}
    else
      {:noreply, %{state | idle_timer_ref: nil}}
    end
  end

  # Ignore unknown messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Subscribe a process with optional account filtering
  @impl true
  def handle_cast({:subscribe, pid, account_id}, state) do
    Process.monitor(pid)

    state = cancel_idle_termination(state)

    was_empty = MapSet.size(state.subscribers) == 0
    subscribers = MapSet.put(state.subscribers, pid)
    subscriber_accounts = Map.put(state.subscriber_accounts, pid, account_id)

    recent_events =
      state.event_windows
      |> get_recent_events(100)
      |> Enum.filter(fn event ->
        filter_event_for_account(event, account_id)
      end)
      |> Enum.map(&struct_to_map/1)

    snapshot = %{
      metrics: state.provider_metrics,
      circuits: state.circuit_states,
      health_counters: state.health_counters,
      cluster: state.cluster_state,
      events: recent_events
    }

    send(pid, {:dashboard_snapshot, snapshot})

    state = %{state | subscribers: subscribers, subscriber_accounts: subscriber_accounts}

    state = if was_empty, do: schedule_tick(state), else: state

    {:noreply, state}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    new_accounts = Map.delete(state.subscriber_accounts, pid)

    state = %{state | subscribers: new_subscribers, subscriber_accounts: new_accounts}

    state =
      if MapSet.size(new_subscribers) == 0 do
        schedule_idle_termination(state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_call({:get_provider_metrics, provider_id}, _from, state) do
    metrics = Map.get(state.provider_metrics, provider_id, default_provider_metrics())
    {:reply, {:ok, metrics}, state}
  end

  def handle_call(:get_all_provider_metrics, _from, state) do
    {:reply, {:ok, state.provider_metrics}, state}
  end

  # Private helpers

  defp schedule_tick(state) do
    if MapSet.size(state.subscribers) > 0 and not state.tick_scheduled do
      Process.send_after(self(), :tick, @batch_interval_ms)
      %{state | tick_scheduled: true}
    else
      state
    end
  end

  defp schedule_idle_termination(state) do
    # Cancel any existing timer first
    state = cancel_idle_termination(state)
    ref = Process.send_after(self(), :check_idle_termination, @idle_timeout_ms)
    %{state | idle_timer_ref: ref}
  end

  defp cancel_idle_termination(%{idle_timer_ref: nil} = state), do: state

  defp cancel_idle_termination(%{idle_timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | idle_timer_ref: nil}
  end

  defp maybe_process_batch(state) do
    if state.pending_count > 0 do
      process_batch(state)
    else
      state
    end
  end

  defp process_batch(state) do
    events = Enum.reverse(state.pending_events)

    state =
      events
      |> Enum.reduce(state, &add_event_to_window/2)
      |> recompute_all_metrics()

    state = queue_metrics_update(state)
    state = queue_routing_events(state, events)

    %{state | pending_events: [], pending_count: 0}
  end

  defp add_event_to_window(event, state) do
    key = {event.provider_id, event.chain, event.source_node_id}
    window = Map.get(state.event_windows, key, [])
    new_window = [event | window] |> Enum.take(@max_events_per_key)
    %{state | event_windows: Map.put(state.event_windows, key, new_window)}
  end

  defp maybe_cleanup(state, now) do
    if now - state.last_cleanup >= @cleanup_interval_ms do
      cleanup_stale_data(%{state | last_cleanup: now})
    else
      state
    end
  end

  defp maybe_set_heartbeat(state, now) do
    if now - state.last_heartbeat >= @heartbeat_interval_ms do
      %{state | last_heartbeat: now, pending_heartbeat: true}
    else
      state
    end
  end

  defp maybe_cleanup_seen_request_ids(state, now) do
    if now - state.last_seen_ids_cleanup >= @seen_ids_cleanup_interval_ms do
      cleanup_seen_request_ids(%{state | last_seen_ids_cleanup: now}, now)
    else
      state
    end
  end

  defp cleanup_seen_request_ids(state, now) do
    cutoff = now - @seen_request_id_ttl_ms

    seen =
      state.seen_request_ids
      |> Enum.reject(fn {_id, ts} -> ts < cutoff end)
      |> Map.new()

    seen = maybe_truncate_seen_ids(seen, now)

    %{state | seen_request_ids: seen}
  end

  defp maybe_truncate_seen_ids(seen, _now) when map_size(seen) <= @max_seen_request_ids, do: seen

  defp maybe_truncate_seen_ids(seen, _now) do
    seen
    |> Enum.sort_by(fn {_id, ts} -> ts end, :desc)
    |> Enum.take(@max_seen_request_ids)
    |> Map.new()
  end

  defp cleanup_stale_data(state) do
    now = System.system_time(:millisecond)
    cutoff = now - @window_duration_ms
    stale_cutoff = now - @stale_block_height_ms

    new_windows =
      state.event_windows
      |> Enum.map(fn {key, events} ->
        {key, Enum.filter(events, &(&1.ts > cutoff))}
      end)
      |> Enum.reject(fn {_, events} -> events == [] end)
      |> Map.new()

    new_heights =
      state.block_heights
      |> Enum.reject(fn {_, %{timestamp: ts}} -> ts < stale_cutoff end)
      |> Map.new()
      |> truncate_by_recency(@max_block_height_entries, & &1.timestamp)

    new_circuit_states =
      state.circuit_states
      |> Enum.reject(fn {_, %{updated_at: ts}} -> ts < stale_cutoff end)
      |> Map.new()
      |> truncate_by_recency(@max_circuit_entries, & &1.updated_at)

    active_provider_regions =
      new_windows
      |> Map.keys()
      |> Enum.map(fn {provider_id, _chain, region} -> {provider_id, region} end)
      |> MapSet.new()

    new_health_counters =
      state.health_counters
      |> Enum.filter(fn {key, _} -> MapSet.member?(active_provider_regions, key) end)
      |> Map.new()

    %{
      state
      | event_windows: new_windows,
        block_heights: new_heights,
        circuit_states: new_circuit_states,
        health_counters: new_health_counters
    }
    |> recompute_all_metrics()
  end

  defp truncate_by_recency(map, max, _ts_fn) when map_size(map) <= max, do: map

  defp truncate_by_recency(map, max, ts_fn) do
    map
    |> Enum.sort_by(fn {_, v} -> ts_fn.(v) end, :desc)
    |> Enum.take(max)
    |> Map.new()
  end

  defp recompute_all_metrics(state) do
    now = System.system_time(:millisecond)
    cutoff = now - @window_duration_ms

    fresh_windows =
      state.event_windows
      |> Enum.map(fn {key, events} ->
        fresh = Enum.filter(events, &(&1.ts > cutoff))
        {key, fresh}
      end)
      |> Enum.reject(fn {_, events} -> events == [] end)
      |> Map.new()

    chain_totals = compute_chain_totals(fresh_windows)

    events_by_provider =
      fresh_windows
      |> Enum.group_by(fn {{provider_id, _chain, _region}, _events} -> provider_id end)
      |> Enum.map(fn {provider_id, entries} ->
        {provider_id, Enum.flat_map(entries, fn {_key, events} -> events end)}
      end)
      |> Map.new()

    provider_metrics =
      events_by_provider
      |> Enum.map(fn {provider_id, events} ->
        metrics =
          compute_provider_metrics(provider_id, events, fresh_windows, chain_totals, state)

        {provider_id, metrics}
      end)
      |> Map.new()

    %{
      state
      | event_windows: fresh_windows,
        chain_totals: chain_totals,
        provider_metrics: provider_metrics
    }
  end

  defp compute_chain_totals(windows) do
    windows
    |> Enum.flat_map(fn {{_provider, chain, region}, events} ->
      Enum.map(events, fn _ -> {chain, region} end)
    end)
    |> Enum.frequencies()
  end

  defp compute_provider_metrics(provider_id, all_events, _windows, chain_totals, state) do
    chain = all_events |> List.first() |> then(&(&1 && &1.chain))

    events_by_region = Enum.group_by(all_events, & &1.source_node_id)

    by_region =
      events_by_region
      |> Enum.map(fn {region, events} ->
        region_chain_total = Map.get(chain_totals, {chain, region}, 0)

        metrics = %{
          total_calls: length(events),
          success_rate: compute_success_rate(events),
          error_count: Enum.count(events, &(&1.result == :error)),
          p50_latency: compute_percentile(events, 50),
          p95_latency: compute_percentile(events, 95),
          traffic_pct: compute_traffic_pct(length(events), region_chain_total),
          events_per_second: length(events) / (@window_duration_ms / 1000),
          block_height: get_block_height(state, provider_id, chain, region),
          block_lag: get_block_lag(state, provider_id, chain, region),
          circuit: get_circuit_state(state, provider_id, region),
          rpc_stats: compute_method_stats(events)
        }

        {region, metrics}
      end)
      |> Map.new()

    total_chain_calls =
      if chain do
        chain_totals
        |> Enum.filter(fn {{c, _r}, _count} -> c == chain end)
        |> Enum.map(fn {_key, count} -> count end)
        |> Enum.sum()
      else
        0
      end

    aggregate = %{
      total_calls: length(all_events),
      success_rate: compute_success_rate(all_events),
      error_count: Enum.count(all_events, &(&1.result == :error)),
      p50_latency: compute_percentile(all_events, 50),
      p95_latency: compute_percentile(all_events, 95),
      traffic_pct: compute_traffic_pct(length(all_events), total_chain_calls),
      events_per_second: length(all_events) / (@window_duration_ms / 1000),
      block_height: get_max_block_height(state, provider_id, chain),
      block_lag: get_worst_block_lag(state, provider_id, chain),
      regions_reporting: Map.keys(by_region),
      rpc_stats: compute_method_stats(all_events)
    }

    %{
      provider_id: provider_id,
      chain: chain,
      aggregate: aggregate,
      by_region: by_region,
      updated_at: System.system_time(:millisecond)
    }
  end

  defp compute_method_stats(events) do
    events
    |> Enum.group_by(& &1.method)
    |> Enum.map(fn {method, method_events} ->
      total = length(method_events)
      successes = Enum.count(method_events, &(&1.result == :success))
      durations = Enum.map(method_events, & &1.duration_ms)
      avg_duration = if total > 0, do: Enum.sum(durations) / total, else: 0.0

      %{
        method: method,
        total_calls: total,
        success_rate: if(total > 0, do: successes / total, else: 0.0),
        avg_duration_ms: avg_duration
      }
    end)
    |> Enum.sort_by(& &1.total_calls, :desc)
    |> Enum.take(10)
  end

  defp compute_success_rate([]), do: 0.0

  defp compute_success_rate(events) do
    successes = Enum.count(events, &(&1.result == :success))
    Float.round(successes / length(events) * 100, 1)
  end

  defp compute_traffic_pct(_provider_calls, 0), do: 0.0

  defp compute_traffic_pct(provider_calls, chain_calls) do
    Float.round(provider_calls / chain_calls * 100, 1)
  end

  defp compute_percentile([], _p), do: nil

  defp compute_percentile(events, p) do
    durations = events |> Enum.map(& &1.duration_ms) |> Enum.sort()
    index = max(0, round(length(durations) * p / 100) - 1)
    Enum.at(durations, index)
  end

  # Block height helpers

  defp find_chain_for_provider(state, provider_id) do
    state.event_windows
    |> Enum.find_value(fn {{pid, chain, _region}, _events} ->
      if pid == provider_id, do: chain, else: nil
    end)
  end

  defp find_chain_from_config(profile, provider_id) do
    case ConfigStore.get_profile_chains(profile) do
      {:ok, chains} ->
        Enum.find_value(chains, fn {chain_name, chain_config} ->
          providers = chain_config.providers || []

          if Enum.any?(providers, fn p -> p.id == provider_id end) do
            chain_name
          end
        end)

      _ ->
        nil
    end
  end

  defp update_block_height(state, provider_id, chain, region, height, source, timestamp) do
    key = {provider_id, chain, region}

    case Map.get(state.block_heights, key) do
      %{height: ^height} ->
        {:unchanged, state}

      _ ->
        block_heights =
          Map.put(state.block_heights, key, %{
            height: height,
            timestamp: timestamp,
            source: source
          })

        consensus = compute_consensus_height(block_heights, chain, region)
        consensus_key = {chain, region}
        consensus_heights = Map.put(state.consensus_heights, consensus_key, consensus)

        {:changed, %{state | block_heights: block_heights, consensus_heights: consensus_heights}}
    end
  end

  defp compute_consensus_height(block_heights, chain, region) do
    block_heights
    |> Enum.filter(fn {{_pid, c, r}, _} -> c == chain and r == region end)
    |> Enum.map(fn {_, %{height: h}} -> h end)
    |> Enum.max(fn -> nil end)
  end

  defp get_block_height(state, provider_id, chain, region) do
    case Map.get(state.block_heights, {provider_id, chain, region}) do
      %{height: h} -> h
      nil -> nil
    end
  end

  defp get_block_lag(state, provider_id, chain, region) do
    height = get_block_height(state, provider_id, chain, region)
    consensus = Map.get(state.consensus_heights, {chain, region})

    case {height, consensus} do
      {nil, _} -> nil
      {_, nil} -> nil
      {h, c} -> h - c
    end
  end

  defp get_max_block_height(state, provider_id, chain) do
    state.block_heights
    |> Enum.filter(fn {{pid, c, _r}, _} -> pid == provider_id and c == chain end)
    |> Enum.map(fn {_, %{height: h}} -> h end)
    |> Enum.max(fn -> nil end)
  end

  defp get_worst_block_lag(state, provider_id, chain) do
    state.block_heights
    |> Enum.filter(fn {{pid, c, _r}, _} -> pid == provider_id and c == chain end)
    |> Enum.map(fn {{_, _, region}, %{height: h}} ->
      consensus = Map.get(state.consensus_heights, {chain, region})
      if consensus, do: h - consensus, else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  # Circuit state helpers

  defp update_circuit_state(state, event_data) do
    %{provider_id: provider_id, transport: transport, to: to_state} = event_data

    node_id =
      Map.get(event_data, :source_node_id) ||
        state.cluster_state.node_ids |> List.first() ||
        get_self_node_id()

    key = {provider_id, node_id}
    current = Map.get(state.circuit_states, key, %{http: :closed, ws: :closed, updated_at: 0})

    updated =
      case transport do
        :http -> %{current | http: to_state, updated_at: System.system_time(:millisecond)}
        :ws -> %{current | ws: to_state, updated_at: System.system_time(:millisecond)}
        _ -> current
      end

    %{state | circuit_states: Map.put(state.circuit_states, key, updated)}
  end

  defp get_circuit_state(state, provider_id, node_id) do
    Map.get(state.circuit_states, {provider_id, node_id}, %{http: :closed, ws: :closed})
  end

  # Queue helpers — accumulate into pending buffers for batch flush

  defp queue_metrics_update(state) do
    if map_size(state.provider_metrics) > 0 do
      %{state | pending_metrics: state.provider_metrics}
    else
      state
    end
  end

  defp queue_routing_events(state, events) when events == [], do: state

  defp queue_routing_events(state, events) do
    map_events = Enum.map(events, &struct_to_map/1)
    %{state | pending_routing_events: Enum.reverse(map_events) ++ state.pending_routing_events}
  end

  defp struct_to_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp struct_to_map(map) when is_map(map), do: map

  defp queue_circuit_update(state, event_data) do
    %{provider_id: provider_id} = event_data

    node_id =
      Map.get(event_data, :source_node_id) ||
        state.cluster_state.node_ids |> List.first() ||
        get_self_node_id()

    key = {provider_id, node_id}
    circuit = get_circuit_state(state, provider_id, node_id)

    %{state | pending_circuit_states: Map.put(state.pending_circuit_states, key, circuit)}
  end

  defp queue_block_update(state, provider_id, node_id, height, chain) do
    key = {provider_id, node_id}
    lag = get_block_lag(state, provider_id, chain, node_id)

    block_data = %{provider_id: provider_id, node_id: node_id, height: height, lag: lag}

    block_event = %{
      chain: chain,
      block_number: height,
      provider_first: provider_id,
      margin_ms: nil
    }

    %{
      state
      | pending_block_states: Map.put(state.pending_block_states, key, block_data),
        pending_block_events: [block_event | state.pending_block_events]
    }
  end

  # Batch flush — send one {:dashboard_batch, batch} per subscriber per tick

  defp flush_pending(state) do
    batch = build_batch(state)

    if batch_empty?(batch) do
      reset_pending(state)
    else
      for pid <- state.subscribers do
        account_filter = Map.get(state.subscriber_accounts, pid)
        send(pid, {:dashboard_batch, filter_batch(batch, account_filter)})
      end

      reset_pending(state)
    end
  end

  defp build_batch(state) do
    %{
      health: state.pending_health,
      circuit_states: state.pending_circuit_states,
      block_states: state.pending_block_states,
      cluster: state.pending_cluster,
      metrics: state.pending_metrics,
      node_ids: Enum.reverse(state.pending_node_ids),
      heartbeat: state.pending_heartbeat,
      routing_events: Enum.reverse(state.pending_routing_events),
      circuit_events: Enum.reverse(state.pending_circuit_events),
      provider_events: Enum.reverse(state.pending_provider_events),
      subscription_events: Enum.reverse(state.pending_subscription_events),
      block_events: Enum.reverse(state.pending_block_events),
      sync_updates: Enum.reverse(state.pending_sync_updates),
      block_cache_updates: Enum.reverse(state.pending_block_cache_updates)
    }
  end

  defp batch_empty?(batch) do
    map_size(batch.health) == 0 and
      map_size(batch.circuit_states) == 0 and
      map_size(batch.block_states) == 0 and
      is_nil(batch.cluster) and
      is_nil(batch.metrics) and
      batch.node_ids == [] and
      batch.heartbeat == false and
      batch.routing_events == [] and
      batch.circuit_events == [] and
      batch.provider_events == [] and
      batch.subscription_events == [] and
      batch.block_events == [] and
      batch.sync_updates == [] and
      batch.block_cache_updates == []
  end

  defp filter_batch(batch, account_filter) do
    %{
      batch
      | routing_events:
          Enum.filter(batch.routing_events, &filter_event_for_account(&1, account_filter))
    }
  end

  defp reset_pending(state) do
    %{
      state
      | pending_health: %{},
        pending_circuit_states: %{},
        pending_block_states: %{},
        pending_cluster: nil,
        pending_metrics: nil,
        pending_routing_events: [],
        pending_circuit_events: [],
        pending_provider_events: [],
        pending_subscription_events: [],
        pending_block_events: [],
        pending_node_ids: [],
        pending_sync_updates: [],
        pending_block_cache_updates: [],
        pending_heartbeat: false
    }
  end

  defp get_recent_events(windows, limit) do
    windows
    |> Enum.flat_map(fn {_key, events} -> events end)
    |> Enum.sort_by(& &1.ts, :desc)
    |> Enum.take(limit)
  end

  defp default_provider_metrics do
    %{
      provider_id: nil,
      chain: nil,
      aggregate: %{
        total_calls: 0,
        success_rate: 0.0,
        error_count: 0,
        p50_latency: nil,
        p95_latency: nil,
        traffic_pct: 0.0,
        events_per_second: 0.0,
        block_height: nil,
        block_lag: nil,
        regions_reporting: [],
        rpc_stats: []
      },
      by_region: %{},
      updated_at: 0
    }
  end

  defp fetch_cluster_state do
    case Topology.get_coverage() do
      coverage when is_map(coverage) ->
        %{
          connected: coverage.connected,
          responding: coverage.responding,
          node_ids: Topology.get_node_ids(),
          last_update: now()
        }

      _ ->
        default_cluster_state()
    end
  catch
    :exit, _ -> default_cluster_state()
  end

  defp get_self_node_id do
    Topology.self_node_id()
  end

  defp get_node_id_for_source(source, _state) when is_atom(source) do
    case Topology.get_node_info(source) do
      %{node_id: node_id} when is_binary(node_id) -> node_id
      _ -> get_self_node_id()
    end
  end

  defp get_node_id_for_source(_source, _state), do: get_self_node_id()

  defp default_cluster_state do
    self_node_id = get_self_node_id()
    %{connected: 1, responding: 1, node_ids: [self_node_id], last_update: now()}
  catch
    :exit, _ -> %{connected: 1, responding: 1, node_ids: [], last_update: now()}
  end

  defp now do
    System.monotonic_time(:millisecond)
  end

  # Filter events by account_id for account-scoped dashboard visibility.
  # - subscriber_account_id nil = no filter, see all events
  # - event account_id nil = visible to all (infrastructure events)
  # - otherwise, must match
  defp filter_event_for_account(_event, nil), do: true

  defp filter_event_for_account(event, subscriber_account_id) do
    event_account_id = get_event_account_id(event)
    event_account_id == nil or event_account_id == subscriber_account_id
  end

  defp get_event_account_id(%{account_id: account_id}), do: account_id
  defp get_event_account_id(_), do: nil
end

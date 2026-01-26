defmodule LassoWeb.Dashboard.EventStream do
  @moduledoc """
  Real-time event aggregation and broadcast for dashboard LiveViews.

  Subscribes to routing decisions, circuit events, block sync events, and topology
  changes via PubSub. Pre-computes metrics and broadcasts batched updates to subscribers.

  ## Usage

      # Ensure stream is running for a profile
      {:ok, _pid} = EventStream.ensure_started("default")

      # Subscribe to receive updates (typically in LiveView mount)
      EventStream.subscribe("default")

      # Handle messages in LiveView:
      # {:metrics_snapshot, %{metrics: metrics}}
      # {:metrics_update, %{metrics: changed_metrics}}
      # {:events_batch, %{events: events}}
      # {:events_snapshot, %{events: recent_events}}
      # {:cluster_update, %{connected: n, responding: n, regions: [...]}}
      # {:circuit_update, %{provider_id: id, region: region, circuit: circuit_info}}
      # {:block_update, %{provider_id: id, region: region, height: h, lag: lag}}
      # {:region_added, %{region: region}}
  """

  use GenServer, restart: :transient
  require Logger

  alias Lasso.Cluster.Topology
  alias Lasso.Config.ConfigStore
  alias Lasso.Events.RoutingDecision

  @batch_interval_ms 50
  @max_batch_size 100
  @window_duration_ms 60_000
  @max_events_per_key 200
  @cleanup_interval_ms 30_000
  @stale_block_height_ms 300_000
  @seen_request_id_ttl_ms 120_000
  @max_seen_request_ids 50_000
  @heartbeat_interval_ms 2_000

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
      regions: [],
      last_update: 0
    },
    # Subscriber management
    subscribers: MapSet.new(),
    # Timing
    last_tick: 0,
    last_cleanup: 0,
    last_heartbeat: 0,
    # Deduplication
    seen_request_ids: %{}
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
        DynamicSupervisor.start_child(
          Lasso.Dashboard.StreamSupervisor,
          {__MODULE__, profile}
        )
    end
  end

  @doc """
  Subscribe the calling process to receive updates.
  """
  def subscribe(profile) do
    case ensure_started(profile) do
      {:ok, pid} -> GenServer.call(pid, {:subscribe, self()})
      {:error, reason} -> {:error, reason}
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
    end

    # Get initial cluster state from Topology
    cluster_state = fetch_cluster_state()

    # Start tick timer
    schedule_tick()

    now = now()

    {:ok,
     %__MODULE__{
       profile: profile,
       cluster_state: cluster_state,
       last_tick: now,
       last_heartbeat: now - @heartbeat_interval_ms
     }}
  end

  # Tick handler
  @impl true
  def handle_info(:tick, state) do
    now = now()

    state =
      state
      |> maybe_process_batch()
      |> maybe_cleanup(now)
      |> cleanup_seen_request_ids(now)
      |> maybe_send_heartbeat(now)

    schedule_tick()
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
      seen = Map.put(state.seen_request_ids, event.request_id, now)

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

  # Circuit breaker events - process immediately
  def handle_info({:circuit_breaker_event, event_data}, state) do
    state = update_circuit_state(state, event_data)
    broadcast_circuit_update(state, event_data)
    {:noreply, state}
  end

  # Block height updates - process immediately
  def handle_info(
        {:block_height_update, {profile, provider_id}, height, source, timestamp},
        state
      ) do
    region = get_region_for_source(source, state)

    chain =
      find_chain_for_provider(state, provider_id) ||
        find_chain_from_config(profile, provider_id)

    if chain do
      state = update_block_height(state, provider_id, chain, region, height, source, timestamp)
      broadcast_block_update(state, provider_id, region, height, chain)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:provider_health_pulse, %{provider_id: pid, region: region} = data}, state) do
    key = {pid, region}

    health_data = %{
      consecutive_failures: data.consecutive_failures,
      consecutive_successes: data.consecutive_successes,
      ts: data.ts
    }

    health_counters = Map.put(state.health_counters, key, health_data)

    broadcast_to_subscribers(
      state,
      {:health_pulse, %{provider_id: pid, region: region, counters: health_data}}
    )

    {:noreply, %{state | health_counters: health_counters}}
  end

  # Topology events - health update
  def handle_info({:topology_event, %{event: :health_update, coverage: coverage}}, state) do
    regions = fetch_regions()

    cluster_state = %{
      connected: coverage.connected,
      responding: coverage.responding,
      regions: regions,
      last_update: now()
    }

    broadcast_to_subscribers(state, {:cluster_update, cluster_state})
    {:noreply, %{state | cluster_state: cluster_state}}
  end

  # Topology events - node connected/disconnected (coverage included)
  def handle_info({:topology_event, %{event: event, coverage: coverage}}, state)
      when event in [:node_connected, :node_disconnected] do
    cluster_state = %{
      state.cluster_state
      | connected: coverage.connected,
        responding: coverage.responding,
        last_update: now()
    }

    broadcast_to_subscribers(state, {:cluster_update, cluster_state})
    {:noreply, %{state | cluster_state: cluster_state}}
  end

  # Topology events - region discovered
  def handle_info({:topology_event, %{event: :region_discovered, node_info: node_info}}, state) do
    regions = [node_info.region | state.cluster_state.regions] |> Enum.uniq()
    cluster_state = %{state.cluster_state | regions: regions}

    broadcast_to_subscribers(state, {:region_added, %{region: node_info.region}})
    {:noreply, %{state | cluster_state: cluster_state}}
  end

  # Ignore other topology events
  def handle_info({:topology_event, _}, state) do
    {:noreply, state}
  end

  # Subscriber died
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  # Ignore unknown messages
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Subscribe a process
  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    subscribers = MapSet.put(state.subscribers, pid)

    # Send current state immediately (map payloads)
    send(pid, {:metrics_snapshot, %{metrics: state.provider_metrics}})
    send(pid, {:circuits_snapshot, %{circuits: state.circuit_states}})
    send(pid, {:health_counters_snapshot, %{counters: state.health_counters}})
    send(pid, {:cluster_update, state.cluster_state})

    # Send recent events from windows (convert structs to maps for Access)
    recent_events =
      state.event_windows
      |> get_recent_events(100)
      |> Enum.map(&struct_to_map/1)

    send(pid, {:events_snapshot, %{events: recent_events}})

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:get_provider_metrics, provider_id}, _from, state) do
    metrics = Map.get(state.provider_metrics, provider_id, default_provider_metrics())
    {:reply, {:ok, metrics}, state}
  end

  def handle_call(:get_all_provider_metrics, _from, state) do
    {:reply, {:ok, state.provider_metrics}, state}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {:noreply, %{state | subscribers: MapSet.delete(state.subscribers, pid)}}
  end

  # Private helpers

  defp schedule_tick do
    Process.send_after(self(), :tick, @batch_interval_ms)
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

    broadcast_metrics_update(state)
    broadcast_events_batch(state, events)

    %{state | pending_events: [], pending_count: 0}
  end

  defp add_event_to_window(event, state) do
    key = {event.provider_id, event.chain, event.source_region}
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

  defp maybe_send_heartbeat(state, now) do
    if now - state.last_heartbeat >= @heartbeat_interval_ms do
      broadcast_to_subscribers(state, {:heartbeat, %{ts: now}})
      %{state | last_heartbeat: now}
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

    new_circuit_states =
      state.circuit_states
      |> Enum.reject(fn {_, %{updated_at: ts}} -> ts < stale_cutoff end)
      |> Map.new()

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

    events_by_region = Enum.group_by(all_events, & &1.source_region)

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

    block_heights =
      Map.put(state.block_heights, key, %{
        height: height,
        timestamp: timestamp,
        source: source
      })

    consensus = compute_consensus_height(block_heights, chain, region)
    consensus_key = {chain, region}
    consensus_heights = Map.put(state.consensus_heights, consensus_key, consensus)

    %{state | block_heights: block_heights, consensus_heights: consensus_heights}
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

    region =
      Map.get(event_data, :source_region) ||
        state.cluster_state.regions |> List.first() ||
        get_self_region()

    key = {provider_id, region}
    current = Map.get(state.circuit_states, key, %{http: :closed, ws: :closed, updated_at: 0})

    updated =
      case transport do
        :http -> %{current | http: to_state, updated_at: System.system_time(:millisecond)}
        :ws -> %{current | ws: to_state, updated_at: System.system_time(:millisecond)}
        _ -> current
      end

    %{state | circuit_states: Map.put(state.circuit_states, key, updated)}
  end

  defp get_circuit_state(state, provider_id, region) do
    Map.get(state.circuit_states, {provider_id, region}, %{http: :closed, ws: :closed})
  end

  # Broadcasting

  defp broadcast_metrics_update(state) do
    if map_size(state.provider_metrics) > 0 do
      broadcast_to_subscribers(state, {:metrics_update, %{metrics: state.provider_metrics}})
    end
  end

  defp broadcast_events_batch(state, events) do
    unless events == [] do
      # Convert structs to maps for consistent Access behaviour in consumers
      map_events = Enum.map(events, &struct_to_map/1)
      broadcast_to_subscribers(state, {:events_batch, %{events: map_events}})
    end
  end

  defp struct_to_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp struct_to_map(map) when is_map(map), do: map

  defp broadcast_circuit_update(state, event_data) do
    %{provider_id: provider_id} = event_data

    region =
      Map.get(event_data, :source_region) ||
        state.cluster_state.regions |> List.first() ||
        get_self_region()

    circuit = get_circuit_state(state, provider_id, region)

    broadcast_to_subscribers(
      state,
      {:circuit_update, %{provider_id: provider_id, region: region, circuit: circuit}}
    )
  end

  defp broadcast_block_update(state, provider_id, region, height, chain) do
    lag = get_block_lag(state, provider_id, chain, region)

    broadcast_to_subscribers(
      state,
      {:block_update, %{provider_id: provider_id, region: region, height: height, lag: lag}}
    )
  end

  defp broadcast_to_subscribers(state, message) do
    for pid <- state.subscribers do
      send(pid, message)
    end
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
          regions: Topology.get_regions(),
          last_update: now()
        }

      _ ->
        default_cluster_state()
    end
  catch
    :exit, _ -> default_cluster_state()
  end

  defp fetch_regions do
    Topology.get_regions()
  catch
    :exit, _ -> []
  end

  defp get_self_region do
    Topology.get_self_region()
  catch
    :exit, _ -> Application.get_env(:lasso, :cluster_region) || "unknown"
  end

  defp get_region_for_source(source, _state) when is_atom(source) do
    case Topology.get_node_info(source) do
      %{region: region} when is_binary(region) and region != "unknown" -> region
      _ -> get_self_region()
    end
  catch
    :exit, _ -> get_self_region()
  end

  defp get_region_for_source(_source, _state), do: get_self_region()

  defp default_cluster_state do
    %{connected: 1, responding: 1, regions: [], last_update: now()}
  end

  defp now do
    System.monotonic_time(:millisecond)
  end
end

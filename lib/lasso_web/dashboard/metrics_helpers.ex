defmodule LassoWeb.Dashboard.MetricsHelpers do
  @moduledoc """
  Performance metrics and statistics calculations for the Dashboard LiveView.
  """

  alias Lasso.Benchmarking.BenchmarkStore
  alias LassoWeb.Dashboard.{Helpers, Constants}
  alias LassoWeb.Dashboard.Metrics.Calculations

  @doc "Assign chain performance metrics to assigns"
  def assign_chain_performance_metrics(assigns, chain_name) do
    # Get chain-wide statistics
    chain_stats = BenchmarkStore.get_chain_wide_stats(chain_name)
    realtime_stats = BenchmarkStore.get_realtime_stats(chain_name)

    # Calculate aggregate performance metrics over 5 minutes
    now_ms = System.system_time(:millisecond)
    window_ms = Constants.metrics_window_5min()

    recent_events =
      Enum.filter(assigns.routing_events, fn e ->
        e[:chain] == chain_name and (e[:ts_ms] || 0) >= now_ms - window_ms
      end)

    latencies =
      recent_events
      |> Enum.map(&(&1[:duration_ms] || 0))
      |> Enum.filter(&(&1 > 0))

    {p50, p95} = Calculations.percentile_pair(latencies)

    success_rate = Calculations.success_rate(recent_events)

    failovers_5m = Enum.count(recent_events, fn e -> (e[:failovers] || 0) > 0 end)

    decision_share =
      recent_events
      |> Enum.group_by(& &1.provider_id)
      |> Enum.map(fn {pid, evs} -> {pid, 100.0 * length(evs) / max(length(recent_events), 1)} end)
      |> Enum.sort_by(fn {_pid, pct} -> -pct end)

    connected_providers =
      Enum.count(assigns.connections, &(&1.chain == chain_name && &1.status == :connected))

    total_providers = Enum.count(assigns.connections, &(&1.chain == chain_name))

    Map.put(assigns, :chain_performance, %{
      total_calls: Map.get(chain_stats, :total_calls, 0),
      success_rate: success_rate,
      p50_latency: p50,
      p95_latency: p95,
      failovers_5m: failovers_5m,
      connected_providers: connected_providers,
      total_providers: total_providers,
      recent_activity: length(recent_events),
      providers_list: Map.get(realtime_stats, :providers, []),
      rpc_methods: Map.get(realtime_stats, :rpc_methods, []),
      last_updated: Map.get(realtime_stats, :last_updated, 0),
      decision_share: decision_share
    })
  end

  @doc "Assign provider performance metrics to assigns"
  def assign_provider_performance_metrics(assigns, provider_id) do
    # Get the chain for this provider
    chain =
      case Enum.find(assigns.connections, &(&1.id == provider_id)) do
        %{chain: chain_name} -> chain_name
        _ -> nil
      end

    metrics =
      if chain do
        calculate_provider_metrics(chain, provider_id, assigns.routing_events)
      else
        empty_provider_metrics()
      end

    Map.put(assigns, :performance_metrics, metrics)
  end

  @doc "Get provider performance metrics (non-socket version)"
  def get_provider_performance_metrics(provider_id, connections \\ [], routing_events \\ []) do
    # Get the chain for this provider
    chain =
      case Enum.find(connections, &(&1.id == provider_id)) do
        %{chain: chain_name} -> chain_name
        _ -> nil
      end

    if chain do
      calculate_provider_metrics(chain, provider_id, routing_events)
    else
      empty_provider_metrics()
    end
  end

  # Private: Calculate provider metrics (shared logic)
  defp calculate_provider_metrics(chain, provider_id, routing_events) do
    provider_score = BenchmarkStore.get_provider_score(chain, provider_id)
    real_time_stats = BenchmarkStore.get_real_time_stats(chain, provider_id)
    anomalies = BenchmarkStore.detect_performance_anomalies(chain, provider_id)

    now_ms = System.system_time(:millisecond)
    five_min_ms = Constants.metrics_window_5min()
    hour_ms = Constants.metrics_window_1hour()

    events_5m =
      Enum.filter(routing_events, fn e ->
        e[:provider_id] == provider_id and (e[:ts_ms] || 0) >= now_ms - five_min_ms
      end)

    latencies_5m =
      events_5m
      |> Enum.map(&(&1[:duration_ms] || 0))
      |> Enum.filter(&(&1 > 0))

    {p50, p95} = Calculations.percentile_pair(latencies_5m)
    success_rate = Calculations.success_rate(events_5m)

    calls_last_minute = Map.get(real_time_stats, :calls_last_minute, 0)

    calls_last_hour =
      routing_events
      |> Enum.count(fn e ->
        e[:provider_id] == provider_id and (e[:ts_ms] || 0) >= now_ms - hour_ms
      end)

    # Provider pick share among chain decisions in 5m
    chain_events_5m =
      Enum.filter(routing_events, fn e ->
        e[:chain] == chain and (e[:ts_ms] || 0) >= now_ms - five_min_ms
      end)

    pick_share_5m =
      if length(chain_events_5m) > 0 do
        100.0 * Enum.count(chain_events_5m, fn e -> e[:provider_id] == provider_id end) /
          length(chain_events_5m)
      else
        0.0
      end

    %{
      provider_score: Float.round(provider_score || 0.0, 2),
      p50_latency: p50,
      p95_latency: p95,
      success_rate: success_rate,
      calls_last_minute: calls_last_minute,
      calls_last_5m: length(events_5m),
      calls_last_hour: calls_last_hour,
      racing_stats: Map.get(real_time_stats, :racing_stats, []),
      rpc_stats: Map.get(real_time_stats, :rpc_stats, []),
      anomalies: anomalies || [],
      recent_activity_count: length(events_5m),
      pick_share_5m: pick_share_5m
    }
  end

  defp empty_provider_metrics do
    %{
      provider_score: 0.0,
      p50_latency: nil,
      p95_latency: nil,
      success_rate: nil,
      calls_last_minute: 0,
      calls_last_5m: 0,
      calls_last_hour: 0,
      racing_stats: [],
      rpc_stats: [],
      anomalies: [],
      recent_activity_count: 0,
      pick_share_5m: 0.0
    }
  end

  @doc "Get chain performance metrics (non-socket version)"
  def get_chain_performance_metrics(assigns, chain_name) do
    # Chain-specific routing events
    chain_events = Enum.filter(assigns.routing_events, &(&1.chain == chain_name))

    # Calculate metrics based on chain_events
    now_ms = System.system_time(:millisecond)
    five_min_ms = 300_000
    _hour_ms = 3_600_000

    recent_events =
      Enum.filter(chain_events, fn e -> (e[:ts_ms] || 0) >= now_ms - five_min_ms end)

    # Calculate success rate
    success_rate =
      if length(recent_events) > 0 do
        successful = Enum.count(recent_events, fn e -> e[:result] == :success end)
        Float.round(successful * 100.0 / length(recent_events), 1)
      else
        nil
      end

    # Calculate latency percentiles
    latencies =
      recent_events
      |> Enum.map(&(&1[:duration_ms] || 0))
      |> Enum.filter(&(&1 > 0))

    {p50, p95} = Calculations.percentile_pair(latencies)

    # Calculate failovers in the last 5 minutes
    failovers_5m = Enum.count(recent_events, &((&1[:failover_count] || 0) > 0))

    # Provider decision share
    decision_share =
      recent_events
      |> Enum.group_by(& &1.provider_id)
      |> Enum.map(fn {pid, evs} -> {pid, 100.0 * length(evs) / max(length(recent_events), 1)} end)
      |> Enum.sort_by(fn {_pid, pct} -> -pct end)

    connected_providers =
      Enum.count(assigns.connections, &(&1.chain == chain_name && &1.status == :connected))

    total_providers = Enum.count(assigns.connections, &(&1.chain == chain_name))

    # Calculate RPS for the chain
    rps = rpc_calls_per_second(chain_events)

    %{
      total_calls: length(chain_events),
      success_rate: success_rate,
      p50_latency: p50,
      p95_latency: p95,
      failovers_5m: failovers_5m,
      connected_providers: connected_providers,
      total_providers: total_providers,
      recent_activity: length(recent_events),
      providers_list: [],
      rpc_methods: [],
      last_updated: 0,
      decision_share: decision_share,
      rps: rps
    }
  end

  def get_latency_leaders_by_chain(_connections) do
    %{}
  end

  @doc "Collect VM metrics"
  def collect_vm_metrics do
    mem = :erlang.memory()

    # CPU percent (runtime/wallclock deltas)
    {_rt_total, rt_delta} = :erlang.statistics(:runtime)
    {_wc_total, wc_delta} = :erlang.statistics(:wall_clock)

    cpu_percent =
      if wc_delta > 0 do
        min(100.0, 100.0 * rt_delta / wc_delta)
      else
        0.0
      end

    # Reductions delta per tick (approx/s)
    {_red_total, red_delta} = :erlang.statistics(:reductions)

    # IO bytes
    io = :erlang.statistics(:io)

    {{_, in_bytes}, {_, out_bytes}} = io

    # Scheduler utilization avg (if enabled)
    sched =
      try do
        :erlang.statistics(:scheduler_wall_time)
      catch
        :error, _ -> :not_available
      end

    sched_util_avg =
      case sched do
        list when is_list(list) and length(list) > 0 ->
          vals =
            Enum.map(list, fn
              {_id, active, total} when total > 0 -> 100.0 * active / total
              {_id, _active, _total} -> 0.0
            end)

          Enum.sum(vals) / max(1, length(vals))

        _ ->
          nil
      end

    %{
      mem_total_mb: Helpers.to_mb(mem[:total]),
      mem_processes_mb: Helpers.to_mb(mem[:processes_used] || mem[:processes] || 0),
      mem_binary_mb: Helpers.to_mb(mem[:binary] || 0),
      mem_code_mb: Helpers.to_mb(mem[:code] || 0),
      mem_ets_mb: Helpers.to_mb(mem[:ets] || 0),
      process_count: :erlang.system_info(:process_count),
      port_count: :erlang.system_info(:port_count),
      atom_count: :erlang.system_info(:atom_count),
      ets_count: :erlang.system_info(:ets_count),
      run_queue: :erlang.statistics(:run_queue),
      cpu_percent: cpu_percent,
      reductions_s: red_delta,
      io_in_mb: Helpers.to_mb(in_bytes),
      io_out_mb: Helpers.to_mb(out_bytes),
      sched_util_avg: sched_util_avg
    }
  end

  @doc "Calculate RPC calls per second from routing events"
  def rpc_calls_per_second(routing_events) when is_list(routing_events) do
    now = System.system_time(:millisecond)
    one_minute_ago = now - 60_000

    recent_events = Enum.filter(routing_events, fn e -> (e[:ts_ms] || 0) >= one_minute_ago end)
    count = length(recent_events)

    # If we have no events, return 0
    if count == 0 do
      0.0
    else
      # Calculate the actual time span of our data
      oldest_event_time =
        recent_events
        |> Enum.map(&(&1[:ts_ms] || now))
        |> Enum.min()

      # Calculate the actual duration in seconds (minimum of 1 second to avoid division by zero)
      actual_duration_seconds = max(1, (now - oldest_event_time) / 1000)

      # Calculate rate based on actual duration
      Float.round(count / actual_duration_seconds, 1)
    end
  end

  @doc "Calculate error rate percentage from routing events"
  def error_rate_percent(routing_events) when is_list(routing_events) do
    now = System.system_time(:millisecond)
    one_minute_ago = now - 60_000
    recent = Enum.filter(routing_events, fn e -> (e[:ts_ms] || 0) >= one_minute_ago end)
    total = max(length(recent), 1)
    errors = Enum.count(recent, fn e -> e[:result] == :error end)
    Float.round(errors * 100.0 / total)
  end

  @doc "Count failovers in the last minute"
  def failovers_last_minute(routing_events) when is_list(routing_events) do
    now = System.system_time(:millisecond)
    one_minute_ago = now - 60_000

    Enum.reduce(routing_events, 0, fn e, acc ->
      if (e[:ts_ms] || 0) >= one_minute_ago and (e[:failovers] || 0) > 0, do: acc + 1, else: acc
    end)
  end
end

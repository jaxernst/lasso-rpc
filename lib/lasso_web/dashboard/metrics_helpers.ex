defmodule LassoWeb.Dashboard.MetricsHelpers do
  @moduledoc """
  Performance metrics and statistics calculations for the Dashboard LiveView.

  ## Time-Windowed Metrics

  Metrics labeled with time windows (e.g., "5m") are calculated from the BenchmarkStore
  ETS tables, which maintain proper time-based data. This ensures accurate statistical
  aggregations regardless of request rate.

  Metrics that benefit from "live feel" (decision breakdown, failovers, activity feed)
  continue to use the in-memory routing_events buffer for instant updates.
  """

  require Logger

  alias Lasso.Benchmarking.BenchmarkStore
  alias LassoWeb.Dashboard.{Constants, Helpers}
  alias LassoWeb.Dashboard.Metrics.Calculations

  # ETS table name helpers (must match BenchmarkStore)
  # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
  defp score_table_name(profile, chain_name), do: :"provider_scores_#{profile}_#{chain_name}"

  # ---------------------------------------------------------------------------
  # ETS-Based Time-Windowed Metrics
  # ---------------------------------------------------------------------------

  @doc """
  Get latency percentiles from ETS provider_scores table within a time window.

  Queries the pre-aggregated `recent_latencies` field from provider_scores,
  filtered by `last_updated` timestamp. This provides accurate time-windowed
  percentiles without expensive full table scans.

  Uses monotonic time for consistency with BenchmarkStore timestamps.
  """
  def get_windowed_percentiles_from_ets(profile, chain_name, window_ms \\ 300_000) do
    score_table = score_table_name(profile, chain_name)
    cutoff = System.monotonic_time(:millisecond) - window_ms

    # Select recent_latencies from all RPC entries updated within the window
    # New 7-tuple schema: monotonic_last_updated is 6th field (:"$6")
    # {{provider_id, method, :rpc}, successes, total, avg_duration, recent_latencies, monotonic_ts, system_ts}
    latencies =
      :ets.select(score_table, [
        {{{:_, :_, :rpc}, :_, :_, :_, :"$1", :"$6", :_},
         [{:>=, :"$6", cutoff}, {:is_list, :"$1"}], [:"$1"]}
      ])
      |> List.flatten()

    Calculations.percentile_pair(latencies)
  rescue
    ArgumentError ->
      # Table doesn't exist yet
      {nil, nil}
  catch
    :error, :badarg ->
      {nil, nil}
  end

  @doc """
  Get success rate from ETS provider_scores table within a time window.

  Aggregates successes and totals from all provider/method pairs that have
  been updated within the specified window.
  """
  def get_windowed_success_rate_from_ets(profile, chain_name, window_ms \\ 300_000) do
    score_table = score_table_name(profile, chain_name)
    cutoff = System.monotonic_time(:millisecond) - window_ms

    # Select {successes, total} from all RPC entries updated within the window
    # New 7-tuple: monotonic_last_updated is 6th field (:"$6")
    stats =
      :ets.select(score_table, [
        {{{:_, :_, :rpc}, :"$1", :"$2", :_, :_, :"$6", :_}, [{:>=, :"$6", cutoff}],
         [{{:"$1", :"$2"}}]}
      ])

    {total_successes, total_calls} =
      Enum.reduce(stats, {0, 0}, fn {s, t}, {acc_s, acc_t} ->
        {acc_s + s, acc_t + t}
      end)

    if total_calls > 0 do
      Float.round(total_successes * 100.0 / total_calls, 1)
    else
      nil
    end
  rescue
    ArgumentError -> nil
  catch
    :error, :badarg -> nil
  end

  @doc """
  Get latency percentiles for a specific provider from ETS within a time window.
  """
  def get_provider_windowed_percentiles_from_ets(
        profile,
        chain_name,
        provider_id,
        window_ms \\ 300_000
      ) do
    score_table = score_table_name(profile, chain_name)
    cutoff = System.monotonic_time(:millisecond) - window_ms

    # Select recent_latencies for this specific provider
    # New 7-tuple: monotonic_last_updated is 6th field (:"$6")
    latencies =
      :ets.select(score_table, [
        {{{:"$1", :_, :rpc}, :_, :_, :_, :"$2", :"$6", :_},
         [{:==, :"$1", provider_id}, {:>=, :"$6", cutoff}, {:is_list, :"$2"}], [:"$2"]}
      ])
      |> List.flatten()

    Calculations.percentile_pair(latencies)
  rescue
    ArgumentError -> {nil, nil}
  catch
    :error, :badarg -> {nil, nil}
  end

  @doc """
  Get success rate for a specific provider from ETS within a time window.
  """
  def get_provider_windowed_success_rate_from_ets(
        profile,
        chain_name,
        provider_id,
        window_ms \\ 300_000
      ) do
    score_table = score_table_name(profile, chain_name)
    cutoff = System.monotonic_time(:millisecond) - window_ms

    # Select {successes, total} for this specific provider
    # New 7-tuple: monotonic_last_updated is 6th field (:"$6")
    stats =
      :ets.select(score_table, [
        {{{:"$1", :_, :rpc}, :"$2", :"$3", :_, :_, :"$6", :_},
         [{:==, :"$1", provider_id}, {:>=, :"$6", cutoff}], [{{:"$2", :"$3"}}]}
      ])

    {total_successes, total_calls} =
      Enum.reduce(stats, {0, 0}, fn {s, t}, {acc_s, acc_t} ->
        {acc_s + s, acc_t + t}
      end)

    if total_calls > 0 do
      Float.round(total_successes * 100.0 / total_calls, 1)
    else
      nil
    end
  rescue
    ArgumentError -> nil
  catch
    :error, :badarg -> nil
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Assign chain performance metrics to assigns"
  def assign_chain_performance_metrics(assigns, chain_name) do
    profile = assigns.selected_profile

    # Get chain-wide statistics
    chain_stats = BenchmarkStore.get_chain_wide_stats(profile, chain_name)
    realtime_stats = BenchmarkStore.get_realtime_stats(profile, chain_name)

    # Time window for ETS queries
    window_ms = Constants.metrics_window_5min()

    # Get time-windowed metrics from ETS (accurate 5-minute aggregations)
    {p50, p95} = get_windowed_percentiles_from_ets(profile, chain_name, window_ms)
    success_rate = get_windowed_success_rate_from_ets(profile, chain_name, window_ms)

    # "Live feel" metrics from routing_events buffer
    chain_events = Enum.filter(assigns.routing_events, &(&1[:chain] == chain_name))
    failovers_recent = Enum.count(chain_events, fn e -> (e[:failovers] || 0) > 0 end)

    # Decision share from buffer (real-time routing patterns)
    decision_share =
      chain_events
      |> Enum.group_by(& &1.provider_id)
      |> Enum.map(fn {pid, evs} -> {pid, 100.0 * length(evs) / max(length(chain_events), 1)} end)
      |> Enum.sort_by(fn {_pid, pct} -> -pct end)

    # Count providers that are available for routing (not circuit open, not rate limited, not lagging)
    # Use determine_provider_status for comprehensive status evaluation
    # Note: :lagging providers are excluded since they return stale data
    chain_connections = Enum.filter(assigns.connections, &(&1.chain == chain_name))

    connected_providers =
      Enum.count(chain_connections, fn provider ->
        LassoWeb.Dashboard.StatusHelpers.determine_provider_status(provider) in [
          :healthy,
          :recovering
        ]
      end)

    total_providers = length(chain_connections)

    Map.put(assigns, :chain_performance, %{
      total_calls: Map.get(chain_stats, :total_calls, 0),
      success_rate: success_rate,
      p50_latency: p50,
      p95_latency: p95,
      failovers_5m: failovers_recent,
      connected_providers: connected_providers,
      total_providers: total_providers,
      recent_activity: length(chain_events),
      providers_list: Map.get(realtime_stats, :providers, []),
      rpc_methods: Map.get(realtime_stats, :rpc_methods, []),
      last_updated: Map.get(realtime_stats, :last_updated, 0),
      decision_share: decision_share
    })
  end

  @doc "Assign provider performance metrics to assigns"
  def assign_provider_performance_metrics(assigns, provider_id) do
    profile = assigns.selected_profile

    # Get the chain for this provider
    chain =
      case Enum.find(assigns.connections, &(&1.id == provider_id)) do
        %{chain: chain_name} -> chain_name
        _ -> nil
      end

    metrics =
      if chain do
        calculate_provider_metrics(profile, chain, provider_id, assigns.routing_events)
      else
        empty_provider_metrics()
      end

    Map.put(assigns, :performance_metrics, metrics)
  end

  @doc "Get provider performance metrics (non-socket version)"
  def get_provider_performance_metrics(
        provider_id,
        connections \\ [],
        routing_events \\ [],
        profile \\ "default"
      ) do
    # Get the chain for this provider
    chain =
      case Enum.find(connections, &(&1.id == provider_id)) do
        %{chain: chain_name} -> chain_name
        _ -> nil
      end

    if chain do
      calculate_provider_metrics(profile, chain, provider_id, routing_events)
    else
      empty_provider_metrics()
    end
  end

  # Private: Calculate provider metrics (shared logic)
  defp calculate_provider_metrics(profile, chain, provider_id, routing_events) do
    provider_score = BenchmarkStore.get_provider_score(profile, chain, provider_id)
    real_time_stats = BenchmarkStore.get_real_time_stats(profile, chain, provider_id)
    anomalies = BenchmarkStore.detect_performance_anomalies(profile, chain, provider_id)

    # Time window for ETS queries
    five_min_ms = Constants.metrics_window_5min()

    # Get time-windowed metrics from ETS (accurate 5-minute aggregations)
    {p50, p95} =
      get_provider_windowed_percentiles_from_ets(profile, chain, provider_id, five_min_ms)

    success_rate =
      get_provider_windowed_success_rate_from_ets(profile, chain, provider_id, five_min_ms)

    # Get call counts from BenchmarkStore real-time stats
    calls_last_minute = Map.get(real_time_stats, :calls_last_minute, 0)

    # Provider events from buffer (for live feel metrics)
    provider_events = Enum.filter(routing_events, &(&1[:provider_id] == provider_id))
    chain_events = Enum.filter(routing_events, &(&1[:chain] == chain))

    # Provider pick share from buffer (shows real-time routing patterns)
    pick_share =
      if length(chain_events) > 0 do
        100.0 * length(provider_events) / length(chain_events)
      else
        0.0
      end

    %{
      provider_score: Float.round(provider_score, 2),
      p50_latency: p50,
      p95_latency: p95,
      success_rate: success_rate,
      calls_last_minute: calls_last_minute,
      rpc_stats: Map.get(real_time_stats, :rpc_stats, []),
      anomalies: anomalies,
      recent_activity_count: length(provider_events),
      pick_share_5m: pick_share
    }
  end

  defp empty_provider_metrics do
    %{
      provider_score: 0.0,
      p50_latency: nil,
      p95_latency: nil,
      success_rate: nil,
      calls_last_minute: 0,
      rpc_stats: [],
      anomalies: [],
      recent_activity_count: 0,
      pick_share_5m: 0.0
    }
  end

  @doc "Get chain performance metrics (non-socket version)"
  def get_chain_performance_metrics(assigns, chain_name) do
    profile = assigns.selected_profile

    # Chain-specific routing events (from 100-item buffer - used for "live feel" metrics)
    chain_events = Enum.filter(assigns.routing_events, &(&1.chain == chain_name))

    # Time window for ETS queries
    window_ms = Constants.metrics_window_5min()

    # Get time-windowed metrics from ETS (accurate 5-minute aggregations)
    {p50, p95} = get_windowed_percentiles_from_ets(profile, chain_name, window_ms)
    success_rate = get_windowed_success_rate_from_ets(profile, chain_name, window_ms)

    # "Live feel" metrics from routing_events buffer (instant updates)
    # These don't need strict time windows - they show recent activity patterns
    failovers_recent =
      Enum.count(chain_events, &((&1[:failovers] || &1[:failover_count] || 0) > 0))

    # Provider decision share from buffer (shows real-time routing patterns)
    decision_share =
      chain_events
      |> Enum.group_by(& &1.provider_id)
      |> Enum.map(fn {pid, evs} -> {pid, 100.0 * length(evs) / max(length(chain_events), 1)} end)
      |> Enum.sort_by(fn {_pid, pct} -> -pct end)

    # Count providers that are available for routing (not circuit open, not rate limited, not lagging)
    # Use determine_provider_status for comprehensive status evaluation
    # Note: :lagging providers are excluded since they return stale data
    chain_connections = Enum.filter(assigns.connections, &(&1.chain == chain_name))

    connected_providers =
      Enum.count(chain_connections, fn provider ->
        LassoWeb.Dashboard.StatusHelpers.determine_provider_status(provider) in [
          :healthy,
          :recovering
        ]
      end)

    total_providers = length(chain_connections)

    # Calculate RPS for the chain
    rps = rpc_calls_per_second(chain_events)

    %{
      total_calls: length(chain_events),
      success_rate: success_rate,
      p50_latency: p50,
      p95_latency: p95,
      failovers_5m: failovers_recent,
      connected_providers: connected_providers,
      total_providers: total_providers,
      recent_activity: length(chain_events),
      providers_list: [],
      rpc_methods: [],
      last_updated: 0,
      decision_share: decision_share,
      rps: rps
    }
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

  @doc "Calculate success rate percentage from routing events (last 1 minute)"
  def success_rate_percent(routing_events) when is_list(routing_events) do
    now = System.system_time(:millisecond)
    one_minute_ago = now - 60_000
    recent = Enum.filter(routing_events, fn e -> (e[:ts_ms] || 0) >= one_minute_ago end)

    case length(recent) do
      0 ->
        nil

      total ->
        Float.round((total - Enum.count(recent, &(&1[:result] == :error))) * 100.0 / total, 1)
    end
  end

  @doc "Calculate average latency in ms from routing events (last 1 minute)"
  def avg_latency_ms(routing_events) when is_list(routing_events) do
    now = System.system_time(:millisecond)
    one_minute_ago = now - 60_000
    recent = Enum.filter(routing_events, fn e -> (e[:ts_ms] || 0) >= one_minute_ago end)

    case length(recent) do
      0 ->
        nil

      count ->
        total_ms = Enum.reduce(recent, 0, fn e, acc -> acc + (e[:duration_ms] || 0) end)
        round(total_ms / count)
    end
  end
end

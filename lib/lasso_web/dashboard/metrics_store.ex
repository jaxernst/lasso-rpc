defmodule LassoWeb.Dashboard.MetricsStore do
  @moduledoc """
  Caches aggregated metrics from cluster-wide RPC queries.

  Uses stale-while-revalidate pattern: returns cached data immediately
  while triggering background refresh when TTL expires.

  Subscribes to topology changes via PubSub and invalidates cache entries
  when cluster membership changes.
  """

  use GenServer
  require Logger

  alias Lasso.Cluster.Topology

  @cache_ttl_ms 15_000
  @refresh_timeout_ms 5_000
  @min_calls_threshold 10
  @cache_cleanup_interval_ms 60_000
  @cache_max_age_ms 300_000

  @type coverage :: %{
          responding: non_neg_integer(),
          total: non_neg_integer(),
          rpc_bad_nodes: [node()],
          duration_ms: non_neg_integer()
        }

  @type cached_result(t) :: %{
          data: t,
          coverage: coverage(),
          cached_at: integer(),
          stale: boolean()
        }

  defstruct cache: %{},
            refreshing: MapSet.new(),
            last_known_node_count: 0

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets provider leaderboard aggregated across all cluster nodes.
  Returns cached data with coverage metadata.
  """
  @spec get_provider_leaderboard(String.t(), String.t()) :: cached_result(list())
  def get_provider_leaderboard(profile, chain) do
    get_cached_or_fetch({:provider_leaderboard, profile, chain}, fn ->
      fetch_from_cluster(
        Lasso.Benchmarking.BenchmarkStore,
        :get_provider_leaderboard,
        [profile, chain]
      )
    end)
  end

  @doc """
  Gets realtime stats aggregated across all cluster nodes.
  """
  @spec get_realtime_stats(String.t(), String.t()) :: cached_result(map())
  def get_realtime_stats(profile, chain) do
    get_cached_or_fetch({:realtime_stats, profile, chain}, fn ->
      fetch_from_cluster(
        Lasso.Benchmarking.BenchmarkStore,
        :get_realtime_stats,
        [profile, chain]
      )
    end)
  end

  @doc """
  Gets RPC method performance with percentiles from all nodes.
  """
  @spec get_rpc_method_performance(String.t(), String.t(), String.t(), String.t()) ::
          cached_result(map() | nil)
  def get_rpc_method_performance(profile, chain, provider_id, method) do
    get_cached_or_fetch({:method_perf, profile, chain, provider_id, method}, fn ->
      fetch_from_cluster(
        Lasso.Benchmarking.BenchmarkStore,
        :get_rpc_method_performance_with_percentiles,
        [profile, chain, provider_id, method]
      )
    end)
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Lasso.PubSub, "cluster:topology")
    schedule_cache_cleanup()

    initial_node_count = get_node_count()

    Logger.info("[MetricsStore] Started with #{initial_node_count} nodes")

    {:ok, %__MODULE__{last_known_node_count: initial_node_count}}
  end

  defp schedule_cache_cleanup do
    Process.send_after(self(), :cleanup_cache, @cache_cleanup_interval_ms)
  end

  @impl true
  def handle_call({:get_or_fetch, key, fetch_fn}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.cache, key) do
      %{cached_at: cached_at, data: data, coverage: coverage}
      when now - cached_at < @cache_ttl_ms ->
        emit_cache_telemetry(:hit, key)

        result = %{
          data: data,
          coverage: coverage,
          cached_at: cached_at,
          stale: false
        }

        {:reply, result, state}

      %{data: data, coverage: coverage, cached_at: cached_at} ->
        emit_cache_telemetry(:stale, key)
        state = maybe_trigger_refresh(state, key, fetch_fn)

        result = %{
          data: data,
          coverage: coverage,
          cached_at: cached_at,
          stale: true
        }

        {:reply, result, state}

      nil ->
        # Cache miss: trigger async refresh instead of blocking
        emit_cache_telemetry(:miss, key)
        state = maybe_trigger_refresh(state, key, fetch_fn)

        # Return empty defaults so callers don't need nil checks
        result = %{
          data: empty_default_for(key),
          coverage: %{responding: 0, total: 0},
          cached_at: nil,
          stale: false,
          loading: true
        }

        {:reply, result, state}
    end
  end

  # Topology events - invalidate cache on node changes
  @impl true
  def handle_info({:topology_event, %{event: event}}, state)
      when event in [:node_connected, :node_disconnected] do
    Logger.debug("[MetricsStore] Cache invalidated due to #{event}")
    emit_cache_telemetry(:invalidated, event)
    {:noreply, %{state | cache: %{}}}
  end

  def handle_info({:topology_event, _}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:refresh_complete, key, data, coverage}, state) do
    now = System.monotonic_time(:millisecond)

    new_cache =
      Map.put(state.cache, key, %{
        data: data,
        coverage: coverage,
        cached_at: now
      })

    new_refreshing = MapSet.delete(state.refreshing, key)

    {:noreply, %{state | cache: new_cache, refreshing: new_refreshing}}
  end

  @impl true
  def handle_info({:refresh_failed, key, reason}, state) do
    Logger.warning("[MetricsStore] Refresh failed for #{inspect(key)}: #{inspect(reason)}")
    new_refreshing = MapSet.delete(state.refreshing, key)
    {:noreply, %{state | refreshing: new_refreshing}}
  end

  @impl true
  def handle_info(:cleanup_cache, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @cache_max_age_ms

    new_cache =
      state.cache
      |> Enum.reject(fn {_key, %{cached_at: ts}} -> ts < cutoff end)
      |> Map.new()

    schedule_cache_cleanup()
    {:noreply, %{state | cache: new_cache}}
  end

  # Private helpers

  defp get_cached_or_fetch(key, fetch_fn) do
    GenServer.call(__MODULE__, {:get_or_fetch, key, fetch_fn}, @refresh_timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} ->
      %{
        data: nil,
        coverage: %{responding: 0, total: 1, rpc_bad_nodes: [node()], duration_ms: 0},
        cached_at: 0,
        stale: true
      }
  end

  defp maybe_trigger_refresh(state, key, fetch_fn) do
    if MapSet.member?(state.refreshing, key) do
      state
    else
      parent = self()

      Task.Supervisor.start_child(Lasso.TaskSupervisor, fn ->
        try do
          {data, coverage} = fetch_fn.()
          send(parent, {:refresh_complete, key, data, coverage})
        catch
          kind, reason ->
            send(parent, {:refresh_failed, key, {kind, reason}})
        end
      end)

      %{state | refreshing: MapSet.put(state.refreshing, key)}
    end
  end

  @doc false
  def fetch_from_cluster(module, function, args) do
    # Use Topology for node list instead of Node.list()
    remote_nodes = get_responding_nodes()
    nodes = [node() | remote_nodes] |> Enum.uniq()

    start_time = System.monotonic_time(:millisecond)

    {results, bad_nodes} = :rpc.multicall(nodes, module, function, args, @refresh_timeout_ms)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    # Filter out {:badrpc, reason} tuples
    valid_results = Enum.reject(results, &match?({:badrpc, _}, &1))

    # Get coverage from Topology (authoritative source)
    topology_coverage = get_topology_coverage()

    coverage = %{
      responding: length(valid_results),
      total: topology_coverage.connected,
      rpc_bad_nodes: bad_nodes,
      duration_ms: duration_ms
    }

    {profile, chain} = extract_telemetry_context(args)
    emit_rpc_telemetry(profile, chain, length(nodes), length(bad_nodes), duration_ms)

    aggregated = aggregate_results(function, valid_results)
    {aggregated, coverage}
  end

  defp get_responding_nodes do
    Topology.get_responding_nodes()
  catch
    :exit, _ -> Node.list()
  end

  defp get_topology_coverage do
    Topology.get_coverage()
  catch
    :exit, _ -> %{connected: length(Node.list()) + 1, responding: 1}
  end

  defp get_node_count do
    coverage = Topology.get_coverage()
    coverage.connected
  catch
    :exit, _ -> length(Node.list()) + 1
  end

  # Made public for testing - these are pure functions with no side effects
  @doc false
  def aggregate_results(:get_provider_leaderboard, results) do
    results
    |> List.flatten()
    |> Enum.group_by(& &1.provider_id)
    |> Enum.map(fn {provider_id, entries} ->
      entries_with_sufficient_calls =
        Enum.filter(entries, fn entry ->
          Map.get(entry, :total_calls, 0) >= @min_calls_threshold
        end)

      if entries_with_sufficient_calls == [] do
        total_calls = entries |> Enum.map(&Map.get(&1, :total_calls, 0)) |> Enum.sum()

        # Compute actual metrics from available data (even if below threshold)
        # This ensures consistency between aggregate and per-region views
        success_rate =
          if total_calls > 0,
            do: weighted_average(entries, :success_rate, total_calls),
            else: 0.0

        avg_latency_ms =
          if total_calls > 0,
            do: weighted_average(entries, :avg_latency_ms, total_calls),
            else: 0.0

        latency_by_node = build_latency_by_node(entries)

        %{
          provider_id: provider_id,
          score: 0.0,
          total_calls: total_calls,
          success_rate: success_rate,
          avg_latency_ms: avg_latency_ms,
          node_count: length(entries),
          cold_start: true,
          latency_by_node: latency_by_node
        }
      else
        aggregate_provider_entries(provider_id, entries_with_sufficient_calls, entries)
      end
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  @doc false
  def aggregate_results(:get_realtime_stats, results) do
    valid_results = Enum.reject(results, &is_nil/1)

    # Use MapSets for O(1) union instead of O(n²) list concatenation
    aggregated =
      Enum.reduce(
        valid_results,
        %{rpc_methods: MapSet.new(), providers: MapSet.new(), total_entries: 0},
        fn stats, acc ->
          %{
            rpc_methods:
              MapSet.union(acc.rpc_methods, MapSet.new(Map.get(stats, :rpc_methods, []))),
            providers: MapSet.union(acc.providers, MapSet.new(Map.get(stats, :providers, []))),
            total_entries: acc.total_entries + Map.get(stats, :total_entries, 0)
          }
        end
      )

    %{
      rpc_methods: MapSet.to_list(aggregated.rpc_methods),
      providers: MapSet.to_list(aggregated.providers),
      total_entries: aggregated.total_entries,
      node_count: length(valid_results),
      last_updated: System.system_time(:millisecond)
    }
  end

  @doc false
  def aggregate_results(:get_rpc_method_performance_with_percentiles, results) do
    valid_results = Enum.reject(results, &is_nil/1)

    case valid_results do
      [] ->
        nil

      [single] ->
        stats_by_node = [
          %{
            node_id: Map.get(single, :source_node_id) || "unidentified",
            node: Map.get(single, :source_node),
            avg_duration_ms: Map.get(single, :avg_duration_ms),
            success_rate: Map.get(single, :success_rate),
            total_calls: Map.get(single, :total_calls, 0),
            percentiles: Map.get(single, :percentiles, %{})
          }
        ]

        single
        |> Map.put(:node_count, 1)
        |> Map.put(:stats_by_node, stats_by_node)

      multiple ->
        aggregate_method_performance(multiple)
    end
  end

  @doc false
  def aggregate_results(_function, results) do
    List.first(results)
  end

  @doc false
  def aggregate_provider_entries(provider_id, entries_for_aggregates, all_entries) do
    total_calls =
      entries_for_aggregates |> Enum.map(&Map.get(&1, :total_calls, 0)) |> Enum.sum()

    latency_by_node = build_latency_by_node(all_entries)

    %{
      provider_id: provider_id,
      score: weighted_average(entries_for_aggregates, :score, total_calls),
      total_calls: total_calls,
      success_rate: weighted_average(entries_for_aggregates, :success_rate, total_calls),
      avg_latency_ms: weighted_average(entries_for_aggregates, :avg_latency_ms, total_calls),
      node_count: length(all_entries),
      latency_by_node: latency_by_node
    }
  end

  defp build_latency_by_node(entries) do
    entries
    |> Enum.map(fn entry ->
      node_id = Map.get(entry, :source_node_id) || "unidentified"

      {node_id,
       %{
         node_id: node_id,
         node: Map.get(entry, :source_node),
         p50: Map.get(entry, :p50_latency),
         p95: Map.get(entry, :p95_latency),
         p99: Map.get(entry, :p99_latency),
         avg: Map.get(entry, :avg_latency_ms),
         success_rate: Map.get(entry, :success_rate),
         total_calls: Map.get(entry, :total_calls, 0)
       }}
    end)
    |> Map.new()
  end

  @doc false
  def weighted_average(entries, field, total_weight) do
    entries
    |> Enum.map(fn entry ->
      calls = Map.get(entry, :total_calls, 0)
      value = Map.get(entry, field, 0.0)
      value * calls
    end)
    |> Enum.sum()
    |> safe_divide(total_weight)
  end

  defp aggregate_method_performance(results) do
    base_results =
      case Enum.filter(results, &(Map.get(&1, :total_calls, 0) >= @min_calls_threshold)) do
        [] -> results
        filtered -> filtered
      end

    total_calls = base_results |> Enum.map(&Map.get(&1, :total_calls, 0)) |> Enum.sum()
    first = List.first(base_results)

    stats_by_node =
      results
      |> Enum.map(fn entry ->
        %{
          node_id: Map.get(entry, :source_node_id) || "unidentified",
          node: Map.get(entry, :source_node),
          avg_duration_ms: Map.get(entry, :avg_duration_ms),
          success_rate: Map.get(entry, :success_rate),
          total_calls: Map.get(entry, :total_calls, 0),
          percentiles: Map.get(entry, :percentiles, %{})
        }
      end)

    %{
      provider_id: Map.get(first, :provider_id),
      method: Map.get(first, :method),
      success_rate: weighted_average(base_results, :success_rate, total_calls),
      total_calls: total_calls,
      avg_duration_ms: weighted_average(base_results, :avg_duration_ms, total_calls),
      percentiles: Map.get(first, :percentiles, %{}),
      node_count: length(results),
      stats_by_node: stats_by_node
    }
  end

  defp safe_divide(_numerator, 0), do: 0.0

  defp safe_divide(numerator, denominator) when is_number(denominator),
    do: numerator / denominator

  defp emit_cache_telemetry(result, key) do
    {profile, chain} = extract_cache_key_context(key)

    :telemetry.execute(
      [:lasso_web, :dashboard, :metrics_store, :cache],
      %{count: 1},
      %{result: result, profile: profile, chain: chain}
    )
  end

  defp emit_rpc_telemetry(profile, chain, node_count, bad_count, duration_ms) do
    :telemetry.execute(
      [:lasso_web, :dashboard, :metrics_store, :rpc],
      %{
        duration_ms: duration_ms,
        node_count: node_count,
        success_count: node_count - bad_count,
        bad_count: bad_count
      },
      %{profile: profile, chain: chain}
    )
  end

  defp extract_cache_key_context(key) when is_tuple(key) and tuple_size(key) >= 3 do
    {elem(key, 1), elem(key, 2)}
  end

  defp extract_cache_key_context(_), do: {"unknown", "unknown"}

  defp extract_telemetry_context(args) do
    case args do
      [profile, chain | _] -> {profile, chain}
      _ -> {"unknown", "unknown"}
    end
  end

  defp empty_default_for({:provider_leaderboard, _, _}), do: []

  defp empty_default_for({:realtime_stats, _, _}) do
    %{rpc_methods: [], providers: [], total_entries: 0, node_count: 0}
  end

  defp empty_default_for({:method_perf, _, _, _, _}), do: nil

  defp empty_default_for(_), do: nil
end

defmodule LassoWeb.Dashboard.MetricsStore do
  @moduledoc """
  Caches aggregated metrics from cluster-wide RPC queries.

  Uses stale-while-revalidate pattern: returns cached data immediately
  while triggering background refresh when TTL expires.

  Subscribes to topology changes and invalidates cache entries when
  cluster membership changes significantly.

  Key changes from ClusterMetricsCache:
  - Uses Topology.get_responding_nodes() instead of Node.list()
  - Subscribes to cluster:topology for cache invalidation
  - Delegates coverage queries to Topology module
  """

  use GenServer
  require Logger

  @cache_ttl_ms 15_000
  @refresh_timeout_ms 5_000
  @min_calls_threshold 10

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
    # Subscribe to topology changes for cache invalidation
    Phoenix.PubSub.subscribe(Lasso.PubSub, "cluster:topology")

    initial_node_count = get_node_count()

    Logger.info("[MetricsStore] Started with #{initial_node_count} nodes")

    {:ok, %__MODULE__{last_known_node_count: initial_node_count}}
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
        emit_cache_telemetry(:miss, key)
        {data, coverage} = fetch_fn.()

        new_cache =
          Map.put(state.cache, key, %{
            data: data,
            coverage: coverage,
            cached_at: now
          })

        result = %{
          data: data,
          coverage: coverage,
          cached_at: now,
          stale: false
        }

        {:reply, result, %{state | cache: new_cache}}
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
        rescue
          e ->
            send(parent, {:refresh_failed, key, e})
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
    try do
      Lasso.Cluster.Topology.get_responding_nodes()
    catch
      :exit, _ -> Node.list()
    end
  end

  defp get_topology_coverage do
    try do
      Lasso.Cluster.Topology.get_coverage()
    catch
      :exit, _ -> %{connected: length(Node.list()) + 1, responding: 1}
    end
  end

  defp get_node_count do
    try do
      coverage = Lasso.Cluster.Topology.get_coverage()
      coverage.connected
    catch
      :exit, _ -> length(Node.list()) + 1
    end
  end

  defp aggregate_results(:get_provider_leaderboard, results) do
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

        %{
          provider_id: provider_id,
          score: 0.0,
          total_calls: total_calls,
          success_rate: 0.0,
          avg_latency_ms: 0.0,
          node_count: length(entries),
          cold_start: true
        }
      else
        aggregate_provider_entries(provider_id, entries_with_sufficient_calls, length(entries))
      end
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp aggregate_results(:get_realtime_stats, results) do
    valid_results = Enum.reject(results, &is_nil/1)
    node_count = length(valid_results)

    aggregated =
      valid_results
      |> Enum.reduce(%{rpc_methods: [], providers: [], total_entries: 0}, fn stats, acc ->
        %{
          rpc_methods: Enum.uniq(acc.rpc_methods ++ Map.get(stats, :rpc_methods, [])),
          providers: Enum.uniq(acc.providers ++ Map.get(stats, :providers, [])),
          total_entries: acc.total_entries + Map.get(stats, :total_entries, 0)
        }
      end)

    Map.merge(aggregated, %{
      node_count: node_count,
      last_updated: System.system_time(:millisecond)
    })
  end

  defp aggregate_results(:get_rpc_method_performance_with_percentiles, results) do
    valid_results = Enum.reject(results, &is_nil/1)

    case valid_results do
      [] ->
        nil

      [single] ->
        Map.put(single, :node_count, 1)

      multiple ->
        aggregate_method_performance(multiple)
    end
  end

  defp aggregate_results(_function, results) do
    List.first(results)
  end

  defp aggregate_provider_entries(provider_id, entries, total_node_count) do
    total_calls = entries |> Enum.map(&Map.get(&1, :total_calls, 0)) |> Enum.sum()

    weighted_score =
      entries
      |> Enum.map(fn entry ->
        calls = Map.get(entry, :total_calls, 0)
        score = Map.get(entry, :score, 0.0)
        score * calls
      end)
      |> Enum.sum()
      |> safe_divide(total_calls)

    weighted_success_rate =
      entries
      |> Enum.map(fn entry ->
        calls = Map.get(entry, :total_calls, 0)
        rate = Map.get(entry, :success_rate, 0.0)
        rate * calls
      end)
      |> Enum.sum()
      |> safe_divide(total_calls)

    weighted_latency =
      entries
      |> Enum.map(fn entry ->
        calls = Map.get(entry, :total_calls, 0)
        latency = Map.get(entry, :avg_latency_ms, 0.0)
        latency * calls
      end)
      |> Enum.sum()
      |> safe_divide(total_calls)

    latency_by_region =
      entries
      |> Enum.map(fn entry ->
        %{
          region: Map.get(entry, :region) || Map.get(entry, :source_region) || "unknown",
          node: Map.get(entry, :source_node),
          p50: Map.get(entry, :p50_latency),
          p95: Map.get(entry, :p95_latency),
          p99: Map.get(entry, :p99_latency),
          avg: Map.get(entry, :avg_latency_ms)
        }
      end)

    %{
      provider_id: provider_id,
      score: weighted_score,
      total_calls: total_calls,
      success_rate: weighted_success_rate,
      avg_latency_ms: weighted_latency,
      node_count: total_node_count,
      latency_by_region: latency_by_region
    }
  end

  defp aggregate_method_performance(results) do
    results_with_sufficient_calls =
      Enum.filter(results, fn r ->
        Map.get(r, :total_calls, 0) >= @min_calls_threshold
      end)

    base_results =
      if results_with_sufficient_calls == [], do: results, else: results_with_sufficient_calls

    total_calls = base_results |> Enum.map(&Map.get(&1, :total_calls, 0)) |> Enum.sum()

    weighted_success_rate =
      base_results
      |> Enum.map(fn r ->
        calls = Map.get(r, :total_calls, 0)
        rate = Map.get(r, :success_rate, 0.0)
        rate * calls
      end)
      |> Enum.sum()
      |> safe_divide(total_calls)

    weighted_duration =
      base_results
      |> Enum.map(fn r ->
        calls = Map.get(r, :total_calls, 0)
        duration = Map.get(r, :avg_duration_ms, 0.0)
        duration * calls
      end)
      |> Enum.sum()
      |> safe_divide(total_calls)

    first = List.first(base_results)

    %{
      provider_id: Map.get(first, :provider_id),
      method: Map.get(first, :method),
      success_rate: weighted_success_rate,
      total_calls: total_calls,
      avg_duration_ms: weighted_duration,
      percentiles: Map.get(first, :percentiles, %{}),
      node_count: length(results),
      percentiles_note: "Percentiles from single node (not averaged)"
    }
  end

  defp safe_divide(_numerator, 0), do: 0.0
  defp safe_divide(numerator, denominator) when is_number(denominator), do: numerator / denominator

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

  defp extract_cache_key_context(key) do
    case key do
      {:provider_leaderboard, profile, chain} -> {profile, chain}
      {:realtime_stats, profile, chain} -> {profile, chain}
      {:method_perf, profile, chain, _provider_id, _method} -> {profile, chain}
      _ -> {"unknown", "unknown"}
    end
  end

  defp extract_telemetry_context(args) do
    case args do
      [profile, chain | _] -> {profile, chain}
      _ -> {"unknown", "unknown"}
    end
  end
end

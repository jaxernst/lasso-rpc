defmodule LassoWeb.Dashboard.MetricsStore do
  @moduledoc """
  Caches aggregated metrics from cluster-wide RPC queries.

  Uses a public ETS table for lock-free reads with stale-while-revalidate
  semantics. Reads bypass the GenServer entirely; only refresh coordination
  goes through the mailbox via casts.

  Subscribes to topology changes via PubSub and invalidates cache entries
  when cluster membership changes. Uses a generation counter to discard
  stale completions from pre-invalidation tasks.
  """

  use GenServer
  require Logger

  alias Lasso.Cluster.Topology

  @cache_table :metrics_store_cache
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

  @type cached_result(t) ::
          %{data: t, coverage: coverage(), cached_at: integer(), stale: boolean()}
          | %{
              data: t,
              coverage: %{responding: 0, total: 0},
              cached_at: nil,
              stale: false,
              loading: true
            }

  defstruct refreshing: MapSet.new(),
            task_keys: %{},
            generation: 0,
            last_known_node_count: 0

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets provider leaderboard aggregated across all cluster nodes.
  Returns cached data with coverage metadata. Reads ETS directly.
  """
  @spec get_provider_leaderboard(String.t(), String.t()) :: cached_result(list())
  def get_provider_leaderboard(profile, chain) do
    key = {:provider_leaderboard, profile, chain}
    ets_read_or_refresh(key, [])
  end

  @doc """
  Gets realtime stats aggregated across all cluster nodes.
  Reads ETS directly.
  """
  @spec get_realtime_stats(String.t(), String.t()) :: cached_result(map())
  def get_realtime_stats(profile, chain) do
    key = {:realtime_stats, profile, chain}

    ets_read_or_refresh(key, %{
      rpc_methods: [],
      providers: [],
      total_entries: 0,
      node_count: 0
    })
  end

  @doc """
  Gets RPC method performance with percentiles from all nodes.
  Reads ETS directly.
  """
  @spec get_rpc_method_performance(String.t(), String.t(), String.t(), String.t()) ::
          cached_result(map() | nil)
  def get_rpc_method_performance(profile, chain, provider_id, method) do
    key = {:method_perf, profile, chain, provider_id, method}
    ets_read_or_refresh(key, nil)
  end

  @doc """
  Gets all method performance data for a profile/chain in one bulk call.
  Reads ETS directly.
  """
  @spec get_bulk_method_performance(String.t(), String.t()) :: cached_result(list())
  def get_bulk_method_performance(profile, chain) do
    key = {:bulk_method_perf, profile, chain}
    ets_read_or_refresh(key, [])
  end

  @impl true
  def init(_opts) do
    :ets.new(@cache_table, [:set, :named_table, :public, read_concurrency: true])
    Phoenix.PubSub.subscribe(Lasso.PubSub, "cluster:topology")
    schedule_cache_cleanup()

    node_count = get_topology_coverage().connected

    Logger.info("[MetricsStore] Started with #{node_count} nodes")

    {:ok, %__MODULE__{last_known_node_count: node_count}}
  end

  defp schedule_cache_cleanup do
    Process.send_after(self(), :cleanup_cache, @cache_cleanup_interval_ms)
  end

  # Cast-based refresh: no closures, derives fetch function from key
  @impl true
  def handle_cast({:maybe_refresh, key}, state) do
    if MapSet.member?(state.refreshing, key) do
      {:noreply, state}
    else
      parent = self()
      gen = state.generation

      {:ok, pid} =
        Task.Supervisor.start_child(Lasso.TaskSupervisor, fn ->
          try do
            {data, coverage} = fetch_fn_for_key(key)
            send(parent, {:refresh_complete, gen, key, data, coverage})
          catch
            kind, reason ->
              send(parent, {:refresh_failed, gen, key, {kind, reason}})
          end
        end)

      ref = Process.monitor(pid)

      {:noreply,
       %{
         state
         | refreshing: MapSet.put(state.refreshing, key),
           task_keys: Map.put(state.task_keys, ref, key)
       }}
    end
  end

  # Topology events - invalidate cache on node changes
  @impl true
  def handle_info({:topology_event, %{event: event}}, state)
      when event in [:node_connected, :node_disconnected] do
    Logger.debug("[MetricsStore] Cache invalidated due to #{event}")
    emit_cache_telemetry(:invalidated, event)
    :ets.delete_all_objects(@cache_table)

    {:noreply,
     %{state | refreshing: MapSet.new(), task_keys: %{}, generation: state.generation + 1}}
  end

  def handle_info({:topology_event, _}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:refresh_complete, gen, key, data, coverage}, state) do
    if gen == state.generation do
      now = System.monotonic_time(:millisecond)
      :ets.insert(@cache_table, {key, data, coverage, now})

      Phoenix.PubSub.broadcast(
        Lasso.PubSub,
        "metrics_store:cache_warmed",
        {:cache_warmed, key}
      )
    end

    {:noreply, %{state | refreshing: MapSet.delete(state.refreshing, key)}}
  end

  @impl true
  def handle_info({:refresh_failed, gen, key, reason}, state) do
    if gen == state.generation do
      Logger.warning("[MetricsStore] Refresh failed for #{inspect(key)}: #{inspect(reason)}")
    end

    {:noreply, %{state | refreshing: MapSet.delete(state.refreshing, key)}}
  end

  # Task crashed without sending completion — clean up refreshing set
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.task_keys, ref) do
      {nil, _task_keys} ->
        {:noreply, state}

      {key, task_keys} ->
        {:noreply,
         %{state | refreshing: MapSet.delete(state.refreshing, key), task_keys: task_keys}}
    end
  end

  @impl true
  def handle_info(:cleanup_cache, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @cache_max_age_ms

    # ETS rows: {key, data, coverage, cached_at}
    match_spec = [{{:_, :_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}]

    try do
      :ets.select_delete(@cache_table, match_spec)
    rescue
      _ -> :ok
    end

    schedule_cache_cleanup()
    {:noreply, state}
  end

  defp read_cache(key) do
    case :ets.lookup(@cache_table, key) do
      [{^key, data, coverage, cached_at}] ->
        stale = System.monotonic_time(:millisecond) - cached_at >= @cache_ttl_ms
        %{data: data, coverage: coverage, cached_at: cached_at, stale: stale}

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  defp ets_read_or_refresh(key, empty_default) do
    case read_cache(key) do
      %{stale: false} = result ->
        emit_cache_telemetry(:hit, key)
        result

      %{stale: true} = result ->
        emit_cache_telemetry(:stale, key)
        GenServer.cast(__MODULE__, {:maybe_refresh, key})
        result

      nil ->
        emit_cache_telemetry(:miss, key)
        GenServer.cast(__MODULE__, {:maybe_refresh, key})

        %{
          data: empty_default,
          coverage: %{responding: 0, total: 0},
          cached_at: nil,
          stale: false,
          loading: true
        }
    end
  end

  defp fetch_fn_for_key({:provider_leaderboard, profile, chain}) do
    fetch_from_cluster(
      Lasso.Benchmarking.BenchmarkStore,
      :get_provider_leaderboard,
      [profile, chain]
    )
  end

  defp fetch_fn_for_key({:realtime_stats, profile, chain}) do
    fetch_from_cluster(
      Lasso.Benchmarking.BenchmarkStore,
      :get_realtime_stats,
      [profile, chain]
    )
  end

  defp fetch_fn_for_key({:method_perf, profile, chain, provider_id, method}) do
    fetch_from_cluster(
      Lasso.Benchmarking.BenchmarkStore,
      :get_rpc_method_performance_with_percentiles,
      [profile, chain, provider_id, method]
    )
  end

  defp fetch_fn_for_key({:bulk_method_perf, profile, chain}) do
    fetch_from_cluster(
      Lasso.Benchmarking.BenchmarkStore,
      :get_all_method_performance,
      [profile, chain]
    )
  end

  @doc false
  def fetch_from_cluster(module, function, args) do
    remote_nodes = get_responding_nodes()
    nodes = [node() | remote_nodes] |> Enum.uniq()

    start_time = System.monotonic_time(:millisecond)

    {results, bad_nodes} = :rpc.multicall(nodes, module, function, args, @refresh_timeout_ms)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    valid_results = Enum.reject(results, &match?({:badrpc, _}, &1))

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

  @doc false
  def aggregate_results(:get_provider_leaderboard, results) do
    results
    |> List.flatten()
    |> Enum.group_by(& &1.provider_id)
    |> Enum.map(fn {provider_id, entries} ->
      sufficient = Enum.filter(entries, &(Map.get(&1, :total_calls, 0) >= @min_calls_threshold))

      if sufficient == [] do
        total_calls = sum_calls(entries)

        %{
          provider_id: provider_id,
          score: 0.0,
          total_calls: total_calls,
          success_rate: weighted_average(entries, :success_rate, total_calls),
          avg_latency_ms: weighted_average(entries, :avg_latency_ms, total_calls),
          node_count: length(entries),
          cold_start: true,
          latency_by_node: build_latency_by_node(entries)
        }
      else
        aggregate_provider_entries(provider_id, sufficient, entries)
      end
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  @doc false
  def aggregate_results(:get_realtime_stats, results) do
    valid_results = Enum.reject(results, &is_nil/1)

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
        single
        |> Map.put(:node_count, 1)
        |> Map.put(:stats_by_node, [build_node_stat(single)])

      multiple ->
        aggregate_method_performance(multiple)
    end
  end

  @doc false
  def aggregate_results(:get_all_method_performance, results) do
    results
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(fn entry -> {entry.provider_id, entry.method} end)
    |> Enum.map(fn {{provider_id, method}, entries} ->
      entries_for_avg = filter_by_threshold(entries)
      total_calls = sum_calls(entries_for_avg)
      best_node = Enum.max_by(entries_for_avg, &Map.get(&1, :total_calls, 0), fn -> nil end)

      %{
        provider_id: provider_id,
        method: method,
        success_rate: weighted_average(entries_for_avg, :success_rate, total_calls),
        total_calls: total_calls,
        avg_duration_ms: weighted_average(entries_for_avg, :avg_duration_ms, total_calls),
        percentiles: if(best_node, do: Map.get(best_node, :percentiles, %{}), else: %{}),
        node_count: length(entries),
        stats_by_node: Enum.map(entries, &build_node_stat/1)
      }
    end)
  end

  @doc false
  def aggregate_results(_function, results) do
    List.first(results)
  end

  @doc false
  def aggregate_provider_entries(provider_id, entries_for_aggregates, all_entries) do
    total_calls = sum_calls(entries_for_aggregates)

    %{
      provider_id: provider_id,
      score: weighted_average(entries_for_aggregates, :score, total_calls),
      total_calls: total_calls,
      success_rate: weighted_average(entries_for_aggregates, :success_rate, total_calls),
      avg_latency_ms: weighted_average(entries_for_aggregates, :avg_latency_ms, total_calls),
      node_count: length(all_entries),
      latency_by_node: build_latency_by_node(all_entries)
    }
  end

  defp build_latency_by_node(entries) do
    Map.new(entries, fn entry ->
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
  end

  defp build_node_stat(entry) do
    %{
      node_id: Map.get(entry, :source_node_id) || "unidentified",
      node: Map.get(entry, :source_node),
      avg_duration_ms: Map.get(entry, :avg_duration_ms),
      success_rate: Map.get(entry, :success_rate),
      total_calls: Map.get(entry, :total_calls, 0),
      percentiles: Map.get(entry, :percentiles, %{})
    }
  end

  defp filter_by_threshold(entries) do
    case Enum.filter(entries, &(Map.get(&1, :total_calls, 0) >= @min_calls_threshold)) do
      [] -> entries
      filtered -> filtered
    end
  end

  defp sum_calls(entries) do
    Enum.reduce(entries, 0, fn entry, acc -> acc + Map.get(entry, :total_calls, 0) end)
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
    base_results = filter_by_threshold(results)
    total_calls = sum_calls(base_results)
    first = List.first(base_results)

    %{
      provider_id: Map.get(first, :provider_id),
      method: Map.get(first, :method),
      success_rate: weighted_average(base_results, :success_rate, total_calls),
      total_calls: total_calls,
      avg_duration_ms: weighted_average(base_results, :avg_duration_ms, total_calls),
      percentiles: Map.get(first, :percentiles, %{}),
      node_count: length(results),
      stats_by_node: Enum.map(results, &build_node_stat/1)
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
end

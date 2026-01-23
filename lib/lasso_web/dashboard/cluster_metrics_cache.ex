defmodule LassoWeb.Dashboard.ClusterMetricsCache do
  @moduledoc """
  Caches aggregated metrics from all cluster nodes.

  Uses a stale-while-revalidate pattern: returns cached data immediately
  while triggering a background refresh when TTL expires. This prevents
  dashboard latency spikes from blocking RPC calls across the cluster.

  Coverage metadata is included with all responses to indicate how many
  nodes contributed to the aggregated data.
  """
  use GenServer
  require Logger

  @cache_ttl_ms 15_000
  @refresh_timeout_ms 5_000

  @type coverage :: %{
          responding: non_neg_integer(),
          total: non_neg_integer(),
          nodes: [node()],
          bad_nodes: [node()]
        }

  @type cached_result(t) :: %{
          data: t,
          coverage: coverage(),
          cached_at: integer(),
          stale: boolean()
        }

  # Client API

  def start_link(opts) do
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

  @doc """
  Returns current cluster coverage info without fetching new data.
  """
  @spec get_cluster_coverage() :: coverage()
  def get_cluster_coverage do
    nodes = [node() | Node.list()]

    %{
      responding: length(nodes),
      total: length(nodes),
      nodes: nodes,
      bad_nodes: []
    }
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    {:ok, %{cache: %{}, refreshing: MapSet.new()}}
  end

  @impl true
  def handle_call({:get_or_fetch, key, fetch_fn}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.cache, key) do
      %{cached_at: cached_at, data: data, coverage: coverage}
      when now - cached_at < @cache_ttl_ms ->
        # Fresh cache hit
        emit_cache_telemetry(:hit, key)

        result = %{
          data: data,
          coverage: coverage,
          cached_at: cached_at,
          stale: false
        }

        {:reply, result, state}

      %{data: data, coverage: coverage, cached_at: cached_at} ->
        # Stale cache - return stale data and trigger background refresh
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
        # Cache miss - fetch synchronously
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
    Logger.warning("Cluster metrics refresh failed for #{inspect(key)}: #{inspect(reason)}")
    new_refreshing = MapSet.delete(state.refreshing, key)
    {:noreply, %{state | refreshing: new_refreshing}}
  end

  # Private helpers

  defp get_cached_or_fetch(key, fetch_fn) do
    GenServer.call(__MODULE__, {:get_or_fetch, key, fetch_fn}, @refresh_timeout_ms + 1_000)
  catch
    :exit, {:timeout, _} ->
      # On timeout, return empty result with degraded coverage
      %{
        data: nil,
        coverage: %{responding: 0, total: 1, nodes: [], bad_nodes: [node()]},
        cached_at: 0,
        stale: true
      }
  end

  defp maybe_trigger_refresh(state, key, fetch_fn) do
    if MapSet.member?(state.refreshing, key) do
      # Already refreshing
      state
    else
      # Start background refresh
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
    nodes = [node() | Node.list()]
    start_time = System.monotonic_time(:millisecond)

    {results, bad_nodes} =
      :rpc.multicall(nodes, module, function, args, @refresh_timeout_ms)

    duration_ms = System.monotonic_time(:millisecond) - start_time

    # Filter out {:badrpc, reason} tuples from failed nodes
    valid_results =
      results
      |> Enum.reject(&match?({:badrpc, _}, &1))

    coverage = %{
      responding: length(valid_results),
      total: length(nodes),
      nodes: nodes -- bad_nodes,
      bad_nodes: bad_nodes
    }

    # Extract profile and chain from args for telemetry
    {profile, chain} = extract_telemetry_context(args)
    emit_rpc_telemetry(profile, chain, length(nodes), length(bad_nodes), duration_ms)

    aggregated = aggregate_results(function, valid_results)

    {aggregated, coverage}
  end

  defp aggregate_results(:get_provider_leaderboard, results) do
    # Merge provider leaderboards by provider_id, averaging scores
    results
    |> List.flatten()
    |> Enum.group_by(& &1.provider_id)
    |> Enum.map(fn {provider_id, entries} ->
      avg_score =
        entries
        |> Enum.map(& &1.score)
        |> Enum.sum()
        |> Kernel./(length(entries))

      %{
        provider_id: provider_id,
        score: avg_score,
        node_count: length(entries)
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp aggregate_results(:get_realtime_stats, results) do
    # Merge realtime stats, summing counts and averaging rates
    results
    |> Enum.reduce(%{rpc_methods: [], total_calls: 0}, fn
      nil, acc ->
        acc

      stats, acc ->
        %{
          rpc_methods: Enum.uniq(acc.rpc_methods ++ Map.get(stats, :rpc_methods, [])),
          total_calls: acc.total_calls + Map.get(stats, :total_calls, 0)
        }
    end)
  end

  defp aggregate_results(:get_rpc_method_performance_with_percentiles, results) do
    # Return first non-nil result (these are already per-provider stats)
    Enum.find(results, & &1)
  end

  defp aggregate_results(_function, results) do
    # Default: return first result
    List.first(results)
  end

  defp emit_cache_telemetry(result, key) do
    {profile, chain} = extract_cache_key_context(key)

    :telemetry.execute(
      [:lasso_web, :dashboard, :cache],
      %{count: 1},
      %{result: result, profile: profile, chain: chain}
    )
  end

  defp emit_rpc_telemetry(profile, chain, node_count, bad_count, duration_ms) do
    :telemetry.execute(
      [:lasso_web, :dashboard, :cluster_rpc],
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

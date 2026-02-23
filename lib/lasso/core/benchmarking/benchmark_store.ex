defmodule Lasso.Benchmarking.BenchmarkStore do
  @moduledoc """
  Manages RPC performance benchmarking data for providers using ETS tables.

  This module provides performance benchmarking by tracking:
  - RPC call latency and success rates for different methods
  - Provider performance history for intelligent routing decisions

  Data is stored in per-chain ETS tables with automatic cleanup to manage memory usage.
  Keeps detailed metrics for 24 hours with periodic cleanup.

  Provider selection is based on method-specific latency and success rate metrics
  """

  use GenServer
  require Logger

  @type profile :: String.t()
  @type chain_name :: String.t()
  @type provider_id :: String.t()
  @type method :: String.t()
  @type result :: :success | :error | :timeout | :network_error | :rate_limit | atom()

  # ~1 entry per second for 24 hours
  @max_entries_per_chain 86_400
  # 1 hour in milliseconds
  @cleanup_interval 3_600_000
  @table_limits_interval 10_000

  @doc """
  Starts the BenchmarkStore GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the provider leaderboard for a profile and chain showing RPC performance.

  Returns a list of providers sorted by average latency and success rate.
  """
  @spec get_provider_leaderboard(profile(), chain_name()) :: [map()]
  def get_provider_leaderboard(profile, chain_name) do
    GenServer.call(__MODULE__, {:get_provider_leaderboard, profile, chain_name})
  end

  @doc """
  Gets detailed metrics for a specific provider on a chain within a profile.
  """
  @spec get_provider_metrics(profile(), chain_name(), provider_id()) :: map()
  def get_provider_metrics(profile, chain_name, provider_id) do
    GenServer.call(__MODULE__, {:get_provider_metrics, profile, chain_name, provider_id})
  end

  @doc """
  Gets performance metrics for a specific RPC method across all providers in a profile.
  """
  @spec get_rpc_method_performance(profile(), chain_name(), method()) :: map()
  def get_rpc_method_performance(profile, chain_name, method) do
    GenServer.call(__MODULE__, {:get_rpc_method_performance, profile, chain_name, method})
  end

  @doc """
  Gets real-time benchmark statistics for dashboard display for a profile and chain.
  """
  @spec get_realtime_stats(profile(), chain_name()) :: map()
  def get_realtime_stats(profile, chain_name) do
    GenServer.call(__MODULE__, {:get_realtime_stats, profile, chain_name})
  end

  @doc """
  Manually triggers cleanup of old entries for a profile and chain.
  """
  @spec cleanup_old_entries(profile(), chain_name()) :: :ok
  def cleanup_old_entries(profile, chain_name) do
    GenServer.cast(__MODULE__, {:cleanup_old_entries, profile, chain_name})
  end

  @doc """
  Creates an hourly snapshot of performance data for persistence for a profile and chain.
  """
  @spec create_hourly_snapshot(profile(), chain_name()) :: map()
  def create_hourly_snapshot(profile, chain_name) do
    GenServer.call(__MODULE__, {:create_hourly_snapshot, profile, chain_name})
  end

  @doc """
  Gets RPC method performance including percentiles for a provider in a profile.
  """
  @spec get_rpc_method_performance_with_percentiles(
          profile(),
          chain_name(),
          provider_id(),
          method()
        ) :: map() | nil
  def get_rpc_method_performance_with_percentiles(profile, chain_name, provider_id, method) do
    GenServer.call(
      __MODULE__,
      {:get_rpc_performance_with_percentiles, profile, chain_name, provider_id, method}
    )
  end

  @doc """
  Gets all method performance data for every provider on a chain within a profile.
  Returns a flat list of per-provider-method entries with percentiles and source metadata.
  """
  @spec get_all_method_performance(profile(), chain_name()) :: [map()]
  def get_all_method_performance(profile, chain_name) do
    GenServer.call(__MODULE__, {:get_all_method_performance, profile, chain_name})
  end

  @doc """
  Clears all metrics for a specific profile and chain.
  """
  @spec clear_chain_metrics(profile(), chain_name()) :: :ok
  def clear_chain_metrics(profile, chain_name) do
    GenServer.call(__MODULE__, {:clear_chain_metrics, profile, chain_name})
  end

  @doc """
  Gets RPC performance metrics for a specific provider and method in a profile.
  """
  @spec get_rpc_performance(profile(), chain_name(), provider_id(), method()) :: map()
  def get_rpc_performance(profile, chain_name, provider_id, method) do
    GenServer.call(__MODULE__, {:get_rpc_performance, profile, chain_name, provider_id, method})
  end

  @doc """
  Gets error statistics for a specific provider and method in a profile.
  """
  @spec get_error_stats(profile(), chain_name(), provider_id(), method()) :: map()
  def get_error_stats(profile, chain_name, provider_id, method) do
    GenServer.call(__MODULE__, {:get_error_stats, profile, chain_name, provider_id, method})
  end

  @doc """
  Gets latency percentiles for a specific provider and method in a profile.
  """
  @spec get_latency_percentiles(profile(), chain_name(), provider_id(), method()) :: map()
  def get_latency_percentiles(profile, chain_name, provider_id, method) do
    GenServer.call(
      __MODULE__,
      {:get_latency_percentiles, profile, chain_name, provider_id, method}
    )
  end

  @doc """
  Gets the overall score for a provider on a chain within a profile.
  """
  @spec get_provider_score(profile(), chain_name(), provider_id()) :: float()
  def get_provider_score(profile, chain_name, provider_id) do
    GenServer.call(__MODULE__, {:get_provider_score, profile, chain_name, provider_id})
  end

  @doc """
  Gets hourly statistics for a provider and method in a profile.
  """
  @spec get_hourly_stats(profile(), chain_name(), provider_id(), method()) :: map()
  def get_hourly_stats(profile, chain_name, provider_id, method) do
    GenServer.call(__MODULE__, {:get_hourly_stats, profile, chain_name, provider_id, method})
  end

  @doc """
  Gets recent RPC calls for display for a profile and chain.
  """
  @spec get_recent_calls(profile(), chain_name(), non_neg_integer()) :: [map()]
  def get_recent_calls(profile, chain_name, limit \\ 10) do
    GenServer.call(__MODULE__, {:get_recent_calls, profile, chain_name, limit})
  end

  @doc """
  Cleans up old metrics across all profiles and chains.
  """
  @spec cleanup_old_metrics() :: :ok
  def cleanup_old_metrics do
    GenServer.cast(__MODULE__, :cleanup_old_metrics)
  end

  @doc """
  Gets chain-wide statistics for a profile and chain.
  """
  @spec get_chain_wide_stats(profile(), chain_name()) :: map()
  def get_chain_wide_stats(profile, chain_name) do
    GenServer.call(__MODULE__, {:get_chain_wide_stats, profile, chain_name})
  end

  @doc """
  Gets real-time statistics for a provider in a profile.
  """
  @spec get_real_time_stats(profile(), chain_name(), provider_id()) :: map()
  def get_real_time_stats(profile, chain_name, provider_id) do
    GenServer.call(__MODULE__, {:get_real_time_stats, profile, chain_name, provider_id})
  end

  @doc """
  Detects performance anomalies for a provider in a profile.
  """
  @spec detect_performance_anomalies(profile(), chain_name(), provider_id()) :: [map()]
  def detect_performance_anomalies(profile, chain_name, provider_id) do
    GenServer.call(__MODULE__, {:detect_performance_anomalies, profile, chain_name, provider_id})
  end

  @doc """
  Creates a performance snapshot for a profile and chain.
  """
  @spec create_performance_snapshot(profile(), chain_name()) :: map()
  def create_performance_snapshot(profile, chain_name) do
    GenServer.call(__MODULE__, {:create_performance_snapshot, profile, chain_name})
  end

  @doc """
  Gets historical performance data for a profile and chain.
  """
  @spec get_historical_performance(profile(), chain_name(), non_neg_integer()) :: list()
  def get_historical_performance(profile, chain_name, hours) do
    GenServer.call(__MODULE__, {:get_historical_performance, profile, chain_name, hours})
  end

  @doc """
  Gets memory usage statistics.
  """
  @spec get_memory_usage() :: map()
  def get_memory_usage do
    GenServer.call(__MODULE__, :get_memory_usage)
  end

  @doc """
  Returns call counts per provider within the specified time window.

  Used for RPS calculation in cluster metrics aggregation. Uses ETS match spec
  for efficient querying without full table scan.

  ## Parameters
    - `profile`: The routing profile name
    - `chain_name`: The blockchain name
    - `window_seconds`: Time window in seconds (default: 60)

  ## Returns
    Map of provider_id to call count: `%{String.t() => non_neg_integer()}`

  ## Examples

      iex> BenchmarkStore.get_calls_in_window("default", "ethereum", 60)
      %{"infura" => 150, "alchemy" => 200}
  """
  @spec get_calls_in_window(profile(), chain_name(), pos_integer()) :: %{
          String.t() => non_neg_integer()
        }
  def get_calls_in_window(profile, chain_name, window_seconds \\ 60) do
    GenServer.call(__MODULE__, {:get_calls_in_window, profile, chain_name, window_seconds})
  end

  @doc """
  Records an RPC call performance metric with dual timestamps.

  Timestamps are captured at the moment this function is called, ensuring
  monotonic and system timestamps are synchronized. This makes the API
  simple and impossible to misuse.

  ## Parameters
    - `profile`: The routing profile name
    - `chain_name`: The blockchain name
    - `provider_id`: Unique provider identifier
    - `method`: The RPC method called
    - `duration_ms`: Response time in milliseconds
    - `result`: `:success` or `:error`

  ## Examples

      iex> BenchmarkStore.record_rpc_call("default", "ethereum", "infura_provider", "eth_getLogs", 150, :success)
      :ok
  """
  @spec record_rpc_call(profile(), chain_name(), provider_id(), method(), number(), result()) ::
          :ok
  def record_rpc_call(profile, chain_name, provider_id, method, duration_ms, result) do
    monotonic_ts = System.monotonic_time(:millisecond)
    system_ts = System.system_time(:millisecond)

    GenServer.cast(
      __MODULE__,
      {:record_rpc_call, profile, chain_name, provider_id, method, duration_ms, result,
       monotonic_ts, system_ts}
    )
  end

  @impl true
  def init(_opts) do
    schedule_cleanup()
    schedule_table_limits_check()

    state = %{
      rpc_tables: %{},
      score_tables: %{},
      profile_chains: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_cast(
        {:record_rpc_call, profile, chain_name, provider_id, method, duration_ms, result,
         monotonic_ts, system_ts},
        state
      ) do
    new_state = ensure_tables_exist(state, profile, chain_name)

    rpc_table = rpc_table_name(profile, chain_name)
    score_table = score_table_name(profile, chain_name)

    :ets.insert(rpc_table, {monotonic_ts, system_ts, provider_id, method, duration_ms, result})

    update_rpc_scores(
      score_table,
      provider_id,
      method,
      duration_ms,
      result,
      monotonic_ts,
      system_ts
    )

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:cleanup_old_entries, profile, chain_name}, state) do
    Logger.info("Cleaning up old benchmark entries for profile: #{profile}, chain: #{chain_name}")

    key = {profile, chain_name}

    cutoff_time = System.monotonic_time(:millisecond) - 24 * 60 * 60 * 1000

    if Map.has_key?(state.rpc_tables, key) do
      rpc_table = rpc_table_name(profile, chain_name)
      cleanup_rpc_table_by_monotonic_timestamp(rpc_table, cutoff_time)
    end

    if Map.has_key?(state.score_tables, key) do
      score_table = score_table_name(profile, chain_name)
      cleanup_score_table_by_monotonic_timestamp(score_table, cutoff_time)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:cleanup_old_metrics, state) do
    Logger.info("Cleaning up old metrics across all profiles and chains")

    Enum.each(state.profile_chains, fn {profile, chains} ->
      Enum.each(chains, fn chain_name ->
        GenServer.cast(__MODULE__, {:cleanup_old_entries, profile, chain_name})
      end)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call({:get_provider_leaderboard, profile, chain_name}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.score_tables, key) do
        calculate_leaderboard(profile, chain_name)
      else
        []
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_provider_metrics, profile, chain_name, provider_id}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.score_tables, key) do
        get_detailed_provider_metrics(profile, chain_name, provider_id)
      else
        %{}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_rpc_method_performance, profile, chain_name, method}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.rpc_tables, key) do
        get_rpc_performance_stats(profile, chain_name, method)
      else
        %{}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_realtime_stats, profile, chain_name}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.score_tables, key) do
        get_realtime_benchmark_stats(profile, chain_name)
      else
        %{providers: [], rpc_methods: [], total_entries: 0, last_updated: 0}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_all_method_performance, profile, chain_name}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.score_tables, key) do
        get_all_method_performance_data(profile, chain_name)
      else
        []
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:create_hourly_snapshot, profile, chain_name}, _from, state) do
    key = {profile, chain_name}

    snapshot =
      if Map.has_key?(state.score_tables, key) do
        snapshot_data = create_performance_snapshot_private(profile, chain_name)

        alias Lasso.Benchmarking.Persistence
        Persistence.save_snapshot(profile, chain_name, snapshot_data)

        snapshot_data
      else
        %{}
      end

    {:reply, snapshot, state}
  end

  @impl true
  def handle_call({:clear_chain_metrics, profile, chain_name}, _from, state) do
    key = {profile, chain_name}

    if Map.has_key?(state.rpc_tables, key) do
      rpc_table = rpc_table_name(profile, chain_name)
      :ets.delete(rpc_table)
    end

    if Map.has_key?(state.score_tables, key) do
      score_table = score_table_name(profile, chain_name)
      :ets.delete(score_table)
    end

    profile_chains_set = Map.get(state.profile_chains, profile, MapSet.new())
    updated_profile_chains_set = MapSet.delete(profile_chains_set, chain_name)

    updated_profile_chains =
      if MapSet.size(updated_profile_chains_set) == 0 do
        Map.delete(state.profile_chains, profile)
      else
        Map.put(state.profile_chains, profile, updated_profile_chains_set)
      end

    new_state = %{
      state
      | rpc_tables: Map.delete(state.rpc_tables, key),
        score_tables: Map.delete(state.score_tables, key),
        profile_chains: updated_profile_chains
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get_rpc_performance, profile, chain_name, provider_id, method}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.score_tables, key) do
        score_table = score_table_name(profile, chain_name)
        lookup_key = {provider_id, method, :rpc}

        case :ets.lookup(score_table, lookup_key) do
          [{_key, successes, total, avg_duration, _samples, _mono_ts, sys_ts}] ->
            %{
              total_calls: total,
              success_calls: successes,
              error_calls: total - successes,
              success_rate: if(total > 0, do: successes / total, else: 0.0),
              avg_latency: avg_duration,
              last_updated_ms: sys_ts
            }

          [] ->
            %{
              total_calls: 0,
              success_calls: 0,
              error_calls: 0,
              success_rate: 0.0,
              avg_latency: 0,
              last_updated_ms: nil
            }
        end
      else
        %{
          total_calls: 0,
          success_calls: 0,
          error_calls: 0,
          success_rate: 0.0,
          avg_latency: 0,
          last_updated_ms: nil
        }
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_error_stats, profile, chain_name, provider_id, method}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.rpc_tables, key) do
        rpc_table = rpc_table_name(profile, chain_name)

        rpc_table
        |> :ets.tab2list()
        |> Enum.filter(fn {_, _, pid, m, _, result} ->
          pid == provider_id and m == method and result != :success
        end)
        |> Enum.reduce(
          %{timeout_count: 0, network_error_count: 0, rate_limit_count: 0},
          fn {_, _, _, _, _, result}, acc ->
            case result do
              :timeout -> %{acc | timeout_count: acc.timeout_count + 1}
              :network_error -> %{acc | network_error_count: acc.network_error_count + 1}
              :rate_limit -> %{acc | rate_limit_count: acc.rate_limit_count + 1}
              _ -> acc
            end
          end
        )
      else
        %{timeout_count: 0, network_error_count: 0, rate_limit_count: 0}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(
        {:get_latency_percentiles, profile, chain_name, provider_id, method},
        _from,
        state
      ) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.rpc_tables, key) do
        rpc_table = rpc_table_name(profile, chain_name)

        latencies =
          rpc_table
          |> :ets.tab2list()
          |> Enum.filter(fn {_, _, pid, m, duration, result} ->
            pid == provider_id and m == method and result == :success and duration > 0
          end)
          |> Enum.map(fn {_, _, _, _, duration, _} -> duration end)
          |> Enum.sort()

        calculate_percentiles(latencies)
      else
        %{p50: 0, p90: 0, p99: 0}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_provider_score, profile, chain_name, provider_id}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.score_tables, key) do
        score_table = score_table_name(profile, chain_name)

        rpc_entries =
          score_table
          |> :ets.tab2list()
          |> Enum.filter(fn {{pid, _, type}, _, _, _, _, _, _} ->
            pid == provider_id and type == :rpc
          end)

        if rpc_entries != [] do
          {total_successes, total_calls, weighted_avg_latency} =
            Enum.reduce(rpc_entries, {0, 0, 0.0}, fn
              {{_, _, _}, successes, total, avg_duration, _, _, _},
              {acc_successes, acc_total, acc_latency} ->
                {acc_successes + successes, acc_total + total, acc_latency + avg_duration * total}
            end)

          success_rate = if total_calls > 0, do: total_successes / total_calls, else: 0.0
          avg_latency = if total_calls > 0, do: weighted_avg_latency / total_calls, else: 0.0

          calculate_rpc_provider_score(success_rate, avg_latency, total_calls)
        else
          0.0
        end
      else
        0.0
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_hourly_stats, profile, chain_name, provider_id, method}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.rpc_tables, key) do
        rpc_table = rpc_table_name(profile, chain_name)
        current_hour = div(System.system_time(:second), 3600) * 3600
        hour_ago = current_hour - 3600

        hourly_calls =
          rpc_table
          |> :ets.tab2list()
          |> Enum.filter(fn {_monotonic_ts, system_ts, pid, m, _duration, _result} ->
            pid == provider_id and m == method and system_ts >= hour_ago
          end)

        if length(hourly_calls) > 0 do
          successful_calls =
            Enum.filter(hourly_calls, fn {_monotonic_ts, _system_ts, _pid, _m, _duration, result} ->
              result == :success
            end)

          total_calls = length(hourly_calls)
          success_rate = length(successful_calls) / total_calls

          avg_latency =
            successful_calls
            |> Enum.map(fn {_monotonic_ts, _system_ts, _pid, _m, duration, _result} ->
              duration
            end)
            |> Enum.filter(&(&1 > 0))
            |> then(fn
              [] -> 0
              latencies -> Enum.sum(latencies) / length(latencies)
            end)

          %{
            total_calls: total_calls,
            success_rate: success_rate,
            avg_latency: avg_latency,
            hour_start: hour_ago,
            hour_end: current_hour
          }
        else
          %{
            total_calls: 0,
            success_rate: 0.0,
            avg_latency: 0,
            hour_start: hour_ago,
            hour_end: current_hour
          }
        end
      else
        %{total_calls: 0, success_rate: 0.0, avg_latency: 0, hour_start: 0, hour_end: 0}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_recent_calls, profile, chain_name, limit}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.rpc_tables, key) do
        rpc_table = rpc_table_name(profile, chain_name)
        current_time = System.system_time(:millisecond)
        lookback = current_time - 30_000

        match_spec = [
          {{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6"}, [{:>, :"$2", lookback}], [:"$_"]}
        ]

        try do
          :ets.select(rpc_table, match_spec)
          |> Enum.sort_by(fn {_monotonic_ts, system_ts, _, _, _, _} -> system_ts end, :desc)
          |> Enum.take(limit)
          |> Enum.map(fn {_monotonic_ts, _system_ts, pid, method, latency, _result} ->
            color =
              cond do
                latency < 50 -> "text-emerald-300"
                latency < 100 -> "text-yellow-300"
                true -> "text-red-300"
              end

            %{
              method: method,
              provider: pid,
              latency: latency,
              color: color
            }
          end)
        rescue
          _ -> []
        end
      else
        []
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_chain_wide_stats, profile, chain_name}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.score_tables, key) do
        score_table = score_table_name(profile, chain_name)

        rpc_entries =
          score_table
          |> :ets.tab2list()
          |> Enum.filter(fn {{_pid, _key, type}, _, _, _, _, _, _} -> type == :rpc end)

        {total_calls, total_successes, provider_set} =
          Enum.reduce(rpc_entries, {0, 0, MapSet.new()}, fn
            {{pid, _, _}, successes, total, _, _, _, _}, {acc_total, acc_successes, providers} ->
              {acc_total + total, acc_successes + successes, MapSet.put(providers, pid)}
          end)

        overall_success_rate = if total_calls > 0, do: total_successes / total_calls, else: 0.0

        %{
          total_calls: total_calls,
          total_successes: total_successes,
          overall_success_rate: overall_success_rate,
          total_providers: MapSet.size(provider_set)
        }
      else
        %{total_calls: 0, total_successes: 0, overall_success_rate: 0.0, total_providers: 0}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_real_time_stats, profile, chain_name, provider_id}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.score_tables, key) do
        score_table = score_table_name(profile, chain_name)

        rpc_stats =
          score_table
          |> :ets.tab2list()
          |> Enum.filter(fn {{pid, _, type}, _, _, _, _, _, _} ->
            pid == provider_id and type == :rpc
          end)
          |> Enum.map(fn {{_, method, _}, successes, total, avg_duration, _, _, last_updated} ->
            %{
              method: method,
              successes: successes,
              total_calls: total,
              success_rate: if(total > 0, do: successes / total, else: 0.0),
              avg_duration_ms: avg_duration,
              last_updated: last_updated
            }
          end)

        current_time = System.system_time(:millisecond)
        minute_ago = current_time - 60_000

        calls_last_minute =
          if Map.has_key?(state.rpc_tables, key) do
            rpc_table = rpc_table_name(profile, chain_name)

            rpc_table
            |> :ets.tab2list()
            |> Enum.filter(fn {_monotonic_ts, system_ts, pid, _method, _duration, _result} ->
              pid == provider_id and system_ts >= minute_ago
            end)
            |> length()
          else
            0
          end

        %{
          provider_id: provider_id,
          rpc_stats: rpc_stats,
          calls_last_minute: calls_last_minute,
          last_updated: System.system_time(:millisecond)
        }
      else
        %{
          provider_id: provider_id,
          rpc_stats: [],
          calls_last_minute: 0,
          last_updated: 0
        }
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:detect_performance_anomalies, profile, chain_name, provider_id}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.score_tables, key) do
        score_table = score_table_name(profile, chain_name)

        score_table
        |> :ets.tab2list()
        |> Enum.filter(fn {{pid, _, type}, _, _, _, _, _, _} ->
          pid == provider_id and type == :rpc
        end)
        |> Enum.reduce([], fn {{_, method, _}, successes, total, avg_duration, _, _, _}, acc ->
          success_rate = if total > 0, do: successes / total, else: 0.0

          cond do
            success_rate < 0.95 ->
              [
                %{
                  method: method,
                  success_rate: success_rate,
                  avg_duration_ms: avg_duration,
                  anomaly_type: :low_success_rate
                }
                | acc
              ]

            avg_duration > 1000 ->
              [
                %{
                  method: method,
                  success_rate: success_rate,
                  avg_duration_ms: avg_duration,
                  anomaly_type: :high_latency
                }
                | acc
              ]

            true ->
              acc
          end
        end)
      else
        []
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:create_performance_snapshot, profile, chain_name}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.score_tables, key) do
        create_performance_snapshot_private(profile, chain_name)
      else
        %{}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_historical_performance, profile, chain_name, _hours}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.score_tables, key) do
        score_table = score_table_name(profile, chain_name)
        :ets.tab2list(score_table)
      else
        []
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_memory_usage, _from, state) do
    total_size =
      state.rpc_tables
      |> Map.keys()
      |> Enum.map(fn key ->
        rpc_size = :ets.info(Map.get(state.rpc_tables, key), :size) || 0
        score_size = :ets.info(Map.get(state.score_tables, key), :size) || 0
        rpc_size + score_size
      end)
      |> Enum.sum()

    profile_count = map_size(state.profile_chains)

    result = %{
      total_entries: total_size,
      chains_tracked: profile_count,
      memory_mb: total_size * 0.001,
      memory_estimate_mb: total_size * 0.001
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_calls_in_window, profile, chain_name, window_seconds}, _from, state) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.rpc_tables, key) do
        rpc_table = rpc_table_name(profile, chain_name)
        cutoff = System.monotonic_time(:millisecond) - window_seconds * 1_000

        match_spec = [
          {
            {:"$1", :_, :"$2", :_, :_, :_},
            [{:>, :"$1", cutoff}],
            [:"$2"]
          }
        ]

        case :ets.info(rpc_table) do
          :undefined ->
            %{}

          _ ->
            :ets.select(rpc_table, match_spec)
            |> Enum.frequencies()
        end
      else
        %{}
      end

    {:reply, result, state}
  rescue
    ArgumentError -> {:reply, %{}, state}
  end

  @impl true
  def handle_call(
        {:get_rpc_performance_with_percentiles, profile, chain_name, provider_id, method},
        _from,
        state
      ) do
    key = {profile, chain_name}

    result =
      if Map.has_key?(state.score_tables, key) do
        get_rpc_performance_with_percentiles_data(profile, chain_name, provider_id, method)
      else
        nil
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:cleanup_all_chains, state) do
    Logger.debug("Running periodic cleanup for all benchmark tables")

    Enum.each(state.profile_chains, fn {profile, chains} ->
      Enum.each(chains, fn chain_name ->
        snapshot = create_performance_snapshot_private(profile, chain_name)
        alias Lasso.Benchmarking.Persistence
        Persistence.save_snapshot(profile, chain_name, snapshot)
      end)
    end)

    Enum.each(state.profile_chains, fn {profile, chains} ->
      Enum.each(chains, fn chain_name ->
        GenServer.cast(__MODULE__, {:cleanup_old_entries, profile, chain_name})
      end)
    end)

    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(:enforce_table_limits, state) do
    Enum.each(state.rpc_tables, fn {_key, rpc_table} ->
      enforce_table_limits(rpc_table)
    end)

    schedule_table_limits_check()
    {:noreply, state}
  end

  defp get_rpc_performance_with_percentiles_data(profile, chain_name, provider_id, method) do
    score_table = score_table_name(profile, chain_name)
    key = {provider_id, method, :rpc}

    case :ets.lookup(score_table, key) do
      [{_key, successes, total, avg_duration, recent_latencies, _mono_ts, sys_ts}] ->
        build_method_performance_entry(
          provider_id,
          method,
          successes,
          total,
          avg_duration,
          recent_latencies,
          sys_ts
        )

      [] ->
        nil
    end
  end

  defp get_all_method_performance_data(profile, chain_name) do
    score_table = score_table_name(profile, chain_name)

    score_table
    |> :ets.tab2list()
    |> Enum.filter(fn {{_provider_id, _method, type}, _, _, _, _, _, _} -> type == :rpc end)
    |> Enum.map(fn {{provider_id, method, _type}, successes, total, avg_duration,
                    recent_latencies, _monotonic_updated, sys_ts} ->
      build_method_performance_entry(
        provider_id,
        method,
        successes,
        total,
        avg_duration,
        recent_latencies,
        sys_ts
      )
    end)
  end

  defp build_method_performance_entry(
         provider_id,
         method,
         successes,
         total,
         avg_duration,
         recent_latencies,
         sys_ts
       ) do
    %{
      provider_id: provider_id,
      method: method,
      success_rate: if(total > 0, do: successes / total, else: 0.0),
      total_calls: total,
      avg_duration_ms: avg_duration,
      percentiles: calculate_percentiles(recent_latencies),
      last_updated: sys_ts,
      source_node_id: Lasso.Cluster.Topology.self_node_id(),
      source_node: node()
    }
  end

  defp calculate_percentiles([]) do
    %{p50: 0, p90: 0, p95: 0, p99: 0}
  end

  defp calculate_percentiles([single]) do
    %{p50: single, p90: single, p95: single, p99: single}
  end

  defp calculate_percentiles(latencies) when is_list(latencies) do
    sorted = Enum.sort(latencies)
    count = length(sorted)

    p50_index = max(0, round(count * 0.5) - 1)
    p90_index = max(0, round(count * 0.9) - 1)
    p95_index = max(0, round(count * 0.95) - 1)
    p99_index = max(0, round(count * 0.99) - 1)

    %{
      p50: Enum.at(sorted, p50_index, 0),
      p90: Enum.at(sorted, p90_index, 0),
      p95: Enum.at(sorted, p95_index, 0),
      p99: Enum.at(sorted, p99_index, 0)
    }
  end

  defp create_performance_snapshot_private(profile, chain_name) do
    score_table = score_table_name(profile, chain_name)
    current_hour = div(System.system_time(:second), 3600) * 3600

    all_entries = :ets.tab2list(score_table)

    rpc_entries =
      Enum.filter(all_entries, fn {{_, _, type}, _, _, _, _, _, _} -> type == :rpc end)

    snapshot_data =
      Enum.map(rpc_entries, fn {{provider_id, method, _}, successes, total, avg_duration, _, _,
                                last_updated} ->
        %{
          profile: profile,
          chain_name: chain_name,
          provider_id: provider_id,
          hour_timestamp: current_hour,
          timestamp: current_hour,
          rpc_method: method,
          rpc_calls: total,
          rpc_avg_duration_ms: avg_duration,
          rpc_success_rate: if(total > 0, do: successes / total, else: 0.0),
          last_updated: last_updated
        }
      end)

    providers =
      all_entries
      |> Enum.map(fn {{provider_id, _, _}, _, _, _, _, _, _} -> provider_id end)
      |> Enum.uniq()

    %{
      profile: profile,
      chain_name: chain_name,
      hour_timestamp: current_hour,
      timestamp: current_hour,
      providers: providers,
      snapshot_data: snapshot_data
    }
  end

  defp ensure_tables_exist(state, profile, chain) do
    key = {profile, chain}

    if Map.has_key?(state.rpc_tables, key) do
      state
    else
      Logger.info("Creating benchmark tables for profile: #{profile}, chain: #{chain}")

      rpc_table = rpc_table_name(profile, chain)
      score_table = score_table_name(profile, chain)

      :ets.new(rpc_table, [:public, :named_table, :bag, :compressed])
      :ets.new(score_table, [:public, :named_table, :set, :compressed])

      profile_chains_set = Map.get(state.profile_chains, profile, MapSet.new())

      updated_profile_chains =
        Map.put(state.profile_chains, profile, MapSet.put(profile_chains_set, chain))

      %{
        state
        | rpc_tables: Map.put(state.rpc_tables, key, rpc_table),
          score_tables: Map.put(state.score_tables, key, score_table),
          profile_chains: updated_profile_chains
      }
    end
  end

  defp update_rpc_scores(
         score_table,
         provider_id,
         method,
         duration_ms,
         result,
         monotonic_ts,
         system_ts
       ) do
    key = {provider_id, method, :rpc}

    try do
      case :ets.lookup(score_table, key) do
        [] ->
          successes = if result == :success, do: 1, else: 0
          total = 1
          avg_duration = if result == :success, do: duration_ms, else: 0

          recent_latencies =
            if result == :success and duration_ms > 0, do: [duration_ms], else: []

          :ets.insert(
            score_table,
            {key, successes, total, avg_duration, recent_latencies, monotonic_ts, system_ts}
          )

        [
          {_key, successes, total, avg_duration, recent_latencies, _monotonic_last_updated,
           _system_last_updated}
        ] ->
          new_successes = if result == :success, do: successes + 1, else: successes
          new_total = total + 1

          new_avg_duration =
            if result == :success do
              if successes == 0,
                do: duration_ms,
                else: (avg_duration * successes + duration_ms) / new_successes
            else
              avg_duration
            end

          updated_latencies =
            if result == :success and duration_ms > 0,
              do: [duration_ms | recent_latencies] |> Enum.take(100),
              else: recent_latencies

          :ets.insert(
            score_table,
            {key, new_successes, new_total, new_avg_duration, updated_latencies, monotonic_ts,
             system_ts}
          )
      end
    rescue
      e ->
        Logger.error("Error updating RPC scores for #{inspect(key)}: #{inspect(e)}")
    catch
      :exit, reason ->
        Logger.error("RPC score table access error for #{inspect(key)}: #{inspect(reason)}")
    end
  end

  defp cleanup_rpc_table_by_monotonic_timestamp(table_name, cutoff_time) do
    match_spec = [
      {{:"$1", :_, :_, :_, :_, :_}, [{:<, :"$1", cutoff_time}], [true]}
    ]

    deleted = :ets.select_delete(table_name, match_spec)
    Logger.debug("Cleaned up #{deleted} old RPC entries from #{table_name}")
  rescue
    e -> Logger.error("Error during RPC table cleanup: #{inspect(e)}")
  end

  defp cleanup_score_table_by_monotonic_timestamp(score_table, cutoff_time) do
    match_spec = [
      {{:_, :_, :_, :_, :_, :"$1", :_}, [{:<, :"$1", cutoff_time}], [true]}
    ]

    deleted = :ets.select_delete(score_table, match_spec)
    Logger.debug("Cleaned up #{deleted} old score entries from #{score_table}")
  rescue
    e -> Logger.error("Error during score table cleanup: #{inspect(e)}")
  end

  defp calculate_leaderboard(profile, chain_name) do
    score_table = score_table_name(profile, chain_name)

    rpc_scores =
      score_table
      |> :ets.tab2list()
      |> Enum.filter(fn {{_, _, type}, _, _, _, _, _, _} -> type == :rpc end)
      |> Enum.group_by(fn {{provider_id, _, _}, _, _, _, _, _, _} -> provider_id end)

    Enum.map(rpc_scores, fn {provider_id, entries} ->
      {total_successes, total_calls, weighted_avg_latency, samples_acc} =
        Enum.reduce(entries, {0, 0, 0.0, []}, fn {{_pid, _method, _type}, successes, total,
                                                  avg_duration, samples, _monotonic_updated,
                                                  _system_updated},
                                                 {acc_successes, acc_total, acc_latency,
                                                  acc_samples} ->
          {acc_successes + successes, acc_total + total, acc_latency + avg_duration * total,
           [samples | acc_samples]}
        end)

      all_samples = List.flatten(samples_acc)

      success_rate = if total_calls > 0, do: total_successes / total_calls, else: 0.0
      avg_latency = if total_calls > 0, do: weighted_avg_latency / total_calls, else: 0.0

      percentiles = calculate_percentiles(all_samples)

      %{
        provider_id: provider_id,
        total_calls: total_calls,
        total_successes: total_successes,
        success_rate: success_rate,
        avg_latency_ms: avg_latency,
        p50_latency: percentiles.p50,
        p95_latency: percentiles.p95,
        p99_latency: percentiles.p99,
        score: calculate_rpc_provider_score(success_rate, avg_latency, total_calls),
        source_node_id: Lasso.Cluster.Topology.self_node_id(),
        source_node: node()
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp get_detailed_provider_metrics(profile, chain_name, provider_id) do
    score_table = score_table_name(profile, chain_name)

    rpc_metrics =
      score_table
      |> :ets.tab2list()
      |> Enum.filter(fn {{pid, _, type}, _, _, _, _, _, _} ->
        pid == provider_id and type == :rpc
      end)
      |> Enum.map(fn {{_pid, method, _type}, successes, total, avg_duration, _samples,
                      _monotonic_updated, last_updated} ->
        %{
          method: method,
          successes: successes,
          total_calls: total,
          success_rate: if(total > 0, do: successes / total, else: 0.0),
          avg_duration_ms: avg_duration,
          last_updated: last_updated
        }
      end)

    %{
      provider_id: provider_id,
      rpc_metrics: rpc_metrics
    }
  end

  defp get_rpc_performance_stats(profile, chain_name, method) do
    score_table = score_table_name(profile, chain_name)

    method_entries =
      score_table
      |> :ets.tab2list()
      |> Enum.filter(fn {{_, m, type}, _, _, _, _, _, _} ->
        type == :rpc and m == method
      end)

    provider_stats =
      Enum.map(method_entries, fn {{provider_id, _m, _type}, successes, total, avg_duration,
                                   _samples, _monotonic_updated, last_updated} ->
        %{
          provider_id: provider_id,
          successes: successes,
          total_calls: total,
          success_rate: if(total > 0, do: successes / total, else: 0.0),
          avg_duration_ms: avg_duration,
          last_updated: last_updated
        }
      end)
      |> Enum.sort_by(& &1.avg_duration_ms, :asc)

    %{
      method: method,
      providers: provider_stats
    }
  end

  defp get_realtime_benchmark_stats(profile, chain_name) do
    score_table = score_table_name(profile, chain_name)
    all_entries = :ets.tab2list(score_table)

    {providers, rpc_methods} =
      Enum.reduce(all_entries, {MapSet.new(), MapSet.new()}, fn
        {{provider_id, method, :rpc}, _, _, _, _, _, _}, {provs, methods} ->
          {MapSet.put(provs, provider_id), MapSet.put(methods, method)}

        {{provider_id, _method, _type}, _, _, _, _, _, _}, {provs, methods} ->
          {MapSet.put(provs, provider_id), methods}
      end)

    %{
      providers: MapSet.to_list(providers),
      rpc_methods: MapSet.to_list(rpc_methods),
      total_entries: length(all_entries),
      last_updated: System.system_time(:millisecond)
    }
  end

  defp calculate_rpc_provider_score(success_rate, avg_latency_ms, total_calls) do
    confidence_factor = :math.log10(max(total_calls, 1))
    latency_factor = if avg_latency_ms > 0, do: 1000 / (1000 + avg_latency_ms), else: 1.0
    success_rate * latency_factor * confidence_factor
  end

  # credo:disable-for-lines:2 Credo.Check.Warning.UnsafeToAtom
  defp rpc_table_name(profile, chain), do: :"rpc_metrics_#{profile}_#{chain}"
  defp score_table_name(profile, chain), do: :"provider_scores_#{profile}_#{chain}"

  defp schedule_cleanup do
    Process.send_after(__MODULE__, :cleanup_all_chains, @cleanup_interval)
  end

  defp schedule_table_limits_check do
    Process.send_after(__MODULE__, :enforce_table_limits, @table_limits_interval)
  end

  defp enforce_table_limits(table_name) do
    current_size = :ets.info(table_name, :size)

    if current_size >= @max_entries_per_chain do
      Logger.debug(
        "Table #{table_name} at limit (#{current_size}/#{@max_entries_per_chain}), removing oldest entries"
      )

      entries_to_remove = div(@max_entries_per_chain, 10)

      oldest_entries =
        table_name
        |> :ets.tab2list()
        |> Enum.sort_by(fn {monotonic_ts, _, _, _, _, _} -> monotonic_ts end)
        |> Enum.take(entries_to_remove)

      Enum.each(oldest_entries, fn entry ->
        :ets.delete_object(table_name, entry)
      end)

      Logger.debug("Removed #{length(oldest_entries)} oldest entries from #{table_name}")
    end
  rescue
    e ->
      Logger.error("Error enforcing table limits for #{table_name}: #{inspect(e)}")
  catch
    :exit, reason ->
      Logger.error("Table #{table_name} may not exist: #{inspect(reason)}")
  end
end

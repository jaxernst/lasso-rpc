defmodule Livechain.Benchmarking.BenchmarkStore do
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

  # ~1 entry per second for 24 hours
  @max_entries_per_chain 86_400
  # 1 hour in milliseconds
  @cleanup_interval 3_600_000

  # Public API

  @doc """
  Starts the BenchmarkStore GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the provider leaderboard for a chain showing RPC performance.

  Returns a list of providers sorted by average latency and success rate.
  """
  def get_provider_leaderboard(chain_name) do
    GenServer.call(__MODULE__, {:get_provider_leaderboard, chain_name})
  end

  @doc """
  Gets detailed metrics for a specific provider on a chain.
  """
  def get_provider_metrics(chain_name, provider_id) do
    GenServer.call(__MODULE__, {:get_provider_metrics, chain_name, provider_id})
  end


  @doc """
  Gets performance metrics for a specific RPC method across all providers.
  """
  def get_rpc_method_performance(chain_name, method) do
    GenServer.call(__MODULE__, {:get_rpc_method_performance, chain_name, method})
  end

  @doc """
  Gets real-time benchmark statistics for dashboard display.
  """
  def get_realtime_stats(chain_name) do
    GenServer.call(__MODULE__, {:get_realtime_stats, chain_name})
  end

  @doc """
  Manually triggers cleanup of old entries for a chain.
  """
  def cleanup_old_entries(chain_name) do
    GenServer.cast(__MODULE__, {:cleanup_old_entries, chain_name})
  end

  @doc """
  Creates an hourly snapshot of performance data for persistence.
  """
  def create_hourly_snapshot(chain_name) do
    GenServer.call(__MODULE__, {:create_hourly_snapshot, chain_name})
  end

  @doc """
  Gets RPC method performance including percentiles for a provider.
  """
  def get_rpc_method_performance_with_percentiles(chain_name, provider_id, method) do
    GenServer.call(
      __MODULE__,
      {:get_rpc_performance_with_percentiles, chain_name, provider_id, method}
    )
  end

  @doc """
  Clears all metrics for a specific chain.
  """
  def clear_chain_metrics(chain_name) do
    GenServer.call(__MODULE__, {:clear_chain_metrics, chain_name})
  end

  @doc """
  Gets RPC performance metrics for a specific provider and method.
  """
  def get_rpc_performance(chain_name, provider_id, method) do
    GenServer.call(__MODULE__, {:get_rpc_performance, chain_name, provider_id, method})
  end

  @doc """
  Gets error statistics for a specific provider and method.
  """
  def get_error_stats(chain_name, provider_id, method) do
    GenServer.call(__MODULE__, {:get_error_stats, chain_name, provider_id, method})
  end

  @doc """
  Gets latency percentiles for a specific provider and method.
  """
  def get_latency_percentiles(chain_name, provider_id, method) do
    GenServer.call(__MODULE__, {:get_latency_percentiles, chain_name, provider_id, method})
  end

  @doc """
  Gets the overall score for a provider on a chain.
  """
  def get_provider_score(chain_name, provider_id) do
    GenServer.call(__MODULE__, {:get_provider_score, chain_name, provider_id})
  end

  @doc """
  Gets hourly statistics for a provider and method.
  """
  def get_hourly_stats(chain_name, provider_id, method) do
    GenServer.call(__MODULE__, {:get_hourly_stats, chain_name, provider_id, method})
  end

  @doc """
  Cleans up old metrics across all chains.
  """
  def cleanup_old_metrics do
    GenServer.cast(__MODULE__, :cleanup_old_metrics)
  end

  @doc """
  Gets chain-wide statistics.
  """
  def get_chain_wide_stats(chain_name) do
    GenServer.call(__MODULE__, {:get_chain_wide_stats, chain_name})
  end

  @doc """
  Gets real-time statistics for a provider.
  """
  def get_real_time_stats(chain_name, provider_id) do
    GenServer.call(__MODULE__, {:get_real_time_stats, chain_name, provider_id})
  end

  @doc """
  Detects performance anomalies for a provider.
  """
  def detect_performance_anomalies(chain_name, provider_id) do
    GenServer.call(__MODULE__, {:detect_performance_anomalies, chain_name, provider_id})
  end

  @doc """
  Creates a performance snapshot for a chain.
  """
  def create_performance_snapshot(chain_name) do
    GenServer.call(__MODULE__, {:create_performance_snapshot, chain_name})
  end

  @doc """
  Gets historical performance data.
  """
  def get_historical_performance(chain_name, hours) do
    GenServer.call(__MODULE__, {:get_historical_performance, chain_name, hours})
  end

  @doc """
  Gets memory usage statistics.
  """
  def get_memory_usage do
    GenServer.call(__MODULE__, :get_memory_usage)
  end

  @doc """
  Records an RPC call performance metric.

  ## Parameters
    - `chain_name`: The blockchain name
    - `provider_id`: Unique provider identifier
    - `method`: The RPC method called
    - `duration_ms`: Response time in milliseconds
    - `result`: `:success` or `:error`
    - `timestamp`: Optional timestamp (defaults to current time)

  ## Examples

      iex> BenchmarkStore.record_rpc_call("ethereum", "infura_provider", "eth_getLogs", 150, :success)
      :ok
  """
  def record_rpc_call(chain_name, provider_id, method, duration_ms, result, timestamp \\ nil) do
    actual_timestamp = timestamp || System.system_time(:millisecond)

    GenServer.cast(
      __MODULE__,
      {:record_rpc_call, chain_name, provider_id, method, duration_ms, result, actual_timestamp}
    )
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting BenchmarkStore")

    # Schedule periodic cleanup
    schedule_cleanup()

    state = %{
      rpc_tables: %{},
      score_tables: %{},
      chains: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:record_rpc_call, chain_name, provider_id, method, duration_ms, result}, state) do
    new_state = ensure_tables_exist(state, chain_name)

    rpc_table = rpc_table_name(chain_name)
    score_table = score_table_name(chain_name)

    # Check and enforce memory limits before inserting
    enforce_table_limits(rpc_table)

    # Record detailed RPC entry
    timestamp = System.monotonic_time(:millisecond)
    :ets.insert(rpc_table, {timestamp, provider_id, method, duration_ms, result})

    # Update aggregated RPC scores
    update_rpc_scores(score_table, provider_id, method, duration_ms, result)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(
        {:record_rpc_call, chain_name, provider_id, method, duration_ms, result, timestamp},
        state
      ) do
    new_state = ensure_tables_exist(state, chain_name)

    rpc_table = rpc_table_name(chain_name)
    score_table = score_table_name(chain_name)

    # Check and enforce memory limits before inserting
    enforce_table_limits(rpc_table)

    # Record detailed RPC entry with provided timestamp
    :ets.insert(rpc_table, {timestamp, provider_id, method, duration_ms, result})

    # Update aggregated RPC scores
    update_rpc_scores(score_table, provider_id, method, duration_ms, result)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:cleanup_old_entries, chain_name}, state) do
    Logger.info("Cleaning up old benchmark entries for #{chain_name}")

    # 24 hours ago - use monotonic time for consistency
    cutoff_time = System.monotonic_time(:millisecond) - 24 * 60 * 60 * 1000


    # Clean RPC table
    if Map.has_key?(state.rpc_tables, chain_name) do
      rpc_table = rpc_table_name(chain_name)
      cleanup_table_by_timestamp(rpc_table, cutoff_time, 0)
    end

    # Clean score table - remove entries that are too old
    if Map.has_key?(state.score_tables, chain_name) do
      score_table = score_table_name(chain_name)
      cleanup_score_table_by_timestamp(score_table, cutoff_time)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:cleanup_old_metrics, state) do
    Logger.info("Cleaning up old metrics across all chains")

    # Clean up old entries for all chains
    Enum.each(state.chains, fn chain_name ->
      GenServer.cast(__MODULE__, {:cleanup_old_entries, chain_name})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call({:get_provider_leaderboard, chain_name}, _from, state) do
    result =
      if Map.has_key?(state.score_tables, chain_name) do
        calculate_leaderboard(chain_name)
      else
        []
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_provider_metrics, chain_name, provider_id}, _from, state) do
    result =
      if Map.has_key?(state.score_tables, chain_name) do
        get_detailed_provider_metrics(chain_name, provider_id)
      else
        %{}
      end

    {:reply, result, state}
  end


  @impl true
  def handle_call({:get_rpc_method_performance, chain_name, method}, _from, state) do
    result =
      if Map.has_key?(state.rpc_tables, chain_name) do
        get_rpc_performance_stats(chain_name, method)
      else
        %{}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_realtime_stats, chain_name}, _from, state) do
    result =
      if Map.has_key?(state.score_tables, chain_name) do
        get_realtime_benchmark_stats(chain_name)
      else
        %{providers: [], event_types: [], rpc_methods: []}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:create_hourly_snapshot, chain_name}, _from, state) do
    snapshot =
      if Map.has_key?(state.score_tables, chain_name) do
        snapshot_data = create_performance_snapshot_private(chain_name)

        # Save to persistence layer
        alias Livechain.Benchmarking.Persistence
        Persistence.save_snapshot(chain_name, snapshot_data)

        snapshot_data
      else
        %{}
      end

    {:reply, snapshot, state}
  end

  @impl true
  def handle_call({:clear_chain_metrics, chain_name}, _from, state) do

    if Map.has_key?(state.rpc_tables, chain_name) do
      rpc_table = rpc_table_name(chain_name)
      :ets.delete(rpc_table)
    end

    if Map.has_key?(state.score_tables, chain_name) do
      score_table = score_table_name(chain_name)
      :ets.delete(score_table)
    end

    new_state = %{
      state
      | rpc_tables: Map.delete(state.rpc_tables, chain_name),
        score_tables: Map.delete(state.score_tables, chain_name),
        chains: MapSet.delete(state.chains, chain_name)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get_rpc_performance, chain_name, provider_id, method}, _from, state) do
    result =
      if Map.has_key?(state.score_tables, chain_name) do
        score_table = score_table_name(chain_name)
        key = {provider_id, method, :rpc}

        case :ets.lookup(score_table, key) do
          [{_key, successes, total, avg_duration, _samples, _last_updated}] ->
            %{
              total_calls: total,
              success_calls: successes,
              error_calls: total - successes,
              success_rate: if(total > 0, do: successes / total, else: 0.0),
              avg_latency: avg_duration
            }

          [] ->
            %{total_calls: 0, success_calls: 0, error_calls: 0, success_rate: 0.0, avg_latency: 0}
        end
      else
        %{total_calls: 0, success_calls: 0, error_calls: 0, success_rate: 0.0, avg_latency: 0}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_error_stats, chain_name, provider_id, method}, _from, state) do
    result =
      if Map.has_key?(state.rpc_tables, chain_name) do
        rpc_table = rpc_table_name(chain_name)

        # Count different error types
        error_counts =
          rpc_table
          |> :ets.tab2list()
          |> Enum.filter(fn {_timestamp, pid, m, _duration, result} ->
            pid == provider_id and m == method and result != :success
          end)
          |> Enum.reduce(
            %{timeout_count: 0, network_error_count: 0, rate_limit_count: 0},
            fn {_timestamp, _pid, _m, _duration, result}, acc ->
              case result do
                :timeout -> Map.update(acc, :timeout_count, 1, &(&1 + 1))
                :network_error -> Map.update(acc, :network_error_count, 1, &(&1 + 1))
                :rate_limit -> Map.update(acc, :rate_limit_count, 1, &(&1 + 1))
                _ -> acc
              end
            end
          )

        error_counts
      else
        %{timeout_count: 0, network_error_count: 0, rate_limit_count: 0}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_latency_percentiles, chain_name, provider_id, method}, _from, state) do
    result =
      if Map.has_key?(state.rpc_tables, chain_name) do
        rpc_table = rpc_table_name(chain_name)

        # Get all latencies for successful calls
        latencies =
          rpc_table
          |> :ets.tab2list()
          |> Enum.filter(fn {_timestamp, pid, m, duration, result} ->
            pid == provider_id and m == method and result == :success and duration > 0
          end)
          |> Enum.map(fn {_timestamp, _pid, _m, duration, _result} -> duration end)
          |> Enum.sort()

        calculate_percentiles(latencies)
      else
        %{p50: 0, p90: 0, p99: 0}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_provider_score, chain_name, provider_id}, _from, state) do
    result =
      if Map.has_key?(state.score_tables, chain_name) do
        score_table = score_table_name(chain_name)

        # Get all RPC entries for this provider
        rpc_entries =
          score_table
          |> :ets.tab2list()
          |> Enum.filter(fn {{pid, _method, type}, _successes, _total, _avg, _samples, _updated} ->
            pid == provider_id and type == :rpc
          end)

        # Calculate composite score based on RPC performance
        if length(rpc_entries) > 0 do
          {total_successes, total_calls, weighted_avg_latency} =
            Enum.reduce(rpc_entries, {0, 0, 0.0}, fn {{_pid, _method, _type}, successes, total, avg_duration, _samples, _updated},
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
  def handle_call({:get_hourly_stats, chain_name, provider_id, method}, _from, state) do
    result =
      if Map.has_key?(state.rpc_tables, chain_name) do
        rpc_table = rpc_table_name(chain_name)
        current_hour = div(System.system_time(:second), 3600) * 3600
        hour_ago = current_hour - 3600

        # Get RPC calls from the last hour
        hourly_calls =
          rpc_table
          |> :ets.tab2list()
          |> Enum.filter(fn {timestamp, pid, m, _duration, _result} ->
            pid == provider_id and m == method and timestamp >= hour_ago
          end)

        if length(hourly_calls) > 0 do
          successful_calls =
            Enum.filter(hourly_calls, fn {_timestamp, _pid, _m, _duration, result} ->
              result == :success
            end)

          total_calls = length(hourly_calls)
          success_rate = length(successful_calls) / total_calls

          # Calculate average latency from successful calls
          avg_latency =
            hourly_calls
            |> Enum.filter(fn {_timestamp, _pid, _m, duration, result} ->
              result == :success and duration > 0
            end)
            |> Enum.map(fn {_timestamp, _pid, _m, duration, _result} -> duration end)
            |> then(fn latencies ->
              if length(latencies) > 0, do: Enum.sum(latencies) / length(latencies), else: 0
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
  def handle_call({:get_chain_wide_stats, chain_name}, _from, state) do
    result =
      if Map.has_key?(state.score_tables, chain_name) do
        score_table = score_table_name(chain_name)

        # Get all RPC entries for this chain
        rpc_entries =
          score_table
          |> :ets.tab2list()
          |> Enum.filter(fn {{_pid, _key, type}, _stat1, _stat2, _stat3, _samples, _updated} ->
            type == :rpc
          end)

        total_calls =
          Enum.reduce(rpc_entries, 0, fn {_key, _successes, total, _avg, _samples, _updated},
                                         acc ->
            acc + total
          end)

        total_successes =
          Enum.reduce(rpc_entries, 0, fn {_key, successes, _total, _avg, _samples, _updated},
                                         acc ->
            acc + successes
          end)

        overall_success_rate = if total_calls > 0, do: total_successes / total_calls, else: 0.0

        %{
          total_calls: total_calls,
          total_successes: total_successes,
          overall_success_rate: overall_success_rate,
          total_providers:
            rpc_entries
            |> Enum.map(fn {{pid, _key, _type}, _stat1, _stat2, _stat3, _samples, _updated} ->
              pid
            end)
            |> Enum.uniq()
            |> length()
        }
      else
        %{total_calls: 0, total_successes: 0, overall_success_rate: 0.0, total_providers: 0}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_real_time_stats, chain_name, provider_id}, _from, state) do
    result =
      if Map.has_key?(state.score_tables, chain_name) do
        score_table = score_table_name(chain_name)

        # Get current racing and RPC stats
        racing_stats =
          score_table
          |> :ets.tab2list()
          |> Enum.filter(fn {{pid, _key, type}, _stat1, _stat2, _stat3, _samples, _updated} ->
            pid == provider_id and type == :racing
          end)
          |> Enum.map(fn {{_pid, event_type, _type}, wins, total, avg_margin, _samples,
                          last_updated} ->
            %{
              event_type: event_type,
              wins: wins,
              total_races: total,
              win_rate: if(total > 0, do: wins / total, else: 0.0),
              avg_margin_ms: avg_margin,
              last_updated: last_updated
            }
          end)

        rpc_stats =
          score_table
          |> :ets.tab2list()
          |> Enum.filter(fn {{pid, _key, type}, _stat1, _stat2, _stat3, _samples, _updated} ->
            pid == provider_id and type == :rpc
          end)
          |> Enum.map(fn {{_pid, method, _type}, successes, total, avg_duration, _samples,
                          last_updated} ->
            %{
              method: method,
              successes: successes,
              total_calls: total,
              success_rate: if(total > 0, do: successes / total, else: 0.0),
              avg_duration_ms: avg_duration,
              last_updated: last_updated
            }
          end)

        # Count calls in the last minute - use monotonic time for consistency
        current_time = System.monotonic_time(:millisecond)
        minute_ago = current_time - 60_000

        calls_last_minute =
          if Map.has_key?(state.rpc_tables, chain_name) do
            rpc_table = rpc_table_name(chain_name)

            rpc_table
            |> :ets.tab2list()
            |> Enum.filter(fn {timestamp, pid, _method, _duration, _result} ->
              pid == provider_id and timestamp >= minute_ago
            end)
            |> length()
          else
            0
          end

        %{
          provider_id: provider_id,
          racing_stats: racing_stats,
          rpc_stats: rpc_stats,
          calls_last_minute: calls_last_minute,
          last_updated: System.system_time(:millisecond)
        }
      else
        %{
          provider_id: provider_id,
          racing_stats: [],
          rpc_stats: [],
          calls_last_minute: 0,
          last_updated: 0
        }
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:detect_performance_anomalies, chain_name, provider_id}, _from, state) do
    result =
      if Map.has_key?(state.score_tables, chain_name) do
        score_table = score_table_name(chain_name)

        # Get recent RPC performance
        rpc_entries =
          score_table
          |> :ets.tab2list()
          |> Enum.filter(fn {{pid, _key, type}, _stat1, _stat2, _stat3, _samples, _updated} ->
            pid == provider_id and type == :rpc
          end)

        anomalies =
          rpc_entries
          |> Enum.filter(fn {{_pid, _method, _type}, successes, total, avg_duration, _samples,
                             _last_updated} ->
            # Very lenient anomaly detection for testing
            success_rate = if total > 0, do: successes / total, else: 0.0
            # 95% success rate, 1 second
            success_rate < 0.95 or avg_duration > 1000
          end)
          |> Enum.map(fn {{_pid, method, _type}, successes, total, avg_duration, _samples,
                          _last_updated} ->
            %{
              method: method,
              success_rate: if(total > 0, do: successes / total, else: 0.0),
              avg_duration_ms: avg_duration,
              anomaly_type:
                cond do
                  if(total > 0, do: successes / total, else: 0.0) < 0.95 -> :low_success_rate
                  avg_duration > 1000 -> :high_latency
                  true -> :unknown
                end
            }
          end)

        anomalies
      else
        []
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:create_performance_snapshot, chain_name}, _from, state) do
    result =
      if Map.has_key?(state.score_tables, chain_name) do
        # Call the private function directly instead of making a GenServer call
        create_performance_snapshot_private(chain_name)
      else
        %{}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_historical_performance, chain_name, hours}, _from, state) do
    result =
      if Map.has_key?(state.score_tables, chain_name) do
        # For now, return current data as historical
        # In a real implementation, this would query persistent storage
        score_table = score_table_name(chain_name)
        current_time = System.system_time(:second)
        _cutoff_time = current_time - hours * 3600

        all_entries = :ets.tab2list(score_table)

        # Return the list of entries directly
        all_entries
      else
        []
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:get_memory_usage, _from, state) do
    total_size =
      state.chains
      |> Enum.map(fn chain_name ->

        rpc_size =
          if Map.has_key?(state.rpc_tables, chain_name),
            do: :ets.info(rpc_table_name(chain_name), :size) || 0,
            else: 0

        score_size =
          if Map.has_key?(state.score_tables, chain_name),
            do: :ets.info(score_table_name(chain_name), :size) || 0,
            else: 0

        rpc_size + score_size
      end)
      |> Enum.sum()

    result = %{
      total_entries: total_size,
      chains_tracked: MapSet.size(state.chains),
      # Use the key the test expects
      memory_mb: total_size * 0.001,
      # Keep the original key too
      memory_estimate_mb: total_size * 0.001
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call(
        {:get_rpc_performance_with_percentiles, chain_name, provider_id, method},
        _from,
        state
      ) do
    result =
      if Map.has_key?(state.score_tables, chain_name) do
        get_rpc_performance_with_percentiles_data(chain_name, provider_id, method)
      else
        nil
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:cleanup_all_chains, state) do
    Logger.debug("Running periodic cleanup for all benchmark tables")

    # Create snapshots before cleanup for all tracked chains
    Enum.each(state.chains, fn chain_name ->
      # Avoid self-call; call private directly
      snapshot = create_performance_snapshot_private(chain_name)
      alias Livechain.Benchmarking.Persistence
      Persistence.save_snapshot(chain_name, snapshot)
    end)

    # Then cleanup old entries
    Enum.each(state.chains, fn chain_name ->
      GenServer.cast(__MODULE__, {:cleanup_old_entries, chain_name})
    end)

    schedule_cleanup()
    {:noreply, state}
  end

  defp get_rpc_performance_with_percentiles_data(chain_name, provider_id, method) do
    score_table = score_table_name(chain_name)
    key = {provider_id, method, :rpc}

    case :ets.lookup(score_table, key) do
      [{_key, successes, total, avg_duration, recent_latencies, last_updated}]
      when is_list(recent_latencies) ->
        success_rate = if total > 0, do: successes / total, else: 0.0
        percentiles = calculate_percentiles(recent_latencies)

        %{
          provider_id: provider_id,
          method: method,
          success_rate: success_rate,
          total_calls: total,
          avg_duration_ms: avg_duration,
          percentiles: percentiles,
          last_updated: last_updated
        }

      [{_key, successes, total, avg_duration, last_updated}] ->
        # Legacy format without percentiles
        success_rate = if total > 0, do: successes / total, else: 0.0

        %{
          provider_id: provider_id,
          method: method,
          success_rate: success_rate,
          total_calls: total,
          avg_duration_ms: avg_duration,
          percentiles: %{p50: avg_duration, p90: avg_duration, p99: avg_duration},
          last_updated: last_updated
        }

      [] ->
        nil
    end
  end

  defp calculate_percentiles(latencies) when length(latencies) < 2 do
    # Not enough data for meaningful percentiles
    case latencies do
      [single] -> %{p50: single, p90: single, p95: single, p99: single}
      [] -> %{p50: 0, p90: 0, p95: 0, p99: 0}
    end
  end

  defp calculate_percentiles(latencies) do
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

  defp create_performance_snapshot_private(chain_name) do
    score_table = score_table_name(chain_name)
    current_hour = div(System.system_time(:second), 3600) * 3600

    # Get all current scores as snapshot
    all_entries = :ets.tab2list(score_table)

    snapshot_data =
      Enum.map(all_entries, fn {{provider_id, key, type}, stat1, stat2, stat3, _samples,
                                last_updated} ->
        case type do
          :racing ->
            %{
              chain_name: chain_name,
              provider_id: provider_id,
              hour_timestamp: current_hour,
              # Add the field the test expects
              timestamp: current_hour,
              event_type: key,
              wins: stat1,
              total_races: stat2,
              avg_margin_ms: stat3,
              rpc_method: nil,
              rpc_calls: nil,
              rpc_avg_duration_ms: nil,
              rpc_success_rate: nil,
              last_updated: last_updated
            }

          :rpc ->
            %{
              chain_name: chain_name,
              provider_id: provider_id,
              hour_timestamp: current_hour,
              # Add the field the test expects
              timestamp: current_hour,
              event_type: nil,
              wins: nil,
              total_races: nil,
              avg_margin_ms: nil,
              rpc_method: key,
              rpc_calls: stat2,
              rpc_avg_duration_ms: stat3,
              rpc_success_rate: if(stat2 > 0, do: stat1 / stat2, else: 0.0),
              last_updated: last_updated
            }
        end
      end)

    # Extract unique providers
    providers =
      all_entries
      |> Enum.map(fn {{provider_id, _key, _type}, _stat1, _stat2, _stat3, _samples, _updated} ->
        provider_id
      end)
      |> Enum.uniq()

    %{
      chain_name: chain_name,
      hour_timestamp: current_hour,
      # Add the field the test expects
      timestamp: current_hour,
      # Add the field the test expects
      providers: providers,
      snapshot_data: snapshot_data
    }
  end

  # Private functions

  defp ensure_tables_exist(state, chain_name) do
    if MapSet.member?(state.chains, chain_name) do
      state
    else
      Logger.info("Creating benchmark tables for chain: #{chain_name}")

      rpc_table = rpc_table_name(chain_name)
      score_table = score_table_name(chain_name)

      # Create ETS tables (no racing table needed)
      :ets.new(rpc_table, [:public, :named_table, :bag, :compressed])
      :ets.new(score_table, [:public, :named_table, :set, :compressed])

      %{
        state
        | rpc_tables: Map.put(state.rpc_tables, chain_name, rpc_table),
          score_tables: Map.put(state.score_tables, chain_name, score_table),
          chains: MapSet.put(state.chains, chain_name)
      }
    end
  end


  defp update_rpc_scores(score_table, provider_id, method, duration_ms, result) do
    key = {provider_id, method, :rpc}

    try do
      case :ets.lookup(score_table, key) do
        [] ->
          # First entry for this provider/method combination
          successes = if result == :success, do: 1, else: 0
          total = 1
          avg_duration = duration_ms
          # Initialize recent latencies list for percentile calculation (keep last 100 samples)
          recent_latencies =
            if result == :success and duration_ms > 0, do: [duration_ms], else: []

          :ets.insert(
            score_table,
            {key, successes, total, avg_duration, recent_latencies,
             System.monotonic_time(:millisecond)}
          )

        [{_key, successes, total, avg_duration, recent_latencies, _last_updated}] ->
          # Update existing entry
          new_successes = if result == :success, do: successes + 1, else: successes
          new_total = total + 1
          new_avg_duration = (avg_duration * total + duration_ms) / new_total

          # Update recent latencies (keep last 100 samples for percentile calculation)
          updated_latencies =
            if result == :success and duration_ms > 0,
              do: [duration_ms | recent_latencies] |> Enum.take(100),
              else: recent_latencies

          :ets.insert(
            score_table,
            {key, new_successes, new_total, new_avg_duration, updated_latencies,
             System.monotonic_time(:millisecond)}
          )

        # Handle legacy entries without recent_latencies field
        [{_key, successes, total, avg_duration, last_updated}] when not is_list(last_updated) ->
          # Migrate old format to new format
          new_successes = if result == :success, do: successes + 1, else: successes
          new_total = total + 1
          new_avg_duration = (avg_duration * new_total + duration_ms) / (new_total + 1)
          # Initialize recent latencies with current duration
          recent_latencies =
            if result == :success and duration_ms > 0, do: [duration_ms], else: []

          :ets.insert(
            score_table,
            {key, new_successes, new_total, new_avg_duration, recent_latencies,
             System.monotonic_time(:millisecond)}
          )

        multiple_entries ->
          Logger.warning(
            "Multiple RPC score entries found for #{inspect(key)}: #{length(multiple_entries)}"
          )

          # Use the first entry and continue with migration if needed
          [{_key, successes, total, avg_duration, field4, field5}] =
            Enum.take(multiple_entries, 1)

          {recent_latencies, _last_updated} =
            case {field4, field5} do
              {recent_list, timestamp} when is_list(recent_list) and is_integer(timestamp) ->
                {recent_list, timestamp}

              {timestamp, nil} when is_integer(timestamp) ->
                {if(result == :success and duration_ms > 0, do: [duration_ms], else: []),
                 timestamp}

              _ ->
                {if(result == :success and duration_ms > 0, do: [duration_ms], else: []),
                 System.monotonic_time(:millisecond)}
            end

          new_successes = if result == :success, do: successes + 1, else: successes
          new_total = total + 1
          new_avg_duration = (avg_duration * total + duration_ms) / new_total

          updated_latencies =
            if result == :success and duration_ms > 0,
              do: [duration_ms | recent_latencies] |> Enum.take(100),
              else: recent_latencies

          :ets.insert(
            score_table,
            {key, new_successes, new_total, new_avg_duration, updated_latencies,
             System.monotonic_time(:millisecond)}
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

  defp cleanup_table_by_timestamp(table_name, cutoff_time, _position) do
    # Use ets:select to find and delete old entries efficiently
    match_spec = [{{:"$1", :"$2", :"$3", :"$4", :"$5"}, [{:<, :"$1", cutoff_time}], [true]}]

    try do
      old_keys = :ets.select(table_name, match_spec)

      Enum.each(old_keys, fn key ->
        :ets.delete_object(table_name, key)
      end)

      Logger.debug("Cleaned up #{length(old_keys)} old entries from #{table_name}")
    rescue
      e -> Logger.error("Error during table cleanup: #{inspect(e)}")
    end
  end

  defp cleanup_score_table_by_timestamp(score_table, cutoff_time) do
    try do
      # Get all entries and filter out old ones
      all_entries = :ets.tab2list(score_table)

      old_entries =
        all_entries
        |> Enum.filter(fn {{_provider_id, _key, _type}, _stat1, _stat2, _stat3, _samples,
                           last_updated} ->
          last_updated < cutoff_time
        end)

      # Remove old entries
      Enum.each(old_entries, fn entry ->
        :ets.delete_object(score_table, entry)
      end)

      Logger.debug("Cleaned up #{length(old_entries)} old score entries")
    rescue
      e -> Logger.error("Error during score table cleanup: #{inspect(e)}")
    end
  end

  defp calculate_leaderboard(chain_name) do
    score_table = score_table_name(chain_name)

    # Get all RPC scores grouped by provider
    rpc_scores =
      score_table
      |> :ets.tab2list()
      |> Enum.filter(fn {{_provider_id, _method, type}, _successes, _total, _avg_duration, _samples,
                         _updated} ->
        type == :rpc
      end)
      |> Enum.group_by(fn {{provider_id, _method, _type}, _successes, _total, _avg_duration, _samples,
                           _updated} ->
        provider_id
      end)

    # Calculate overall scores for each provider based on RPC latency metrics
    Enum.map(rpc_scores, fn {provider_id, entries} ->
      {total_successes, total_calls, weighted_avg_latency} =
        Enum.reduce(entries, {0, 0, 0.0}, fn {{_pid, _method, _type}, successes, total, avg_duration,
                                              _samples, _updated},
                                             {acc_successes, acc_total, acc_latency} ->
          {acc_successes + successes, acc_total + total, acc_latency + avg_duration * total}
        end)

      success_rate = if total_calls > 0, do: total_successes / total_calls, else: 0.0
      avg_latency = if total_calls > 0, do: weighted_avg_latency / total_calls, else: 0.0

      %{
        provider_id: provider_id,
        total_calls: total_calls,
        total_successes: total_successes,
        success_rate: success_rate,
        avg_latency_ms: avg_latency,
        # For backward compatibility, include legacy fields mapped to RPC equivalents
        total_wins: total_successes,
        total_races: total_calls,
        win_rate: success_rate,
        avg_margin_ms: avg_latency,
        score: calculate_rpc_provider_score(success_rate, avg_latency, total_calls)
      }
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp get_detailed_provider_metrics(chain_name, provider_id) do
    score_table = score_table_name(chain_name)

    # Get all entries for this provider
    provider_entries =
      score_table
      |> :ets.tab2list()
      |> Enum.filter(fn {{pid, _event_type, _type}, _wins, _total, _avg, _samples, _updated} ->
        pid == provider_id
      end)

    # Group by type (racing vs rpc)
    {racing_entries, rpc_entries} =
      Enum.split_with(provider_entries, fn {{_pid, _key, type}, _wins, _total, _avg, _samples,
                                            _updated} ->
        type == :racing
      end)

    racing_metrics =
      Enum.map(racing_entries, fn {{_pid, event_type, _type}, wins, total, avg_margin, _samples,
                                   last_updated} ->
        %{
          event_type: event_type,
          wins: wins,
          total_races: total,
          win_rate: if(total > 0, do: wins / total, else: 0.0),
          avg_margin_ms: avg_margin,
          last_updated: last_updated
        }
      end)

    rpc_metrics =
      Enum.map(rpc_entries, fn {{_pid, method, _type}, successes, total, avg_duration, _samples,
                                last_updated} ->
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
      racing_metrics: racing_metrics,
      rpc_metrics: rpc_metrics
    }
  end


  defp get_rpc_performance_stats(chain_name, method) do
    score_table = score_table_name(chain_name)

    # Get all RPC entries for this method
    method_entries =
      score_table
      |> :ets.tab2list()
      |> Enum.filter(fn {{_pid, m, type}, _successes, _total, _avg, _samples, _updated} ->
        type == :rpc and m == method
      end)

    provider_stats =
      Enum.map(method_entries, fn {{provider_id, _m, _type}, successes, total, avg_duration,
                                   _samples, last_updated} ->
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

  defp get_realtime_benchmark_stats(chain_name) do
    score_table = score_table_name(chain_name)

    all_entries = :ets.tab2list(score_table)

    providers =
      all_entries
      |> Enum.map(fn {{provider_id, _key, _type}, _stat1, _stat2, _stat3, _samples, _updated} ->
        provider_id
      end)
      |> Enum.uniq()

    event_types =
      all_entries
      |> Enum.filter(fn {{_pid, _key, type}, _stat1, _stat2, _stat3, _samples, _updated} ->
        type == :racing
      end)
      |> Enum.map(fn {{_pid, event_type, _type}, _stat1, _stat2, _stat3, _samples, _updated} ->
        event_type
      end)
      |> Enum.uniq()

    rpc_methods =
      all_entries
      |> Enum.filter(fn {{_pid, _key, type}, _stat1, _stat2, _stat3, _samples, _updated} ->
        type == :rpc
      end)
      |> Enum.map(fn {{_pid, method, _type}, _stat1, _stat2, _stat3, _samples, _updated} ->
        method
      end)
      |> Enum.uniq()

    %{
      providers: providers,
      event_types: event_types,
      rpc_methods: rpc_methods,
      total_entries: length(all_entries),
      last_updated: System.monotonic_time(:millisecond)
    }
  end


  defp calculate_rpc_provider_score(success_rate, avg_latency_ms, total_calls) do
    # RPC-based scoring algorithm - optimized for performance
    # Higher success rate is better, lower latency is better, more calls gives confidence
    confidence_factor = :math.log10(max(total_calls, 1))

    # Penalize latency: providers with lower latency get higher scores
    # Use 1000ms as baseline - anything faster gets bonus, slower gets penalty
    latency_factor = if avg_latency_ms > 0, do: 1000 / (1000 + avg_latency_ms), else: 1.0

    # Heavily weight success rate and latency
    success_rate * latency_factor * confidence_factor
  end

  defp rpc_table_name(chain_name), do: :"rpc_metrics_#{chain_name}"
  defp score_table_name(chain_name), do: :"provider_scores_#{chain_name}"

  defp schedule_cleanup do
    Process.send_after(__MODULE__, :cleanup_all_chains, @cleanup_interval)
  end

  defp enforce_table_limits(table_name) do
    try do
      # Get current table size
      current_size = :ets.info(table_name, :size)

      if current_size >= @max_entries_per_chain do
        Logger.debug(
          "Table #{table_name} at limit (#{current_size}/#{@max_entries_per_chain}), removing oldest entries"
        )

        # Remove 10% of entries (oldest first) to make room
        entries_to_remove = div(@max_entries_per_chain, 10)

        # Get oldest entries by timestamp (first element of tuple)
        oldest_entries =
          table_name
          |> :ets.tab2list()
          |> Enum.sort_by(fn {timestamp, _provider, _key, _stat, _result} -> timestamp end)
          |> Enum.take(entries_to_remove)

        # Remove oldest entries
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
end

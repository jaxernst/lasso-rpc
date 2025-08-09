defmodule Livechain.Benchmarking.BenchmarkStore do
  @moduledoc """
  Manages performance benchmarking data for RPC providers using ETS tables.

  This module provides passive benchmarking by tracking:
  1. Event racing metrics - which provider delivers events fastest
  2. RPC call performance - latency and success rates for JSON-RPC calls
  
  Data is stored in per-chain ETS tables with automatic cleanup to manage memory usage.
  Keeps detailed metrics for 24 hours with hourly snapshots for historical analysis.
  """

  use GenServer
  require Logger

  @max_entries_per_chain 86_400  # ~1 entry per second for 24 hours
  @cleanup_interval 3_600_000     # 1 hour in milliseconds

  # Public API

  @doc """
  Starts the BenchmarkStore GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a racing victory for an event.
  
  ## Examples
  
      iex> BenchmarkStore.record_event_race_win("ethereum", "infura_provider", "newHeads", 1640995200000)
      :ok
  """
  def record_event_race_win(chain_name, provider_id, event_type, timestamp) do
    GenServer.cast(__MODULE__, {:record_race_win, chain_name, provider_id, event_type, timestamp})
  end

  @doc """
  Records a racing loss for an event with the margin by which it lost.
  
  ## Examples
  
      iex> BenchmarkStore.record_event_race_loss("ethereum", "alchemy_provider", "newHeads", 1640995200050, 50)
      :ok
  """
  def record_event_race_loss(chain_name, provider_id, event_type, timestamp, margin_ms) do
    GenServer.cast(__MODULE__, {:record_race_loss, chain_name, provider_id, event_type, timestamp, margin_ms})
  end

  @doc """
  Records an RPC call performance metric.
  
  ## Examples
  
      iex> BenchmarkStore.record_rpc_call("ethereum", "infura_provider", "eth_getLogs", 150, :success)
      :ok
  """
  def record_rpc_call(chain_name, provider_id, method, duration_ms, result) do
    GenServer.cast(__MODULE__, {:record_rpc_call, chain_name, provider_id, method, duration_ms, result})
  end

  @doc """
  Gets the provider leaderboard for a chain showing racing performance.
  
  Returns a list of providers sorted by performance with metrics.
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
  Gets performance metrics for a specific event type across all providers.
  """
  def get_event_type_performance(chain_name, event_type) do
    GenServer.call(__MODULE__, {:get_event_type_performance, chain_name, event_type})
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

  # GenServer callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting BenchmarkStore")
    
    # Schedule periodic cleanup
    schedule_cleanup()
    
    state = %{
      racing_tables: %{},
      rpc_tables: %{},
      score_tables: %{},
      chains: MapSet.new()
    }
    
    {:ok, state}
  end

  @impl true
  def handle_cast({:record_race_win, chain_name, provider_id, event_type, timestamp}, state) do
    new_state = ensure_tables_exist(state, chain_name)
    
    racing_table = racing_table_name(chain_name)
    score_table = score_table_name(chain_name)
    
    # Check and enforce memory limits before inserting
    enforce_table_limits(racing_table)
    
    # Record detailed racing entry
    :ets.insert(racing_table, {timestamp, provider_id, event_type, :win, 0})
    
    # Update aggregated scores
    update_score_table(score_table, provider_id, event_type, :win, 0)
    
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:record_race_loss, chain_name, provider_id, event_type, timestamp, margin_ms}, state) do
    new_state = ensure_tables_exist(state, chain_name)
    
    racing_table = racing_table_name(chain_name)
    score_table = score_table_name(chain_name)
    
    # Check and enforce memory limits before inserting
    enforce_table_limits(racing_table)
    
    # Record detailed racing entry
    :ets.insert(racing_table, {timestamp, provider_id, event_type, :loss, margin_ms})
    
    # Update aggregated scores
    update_score_table(score_table, provider_id, event_type, :loss, margin_ms)
    
    {:noreply, new_state}
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
  def handle_cast({:cleanup_old_entries, chain_name}, state) do
    Logger.info("Cleaning up old benchmark entries for #{chain_name}")
    
    cutoff_time = System.monotonic_time(:millisecond) - (24 * 60 * 60 * 1000) # 24 hours ago
    
    # Clean racing table
    if Map.has_key?(state.racing_tables, chain_name) do
      racing_table = racing_table_name(chain_name)
      cleanup_table_by_timestamp(racing_table, cutoff_time, 0)
    end
    
    # Clean RPC table
    if Map.has_key?(state.rpc_tables, chain_name) do
      rpc_table = rpc_table_name(chain_name)
      cleanup_table_by_timestamp(rpc_table, cutoff_time, 0)
    end
    
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
  def handle_call({:get_event_type_performance, chain_name, event_type}, _from, state) do
    result = 
      if Map.has_key?(state.racing_tables, chain_name) do
        get_event_performance_stats(chain_name, event_type)
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
        snapshot_data = create_performance_snapshot(chain_name)
        
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
  def handle_info(:cleanup_all_chains, state) do
    Logger.debug("Running periodic cleanup for all benchmark tables")
    
    # Create snapshots before cleanup for all tracked chains
    Enum.each(state.chains, fn chain_name ->
      GenServer.call(__MODULE__, {:create_hourly_snapshot, chain_name})
    end)
    
    # Then cleanup old entries
    Enum.each(state.chains, fn chain_name ->
      GenServer.cast(__MODULE__, {:cleanup_old_entries, chain_name})
    end)
    
    schedule_cleanup()
    {:noreply, state}
  end

  # Private functions

  defp ensure_tables_exist(state, chain_name) do
    if MapSet.member?(state.chains, chain_name) do
      state
    else
      Logger.info("Creating benchmark tables for chain: #{chain_name}")
      
      racing_table = racing_table_name(chain_name)
      rpc_table = rpc_table_name(chain_name)
      score_table = score_table_name(chain_name)
      
      # Create ETS tables
      :ets.new(racing_table, [:public, :named_table, :bag, :compressed])
      :ets.new(rpc_table, [:public, :named_table, :bag, :compressed])
      :ets.new(score_table, [:public, :named_table, :set, :compressed])
      
      %{
        state |
        racing_tables: Map.put(state.racing_tables, chain_name, racing_table),
        rpc_tables: Map.put(state.rpc_tables, chain_name, rpc_table),
        score_tables: Map.put(state.score_tables, chain_name, score_table),
        chains: MapSet.put(state.chains, chain_name)
      }
    end
  end

  defp update_score_table(score_table, provider_id, event_type, result, margin_ms) do
    key = {provider_id, event_type, :racing}
    
    try do
      case :ets.lookup(score_table, key) do
        [] ->
          # First entry for this provider/event_type combination
          wins = if result == :win, do: 1, else: 0
          total = 1
          avg_margin = margin_ms
          
          :ets.insert(score_table, {key, wins, total, avg_margin, System.monotonic_time(:millisecond)})
          
        [{_key, wins, total, avg_margin, _last_updated}] ->
          # Update existing entry
          new_wins = if result == :win, do: wins + 1, else: wins
          new_total = total + 1
          new_avg_margin = (avg_margin * total + margin_ms) / new_total
          
          :ets.insert(score_table, {key, new_wins, new_total, new_avg_margin, System.monotonic_time(:millisecond)})
          
        multiple_entries ->
          Logger.warning("Multiple score entries found for #{inspect(key)}: #{length(multiple_entries)}")
          # Use the first entry and continue
          [{_key, wins, total, avg_margin, _last_updated}] = Enum.take(multiple_entries, 1)
          new_wins = if result == :win, do: wins + 1, else: wins
          new_total = total + 1
          new_avg_margin = (avg_margin * total + margin_ms) / new_total
          
          :ets.insert(score_table, {key, new_wins, new_total, new_avg_margin, System.monotonic_time(:millisecond)})
      end
    rescue
      e -> 
        Logger.error("Error updating score table for #{inspect(key)}: #{inspect(e)}")
    catch
      :exit, reason -> 
        Logger.error("Score table access error for #{inspect(key)}: #{inspect(reason)}")
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
          
          :ets.insert(score_table, {key, successes, total, avg_duration, System.monotonic_time(:millisecond)})
          
        [{_key, successes, total, avg_duration, _last_updated}] ->
          # Update existing entry
          new_successes = if result == :success, do: successes + 1, else: successes
          new_total = total + 1
          new_avg_duration = (avg_duration * total + duration_ms) / new_total
          
          :ets.insert(score_table, {key, new_successes, new_total, new_avg_duration, System.monotonic_time(:millisecond)})
          
        multiple_entries ->
          Logger.warning("Multiple RPC score entries found for #{inspect(key)}: #{length(multiple_entries)}")
          # Use the first entry and continue
          [{_key, successes, total, avg_duration, _last_updated}] = Enum.take(multiple_entries, 1)
          new_successes = if result == :success, do: successes + 1, else: successes
          new_total = total + 1
          new_avg_duration = (avg_duration * total + duration_ms) / new_total
          
          :ets.insert(score_table, {key, new_successes, new_total, new_avg_duration, System.monotonic_time(:millisecond)})
      end
    rescue
      e -> 
        Logger.error("Error updating RPC scores for #{inspect(key)}: #{inspect(e)}")
    catch
      :exit, reason -> 
        Logger.error("RPC score table access error for #{inspect(key)}: #{inspect(reason)}")
    end
  end

  defp cleanup_table_by_timestamp(table_name, cutoff_time, position) do
    # Use ets:select to find and delete old entries efficiently
    match_spec = [{{:"$1", :"$2", :"$3", :"$4", :"$5"}, [{:"<", :"$1", cutoff_time}], [true]}]
    
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

  defp calculate_leaderboard(chain_name) do
    score_table = score_table_name(chain_name)
    
    # Get all racing scores grouped by provider
    racing_scores = 
      score_table
      |> :ets.tab2list()
      |> Enum.filter(fn {{_provider_id, _event_type, type}, _wins, _total, _avg, _updated} -> 
           type == :racing 
         end)
      |> Enum.group_by(fn {{provider_id, _event_type, _type}, _wins, _total, _avg, _updated} -> 
           provider_id 
         end)
    
    # Calculate overall scores for each provider
    Enum.map(racing_scores, fn {provider_id, entries} ->
      {total_wins, total_races, weighted_avg_margin} = 
        Enum.reduce(entries, {0, 0, 0.0}, fn {{_pid, _et, _type}, wins, total, avg_margin, _updated}, {acc_wins, acc_total, acc_margin} ->
          {acc_wins + wins, acc_total + total, acc_margin + (avg_margin * total)}
        end)
      
      win_rate = if total_races > 0, do: total_wins / total_races, else: 0.0
      avg_margin = if total_races > 0, do: weighted_avg_margin / total_races, else: 0.0
      
      %{
        provider_id: provider_id,
        total_wins: total_wins,
        total_races: total_races,
        win_rate: win_rate,
        avg_margin_ms: avg_margin,
        score: calculate_provider_score(win_rate, avg_margin, total_races)
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
      |> Enum.filter(fn {{pid, _event_type, _type}, _wins, _total, _avg, _updated} -> 
           pid == provider_id 
         end)
    
    # Group by type (racing vs rpc)
    {racing_entries, rpc_entries} = 
      Enum.split_with(provider_entries, fn {{_pid, _key, type}, _wins, _total, _avg, _updated} -> 
        type == :racing 
      end)
    
    racing_metrics = 
      Enum.map(racing_entries, fn {{_pid, event_type, _type}, wins, total, avg_margin, last_updated} ->
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
      Enum.map(rpc_entries, fn {{_pid, method, _type}, successes, total, avg_duration, last_updated} ->
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

  defp get_event_performance_stats(chain_name, event_type) do
    score_table = score_table_name(chain_name)
    
    # Get all racing entries for this event type
    event_entries = 
      score_table
      |> :ets.tab2list()
      |> Enum.filter(fn {{_pid, et, type}, _wins, _total, _avg, _updated} -> 
           type == :racing and et == event_type 
         end)
    
    provider_stats = 
      Enum.map(event_entries, fn {{provider_id, _et, _type}, wins, total, avg_margin, last_updated} ->
        %{
          provider_id: provider_id,
          wins: wins,
          total_races: total,
          win_rate: if(total > 0, do: wins / total, else: 0.0),
          avg_margin_ms: avg_margin,
          last_updated: last_updated
        }
      end)
      |> Enum.sort_by(& &1.win_rate, :desc)
    
    %{
      event_type: event_type,
      providers: provider_stats
    }
  end

  defp get_rpc_performance_stats(chain_name, method) do
    score_table = score_table_name(chain_name)
    
    # Get all RPC entries for this method
    method_entries = 
      score_table
      |> :ets.tab2list()
      |> Enum.filter(fn {{_pid, m, type}, _successes, _total, _avg, _updated} -> 
           type == :rpc and m == method 
         end)
    
    provider_stats = 
      Enum.map(method_entries, fn {{provider_id, _m, _type}, successes, total, avg_duration, last_updated} ->
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
      |> Enum.map(fn {{provider_id, _key, _type}, _stat1, _stat2, _stat3, _updated} -> provider_id end)
      |> Enum.uniq()
    
    event_types = 
      all_entries
      |> Enum.filter(fn {{_pid, _key, type}, _stat1, _stat2, _stat3, _updated} -> type == :racing end)
      |> Enum.map(fn {{_pid, event_type, _type}, _stat1, _stat2, _stat3, _updated} -> event_type end)
      |> Enum.uniq()
    
    rpc_methods = 
      all_entries
      |> Enum.filter(fn {{_pid, _key, type}, _stat1, _stat2, _stat3, _updated} -> type == :rpc end)
      |> Enum.map(fn {{_pid, method, _type}, _stat1, _stat2, _stat3, _updated} -> method end)
      |> Enum.uniq()
    
    %{
      providers: providers,
      event_types: event_types,
      rpc_methods: rpc_methods,
      total_entries: length(all_entries),
      last_updated: System.monotonic_time(:millisecond)
    }
  end

  defp create_performance_snapshot(chain_name) do
    score_table = score_table_name(chain_name)
    current_hour = div(System.system_time(:second), 3600) * 3600
    
    # Get all current scores as snapshot
    all_entries = :ets.tab2list(score_table)
    
    snapshot_data = 
      Enum.map(all_entries, fn {{provider_id, key, type}, stat1, stat2, stat3, last_updated} ->
        case type do
          :racing ->
            %{
              chain_name: chain_name,
              provider_id: provider_id,
              hour_timestamp: current_hour,
              event_type: key,
              wins: stat1,
              total_races: stat2,
              avg_margin_ms: stat3,
              rpc_method: nil,
              rpc_calls: nil,
              rpc_avg_duration_ms: nil,
              rpc_success_rate: nil
            }
          
          :rpc ->
            %{
              chain_name: chain_name,
              provider_id: provider_id,
              hour_timestamp: current_hour,
              event_type: nil,
              wins: nil,
              total_races: nil,
              avg_margin_ms: nil,
              rpc_method: key,
              rpc_calls: stat2,
              rpc_avg_duration_ms: stat3,
              rpc_success_rate: if(stat2 > 0, do: stat1 / stat2, else: 0.0)
            }
        end
      end)
    
    %{
      chain_name: chain_name,
      hour_timestamp: current_hour,
      snapshot_data: snapshot_data
    }
  end

  defp calculate_provider_score(win_rate, avg_margin_ms, total_races) do
    # Simple scoring algorithm - can be enhanced later
    # Higher win rate is better, lower margin is better, more races gives confidence
    confidence_factor = :math.log10(max(total_races, 1))
    margin_penalty = if avg_margin_ms > 0, do: 1 / (1 + avg_margin_ms / 100), else: 1.0
    
    win_rate * margin_penalty * confidence_factor
  end

  defp racing_table_name(chain_name), do: :"racing_metrics_#{chain_name}"
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
        Logger.debug("Table #{table_name} at limit (#{current_size}/#{@max_entries_per_chain}), removing oldest entries")
        
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
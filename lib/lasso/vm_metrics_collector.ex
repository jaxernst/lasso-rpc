defmodule Lasso.VMMetricsCollector do
  @moduledoc """
  Centralized BEAM VM metrics collector.

  This GenServer collects VM metrics at a fixed interval and broadcasts them
  to all subscribed LiveView processes. This architecture:

  1. **Fixes correctness issues**: `:erlang.statistics/1` calls for `:runtime`,
     `:wall_clock`, `:reductions`, and `:io` return global deltas since the last
     call by ANY process. With multiple dashboard users, each LiveView collecting
     independently would produce incorrect delta values. A single collector ensures
     accurate statistics.

  2. **Improves efficiency**: Metrics are collected once every interval regardless
     of how many dashboard users are connected, rather than N times for N users.

  3. **Scales better**: Supports 1000+ concurrent dashboard users since they all
     consume the same data stream.

  ## Configuration

  The collector is disabled by default in production SaaS deployments where
  exposing VM internals may not be appropriate. Enable via config:

      config :lasso, :vm_metrics_enabled, true

  When disabled, the collector process still starts but does not collect metrics
  and returns empty data to subscribers.
  """

  use GenServer
  require Logger

  alias LassoWeb.Dashboard.Helpers

  @collection_interval_ms 2_000
  @subscriber_cleanup_interval_ms 30_000

  defmodule State do
    @moduledoc false
    defstruct [
      :last_scheduler_times,
      :last_stats_time,
      :last_runtime,
      :last_wall_clock,
      :last_reductions,
      :last_io,
      :latest_metrics,
      :enabled,
      subscribers: %{}
    ]
  end

  ## Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if VM metrics collection is enabled.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:lasso, :vm_metrics_enabled, false)
  end

  @doc """
  Subscribe to receive metrics updates.
  Returns `{:ok, latest_metrics}` or `{:error, reason}`.

  The caller process will receive `{:vm_metrics_update, metrics}` messages
  at the configured collection interval.
  """
  @spec subscribe(pid()) :: {:ok, map() | nil} | {:error, :disabled}
  def subscribe(pid \\ self()) do
    GenServer.call(__MODULE__, {:subscribe, pid})
  end

  @doc """
  Unsubscribe from metrics updates.
  """
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid \\ self()) do
    GenServer.cast(__MODULE__, {:unsubscribe, pid})
  end

  @doc """
  Get the latest collected metrics without subscribing.
  Returns `nil` if no metrics have been collected yet or if disabled.
  """
  @spec get_latest_metrics() :: map() | nil
  def get_latest_metrics do
    GenServer.call(__MODULE__, :get_latest_metrics)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    enabled = enabled?()

    state =
      if enabled do
        # Enable scheduler wall time for utilization metrics
        try do
          :erlang.system_flag(:scheduler_wall_time, true)
        rescue
          _ -> :ok
        end

        # Prime the statistics for delta calculations
        initial_sched =
          try do
            :erlang.statistics(:scheduler_wall_time)
          catch
            :error, _ -> :not_available
          end

        {rt_total, _} = :erlang.statistics(:runtime)
        {wc_total, _} = :erlang.statistics(:wall_clock)
        {red_total, _} = :erlang.statistics(:reductions)
        {{:input, io_in}, {:output, io_out}} = :erlang.statistics(:io)

        now = System.monotonic_time(:millisecond)

        %State{
          last_scheduler_times: initial_sched,
          last_stats_time: now,
          last_runtime: rt_total,
          last_wall_clock: wc_total,
          last_reductions: red_total,
          last_io: {io_in, io_out},
          latest_metrics: nil,
          enabled: true,
          subscribers: %{}
        }
      else
        Logger.info("VM metrics collection disabled")

        %State{
          last_scheduler_times: nil,
          last_stats_time: nil,
          last_runtime: nil,
          last_wall_clock: nil,
          last_reductions: nil,
          last_io: nil,
          latest_metrics: %{enabled: false},
          enabled: false,
          subscribers: %{}
        }
      end

    # Schedule first collection (even if disabled, to maintain subscriber list)
    schedule_collection()
    schedule_cleanup()

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    # Monitor subscriber so we can clean up when it dies
    ref = Process.monitor(pid)

    new_subscribers = Map.put(state.subscribers, pid, ref)
    new_state = %{state | subscribers: new_subscribers}

    # Return latest metrics immediately if available
    {:reply, {:ok, state.latest_metrics}, new_state}
  end

  @impl true
  def handle_call(:get_latest_metrics, _from, state) do
    {:reply, state.latest_metrics, state}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    state = remove_subscriber(state, pid)
    {:noreply, state}
  end

  @impl true
  def handle_info(:collect_metrics, %{enabled: false} = state) do
    # When disabled, just broadcast empty metrics to maintain subscriber expectations
    broadcast_metrics(state.subscribers, %{enabled: false})
    schedule_collection()
    {:noreply, state}
  end

  @impl true
  def handle_info(:collect_metrics, state) do
    start_time = System.monotonic_time(:microsecond)

    # Collect metrics with proper delta calculations
    {metrics, new_state} = collect_metrics(state)

    collection_time = System.monotonic_time(:microsecond) - start_time
    metrics = Map.put(metrics, :collection_time_us, collection_time)

    # Broadcast to all subscribers
    broadcast_metrics(state.subscribers, metrics)

    # Log if collection is slow (> 1ms)
    if collection_time > 1_000 do
      Logger.warning("Slow VM metrics collection: #{collection_time}μs",
        subscriber_count: map_size(state.subscribers)
      )
    end

    schedule_collection()
    {:noreply, %{new_state | latest_metrics: metrics}}
  end

  @impl true
  def handle_info(:cleanup_dead_subscribers, state) do
    # Remove any dead processes we might have missed
    alive_subscribers =
      state.subscribers
      |> Enum.filter(fn {pid, _ref} -> Process.alive?(pid) end)
      |> Map.new()

    schedule_cleanup()
    {:noreply, %{state | subscribers: alive_subscribers}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Subscriber died, clean it up
    state = remove_subscriber(state, pid)
    {:noreply, state}
  end

  ## Private Functions

  defp collect_metrics(state) do
    now = System.monotonic_time(:millisecond)
    time_delta_ms = now - state.last_stats_time

    # Memory (relatively expensive, ~5-50μs)
    mem = :erlang.memory()

    # Scheduler utilization (cheap, ~2-5μs)
    current_sched =
      try do
        :erlang.statistics(:scheduler_wall_time)
      catch
        :error, _ -> :not_available
      end

    sched_util_avg =
      calculate_scheduler_utilization(
        state.last_scheduler_times,
        current_sched
      )

    # Statistics - we calculate our own deltas from totals
    # This avoids the global delta interference issue
    {rt_total, _rt_delta} = :erlang.statistics(:runtime)
    {wc_total, _wc_delta} = :erlang.statistics(:wall_clock)
    {red_total, _red_delta} = :erlang.statistics(:reductions)
    {{:input, io_in}, {:output, io_out}} = :erlang.statistics(:io)

    # Calculate our own deltas from tracked state
    rt_delta = rt_total - state.last_runtime
    wc_delta = wc_total - state.last_wall_clock
    red_delta = red_total - state.last_reductions
    {last_io_in, last_io_out} = state.last_io
    io_in_delta = io_in - last_io_in
    io_out_delta = io_out - last_io_out

    cpu_percent =
      if wc_delta > 0 do
        min(100.0, 100.0 * rt_delta / wc_delta)
      else
        0.0
      end

    # Normalize reductions to per-second rate
    reductions_per_sec =
      if time_delta_ms > 0 do
        trunc(red_delta * 1000 / time_delta_ms)
      else
        0
      end

    metrics = %{
      enabled: true,
      timestamp: now,
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
      cpu_percent: Float.round(cpu_percent, 2),
      reductions_s: reductions_per_sec,
      io_in_mb: Helpers.to_mb(io_in_delta),
      io_out_mb: Helpers.to_mb(io_out_delta),
      sched_util_avg: sched_util_avg,
      subscriber_count: map_size(state.subscribers)
    }

    new_state = %{
      state
      | last_scheduler_times: current_sched,
        last_stats_time: now,
        last_runtime: rt_total,
        last_wall_clock: wc_total,
        last_reductions: red_total,
        last_io: {io_in, io_out}
    }

    {metrics, new_state}
  end

  defp calculate_scheduler_utilization(nil, _current), do: nil
  defp calculate_scheduler_utilization(_last, nil), do: nil
  defp calculate_scheduler_utilization(:not_available, _), do: nil
  defp calculate_scheduler_utilization(_, :not_available), do: nil

  defp calculate_scheduler_utilization(last_times, current_times)
       when is_list(last_times) and is_list(current_times) do
    last_map = Map.new(last_times, fn {id, active, total} -> {id, {active, total}} end)

    utilizations =
      Enum.map(current_times, fn {id, curr_active, curr_total} ->
        case Map.get(last_map, id) do
          {last_active, last_total} ->
            active_delta = curr_active - last_active
            total_delta = curr_total - last_total

            if total_delta > 0 do
              100.0 * active_delta / total_delta
            else
              0.0
            end

          nil ->
            0.0
        end
      end)

    if length(utilizations) > 0 do
      Float.round(Enum.sum(utilizations) / length(utilizations), 2)
    else
      nil
    end
  end

  defp broadcast_metrics(subscribers, metrics) do
    Enum.each(subscribers, fn {pid, _ref} ->
      send(pid, {:vm_metrics_update, metrics})
    end)
  end

  defp remove_subscriber(state, pid) do
    case Map.get(state.subscribers, pid) do
      nil ->
        state

      ref ->
        Process.demonitor(ref, [:flush])
        new_subscribers = Map.delete(state.subscribers, pid)
        %{state | subscribers: new_subscribers}
    end
  end

  defp schedule_collection do
    Process.send_after(self(), :collect_metrics, @collection_interval_ms)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_dead_subscribers, @subscriber_cleanup_interval_ms)
  end
end

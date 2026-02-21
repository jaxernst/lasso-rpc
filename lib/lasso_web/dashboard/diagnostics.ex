defmodule LassoWeb.Dashboard.Diagnostics do
  @moduledoc """
  Runtime diagnostics for dashboard LiveView process health.

  Attach in IEx on staging/prod to diagnose freezes:

      LassoWeb.Dashboard.Diagnostics.start()

  Then click around in the dashboard. Slow callbacks and queue buildup
  will be logged to the console. When done:

      LassoWeb.Dashboard.Diagnostics.stop()
  """

  require Logger

  @slow_threshold_ms 100
  @queue_alarm_threshold 50
  @poll_interval_ms 2_000

  # -- Public API --

  def start(opts \\ []) do
    threshold = Keyword.get(opts, :threshold_ms, @slow_threshold_ms)
    poll_interval = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)

    attach_handle_event_telemetry(threshold)
    {:ok, pid} = start_queue_monitor(poll_interval)

    IO.puts("""
    [Diagnostics] Started
      - handle_event slow-log threshold: #{threshold}ms
      - queue monitor polling every: #{poll_interval}ms
      - queue alarm threshold: #{@queue_alarm_threshold} messages
    """)

    {:ok, pid}
  end

  def stop do
    :telemetry.detach("lasso.dashboard.diag.handle_event.start")
    :telemetry.detach("lasso.dashboard.diag.handle_event.stop")

    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    IO.puts("[Diagnostics] Stopped")
    :ok
  end

  @doc """
  One-shot snapshot of all dashboard LiveView processes.
  """
  def snapshot do
    lv_pids = find_dashboard_lv_pids()

    IO.puts("\n=== Dashboard LiveView Process Snapshot ===")
    IO.puts("Found #{length(lv_pids)} dashboard LV process(es)\n")

    for {pid, info} <- lv_pids do
      queue_len = Keyword.get(info, :message_queue_len, 0)
      reductions = Keyword.get(info, :reductions, 0)
      memory = Keyword.get(info, :memory, 0)
      status = Keyword.get(info, :status, :unknown)
      current_fn = Keyword.get(info, :current_function, :unknown)

      marker = if queue_len > @queue_alarm_threshold, do: " ⚠️  QUEUE BUILDUP", else: ""

      IO.puts("""
        PID: #{inspect(pid)}#{marker}
          status:       #{status}
          current_fn:   #{inspect(current_fn)}
          msg_queue:    #{queue_len}
          reductions:   #{reductions}
          memory:       #{div(memory, 1024)}KB
      """)
    end

    snapshot_genservers()
  end

  @doc """
  Continuous trace of a specific LV process — shows message queue length
  every 200ms for `duration_ms`. Use to watch queue buildup in real-time
  while clicking.
  """
  def trace_pid(pid, duration_ms \\ 10_000) do
    IO.puts("[Diagnostics] Tracing #{inspect(pid)} for #{duration_ms}ms...")

    end_time = System.monotonic_time(:millisecond) + duration_ms
    trace_loop(pid, end_time, 0)
  end

  # -- Telemetry Handlers --

  defp attach_handle_event_telemetry(threshold) do
    :telemetry.attach(
      "lasso.dashboard.diag.handle_event.start",
      [:phoenix, :live_view, :handle_event, :start],
      fn _event, measurements, metadata, _config ->
        pid = self()
        queue_len = Process.info(pid, :message_queue_len) |> elem(1)

        if queue_len > 10 do
          IO.puts(
            "[Diagnostics] handle_event START event=#{metadata.event} " <>
              "queue_len=#{queue_len} pid=#{inspect(pid)}"
          )
        end

        Process.put(:diag_handle_event_start, System.monotonic_time(:microsecond))
        Process.put(:diag_handle_event_name, metadata.event)
        Process.put(:diag_handle_event_queue, queue_len)
        _ = measurements
      end,
      nil
    )

    :telemetry.attach(
      "lasso.dashboard.diag.handle_event.stop",
      [:phoenix, :live_view, :handle_event, :stop],
      fn _event, measurements, metadata, _config ->
        start_time = Process.get(:diag_handle_event_start)

        if start_time do
          elapsed_us = System.monotonic_time(:microsecond) - start_time
          elapsed_ms = elapsed_us / 1_000
          event_name = Process.get(:diag_handle_event_name, metadata.event)
          queue_before = Process.get(:diag_handle_event_queue, 0)
          queue_after = Process.info(self(), :message_queue_len) |> elem(1)

          if elapsed_ms > threshold do
            IO.puts(
              "[Diagnostics] SLOW handle_event " <>
                "event=#{event_name} " <>
                "duration=#{Float.round(elapsed_ms, 1)}ms " <>
                "queue_before=#{queue_before} queue_after=#{queue_after} " <>
                "pid=#{inspect(self())}"
            )
          end

          Process.delete(:diag_handle_event_start)
          Process.delete(:diag_handle_event_name)
          Process.delete(:diag_handle_event_queue)
        end

        _ = measurements
      end,
      nil
    )
  end

  # -- Queue Monitor (GenServer) --

  use GenServer

  defp start_queue_monitor(interval) do
    GenServer.start_link(__MODULE__, interval, name: __MODULE__)
  end

  @impl true
  def init(interval) do
    Process.send_after(self(), :poll, interval)
    {:ok, %{interval: interval, max_seen: %{}, alert_count: 0}}
  end

  @impl true
  def handle_info(:poll, state) do
    lv_pids = find_dashboard_lv_pids()

    state =
      Enum.reduce(lv_pids, state, fn {pid, info}, acc ->
        queue_len = Keyword.get(info, :message_queue_len, 0)
        prev_max = Map.get(acc.max_seen, pid, 0)
        new_max = max(queue_len, prev_max)

        if queue_len > @queue_alarm_threshold do
          status = Keyword.get(info, :status, :unknown)
          current_fn = Keyword.get(info, :current_function, :unknown)

          IO.puts(
            "[Diagnostics] ⚠️  QUEUE BUILDUP pid=#{inspect(pid)} " <>
              "queue=#{queue_len} status=#{status} " <>
              "current_fn=#{inspect(current_fn)} " <>
              "max_seen=#{new_max}"
          )

          %{acc | max_seen: Map.put(acc.max_seen, pid, new_max), alert_count: acc.alert_count + 1}
        else
          %{acc | max_seen: Map.put(acc.max_seen, pid, new_max)}
        end
      end)

    # Also monitor key GenServers
    check_genserver_health()

    Process.send_after(self(), :poll, state.interval)
    {:noreply, state}
  end

  # -- Helpers --

  defp find_dashboard_lv_pids do
    for pid <- Process.list(),
        info =
          Process.info(pid, [
            :dictionary,
            :message_queue_len,
            :reductions,
            :memory,
            :status,
            :current_function
          ]),
        info != nil,
        dict = Keyword.get(info, :dictionary, []),
        Enum.any?(dict, fn
          {:"$initial_call", {LassoWeb.Dashboard, _, _}} -> true
          _ -> false
        end) do
      {pid, info}
    end
  end

  defp snapshot_genservers do
    IO.puts("=== Key GenServer Health ===\n")

    genservers = [
      {LassoWeb.Dashboard.MetricsStore, "MetricsStore"},
      {Lasso.Finch, "Finch (HTTP)"}
    ]

    for {name, label} <- genservers do
      case Process.whereis(name) do
        nil ->
          IO.puts("  #{label}: not running")

        pid ->
          info =
            Process.info(pid, [
              :message_queue_len,
              :reductions,
              :memory,
              :status,
              :current_function
            ])

          queue = Keyword.get(info, :message_queue_len, 0)
          status = Keyword.get(info, :status, :unknown)

          IO.puts("  #{label} (#{inspect(pid)}): queue=#{queue} status=#{status}")
      end
    end

    # EventStream processes (one per profile)
    IO.puts("")

    event_streams =
      Registry.select(Lasso.Dashboard.StreamRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])

    case event_streams do
      [] ->
        IO.puts("  EventStream: no instances running")

      pids ->
        for pid <- pids do
          info = Process.info(pid, [:message_queue_len, :status, :current_function])
          queue = Keyword.get(info || [], :message_queue_len, 0)
          status = Keyword.get(info || [], :status, :unknown)

          IO.puts("  EventStream (#{inspect(pid)}): queue=#{queue} status=#{status}")
        end
    end

    IO.puts("")
  end

  defp check_genserver_health do
    event_streams =
      try do
        Registry.select(Lasso.Dashboard.StreamRegistry, [{{:_, :"$1", :_}, [], [:"$1"]}])
      rescue
        _ -> []
      end

    for pid <- event_streams, is_pid(pid), Process.alive?(pid) do
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, len} when len > @queue_alarm_threshold ->
          IO.puts(
            "[Diagnostics] ⚠️  EventStream queue buildup " <>
              "pid=#{inspect(pid)} queue=#{len}"
          )

        _ ->
          :ok
      end
    end
  end

  defp trace_loop(pid, end_time, count) do
    now = System.monotonic_time(:millisecond)

    if now >= end_time or not Process.alive?(pid) do
      IO.puts("[Diagnostics] Trace complete. #{count} samples collected.")
      :ok
    else
      case Process.info(pid, [:message_queue_len, :status, :current_function]) do
        nil ->
          IO.puts("[Diagnostics] Process #{inspect(pid)} died during trace.")
          :ok

        info ->
          queue = Keyword.get(info, :message_queue_len, 0)
          status = Keyword.get(info, :status, :unknown)
          current_fn = Keyword.get(info, :current_function, :unknown)

          if queue > 5 do
            IO.puts("  [#{count}] queue=#{queue} status=#{status} fn=#{inspect(current_fn)}")
          end

          Process.sleep(200)
          trace_loop(pid, end_time, count + 1)
      end
    end
  end
end

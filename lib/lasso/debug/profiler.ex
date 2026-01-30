defmodule Lasso.Debug.Profiler do
  @moduledoc """
  Production profiling utilities for identifying CPU hotspots.

  Usage from IEx console:

      Lasso.Debug.Profiler.reduction_snapshot(5_000)
      Lasso.Debug.Profiler.process_inventory()
      Lasso.Debug.Profiler.timer_inventory()
      Lasso.Debug.Profiler.scheduler_util()
  """

  @doc """
  Take a reduction snapshot over the given duration (default 5 seconds).
  Returns the top processes by CPU work.
  """
  @spec reduction_snapshot(non_neg_integer()) :: list()
  def reduction_snapshot(duration_ms \\ 5_000) do
    IO.puts("Taking #{duration_ms}ms reduction snapshot...")

    snap1 = capture_reductions()
    Process.sleep(duration_ms)
    snap2 = capture_reductions()

    results =
      snap2
      |> Enum.map(fn {pid, info2} ->
        case Map.get(snap1, pid) do
          nil ->
            nil

          info1 ->
            delta = info2[:reductions] - info1[:reductions]

            {pid, info2[:registered_name], delta, info2[:current_function],
             info2[:message_queue_len]}
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&elem(&1, 2), :desc)
      |> Enum.take(25)

    IO.puts("\nTop 25 processes by reductions (#{duration_ms}ms window):")
    IO.puts(String.duplicate("-", 90))

    Enum.each(results, fn {pid, name, delta, func, mq_len} ->
      label = format_process_label(pid, name)

      IO.puts(
        "#{String.pad_trailing(label, 50)} #{String.pad_leading(format_number(delta), 12)} reductions  mq=#{mq_len}  #{inspect(func)}"
      )
    end)

    IO.puts(String.duplicate("-", 90))
    total = Enum.reduce(results, 0, fn {_, _, delta, _, _}, acc -> acc + delta end)
    IO.puts("Total (top 25): #{format_number(total)} reductions")

    results
  end

  @doc """
  Show inventory of all active processes by type.
  """
  @spec process_inventory() :: map()
  def process_inventory do
    processes =
      for pid <- Process.list(),
          info = Process.info(pid, [:dictionary, :initial_call, :registered_name, :memory]),
          info != nil do
        {pid, info}
      end

    categories = categorize_processes(processes)

    IO.puts("\nProcess Inventory:")
    IO.puts(String.duplicate("-", 60))

    categories
    |> Enum.sort_by(fn {_, procs} -> length(procs) end, :desc)
    |> Enum.each(fn {category, procs} ->
      total_mem = procs |> Enum.map(fn {_, info} -> info[:memory] || 0 end) |> Enum.sum()

      IO.puts(
        "#{String.pad_trailing(category, 40)} #{String.pad_leading(to_string(length(procs)), 5)}  (#{format_bytes(total_mem)})"
      )
    end)

    IO.puts(String.duplicate("-", 60))
    IO.puts("Total processes: #{length(processes)}")

    categories
  end

  @doc """
  Find all active timers (Process.send_after) in the system.
  """
  @spec timer_inventory() :: list()
  def timer_inventory do
    timers =
      for pid <- Process.list(),
          info = Process.info(pid, [:dictionary, :registered_name, :timers]),
          info != nil,
          info[:timers] != nil do
        {pid, info[:registered_name], info[:timers]}
      end
      |> Enum.filter(fn {_, _, timers} -> timers != [] end)

    IO.puts("\nActive Timers by Process:")
    IO.puts(String.duplicate("-", 60))

    timers
    |> Enum.sort_by(fn {_, _, t} -> length(t) end, :desc)
    |> Enum.take(20)
    |> Enum.each(fn {pid, name, timer_list} ->
      label = name || inspect(pid)
      IO.puts("#{label}: #{length(timer_list)} timers")
    end)

    IO.puts(String.duplicate("-", 60))
    total = Enum.reduce(timers, 0, fn {_, _, t}, acc -> acc + length(t) end)
    IO.puts("Total active timers: #{total}")

    timers
  end

  @doc """
  Show scheduler utilization over the given duration.
  """
  @spec scheduler_util(non_neg_integer()) :: list()
  def scheduler_util(duration_ms \\ 5_000) do
    IO.puts("Measuring scheduler utilization over #{duration_ms}ms...")

    try do
      :erlang.system_flag(:scheduler_wall_time, true)
    rescue
      _ -> :ok
    end

    snap1 = :erlang.statistics(:scheduler_wall_time)
    Process.sleep(duration_ms)
    snap2 = :erlang.statistics(:scheduler_wall_time)

    utilizations = calculate_utilization(snap1, snap2)

    IO.puts("\nScheduler Utilization:")
    IO.puts(String.duplicate("-", 40))

    Enum.each(utilizations, fn {id, util} ->
      bar = String.duplicate("█", trunc(util / 5))

      IO.puts(
        "Scheduler #{String.pad_leading(to_string(id), 2)}: #{String.pad_leading(:erlang.float_to_binary(util, decimals: 1), 5)}%  #{bar}"
      )
    end)

    avg = Enum.reduce(utilizations, 0.0, fn {_, u}, acc -> acc + u end) / length(utilizations)
    IO.puts(String.duplicate("-", 40))
    IO.puts("Average: #{:erlang.float_to_binary(avg, decimals: 2)}%")

    utilizations
  end

  @doc """
  Summary report with key metrics.
  """
  @spec summary_report(non_neg_integer()) :: :ok
  def summary_report(duration_ms \\ 5_000) do
    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("LASSO PERFORMANCE SUMMARY REPORT")
    IO.puts(String.duplicate("=", 70))

    scheduler_util(duration_ms)
    process_inventory()
    reduction_snapshot(duration_ms)

    IO.puts("\n" <> String.duplicate("=", 70))
    IO.puts("END REPORT")
    IO.puts(String.duplicate("=", 70))
  end

  # Private helpers

  defp capture_reductions do
    for pid <- Process.list(),
        info =
          Process.info(pid, [:reductions, :registered_name, :current_function, :message_queue_len]),
        info != nil,
        into: %{} do
      {pid, info}
    end
  end

  defp format_process_label(pid, nil) do
    case Process.info(pid, [:dictionary, :initial_call]) do
      nil ->
        inspect(pid)

      info ->
        case get_in(info, [:dictionary, :"$initial_call"]) do
          nil ->
            case get_in(info, [:dictionary, :"$process_label"]) do
              nil -> inspect(pid)
              label -> inspect(label)
            end

          {m, f, a} ->
            "#{inspect(m)}.#{f}/#{a}"
        end
    end
  end

  defp format_process_label(_pid, name), do: inspect(name)

  defp categorize_processes(processes) do
    processes
    |> Enum.group_by(fn {_pid, info} ->
      cond do
        match?({:via, _, {Lasso.Registry, {:block_sync_worker, _, _, _}}}, info[:registered_name]) ->
          "BlockSync.Worker"

        match?(
          {:via, _, {Lasso.Registry, {:health_probe_coordinator, _, _}}},
          info[:registered_name]
        ) ->
          "HealthProbe.BatchCoordinator"

        match?({:via, _, {Lasso.Registry, {:ws_connection, _, _, _}}}, info[:registered_name]) ->
          "WebSocket.Connection"

        info[:registered_name] != nil and is_atom(info[:registered_name]) ->
          Atom.to_string(info[:registered_name])

        true ->
          case get_in(info, [:dictionary, :"$initial_call"]) do
            nil -> "Other"
            {m, _, _} -> inspect(m)
          end
      end
    end)
  end

  defp calculate_utilization(snap1, snap2) when is_list(snap1) and is_list(snap2) do
    last_map = Map.new(snap1, fn {id, active, total} -> {id, {active, total}} end)

    snap2
    |> Enum.map(fn {id, curr_active, curr_total} ->
      case Map.get(last_map, id) do
        {last_active, last_total} ->
          active_delta = curr_active - last_active
          total_delta = curr_total - last_total
          util = if total_delta > 0, do: 100.0 * active_delta / total_delta, else: 0.0
          {id, util}

        nil ->
          {id, 0.0}
      end
    end)
    |> Enum.sort_by(fn {id, _} -> id end)
  end

  defp calculate_utilization(_, _), do: []

  defp format_number(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n), do: to_string(n)

  defp format_bytes(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes) when bytes >= 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes), do: "#{bytes} B"
end

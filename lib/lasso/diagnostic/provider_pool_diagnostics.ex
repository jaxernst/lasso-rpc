defmodule Lasso.Diagnostic.ProviderPoolDiagnostics do
  @moduledoc """
  Diagnostic tools for analyzing ProviderPool performance bottlenecks.

  Usage in production:
    # Start monitoring a specific chain
    Lasso.Diagnostic.ProviderPoolDiagnostics.start_monitoring("ethereum", interval_ms: 100)

    # Check current mailbox state
    Lasso.Diagnostic.ProviderPoolDiagnostics.check_mailbox("ethereum")

    # Get process info
    Lasso.Diagnostic.ProviderPoolDiagnostics.process_info("ethereum")
  """

  require Logger
  alias Lasso.RPC.ProviderPool

  @doc """
  Continuously monitors the ProviderPool GenServer for a chain.

  Options:
    - interval_ms: How often to check (default: 100ms)
    - duration_ms: How long to monitor (default: 10_000ms = 10 seconds)
    - log_threshold: Only log if mailbox exceeds this size (default: 5)
  """
  def start_monitoring(chain_name, opts \\ []) do
    interval_ms = Keyword.get(opts, :interval_ms, 100)
    duration_ms = Keyword.get(opts, :duration_ms, 10_000)
    log_threshold = Keyword.get(opts, :log_threshold, 5)

    Task.start(fn ->
      Logger.info("Starting ProviderPool monitoring for #{chain_name}")
      end_time = System.monotonic_time(:millisecond) + duration_ms
      monitor_loop(chain_name, interval_ms, end_time, log_threshold, [])
    end)
  end

  defp monitor_loop(chain_name, interval_ms, end_time, log_threshold, samples) do
    now = System.monotonic_time(:millisecond)

    if now >= end_time do
      # Report summary
      report_summary(chain_name, samples)
    else
      sample = collect_sample(chain_name)

      if sample.message_queue_len >= log_threshold do
        Logger.warning(
          "[ProviderPool] #{chain_name}: mailbox=#{sample.message_queue_len}, " <>
            "reductions=#{sample.reductions}, memory=#{div(sample.memory, 1024)}KB"
        )
      end

      Process.sleep(interval_ms)
      monitor_loop(chain_name, interval_ms, end_time, log_threshold, [sample | samples])
    end
  end

  defp collect_sample(chain_name) do
    case GenServer.whereis(ProviderPool.via_name(chain_name)) do
      nil ->
        %{
          timestamp: System.monotonic_time(:millisecond),
          message_queue_len: :not_found,
          reductions: :not_found,
          memory: :not_found,
          status: :not_found
        }

      pid ->
        info = Process.info(pid, [:message_queue_len, :reductions, :memory, :status])

        %{
          timestamp: System.monotonic_time(:millisecond),
          message_queue_len: info[:message_queue_len] || 0,
          reductions: info[:reductions] || 0,
          memory: info[:memory] || 0,
          status: info[:status] || :unknown
        }
    end
  end

  defp report_summary(chain_name, samples) do
    valid_samples = Enum.reject(samples, fn s -> s.message_queue_len == :not_found end)

    if Enum.empty?(valid_samples) do
      Logger.warning("[ProviderPool] #{chain_name}: No valid samples collected")
    else
      mailbox_sizes = Enum.map(valid_samples, & &1.message_queue_len)
      reductions = Enum.map(valid_samples, & &1.reductions)

      Logger.info("""
      [ProviderPool] #{chain_name} Monitoring Summary:
        Samples: #{length(valid_samples)}
        Mailbox: max=#{Enum.max(mailbox_sizes)}, avg=#{avg(mailbox_sizes)}, p95=#{percentile(mailbox_sizes, 0.95)}
        Reductions: max=#{Enum.max(reductions)}, avg=#{avg(reductions)}
      """)
    end
  end

  @doc """
  Gets current mailbox and process info for a chain's ProviderPool.
  """
  def check_mailbox(chain_name) do
    case GenServer.whereis(ProviderPool.via_name(chain_name)) do
      nil ->
        {:error, :not_found}

      pid ->
        info =
          Process.info(pid, [
            :message_queue_len,
            :reductions,
            :memory,
            :status,
            :current_function,
            :current_stacktrace
          ])

        {:ok, info}
    end
  end

  @doc """
  Gets detailed process information including backtrace.
  Use this to see if the GenServer is stuck in a specific call.
  """
  def process_info(chain_name) do
    case GenServer.whereis(ProviderPool.via_name(chain_name)) do
      nil ->
        {:error, :not_found}

      pid ->
        info =
          Process.info(pid, [
            :message_queue_len,
            :messages,
            :reductions,
            :memory,
            :status,
            :current_function,
            :current_stacktrace,
            :total_heap_size,
            :heap_size,
            :stack_size,
            :garbage_collection
          ])

        {:ok, info}
    end
  end

  @doc """
  Measures the actual time spent in list_candidates under load.

  Returns timing breakdown:
  - total_us: Total time including GenServer.call overhead
  - call_us: Time waiting in mailbox + processing
  - handle_call_us: Actual processing time (if measurable)
  """
  def measure_list_candidates(chain_name, filters \\ %{}, iterations \\ 100) do
    measurements =
      for _ <- 1..iterations do
        start = System.monotonic_time(:microsecond)
        _result = ProviderPool.list_candidates(chain_name, filters)
        duration_us = System.monotonic_time(:microsecond) - start
        duration_us
      end

    %{
      iterations: iterations,
      min_us: Enum.min(measurements),
      max_us: Enum.max(measurements),
      avg_us: avg(measurements),
      median_us: percentile(measurements, 0.5),
      p95_us: percentile(measurements, 0.95),
      p99_us: percentile(measurements, 0.99),
      total_ms: Enum.sum(measurements) / 1000
    }
  end

  @doc """
  Simulates concurrent load to reproduce the bottleneck.

  Spawns `concurrency` processes that each make `requests_per_process` calls.
  """
  def simulate_load(chain_name, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, 20)
    requests_per_process = Keyword.get(opts, :requests_per_process, 10)
    filters = Keyword.get(opts, :filters, %{})

    Logger.info("Starting load simulation: #{concurrency} concurrent, #{requests_per_process} requests each")

    start_time = System.monotonic_time(:millisecond)

    tasks =
      for i <- 1..concurrency do
        Task.async(fn ->
          timings =
            for j <- 1..requests_per_process do
              request_start = System.monotonic_time(:microsecond)
              _result = ProviderPool.list_candidates(chain_name, filters)
              duration_us = System.monotonic_time(:microsecond) - request_start

              %{
                worker: i,
                request: j,
                duration_us: duration_us,
                timestamp: System.monotonic_time(:millisecond)
              }
            end

          timings
        end)
      end

    results = Task.await_many(tasks, 30_000)
    total_time_ms = System.monotonic_time(:millisecond) - start_time

    all_timings = List.flatten(results)
    durations = Enum.map(all_timings, & &1.duration_us)

    %{
      total_requests: length(all_timings),
      total_time_ms: total_time_ms,
      throughput_per_sec: length(all_timings) / (total_time_ms / 1000),
      latency_min_us: Enum.min(durations),
      latency_max_us: Enum.max(durations),
      latency_avg_us: avg(durations),
      latency_median_us: percentile(durations, 0.5),
      latency_p95_us: percentile(durations, 0.95),
      latency_p99_us: percentile(durations, 0.99),
      raw_timings: all_timings
    }
  end

  # Helpers

  defp avg([]), do: 0
  defp avg(list), do: Enum.sum(list) / length(list)

  defp percentile(list, p) when p >= 0 and p <= 1 do
    sorted = Enum.sort(list)
    index = round(length(sorted) * p) - 1
    index = max(0, min(index, length(sorted) - 1))
    Enum.at(sorted, index)
  end
end

Code.require_file("response_parser.ex", __DIR__)
Code.require_file("corpus.ex", __DIR__)

defmodule LassoPrototype.TransportEquivalent do
  @moduledoc """
  PROTOTYPE equivalent of the active transport worktree's same-ID HTTP
  `UpstreamResponse.validate_unary/3` seam.

  The active worktree uses the same OTP callback parser. This wrapper adds its
  response-struct construction and preserves the current second parse for
  JSON-RPC error responses without importing or modifying the dirty worktree.
  """

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.Response
  alias LassoPrototype.ResponseParser

  def validate(raw_bytes, expected_id) do
    case ResponseParser.validate(raw_bytes, expected_id) do
      {:ok, %{kind: :result}} ->
        {:ok, %Response.Success{id: expected_id, jsonrpc: "2.0", raw_bytes: raw_bytes}}

      {:ok, %{kind: :error, error_code: code, error_message: message}} ->
        case Response.from_bytes(raw_bytes) do
          {:ok, %Response.Error{error: %JError{} = error}} -> {:error, error}
          _unexpected -> {:error, JError.new(code, message)}
        end

      {:error, reason} ->
        {:invalid, reason}
    end
  end
end

defmodule LassoPrototype.RealisticCorpusRunner do
  @moduledoc false

  alias LassoPrototype.{ResponseCorpus, ResponseParser, TransportEquivalent}

  @methods [:otp_discard, :transport_equivalent, :jason]
  @runs 5
  @concurrency 64
  @word_size :erlang.system_info(:wordsize)

  def main do
    entries = ResponseCorpus.entries()
    validate_corpus!(entries)

    IO.puts("PROTOTYPE realistic EVM response corpus")
    IO.puts("Runtime: OTP #{System.otp_release()} / Elixir #{System.version()}")
    IO.puts("Weights are a provisional request-frequency model, not production telemetry.")
    IO.puts("")

    rows = benchmark_c1(entries)
    print_c1(rows)
    IO.puts("")
    print_weighted(rows)
    IO.puts("")

    concurrent_rows = benchmark_c64(entries)
    print_c64(concurrent_rows)
  end

  defp validate_corpus!(entries) do
    unless Enum.sum_by(entries, & &1.weight_bp) == 10_000 do
      raise "corpus weights must total 10,000 basis points"
    end

    Enum.each(entries, fn entry ->
      case ResponseParser.validate(entry.bytes, 7) do
        {:ok, %{kind: kind, raw_bytes: returned}}
        when kind in [:result, :error] and returned == entry.bytes ->
          unless :erts_debug.same(returned, entry.bytes), do: raise("raw identity lost")

        other ->
          raise "invalid corpus entry #{entry.shape}/#{entry.size_label}: #{inspect(other)}"
      end
    end)
  end

  defp adapters do
    %{
      otp_discard: &ResponseParser.validate/2,
      transport_equivalent: &TransportEquivalent.validate/2,
      jason: &jason_validate/2
    }
  end

  defp jason_validate(raw_bytes, expected_id) do
    with {:ok, decoded} <- Jason.decode(raw_bytes),
         %{"jsonrpc" => "2.0", "id" => ^expected_id} <- decoded,
         {:ok, kind} <- jason_kind(decoded) do
      {:ok, %{kind: kind, id: expected_id, raw_bytes: raw_bytes}}
    else
      _invalid -> {:invalid, :invalid_response}
    end
  end

  defp jason_kind(decoded) do
    case {Map.has_key?(decoded, "result"), Map.has_key?(decoded, "error")} do
      {true, false} ->
        {:ok, :result}

      {false, true} ->
        case decoded["error"] do
          %{"code" => code, "message" => message}
          when is_integer(code) and is_binary(message) ->
            {:ok, :error}

          _invalid ->
            {:invalid, :invalid_error}
        end

      _ambiguous ->
        {:invalid, :ambiguous_response}
    end
  end

  defp benchmark_c1(entries) do
    Enum.flat_map(entries, fn entry ->
      Enum.each(@methods, fn method ->
        result = run_adapter(method, entry.bytes)
        ensure_valid_result!(entry.shape, method, result)
      end)

      samples =
        Enum.reduce(0..(@runs - 1), Map.new(@methods, &{&1, []}), fn run, acc ->
          methods = rotate(@methods, run)

          Enum.reduce(methods, acc, fn method, run_acc ->
            sample = measure_c1(method, entry)
            Map.update!(run_acc, method, &[sample | &1])
          end)
        end)

      Enum.map(@methods, fn method ->
        summarize_c1(entry, method, Map.fetch!(samples, method))
      end)
    end)
  end

  defp measure_c1(method, entry) do
    parent = self()

    pid =
      :erlang.spawn_opt(
        fn -> measurement_worker(parent, method, entry.shape, entry.bytes) end,
        fullsweep_after: 65_535
      )

    receive do
      {:measurement_ready, ^pid, baseline} ->
        :erlang.trace(pid, true, [:garbage_collection])
        send(pid, :measure)
        collect_c1(pid, baseline, 0)
    after
      30_000 ->
        Process.exit(pid, :kill)
        raise "c1 setup timeout"
    end
  end

  defp collect_c1(pid, baseline, reclaimed_words) do
    receive do
      {:trace, ^pid, event, info} when event in [:gc_minor_end, :gc_major_end] ->
        collect_c1(pid, baseline, reclaimed_words + Keyword.get(info, :wordsize, 0))

      {:trace, ^pid, event, _info} when event in [:gc_minor_start, :gc_major_start] ->
        collect_c1(pid, baseline, reclaimed_words)

      {:measurement_done, ^pid, elapsed, reductions, before_gc, retained} ->
        :erlang.trace(pid, false, [:garbage_collection])
        send(pid, :release)
        metrics(elapsed, reductions, baseline, before_gc, retained, reclaimed_words)
    after
      120_000 ->
        Process.exit(pid, :kill)
        raise "c1 measurement timeout"
    end
  end

  defp measurement_worker(parent, method, shape, raw_bytes) do
    :erlang.garbage_collect(self())
    baseline = snapshot(self())
    send(parent, {:measurement_ready, self(), baseline})

    receive do
      :measure ->
        reductions_before = reductions(self())
        started = System.monotonic_time()
        result = run_adapter(method, raw_bytes)
        elapsed = System.monotonic_time() - started
        reductions_after = reductions(self())
        ensure_valid_result!(shape, method, result)
        before_gc = snapshot(self())
        :erlang.garbage_collect(self())
        retained = snapshot(self())

        send(
          parent,
          {:measurement_done, self(), elapsed, reductions_after - reductions_before, before_gc,
           retained}
        )

        receive do
          :release -> :ok
        end
    end
  end

  defp metrics(elapsed, reductions, baseline, before_gc, retained, reclaimed_words) do
    %{
      wall_ms: System.convert_time_unit(elapsed, :native, :microsecond) / 1000,
      reductions: reductions,
      heap_alloc_bytes:
        max(before_gc.total_heap_words - baseline.total_heap_words, 0) * @word_size,
      heap_retained_bytes:
        max(retained.total_heap_words - baseline.total_heap_words, 0) * @word_size,
      binary_alloc_bytes: max(before_gc.binary_bytes - baseline.binary_bytes, 0),
      binary_retained_bytes: max(retained.binary_bytes - baseline.binary_bytes, 0),
      reclaimed_bytes: reclaimed_words * @word_size
    }
  end

  defp summarize_c1(entry, method, samples) do
    %{
      shape: entry.shape,
      size_label: entry.size_label,
      bytes: entry.actual_bytes,
      weight_bp: entry.weight_bp,
      method: method,
      wall_ms: median(samples, :wall_ms),
      reductions: round(median(samples, :reductions)),
      heap_alloc_bytes: round(median(samples, :heap_alloc_bytes)),
      heap_retained_bytes: round(median(samples, :heap_retained_bytes)),
      binary_alloc_bytes: round(median(samples, :binary_alloc_bytes)),
      binary_retained_bytes: round(median(samples, :binary_retained_bytes)),
      reclaimed_bytes: round(median(samples, :reclaimed_bytes))
    }
  end

  defp benchmark_c64(entries) do
    samples =
      Enum.reduce(0..(@runs - 1), Map.new(@methods, &{&1, []}), fn trial, acc ->
        methods = rotate(@methods, trial)

        Enum.reduce(methods, acc, fn method, run_acc ->
          sample = concurrent_trial(entries, method, trial)
          Map.update!(run_acc, method, &[sample | &1])
        end)
      end)

    Enum.map(@methods, fn method ->
      method_samples = Map.fetch!(samples, method)

      %{
        method: method,
        responses_per_second: median(method_samples, :responses_per_second),
        mib_per_second: median(method_samples, :mib_per_second),
        batch_wall_ms: median(method_samples, :batch_wall_ms),
        p50_ms: median(method_samples, :p50_ms),
        p95_ms: median(method_samples, :p95_ms),
        reductions_per_response: round(median(method_samples, :reductions_per_response)),
        heap_alloc_bytes: round(median(method_samples, :heap_alloc_bytes)),
        heap_retained_bytes: round(median(method_samples, :heap_retained_bytes)),
        binary_alloc_bytes: round(median(method_samples, :binary_alloc_bytes)),
        binary_retained_bytes: round(median(method_samples, :binary_retained_bytes)),
        payload_bytes: round(median(method_samples, :payload_bytes))
      }
    end)
  end

  defp concurrent_trial(entries, method, trial) do
    parent = self()
    offset = rem(trial * 997, 10_000)

    workers =
      Enum.map(0..(@concurrency - 1), fn index ->
        position = rem(offset + div(index * 10_000, @concurrency), 10_000)
        entry = ResponseCorpus.weighted_entry_at(entries, position)
        raw_bytes = :binary.copy(entry.bytes)

        pid =
          :erlang.spawn_opt(
            fn -> concurrent_worker(parent, method, entry.shape, raw_bytes) end,
            fullsweep_after: 65_535
          )

        %{pid: pid, bytes: entry.actual_bytes}
      end)

    baselines = collect_ready(workers, %{})
    started = System.monotonic_time()
    Enum.each(workers, &send(&1.pid, :measure))
    completed = collect_completed(workers, %{})
    elapsed = System.monotonic_time() - started
    Enum.each(workers, &send(&1.pid, :release))

    elapsed_ms = System.convert_time_unit(elapsed, :native, :microsecond) / 1000
    payload_bytes = Enum.sum_by(workers, & &1.bytes)
    durations = completed |> Map.values() |> Enum.map(& &1.wall_ms) |> Enum.sort()

    aggregate =
      Enum.reduce(workers, empty_aggregate(), fn worker, acc ->
        baseline = Map.fetch!(baselines, worker.pid)
        sample = Map.fetch!(completed, worker.pid)

        %{
          reductions: acc.reductions + sample.reductions,
          heap_alloc_bytes:
            acc.heap_alloc_bytes +
              max(sample.before_gc.total_heap_words - baseline.total_heap_words, 0) * @word_size,
          heap_retained_bytes:
            acc.heap_retained_bytes +
              max(sample.retained.total_heap_words - baseline.total_heap_words, 0) * @word_size,
          binary_alloc_bytes:
            acc.binary_alloc_bytes +
              max(sample.before_gc.binary_bytes - baseline.binary_bytes, 0),
          binary_retained_bytes:
            acc.binary_retained_bytes +
              max(sample.retained.binary_bytes - baseline.binary_bytes, 0)
        }
      end)

    %{
      responses_per_second: @concurrency / (elapsed_ms / 1000),
      mib_per_second: payload_bytes / 1024 / 1024 / (elapsed_ms / 1000),
      batch_wall_ms: elapsed_ms,
      p50_ms: percentile(durations, 0.50),
      p95_ms: percentile(durations, 0.95),
      reductions_per_response: aggregate.reductions / @concurrency,
      heap_alloc_bytes: aggregate.heap_alloc_bytes,
      heap_retained_bytes: aggregate.heap_retained_bytes,
      binary_alloc_bytes: aggregate.binary_alloc_bytes,
      binary_retained_bytes: aggregate.binary_retained_bytes,
      payload_bytes: payload_bytes
    }
  end

  defp concurrent_worker(parent, method, shape, raw_bytes) do
    :erlang.garbage_collect(self())
    baseline = snapshot(self())
    send(parent, {:concurrent_ready, self(), baseline})

    receive do
      :measure ->
        reductions_before = reductions(self())
        started = System.monotonic_time()
        result = run_adapter(method, raw_bytes)
        elapsed = System.monotonic_time() - started
        reductions_after = reductions(self())
        ensure_valid_result!(shape, method, result)
        before_gc = snapshot(self())
        :erlang.garbage_collect(self())
        retained = snapshot(self())

        send(
          parent,
          {:concurrent_done, self(),
           %{
             wall_ms: System.convert_time_unit(elapsed, :native, :microsecond) / 1000,
             reductions: reductions_after - reductions_before,
             before_gc: before_gc,
             retained: retained
           }}
        )

        receive do
          :release -> :ok
        end
    end
  end

  defp collect_ready([], baselines), do: baselines

  defp collect_ready(workers, baselines) do
    receive do
      {:concurrent_ready, pid, baseline} ->
        collect_ready(Enum.reject(workers, &(&1.pid == pid)), Map.put(baselines, pid, baseline))
    after
      30_000 ->
        Enum.each(workers, &Process.exit(&1.pid, :kill))
        raise "c64 setup timeout"
    end
  end

  defp collect_completed([], completed), do: completed

  defp collect_completed(workers, completed) do
    receive do
      {:concurrent_done, pid, sample} ->
        collect_completed(Enum.reject(workers, &(&1.pid == pid)), Map.put(completed, pid, sample))
    after
      180_000 ->
        Enum.each(workers, &Process.exit(&1.pid, :kill))
        raise "c64 measurement timeout"
    end
  end

  defp empty_aggregate do
    %{
      reductions: 0,
      heap_alloc_bytes: 0,
      heap_retained_bytes: 0,
      binary_alloc_bytes: 0,
      binary_retained_bytes: 0
    }
  end

  defp run_adapter(method, raw_bytes) do
    Map.fetch!(adapters(), method).(raw_bytes, 7)
  end

  defp ensure_valid_result!(:error, :transport_equivalent, {:error, %Lasso.JSONRPC.Error{}}),
    do: :ok

  defp ensure_valid_result!(_shape, :transport_equivalent, {:ok, %Lasso.RPC.Response.Success{}}),
    do: :ok

  defp ensure_valid_result!(shape, method, {:ok, %{kind: kind, raw_bytes: raw_bytes}})
       when method in [:otp_discard, :jason] and is_binary(raw_bytes) do
    expected_kind = if shape == :error, do: :error, else: :result
    if kind == expected_kind, do: :ok, else: raise("wrong response kind")
  end

  defp ensure_valid_result!(shape, method, result) do
    raise "#{method} failed #{shape}: #{inspect(result, limit: 5)}"
  end

  defp snapshot(pid) do
    info = Process.info(pid, [:total_heap_size, :binary])

    %{
      total_heap_words: Keyword.fetch!(info, :total_heap_size),
      binary_bytes: info |> Keyword.fetch!(:binary) |> unique_binary_bytes()
    }
  end

  defp unique_binary_bytes(binaries) do
    binaries
    |> Enum.uniq_by(fn {reference, _size, _ref_count} -> reference end)
    |> Enum.sum_by(fn {_reference, size, _ref_count} -> size end)
  end

  defp reductions(pid) do
    {:reductions, reductions} = Process.info(pid, :reductions)
    reductions
  end

  defp median(samples, key) do
    samples
    |> Enum.map(&Map.fetch!(&1, key))
    |> Enum.sort()
    |> percentile(0.50)
  end

  defp percentile([], _fraction), do: 0.0

  defp percentile(values, fraction) do
    index = max(ceil(length(values) * fraction) - 1, 0)
    Enum.at(values, index)
  end

  defp rotate(values, by) do
    amount = rem(by, length(values))
    Enum.drop(values, amount) ++ Enum.take(values, amount)
  end

  defp print_c1(rows) do
    IO.puts("c1 cell medians (#{@runs} interleaved isolated-process runs)")
    IO.puts("heap+/bin+ are pre-GC peak proxies; reclaim is GC-reclaimed allocation pressure")
    IO.puts("heap=/bin= are post-GC retention deltas")

    IO.puts(
      "shape       size   actual parser                 ms reductions   heap+ reclaim heap=   bin+   bin="
    )

    Enum.each(rows, fn row ->
      IO.puts(
        "#{pad(row.shape, 11)} #{pad(row.size_label, 6)} #{pad(format_bytes(row.bytes), 6)} " <>
          "#{pad(row.method, 22)} #{pad(format_float(row.wall_ms), 7)} " <>
          "#{pad(row.reductions, 10)} #{pad(format_bytes(row.heap_alloc_bytes), 7)} " <>
          "#{pad(format_bytes(row.reclaimed_bytes), 7)} " <>
          "#{pad(format_bytes(row.heap_retained_bytes), 7)} " <>
          "#{pad(format_bytes(row.binary_alloc_bytes), 6)} " <>
          format_bytes(row.binary_retained_bytes)
      )
    end)
  end

  defp print_weighted(rows) do
    IO.puts("modeled weighted c1 mean per response")
    IO.puts("parser                    ms reductions   heap+ reclaim heap=   bin+   bin=")

    Enum.each(@methods, fn method ->
      method_rows = Enum.filter(rows, &(&1.method == method))

      weighted = fn key ->
        Enum.sum_by(method_rows, &(&1.weight_bp * Map.fetch!(&1, key))) / 10_000
      end

      IO.puts(
        "#{pad(method, 25)} #{pad(format_float(weighted.(:wall_ms)), 7)} " <>
          "#{pad(round(weighted.(:reductions)), 10)} " <>
          "#{pad(format_bytes(round(weighted.(:heap_alloc_bytes))), 7)} " <>
          "#{pad(format_bytes(round(weighted.(:reclaimed_bytes))), 7)} " <>
          "#{pad(format_bytes(round(weighted.(:heap_retained_bytes))), 7)} " <>
          "#{pad(format_bytes(round(weighted.(:binary_alloc_bytes))), 6)} " <>
          format_bytes(round(weighted.(:binary_retained_bytes)))
      )
    end)
  end

  defp print_c64(rows) do
    IO.puts(
      "c64 bounded mixed-response burst (#{@runs} interleaved trials, 64 distinct binaries)"
    )

    IO.puts("Memory deltas are aggregate across workers and exclude baseline input binaries.")

    IO.puts(
      "parser                 rsp/s  MiB/s batch ms  p50 ms  p95 ms red/rsp   heap+  heap=   bin+   bin="
    )

    Enum.each(rows, fn row ->
      IO.puts(
        "#{pad(row.method, 22)} #{pad(format_float(row.responses_per_second), 6)} " <>
          "#{pad(format_float(row.mib_per_second), 6)} " <>
          "#{pad(format_float(row.batch_wall_ms), 9)} " <>
          "#{pad(format_float(row.p50_ms), 7)} #{pad(format_float(row.p95_ms), 7)} " <>
          "#{pad(row.reductions_per_response, 9)} " <>
          "#{pad(format_bytes(row.heap_alloc_bytes), 7)} " <>
          "#{pad(format_bytes(row.heap_retained_bytes), 7)} " <>
          "#{pad(format_bytes(row.binary_alloc_bytes), 6)} " <>
          format_bytes(row.binary_retained_bytes)
      )
    end)
  end

  defp format_float(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)
  defp format_bytes(bytes) when bytes < 1024, do: "#{round(bytes)}B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)}K"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)}M"

  defp pad(value, width), do: value |> to_string() |> String.pad_trailing(width)
end

LassoPrototype.RealisticCorpusRunner.main()

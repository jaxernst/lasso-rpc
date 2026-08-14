Code.require_file("response_parser.ex", __DIR__)

defmodule LassoPrototype.ResponseParserShell do
  @moduledoc false

  alias Lasso.RPC.EnvelopeParser
  alias LassoPrototype.ResponseParser

  @word_size :erlang.system_info(:wordsize)
  @methods [:current_scanner, :otp_discard, :jason, :scan_then_otp]
  @benchmark_runs 5

  def main(args) do
    args = Enum.reject(args, &(&1 == "--"))

    case args do
      ["--all"] ->
        print_probe_report()
        IO.puts("")
        print_benchmark_report(benchmark_sizes(), @benchmark_runs)

      ["--probes"] ->
        print_probe_report()

      ["--bench"] ->
        print_benchmark_report(benchmark_sizes(), @benchmark_runs)

      _other ->
        interactive(%{probe_index: 0, last_action: "started", benchmark: []})
    end
  end

  defp probes do
    invalid_unicode =
      <<"{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":\"", 0xFF, "\"}">>

    [
      %{
        name: "valid result",
        expected: 7,
        bytes: ~s({"jsonrpc":"2.0","id":7,"result":{"ok":true}}),
        strict: :accept
      },
      %{
        name: "result-first nested ID before top-level ID",
        expected: 7,
        bytes: ~s({"jsonrpc":"2.0","result":{"meta":{"id":"wrong"}},"id":7}),
        strict: :accept
      },
      %{
        name: "nested ID with no top-level ID",
        expected: 7,
        bytes: ~s({"jsonrpc":"2.0","result":{"id":7}}),
        strict: :reject
      },
      %{
        name: "duplicate top-level ID",
        expected: 7,
        bytes: ~s({"jsonrpc":"2.0","id":7,"id":7,"result":1}),
        strict: :reject
      },
      %{
        name: "malformed result grammar",
        expected: 7,
        bytes: ~s({"jsonrpc":"2.0","id":7,"result":[1,2,]}),
        strict: :reject
      },
      %{
        name: "invalid UTF-8 in result",
        expected: 7,
        bytes: invalid_unicode,
        strict: :reject
      },
      %{
        name: "trailing bytes",
        expected: 7,
        bytes: ~s({"jsonrpc":"2.0","id":7,"result":1}garbage),
        strict: :reject
      },
      %{
        name: "result and error together",
        expected: 7,
        bytes: ~s({"jsonrpc":"2.0","id":7,"result":1,"error":{"code":-1,"message":"x"}}),
        strict: :reject
      },
      %{
        name: "valid error",
        expected: 7,
        bytes:
          ~s({"jsonrpc":"2.0","id":7,"error":{"code":-32000,"message":"boom","data":{"id":"nested"}}}),
        strict: :accept
      },
      %{
        name: "error missing message",
        expected: 7,
        bytes: ~s({"jsonrpc":"2.0","id":7,"error":{"code":-32000}}),
        strict: :reject
      },
      %{
        name: "escaped top-level ID",
        expected: "lasso-id",
        bytes: ~s({"jsonrpc":"2.0","\u0069d":"lasso-id","result":1}),
        strict: :accept
      },
      %{
        name: "same-ID original binary identity",
        expected: 7,
        bytes: ~s({"jsonrpc":"2.0","id":7,"result":[1,2,3]}),
        strict: :accept
      }
    ]
  end

  defp adapters do
    %{
      current_scanner: &current_scanner/2,
      otp_discard: &otp_discard/2,
      jason: &jason/2,
      scan_then_otp: &scan_then_otp/2
    }
  end

  defp current_scanner(raw_bytes, expected_id) do
    with {:ok, envelope} <- EnvelopeParser.parse(raw_bytes),
         true <- envelope.id == expected_id,
         true <- envelope.type in [:result, :error] do
      {:ok, %{kind: envelope.type, id: envelope.id, raw_bytes: envelope.raw_bytes}}
    else
      false -> {:error, :not_correlated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp otp_discard(raw_bytes, expected_id) do
    ResponseParser.validate(raw_bytes, expected_id)
  end

  defp scan_then_otp(raw_bytes, expected_id) do
    _non_authoritative_hint = EnvelopeParser.parse(raw_bytes)
    ResponseParser.validate(raw_bytes, expected_id)
  end

  defp jason(raw_bytes, expected_id) do
    with {:ok, decoded} <- Jason.decode(raw_bytes),
         {:ok, kind} <- validate_decoded(decoded, expected_id) do
      {:ok, %{kind: kind, id: decoded["id"], raw_bytes: raw_bytes}}
    end
  end

  defp validate_decoded(%{"jsonrpc" => "2.0", "id" => id} = decoded, expected_id)
       when id == expected_id do
    case {Map.has_key?(decoded, "result"), Map.has_key?(decoded, "error")} do
      {true, false} -> {:ok, :result}
      {false, true} -> validate_decoded_error(decoded["error"])
      _other -> {:error, :ambiguous_result_or_error}
    end
  end

  defp validate_decoded(_decoded, _expected_id), do: {:error, :invalid_response}

  defp validate_decoded_error(%{"code" => code, "message" => message})
       when is_integer(code) and is_binary(message),
       do: {:ok, :error}

  defp validate_decoded_error(_error), do: {:error, :invalid_error_object}

  defp interactive(state) do
    render(state)

    case IO.gets("") do
      nil -> :ok
      :eof -> :ok
      input -> dispatch(String.trim(input), state)
    end
  end

  defp dispatch("q", _state), do: :ok

  defp dispatch("p", state) do
    next = rem(state.probe_index + 1, length(probes()))
    interactive(%{state | probe_index: next, last_action: "selected next probe"})
  end

  defp dispatch("r", state) do
    interactive(%{state | last_action: probe_summary()})
  end

  defp dispatch("b", state) do
    rows = benchmark_sizes([1], [:large_string, :escaped_string, :compact_array], 3)
    interactive(%{state | benchmark: rows, last_action: "ran quick 1 MiB benchmark"})
  end

  defp dispatch(_unknown, state) do
    interactive(%{state | last_action: "unknown key"})
  end

  defp render(state) do
    IO.write("\e[2J\e[H")
    probe = Enum.at(probes(), state.probe_index)

    IO.puts("\e[1mPROTOTYPE — strict JSON-RPC response correlation\e[0m")
    IO.puts("\e[2mThrowaway branch: prototype/500-response-parser\e[0m")
    IO.puts("")
    IO.puts("\e[1mCurrent state\e[0m")
    IO.puts("probe:       #{state.probe_index + 1}/#{length(probes())} #{probe.name}")
    IO.puts("strict:      #{probe.strict}")
    IO.puts("expected ID: #{inspect(probe.expected)}")
    IO.puts("last action: #{state.last_action}")
    IO.puts("")
    IO.puts("\e[1mParser outcomes\e[0m")

    Enum.each(@methods, fn method ->
      result = run_adapter(method, probe.bytes, probe.expected)
      IO.puts("#{pad(method, 18)} #{format_result(result, probe.bytes)}")
    end)

    if state.benchmark != [] do
      IO.puts("")
      IO.puts("\e[1mQuick benchmark\e[0m")
      print_rows(state.benchmark)
    end

    IO.puts("")

    IO.puts(
      "\e[1m[p]\e[0m \e[2mnext probe\e[0m  \e[1m[r]\e[0m \e[2mrun probe summary\e[0m  \e[1m[b]\e[0m \e[2mquick benchmark\e[0m  \e[1m[q]\e[0m \e[2mquit\e[0m"
    )
  end

  defp print_probe_report do
    IO.puts("PROTOTYPE strictness probes")
    IO.puts("case | expected | current | otp-discard | Jason | scan+OTP")

    Enum.each(probes(), fn probe ->
      outcomes =
        Enum.map(@methods, fn method ->
          method
          |> run_adapter(probe.bytes, probe.expected)
          |> acceptance()
        end)

      IO.puts(
        "#{probe.name} | #{probe.strict} | " <>
          Enum.map_join(outcomes, " | ", &Atom.to_string/1)
      )
    end)

    IO.puts("")
    IO.puts(probe_summary())
  end

  defp probe_summary do
    otp_correct = agreement_count(:otp_discard)
    current_correct = agreement_count(:current_scanner)
    jason_correct = agreement_count(:jason)
    hybrid_correct = agreement_count(:scan_then_otp)

    "strict agreement: current=#{current_correct}/#{length(probes())}, " <>
      "otp=#{otp_correct}/#{length(probes())}, Jason=#{jason_correct}/#{length(probes())}, " <>
      "hybrid=#{hybrid_correct}/#{length(probes())}"
  end

  defp agreement_count(method) do
    Enum.count(probes(), fn probe ->
      acceptance(run_adapter(method, probe.bytes, probe.expected)) == probe.strict
    end)
  end

  defp acceptance({:ok, _validated}), do: :accept
  defp acceptance({:error, _reason}), do: :reject

  defp run_adapter(method, raw_bytes, expected_id) do
    Map.fetch!(adapters(), method).(raw_bytes, expected_id)
  end

  defp format_result({:ok, %{raw_bytes: returned}}, original) do
    identity = :erts_debug.same(returned, original)
    "accept raw_identity=#{identity}"
  end

  defp format_result({:error, reason}, _original), do: "reject #{inspect(reason)}"

  defp benchmark_sizes do
    benchmark_sizes(
      [1, 4, 16],
      [:large_string, :escaped_string, :compact_array],
      @benchmark_runs
    )
  end

  defp benchmark_sizes(mebibytes, shapes, runs) do
    Enum.flat_map(shapes, fn shape ->
      Enum.flat_map(mebibytes, fn mib ->
        input = build_input(shape, mib * 1024 * 1024)
        benchmark_case(shape, mib, input, runs)
      end)
    end)
  end

  defp benchmark_case(shape, mib, input, runs) do
    expected_id = 7

    Enum.each(@methods, fn method ->
      _warmup = run_adapter(method, input, expected_id)
    end)

    samples_by_method =
      Enum.reduce(0..(runs - 1), Map.new(@methods, &{&1, []}), fn run, samples ->
        ordered_methods = Enum.drop(@methods, run) ++ Enum.take(@methods, run)

        Enum.reduce(ordered_methods, samples, fn method, run_samples ->
          Map.update!(run_samples, method, &[measure(method, input, expected_id) | &1])
        end)
      end)

    Enum.map(@methods, fn method ->
      summarize(shape, mib, method, Map.fetch!(samples_by_method, method))
    end)
  end

  defp print_benchmark_report(rows, runs) do
    IO.puts("PROTOTYPE benchmark — median of #{runs} isolated process runs")
    IO.puts("Runtime: #{System.otp_release()} / Elixir #{System.version()}")
    IO.puts("heapΔ is observed heap-capacity growth; reclaimed is a GC allocation-pressure proxy")
    IO.puts("binaryΔ is a vheap upper bound; young/old references can double-count one binary")
    print_rows(rows)
  end

  defp print_rows(rows) do
    IO.puts(
      "shape          MiB parser             wall ms reductions      heapΔ   reclaimed binaryΔ"
    )

    Enum.each(rows, fn row ->
      IO.puts(
        "#{pad(row.shape, 14)} #{pad(row.mib, 3)} #{pad(row.method, 18)} " <>
          "#{pad(format_float(row.wall_ms), 8)} #{pad(format_integer(row.reductions), 11)} " <>
          "#{pad(format_bytes(row.heap_delta_bytes), 8)} " <>
          "#{pad(format_bytes(row.reclaimed_bytes), 9)} " <>
          format_bytes(row.binary_delta_bytes)
      )
    end)
  end

  defp build_input(:large_string, target_bytes) do
    prefix = ~s({"jsonrpc":"2.0","id":7,"result":")
    suffix = ~s("})
    body_size = max(target_bytes - byte_size(prefix) - byte_size(suffix), 1)
    IO.iodata_to_binary([prefix, :binary.copy("x", body_size), suffix])
  end

  defp build_input(:escaped_string, target_bytes) do
    prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":\"\\n"
    suffix = ~s("})
    body_size = max(target_bytes - byte_size(prefix) - byte_size(suffix), 1)
    IO.iodata_to_binary([prefix, :binary.copy("x", body_size), suffix])
  end

  defp build_input(:compact_array, target_bytes) do
    prefix = ~s({"jsonrpc":"2.0","id":7,"result":[)
    suffix = ~s(]})
    body_size = max(target_bytes - byte_size(prefix) - byte_size(suffix), 1)
    pairs = div(body_size, 2)
    body = :binary.copy("0,", pairs)
    trimmed = binary_part(body, 0, max(byte_size(body) - 1, 0))
    IO.iodata_to_binary([prefix, trimmed, suffix])
  end

  defp measure(method, input, expected_id) do
    parent = self()

    pid =
      :erlang.spawn_opt(
        fn -> measurement_worker(parent, method, input, expected_id) end,
        fullsweep_after: 65_535
      )

    receive do
      {:measurement_ready, ^pid, baseline} ->
        :erlang.trace(pid, true, [:garbage_collection])
        send(pid, :measure)
        collect_measurement(pid, baseline, empty_trace_metrics())
    after
      30_000 -> exit({:measurement_setup_timeout, method})
    end
  end

  defp measurement_worker(parent, method, input, expected_id) do
    :erlang.garbage_collect(self())
    baseline = process_snapshot(self())
    send(parent, {:measurement_ready, self(), baseline})

    receive do
      :measure ->
        reductions_before = process_reductions(self())
        started = System.monotonic_time()
        result = run_adapter(method, input, expected_id)
        elapsed = System.monotonic_time() - started
        reductions_after = process_reductions(self())
        :erlang.garbage_collect(self())
        final = process_snapshot(self())

        send(
          parent,
          {:measurement_done, self(), result, elapsed, reductions_after - reductions_before,
           final}
        )

        receive do
          :release -> :ok
        end
    end
  end

  defp collect_measurement(pid, baseline, trace_metrics) do
    receive do
      {:trace, ^pid, event, info}
      when event in [:gc_minor_start, :gc_minor_end, :gc_major_start, :gc_major_end] ->
        collect_measurement(pid, baseline, update_trace_metrics(trace_metrics, event, info))

      {:measurement_done, ^pid, result, elapsed, reductions, final} ->
        :erlang.trace(pid, false, [:garbage_collection])
        send(pid, :release)
        ensure_success!(result)

        %{
          wall_ms: System.convert_time_unit(elapsed, :native, :microsecond) / 1000,
          reductions: reductions,
          heap_delta_bytes:
            max(trace_metrics.peak_heap_words - baseline.total_heap_words, 0) * @word_size,
          reclaimed_bytes: trace_metrics.reclaimed_words * @word_size,
          binary_delta_bytes:
            max(trace_metrics.peak_binary_words * @word_size - baseline.binary_bytes, 0),
          final_heap_bytes: final.total_heap_words * @word_size
        }
    after
      120_000 ->
        Process.exit(pid, :kill)
        exit(:measurement_timeout)
    end
  end

  defp empty_trace_metrics do
    %{peak_heap_words: 0, peak_binary_words: 0, reclaimed_words: 0}
  end

  defp update_trace_metrics(metrics, event, info) do
    heap_words =
      Keyword.get(info, :heap_block_size, 0) +
        Keyword.get(info, :old_heap_block_size, 0) + Keyword.get(info, :mbuf_size, 0)

    binary_words =
      Keyword.get(info, :bin_vheap_size, 0) + Keyword.get(info, :bin_old_vheap_size, 0)

    reclaimed =
      if event in [:gc_minor_end, :gc_major_end], do: Keyword.get(info, :wordsize, 0), else: 0

    %{
      peak_heap_words: max(metrics.peak_heap_words, heap_words),
      peak_binary_words: max(metrics.peak_binary_words, binary_words),
      reclaimed_words: metrics.reclaimed_words + reclaimed
    }
  end

  defp process_snapshot(pid) do
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

  defp process_reductions(pid) do
    {:reductions, reductions} = Process.info(pid, :reductions)
    reductions
  end

  defp ensure_success!({:ok, %{raw_bytes: raw_bytes}}) when is_binary(raw_bytes), do: :ok
  defp ensure_success!(result), do: exit({:benchmark_parser_failed, result})

  defp summarize(shape, mib, method, samples) do
    %{
      shape: shape,
      mib: mib,
      method: method,
      wall_ms: median(samples, :wall_ms),
      reductions: round(median(samples, :reductions)),
      heap_delta_bytes: round(median(samples, :heap_delta_bytes)),
      reclaimed_bytes: round(median(samples, :reclaimed_bytes)),
      binary_delta_bytes: round(median(samples, :binary_delta_bytes))
    }
  end

  defp median(samples, key) do
    values = samples |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sort()
    Enum.at(values, div(length(values), 2))
  end

  defp format_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_integer(value), do: Integer.to_string(value)

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)}K"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1024 / 1024, 1)}M"

  defp pad(value, width) do
    value
    |> to_string()
    |> String.pad_trailing(width)
  end
end

LassoPrototype.ResponseParserShell.main(System.argv())

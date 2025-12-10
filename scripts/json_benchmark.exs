# JSON Performance Benchmark for Pass-Through Investigation
# Run with: mix run scripts/json_benchmark.exs
#
# This benchmark measures the CPU cost of JSON decode/encode operations
# for various payload sizes to inform the pass-through optimization decision.

defmodule JSONBenchmark do
  @moduledoc """
  Benchmark JSON operations at various payload sizes.
  """

  # Generate a realistic eth_getLogs response structure
  def generate_log_entry(index) do
    %{
      "address" => "0x" <> :crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower),
      "topics" => [
        "0x" <> :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
        "0x" <> :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
        "0x" <> :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      ],
      "data" => "0x" <> :crypto.strong_rand_bytes(256) |> Base.encode16(case: :lower),
      "blockNumber" => "0x" <> Integer.to_string(18_000_000 + index, 16),
      "transactionHash" => "0x" <> :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
      "transactionIndex" => "0x" <> Integer.to_string(rem(index, 200), 16),
      "blockHash" => "0x" <> :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
      "logIndex" => "0x" <> Integer.to_string(rem(index, 500), 16),
      "removed" => false
    }
  end

  def generate_jsonrpc_response(log_count) do
    logs = Enum.map(1..log_count, &generate_log_entry/1)

    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "result" => logs
    }
  end

  def measure_time(fun) do
    {time_us, result} = :timer.tc(fun)
    {time_us / 1000.0, result}
  end

  def run_benchmark(payload_size_target_mb) do
    IO.puts("\n=== Generating #{payload_size_target_mb}MB payload ===")

    # Estimate logs needed for target size
    # Each log entry is approximately 1KB when serialized
    estimated_logs = trunc(payload_size_target_mb * 1024)

    # Generate and encode
    {gen_time_ms, response} = measure_time(fn ->
      generate_jsonrpc_response(estimated_logs)
    end)

    {encode_time_ms, json_string} = measure_time(fn ->
      Jason.encode!(response)
    end)

    actual_size_mb = byte_size(json_string) / (1024 * 1024)
    IO.puts("Generated #{estimated_logs} log entries")
    IO.puts("Actual payload size: #{Float.round(actual_size_mb, 2)}MB")
    IO.puts("Generation time: #{Float.round(gen_time_ms, 2)}ms")
    IO.puts("Encode time: #{Float.round(encode_time_ms, 2)}ms")

    # Decode benchmark
    {decode_time_ms, decoded} = measure_time(fn ->
      Jason.decode!(json_string)
    end)
    IO.puts("Decode time: #{Float.round(decode_time_ms, 2)}ms")

    # Re-encode benchmark (simulating current proxy behavior)
    {reencode_time_ms, _} = measure_time(fn ->
      Jason.encode!(decoded)
    end)
    IO.puts("Re-encode time: #{Float.round(reencode_time_ms, 2)}ms")

    # Total decode + reencode (current proxy overhead)
    total_current = decode_time_ms + reencode_time_ms
    IO.puts("\n>> TOTAL CURRENT PROXY OVERHEAD: #{Float.round(total_current, 2)}ms")

    # Memory estimation
    decoded_size = :erts_debug.flat_size(decoded) * 8 / (1024 * 1024)
    IO.puts(">> ESTIMATED MEMORY FOR DECODED: #{Float.round(decoded_size, 2)}MB")

    # Benchmark extracting just the result field
    {extract_time_ms, result} = measure_time(fn ->
      decoded["result"]
    end)
    IO.puts("\nExtract result field: #{Float.round(extract_time_ms, 4)}ms")

    # Benchmark checking for error (string search approach)
    {string_search_time_ms, has_error} = measure_time(fn ->
      String.contains?(json_string, "\"error\":")
    end)
    IO.puts("String search for 'error': #{Float.round(string_search_time_ms, 4)}ms (found: #{has_error})")

    # Benchmark checking first N bytes
    {first_bytes_time_ms, first_500} = measure_time(fn ->
      binary_part(json_string, 0, min(500, byte_size(json_string)))
    end)
    IO.puts("Extract first 500 bytes: #{Float.round(first_bytes_time_ms, 4)}ms")

    # Check if error in first 500 bytes
    has_error_first = String.contains?(first_500, "\"error\"")
    has_result_first = String.contains?(first_500, "\"result\"")
    IO.puts("First 500 bytes contains error: #{has_error_first}, result: #{has_result_first}")

    %{
      target_mb: payload_size_target_mb,
      actual_mb: actual_size_mb,
      log_count: estimated_logs,
      encode_ms: encode_time_ms,
      decode_ms: decode_time_ms,
      reencode_ms: reencode_time_ms,
      total_current_ms: total_current,
      memory_mb: decoded_size,
      string_search_ms: string_search_time_ms,
      first_bytes_ms: first_bytes_time_ms
    }
  end

  def run_all do
    IO.puts("=" |> String.duplicate(60))
    IO.puts("JSON PERFORMANCE BENCHMARK FOR PASS-THROUGH OPTIMIZATION")
    IO.puts("=" |> String.duplicate(60))

    sizes = [1, 5, 10, 25, 50, 100]

    results = Enum.map(sizes, &run_benchmark/1)

    IO.puts("\n" <> "=" |> String.duplicate(60))
    IO.puts("SUMMARY")
    IO.puts("=" |> String.duplicate(60))
    IO.puts("\nSize(MB) | Decode(ms) | Encode(ms) | Total(ms) | Memory(MB)")
    IO.puts("-" |> String.duplicate(60))

    Enum.each(results, fn r ->
      IO.puts(
        "#{String.pad_leading(Float.to_string(Float.round(r.actual_mb, 1)), 8)} | " <>
        "#{String.pad_leading(Float.to_string(Float.round(r.decode_ms, 1)), 10)} | " <>
        "#{String.pad_leading(Float.to_string(Float.round(r.reencode_ms, 1)), 10)} | " <>
        "#{String.pad_leading(Float.to_string(Float.round(r.total_current_ms, 1)), 9)} | " <>
        "#{String.pad_leading(Float.to_string(Float.round(r.memory_mb, 1)), 9)}"
      )
    end)

    IO.puts("\n" <> "=" |> String.duplicate(60))
    IO.puts("ANALYSIS")
    IO.puts("=" |> String.duplicate(60))

    # Calculate throughput at 10 RPS
    result_10mb = Enum.find(results, fn r -> r.actual_mb > 9 and r.actual_mb < 11 end)
    result_50mb = Enum.find(results, fn r -> r.actual_mb > 45 and r.actual_mb < 55 end)
    result_100mb = Enum.find(results, fn r -> r.actual_mb > 90 end)

    if result_10mb do
      cpu_at_10rps = result_10mb.total_current_ms * 10 / 1000.0
      IO.puts("\n10MB payload at 10 RPS:")
      IO.puts("  - CPU time per second: #{Float.round(cpu_at_10rps * 100, 1)}% of 1 CPU core")
      IO.puts("  - Memory per request: #{Float.round(result_10mb.memory_mb, 1)}MB")
    end

    if result_50mb do
      cpu_at_10rps = result_50mb.total_current_ms * 10 / 1000.0
      IO.puts("\n50MB payload at 10 RPS:")
      IO.puts("  - CPU time per second: #{Float.round(cpu_at_10rps * 100, 1)}% of 1 CPU core")
      IO.puts("  - Memory per request: #{Float.round(result_50mb.memory_mb, 1)}MB")
    end

    if result_100mb do
      cpu_at_10rps = result_100mb.total_current_ms * 10 / 1000.0
      IO.puts("\n100MB payload at 10 RPS:")
      IO.puts("  - CPU time per second: #{Float.round(cpu_at_10rps * 100, 1)}% of 1 CPU core")
      IO.puts("  - Memory per request: #{Float.round(result_100mb.memory_mb, 1)}MB")
    end

    IO.puts("\n" <> "=" |> String.duplicate(60))
    IO.puts("PASS-THROUGH SAVINGS ESTIMATE")
    IO.puts("=" |> String.duplicate(60))

    Enum.each(results, fn r ->
      # With pass-through, we avoid decode + reencode
      # We still need ~0.1ms for string search or byte inspection
      passthrough_overhead = 0.1
      savings_ms = r.total_current_ms - passthrough_overhead
      savings_percent = savings_ms / r.total_current_ms * 100

      IO.puts("\n#{Float.round(r.actual_mb, 1)}MB payload:")
      IO.puts("  - Current overhead: #{Float.round(r.total_current_ms, 1)}ms")
      IO.puts("  - Pass-through overhead: ~#{passthrough_overhead}ms")
      IO.puts("  - Savings: #{Float.round(savings_ms, 1)}ms (#{Float.round(savings_percent, 1)}%)")
    end)

    results
  end
end

# Run the benchmark
JSONBenchmark.run_all()

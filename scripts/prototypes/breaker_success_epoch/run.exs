Code.require_file("model.exs", __DIR__)
Code.require_file("benchmark.exs", __DIR__)

defmodule Lasso.Prototypes.BreakerSuccessEpoch.CLI do
  @moduledoc false

  alias Lasso.Prototypes.BreakerSuccessEpoch.{Benchmark, Model, Reference}

  @bold "\e[1m"
  @dim "\e[2m"
  @green "\e[32m"
  @yellow "\e[33m"
  @reset "\e[0m"

  def main(args) do
    if "--interactive" in args do
      interactive(Model.new(:epoch, capacity: 8), nil)
    else
      count = parse_count(args)
      audit(count)
    end
  end

  defp audit(count) do
    IO.puts("#{@bold}PROTOTYPE — closed-breaker success epoch#{@reset}")

    IO.puts(
      "Question: can routine closed successes avoid the bounded control ring without changing breaker decisions?\n"
    )

    checks = Reference.check!()
    Enum.each(checks, fn {name, :ok} -> IO.puts("#{@green}PASS#{@reset} #{name}") end)

    race = Reference.naive_publication_race()

    IO.puts(
      "#{@yellow}FALSIFIED#{@reset} naive atomic-get then later ETS publication: #{race.falsified?}"
    )

    IO.puts("#{@dim}  #{Enum.join(race.schedule, " -> ")}#{@reset}\n")

    results = Benchmark.run(count)
    print_table("Active owner", results.active)
    print_table("Suspended owner", results.suspended)

    epoch_suspended = find(results.suspended, :epoch, 10)
    ring_suspended = find(results.suspended, :ring, 10)

    invariant? =
      epoch_suspended.accepted == count and epoch_suspended.drops == 0 and
        not epoch_suspended.degraded? and epoch_suspended.admission == :ordinary

    IO.puts("#{@bold}#{format_integer(count)}-success safety result#{@reset}")
    IO.puts("  epoch ordinary admission: #{if(invariant?, do: "PASS", else: "FAIL")}")

    IO.puts(
      "  ring: accepted=#{ring_suspended.accepted}, drops=#{ring_suspended.drops}, degraded=#{ring_suspended.degraded?}, admission=#{ring_suspended.admission}"
    )

    IO.puts(
      "  epoch: accepted=#{epoch_suspended.accepted}, drops=#{epoch_suspended.drops}, degraded=#{epoch_suspended.degraded?}, admission=#{epoch_suspended.admission}\n"
    )

    active_ring = find(results.active, :ring, 10)
    active_epoch = find(results.active, :epoch, 10)
    ratio = active_epoch.reports_per_second / active_ring.reports_per_second

    IO.puts("#{@bold}Verdict: GO WITH A LINEARIZATION REQUIREMENT#{@reset}")

    IO.puts(
      "The reducer preserves decisions across the checked traces and the 10-producer prototype is #{format(ratio)}x the ring's report rate."
    )

    IO.puts(
      "Do not ship a naked atomic read followed by an ETS insert: the adversarial schedule above proves that form can reorder a failure across success."
    )

    IO.puts(
      "#{@dim}Directional microbenchmark only; run the production A/B and c64/c128 launch cells before making an end-to-end claim.#{@reset}"
    )
  end

  defp print_table(title, rows) do
    IO.puts("#{@bold}#{title}#{@reset}")

    IO.puts(
      "kind   prod   ms       reports/s   red/report   ETS/report   atom/report   msgs   wakes   drops   degraded"
    )

    rows
    |> Enum.sort_by(fn row -> {row.producers, row.kind} end)
    |> Enum.each(fn row ->
      IO.puts([
        cell(Atom.to_string(row.kind), 6, :right),
        cell(row.producers, 5),
        cell(format(row.elapsed_us / 1_000), 9),
        cell(round(row.reports_per_second), 12),
        cell(format(row.reductions_per_report), 13),
        cell(format(row.ets_ops_per_report), 13),
        cell(format(row.atomics_ops_per_report), 14),
        cell(row.producer_messages, 7),
        cell(row.owner_wakes, 8),
        cell(row.drops, 8),
        cell(row.degraded?, 10)
      ])
    end)

    IO.puts("")
  end

  defp interactive(state, last_action) do
    IO.write("\e[2J\e[H")
    IO.puts("#{@bold}PROTOTYPE — success epoch state#{@reset}")
    IO.puts("#{@dim}Last action: #{last_action || "initial"}#{@reset}\n")

    state
    |> Map.take([
      :state,
      :generation,
      :owner_epoch,
      :failure_count,
      :success_epoch,
      :applied_success_epoch,
      :control_health,
      :queue,
      :wakes,
      :drops,
      :stale_reports
    ])
    |> Enum.sort()
    |> Enum.each(fn {key, value} ->
      IO.puts("#{@bold}#{key}:#{@reset} #{inspect(value)}")
    end)

    IO.puts(
      "\n#{@bold}s#{@reset} success  #{@bold}f#{@reset} timeout failure  #{@bold}r#{@reset} rate-limit failure  #{@bold}d#{@reset} drain"
    )

    IO.puts(
      "#{@bold}g#{@reset} replace generation  #{@bold}o#{@reset} owner restart  #{@bold}q#{@reset} quit"
    )

    case IO.gets("> ") do
      "s\n" -> act(state, :success, "closed success")
      "f\n" -> act(state, {:failure, :timeout}, "timeout failure")
      "r\n" -> act(state, {:failure, :rate_limit}, "rate-limit failure")
      "d\n" -> interactive(Model.drain(state), "owner drain")
      "g\n" -> interactive(Model.replace_generation(state), "replace generation")
      "o\n" -> interactive(Model.restart_owner(state), "owner restart")
      "q\n" -> :ok
      nil -> :ok
      _ -> interactive(state, "unknown command")
    end
  end

  defp act(state, signal, label) do
    interactive(Model.report(state, Model.receipt(state), signal), label)
  end

  defp find(rows, kind, producers) do
    Enum.find(rows, &(&1.kind == kind and &1.producers == producers))
  end

  defp parse_count(args) do
    case Enum.find_value(args, fn
           "--count=" <> value -> Integer.parse(value)
           _ -> nil
         end) do
      {count, ""} when count > 0 -> count
      _ -> 100_000
    end
  end

  defp format(number), do: :erlang.float_to_binary(number, decimals: 2)

  defp format_integer(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp cell(value, width, side \\ :left) do
    string = to_string(value)

    case side do
      :left -> String.pad_leading(string, width)
      :right -> String.pad_trailing(string, width)
    end
  end
end

Lasso.Prototypes.BreakerSuccessEpoch.CLI.main(System.argv())

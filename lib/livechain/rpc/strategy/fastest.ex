defmodule Livechain.RPC.Strategy.Fastest do
  @moduledoc "Choose fastest provider using method-specific latency scores with quality filters."

  @behaviour Livechain.RPC.Strategy

  alias Livechain.Benchmarking.BenchmarkStore
  # Strategy consumes availability from ProviderPool; performance from BenchmarkStore

  @impl true
  def choose(candidates, method, ctx) do
    case method do
      nil -> by_priority(candidates)
      method_name -> pick_fastest(candidates, method_name, ctx)
    end
  end

  defp by_priority(candidates) do
    candidates
    |> Enum.sort_by(& &1.config.priority)
    |> List.first()
    |> case do
      nil -> nil
      provider -> provider.id
    end
  end

  defp pick_fastest(candidates, method_name, ctx) do
    freshness_cutoff_ms = Map.get(ctx, :freshness_cutoff_ms, 10 * 60 * 1000)
    min_calls = Map.get(ctx, :min_calls, 3)
    min_success_rate = Map.get(ctx, :min_success_rate, 0.9)

    case BenchmarkStore.get_rpc_method_performance(any_chain(candidates), method_name) do
      %{providers: [_ | _] = stats} ->
        pick_from_stats(candidates, stats, %{
          freshness_cutoff_ms: freshness_cutoff_ms,
          min_calls: min_calls,
          min_success_rate: min_success_rate
        })

      _ ->
        by_priority(candidates)
    end
  end

  defp pick_from_stats(candidates, stats, gates) do
    provider_ids = MapSet.new(Enum.map(candidates, & &1.id))

    # Rank by availability first, then by avg latency asc, with basic quality gates
    candidates_by_id = Map.new(candidates, &{&1.id, &1})

    stats
    |> Enum.filter(&MapSet.member?(provider_ids, &1.provider_id))
    |> Enum.filter(&(&1.total_calls >= gates.min_calls))
    |> Enum.filter(&(Map.get(&1, :success_rate, 1.0) >= gates.min_success_rate))
    |> Enum.filter(fn s ->
      # If last_updated exists, ensure freshness
      case Map.get(s, :last_updated) do
        nil ->
          true

        ts when is_integer(ts) ->
          System.monotonic_time(:millisecond) - ts <= gates.freshness_cutoff_ms

        _ ->
          true
      end
    end)
    |> Enum.sort_by(fn s ->
      availability = Map.get(candidates_by_id[s.provider_id], :availability, :up)
      availability_rank = if availability == :up, do: 0, else: 1
      {availability_rank, s.avg_duration_ms}
    end)
    |> List.first()
    |> case do
      nil -> by_priority(candidates)
      s -> s.provider_id
    end
  end

  defp any_chain([]), do: ""
  defp any_chain([%{config: %{chain: chain}} | _]), do: chain
  defp any_chain([_ | rest]), do: any_chain(rest)
end

defmodule Lasso.RPC.Strategies.Fastest do
  @moduledoc "Choose fastest provider using method-specific latency scores with quality filters."

  @behaviour Lasso.RPC.Strategy

  alias Lasso.RPC.Metrics

  @impl true
  def prepare_context(selection) do
    base_ctx = Lasso.RPC.StrategyContext.new(selection)
    # Allow gates to be configured via env, with base_ctx defaults
    freshness_cutoff_ms =
      Application.get_env(:lasso, :fastest_freshness_cutoff_ms, 10 * 60 * 1000)

    min_calls = Application.get_env(:lasso, :fastest_min_calls, 3)
    min_success_rate = Application.get_env(:lasso, :fastest_min_success_rate, 0.9)

    %{
      base_ctx
      | freshness_cutoff_ms: base_ctx.freshness_cutoff_ms || freshness_cutoff_ms,
        min_calls: base_ctx.min_calls || min_calls,
        min_success_rate: base_ctx.min_success_rate || min_success_rate,
        chain: selection.chain
    }
  end

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
    freshness_cutoff_ms = ctx.freshness_cutoff_ms || 10 * 60 * 1000
    min_calls = ctx.min_calls || 3
    min_success_rate = ctx.min_success_rate || 0.9

    chain = ctx.chain || any_chain(candidates)

    case Metrics.get_method_performance(chain, method_name) do
      [_ | _] = provider_performances ->
        pick_from_performances(candidates, provider_performances, %{
          freshness_cutoff_ms: freshness_cutoff_ms,
          min_calls: min_calls,
          min_success_rate: min_success_rate
        })

      _ ->
        by_priority(candidates)
    end
  end

  defp pick_from_performances(candidates, provider_performances, gates) do
    provider_ids = MapSet.new(Enum.map(candidates, & &1.id))

    # Rank by availability first, then by performance metrics, with quality gates
    candidates_by_id = Map.new(candidates, &{&1.id, &1})

    provider_performances
    |> Enum.filter(&MapSet.member?(provider_ids, &1.provider_id))
    |> Enum.filter(&(&1.performance.total_calls >= gates.min_calls))
    |> Enum.filter(&(&1.performance.success_rate >= gates.min_success_rate))
    # Require minimum confidence
    |> Enum.filter(&(&1.performance.confidence_score > 0.1))
    |> Enum.sort_by(fn %{provider_id: pid, performance: perf} ->
      availability = Map.get(candidates_by_id[pid], :availability, :up)
      availability_rank = if availability == :up, do: 0, else: 1
      # Score combines latency and confidence (lower is better)
      performance_score = perf.latency_ms / max(perf.confidence_score, 0.1)
      {availability_rank, performance_score}
    end)
    |> List.first()
    |> case do
      nil -> by_priority(candidates)
      %{provider_id: pid} -> pid
    end
  end

  defp any_chain([]), do: ""
  defp any_chain([%{config: %{chain: chain}} | _]), do: chain
  defp any_chain([_ | rest]), do: any_chain(rest)
end

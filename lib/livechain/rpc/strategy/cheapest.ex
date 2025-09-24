defmodule Livechain.RPC.Strategy.Cheapest do
  @moduledoc "Prefer public (free) providers with round-robin fallback among groups."

  @behaviour Livechain.RPC.Strategy

  @impl true
  def choose(candidates, _method, ctx) do
    {public, non_public} =
      Enum.split_with(candidates, &(&1.config.type == "public"))

    choose_rr_or_first(public, ctx) || choose_rr_or_first(non_public, ctx)
  end

  defp choose_rr_or_first([], _ctx), do: nil

  defp choose_rr_or_first(cands, ctx) do
    total_requests = Map.get(ctx, :total_requests, 0)

    cands
    |> Enum.sort_by(& &1.id)
    |> Enum.at(rem(total_requests, max(length(cands), 1)))
    |> case do
      nil -> nil
      provider -> provider.id
    end
  end
end

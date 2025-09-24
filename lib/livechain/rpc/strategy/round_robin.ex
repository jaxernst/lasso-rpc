defmodule Livechain.RPC.Strategy.RoundRobin do
  @moduledoc "Round-robin selection based on a rolling request counter from pool context."

  @behaviour Livechain.RPC.Strategy

  @impl true
  def choose(candidates, _method, ctx) do
    total_requests = Map.get(ctx, :total_requests, 0)

    candidates
    |> Enum.sort_by(& &1.id)
    |> Enum.at(rem(total_requests, max(length(candidates), 1)))
    |> case do
      nil -> nil
      provider -> provider.id
    end
  end
end

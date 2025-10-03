defmodule Lasso.RPC.Strategies.RoundRobin do
  @moduledoc "Round-robin selection based on a rolling request counter from pool context."

  @behaviour Lasso.RPC.Strategy

  alias Lasso.RPC.ProviderPool

  @impl true
  def prepare_context(selection) do
    base_ctx = Lasso.RPC.StrategyContext.new(selection)
    chain = selection.chain

    total_requests =
      case ProviderPool.get_status(chain) do
        {:ok, %{stats: %{total_requests: tr}}} -> tr
        _ -> base_ctx.total_requests || 0
      end

    %{base_ctx | total_requests: total_requests}
  end

  @impl true
  def choose(candidates, _method, ctx) do
    total_requests = ctx.total_requests || 0

    candidates
    |> Enum.sort_by(& &1.id)
    |> Enum.at(rem(total_requests, max(length(candidates), 1)))
    |> case do
      nil -> nil
      provider -> provider.id
    end
  end
end

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
        {:ok, %{total_requests: tr}} when is_integer(tr) -> tr
        {:ok, status} when is_map(status) -> Map.get(status, :total_requests, 0)
        _ -> base_ctx.total_requests || 0
      end

    %{base_ctx | total_requests: total_requests}
  end

  @doc """
  Strategy-provided channel ranking: random shuffle per call (legacy behavior).
  """
  @impl true
  def rank_channels(channels, _method, ctx, _profile, _chain) do
    _ = ctx
    Enum.shuffle(channels)
  end
end

defmodule Lasso.RPC.Strategies.Priority do
  @moduledoc "Priority-based selection using configured provider priorities."

  @behaviour Lasso.RPC.Strategy

  @impl true
  def prepare_context(_profile, chain_id, _method, timeout) do
    Lasso.RPC.StrategyContext.new(chain_id, timeout)
  end

  @doc """
  Strategy-provided channel ranking: sort by configured provider priority, then transport.
  Lower numeric priority wins; HTTP preferred over WS for equal priority.
  """
  @impl true
  def rank_channels(channels, _method, ctx, _profile, _chain_id) do
    priority_by_id = ctx.provider_priorities || %{}

    Enum.sort_by(channels, fn ch ->
      provider_priority = Map.get(priority_by_id, ch.provider_id, 1_000_000)
      transport_priority = if ch.transport == :http, do: 0, else: 1
      {provider_priority, transport_priority}
    end)
  end
end

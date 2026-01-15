defmodule Lasso.RPC.Strategies.Cheapest do
  @moduledoc "Prefer public (free) providers with round-robin fallback among groups."

  @behaviour Lasso.RPC.Strategy

  alias Lasso.RPC.ProviderPool

  @impl true
  def prepare_context(profile, chain, _method, timeout) do
    base_ctx = Lasso.RPC.StrategyContext.new(chain, timeout)

    total_requests =
      case ProviderPool.get_status(profile, chain) do
        {:ok, %{total_requests: tr}} when is_integer(tr) ->
          tr

        {:ok, status} when is_map(status) ->
          case Map.get(status, :total_requests) do
            tr when is_integer(tr) -> tr
            _ -> 0
          end

        _ ->
          base_ctx.total_requests || 0
      end

    %{base_ctx | total_requests: total_requests}
  end

  @doc """
  Strategy-provided channel ranking: prefer HTTP, and loosely round-robin by provider id.
  """
  @impl true
  def rank_channels(channels, _method, ctx, _profile, _chain) do
    total_requests = ctx.total_requests || 0

    channels
    |> Enum.sort_by(fn ch ->
      transport_priority = if ch.transport == :http, do: 0, else: 1
      {transport_priority, ch.provider_id}
    end)
    |> rotate(rem(total_requests, max(length(channels), 1)))
  end

  defp rotate(list, 0), do: list
  defp rotate([], _n), do: []

  defp rotate(list, n) do
    {a, b} = Enum.split(list, n)
    b ++ a
  end
end

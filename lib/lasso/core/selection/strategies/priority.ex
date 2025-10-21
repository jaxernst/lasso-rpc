defmodule Lasso.RPC.Strategies.Priority do
  @moduledoc "Priority-based selection using configured provider priorities."

  @behaviour Lasso.RPC.Strategy

  alias Lasso.Config.ConfigStore

  @impl true
  def prepare_context(selection) do
    Lasso.RPC.StrategyContext.new(selection)
  end

  @doc """
  Strategy-provided channel ranking: sort by configured provider priority, then transport.
  Lower numeric priority wins; HTTP preferred over WS for equal priority.
  """
  @impl true
  def rank_channels(channels, _method, _ctx, chain) do
    priority_by_id = provider_priority_map(chain)

    Enum.sort_by(channels, fn ch ->
      provider_priority = Map.get(priority_by_id, ch.provider_id, 1_000_000)
      transport_priority = if ch.transport == :http, do: 0, else: 1
      {provider_priority, transport_priority}
    end)
  end

  defp provider_priority_map(chain) do
    case ConfigStore.get_chain(chain) do
      {:ok, %{providers: providers}} when is_list(providers) ->
        providers
        |> Enum.map(fn p ->
          {Map.get(p, :id) || Map.get(p, "id"),
           Map.get(p, :priority) || Map.get(p, "priority") || 1_000_000}
        end)
        |> Enum.reject(fn {id, _priority} -> is_nil(id) end)
        |> Enum.into(%{})

      _ ->
        %{}
    end
  end
end

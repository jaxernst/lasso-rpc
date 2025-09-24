defmodule Livechain.RPC.Strategy.Priority do
  @moduledoc "Priority-based selection using configured provider priorities."

  @behaviour Livechain.RPC.Strategy

  @impl true
  def choose(candidates, _method, _ctx) do
    candidates
    |> Enum.sort_by(& &1.config.priority)
    |> List.first()
    |> case do
      nil -> nil
      provider -> provider.id
    end
  end
end

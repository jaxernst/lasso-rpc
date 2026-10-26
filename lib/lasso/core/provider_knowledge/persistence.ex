defmodule Lasso.RPC.ProviderKnowledge.Persistence do
  @moduledoc "Off-path authority and bounded snapshot exchange for provider knowledge."

  @type target :: {binary(), pos_integer(), binary()}

  @callback epoch(target()) :: non_neg_integer()
  @callback allowed?(target(), map()) :: boolean()
  @callback observe(Lasso.RPC.ProviderKnowledge.Evidence.t()) :: :ok
  @callback apply_loss() :: map()

  @spec adapter() :: module()
  def adapter,
    do: Application.get_env(:lasso, :provider_knowledge_persistence, __MODULE__.None)
end

defmodule Lasso.RPC.ProviderKnowledge.Persistence.None do
  @moduledoc "Cold-start provider knowledge for the OSS edition."
  @behaviour Lasso.RPC.ProviderKnowledge.Persistence

  @impl true
  def epoch(_target), do: 0

  @impl true
  def allowed?(_target, _scope), do: true

  @impl true
  def observe(evidence), do: Lasso.RPC.ProviderKnowledge.ReadModel.apply(evidence)

  @impl true
  def apply_loss, do: %{total: 0, counters: %{}}
end

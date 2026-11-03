defmodule Lasso.RPC.RoutingPlan do
  @moduledoc false

  @enforce_keys [
    :profile,
    :chain_id,
    :generation,
    :providers,
    :provider_priorities,
    :max_lag_blocks,
    :archival_threshold,
    :head_scope
  ]
  defstruct @enforce_keys ++ [transactions: nil]

  @type provider :: %{
          required(:id) => String.t(),
          required(:instance_id) => String.t(),
          required(:routing_instance_id) => String.t(),
          required(:config) => map(),
          required(:priority) => non_neg_integer(),
          required(:capabilities) => map() | nil,
          required(:archival) => boolean(),
          required(:subscribe_new_heads) => boolean(),
          required(:transports) => [:http | :ws],
          required(:head_freshness_ms) => %{http: pos_integer(), ws: pos_integer()}
        }

  @type t :: %__MODULE__{
          profile: String.t(),
          chain_id: pos_integer(),
          generation: non_neg_integer(),
          providers: [provider()],
          provider_priorities: %{String.t() => non_neg_integer()},
          max_lag_blocks: non_neg_integer() | nil,
          archival_threshold: non_neg_integer(),
          head_scope: Lasso.Observations.HeadScope.t(),
          transactions: Lasso.Config.ChainConfig.Transactions.t() | nil
        }
  @spec for_request(t(), atom() | {atom(), atom()}) :: t()
  def for_request(%__MODULE__{transactions: nil} = plan, _request), do: plan

  def for_request(plan, {class, phase}) do
    send? = class == :raw_transaction_broadcast
    transaction_providers? = send? and phase == :providers

    providers =
      Enum.filter(plan.providers, fn provider ->
        provider.id in plan.transactions.providers == transaction_providers?
      end)

    %{
      plan
      | providers: providers,
        provider_priorities: Map.take(plan.provider_priorities, Enum.map(providers, & &1.id)),
        max_lag_blocks: if(send?, do: nil, else: plan.max_lag_blocks)
    }
  end

  def for_request(plan, class), do: for_request(plan, {class, :providers})
end

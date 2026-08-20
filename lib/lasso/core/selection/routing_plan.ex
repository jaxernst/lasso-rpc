defmodule Lasso.RPC.RoutingPlan do
  @moduledoc false

  @enforce_keys [
    :profile,
    :chain_id,
    :generation,
    :providers,
    :provider_priorities,
    :max_lag_blocks,
    :archival_threshold
  ]
  defstruct @enforce_keys

  @type provider :: %{
          required(:id) => String.t(),
          required(:instance_id) => String.t(),
          required(:routing_instance_id) => String.t(),
          required(:config) => map(),
          required(:priority) => non_neg_integer(),
          required(:capabilities) => map() | nil,
          required(:archival) => boolean(),
          required(:subscribe_new_heads) => boolean(),
          required(:transports) => [:http | :ws]
        }

  @type t :: %__MODULE__{
          profile: String.t(),
          chain_id: pos_integer(),
          generation: non_neg_integer(),
          providers: [provider()],
          provider_priorities: %{String.t() => non_neg_integer()},
          max_lag_blocks: non_neg_integer() | nil,
          archival_threshold: non_neg_integer()
        }
end

defmodule Lasso.Observations.HeadScope do
  @moduledoc """
  The immutable comparison scope for one profile's view of a chain head.

  A scope fixes the physical upstream voters, the upstreams whose heads its
  rounds compare, and the comparison policy used by a routing plan, so a change
  to any of them gives a new scope identity. Its cache key is built once with
  the plan, keeping profile isolation explicit without adding sorting or hashing
  to request routing.
  """

  alias Lasso.Observations.HeadComparison.Policy

  @enforce_keys [
    :profile_id,
    :chain_id,
    :instance_ids,
    :observer_ids,
    :policy,
    :scope_id,
    :cache_key
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          profile_id: String.t(),
          chain_id: pos_integer(),
          instance_ids: [String.t()],
          observer_ids: [String.t()],
          policy: Policy.t(),
          scope_id: tuple(),
          cache_key: tuple()
        }

  @spec new(String.t(), pos_integer(), [String.t()], [String.t()], Policy.t()) :: t()
  def new(profile_id, chain_id, instance_ids, observer_ids, %Policy{} = policy)
      when is_binary(profile_id) and profile_id != "" and is_integer(chain_id) and
             chain_id > 0 and is_list(instance_ids) and is_list(observer_ids) do
    instance_ids = normalize(instance_ids)
    observer_ids = normalize(observer_ids)

    scope_id =
      {:head_scope, profile_id, chain_id, List.to_tuple(instance_ids),
       List.to_tuple(observer_ids), policy.block_time_ms, policy.reference_freshness_ms,
       policy.agreement_window_ms}

    %__MODULE__{
      profile_id: profile_id,
      chain_id: chain_id,
      instance_ids: instance_ids,
      observer_ids: observer_ids,
      policy: policy,
      scope_id: scope_id,
      cache_key: put_elem(scope_id, 0, :head_snapshot_scope)
    }
  end

  defp normalize(instance_ids) do
    instance_ids
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end
end

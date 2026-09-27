defmodule Lasso.Events.HeadObserved do
  @moduledoc """
  A versioned delivery envelope for one attributed chain-head observation.

  `observation` is the provider fact. The surrounding fields identify the
  profile alias and cluster member through which that fact is projected to an
  operator surface. Consumers never need to infer a chain from a provider
  label or recover physical identity from mutable configuration.
  """

  alias Lasso.Observations.{HeadObservation, HeadSnapshot}

  @enforce_keys [:profile, :provider_id, :node_id, :observation]
  defstruct @enforce_keys ++ [:head_snapshot, v: 1]

  @type t :: %__MODULE__{
          v: pos_integer(),
          profile: String.t(),
          provider_id: String.t(),
          node_id: String.t(),
          observation: HeadObservation.t(),
          head_snapshot: HeadSnapshot.t() | nil
        }
end

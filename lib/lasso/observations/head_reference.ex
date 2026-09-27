defmodule Lasso.Observations.HeadReference do
  @moduledoc """
  A qualified reference head captured when an upstream observation begins.

  The revision and capture time preserve the provenance needed to compare a
  later request result without feeding that result back into the reference that
  qualifies it.
  """

  @enforce_keys [:chain_id, :height, :revision, :captured_at_ms]
  defstruct @enforce_keys ++ [:observed_at_ms, :instance_id, :transport, :scope_id]

  @type t :: %__MODULE__{
          chain_id: pos_integer(),
          height: non_neg_integer(),
          revision: non_neg_integer(),
          captured_at_ms: integer(),
          observed_at_ms: integer() | nil,
          instance_id: String.t() | nil,
          transport: :http | :ws | nil,
          scope_id: tuple() | nil
        }

  @doc "Checks that a captured reference can qualify one later observation."
  @spec valid_for_observation?(t(), pos_integer(), non_neg_integer()) :: boolean()
  def valid_for_observation?(
        %__MODULE__{
          chain_id: chain_id,
          height: height,
          revision: revision,
          captured_at_ms: captured_at_ms,
          observed_at_ms: reference_observed_at_ms,
          instance_id: reference_instance_id,
          transport: reference_transport,
          scope_id: scope_id
        },
        chain_id,
        observation_observed_at_ms
      )
      when is_integer(chain_id) and chain_id > 0 and is_integer(height) and height >= 0 and
             is_integer(revision) and revision >= 0 and is_integer(captured_at_ms) and
             captured_at_ms >= 0 and is_integer(observation_observed_at_ms) and
             captured_at_ms <= observation_observed_at_ms do
    valid_optional_observation_time?(reference_observed_at_ms, captured_at_ms) and
      valid_optional_instance?(reference_instance_id) and
      reference_transport in [:http, :ws, nil] and
      (is_tuple(scope_id) or is_nil(scope_id))
  end

  def valid_for_observation?(%__MODULE__{}, _chain_id, _observation_observed_at_ms), do: false

  defp valid_optional_observation_time?(nil, _captured_at_ms), do: true

  defp valid_optional_observation_time?(observed_at_ms, captured_at_ms),
    do: is_integer(observed_at_ms) and observed_at_ms >= 0 and observed_at_ms <= captured_at_ms

  defp valid_optional_instance?(nil), do: true
  defp valid_optional_instance?(instance_id), do: is_binary(instance_id) and instance_id != ""
end

defmodule Lasso.Core.Support.ErrorResolution do
  @moduledoc """
  Body-free resolution of an error claim and its existing control consequences.

  Classification provenance describes how a claim was interpreted, not whether
  the upstream's claim is true. Retryability is separate from execution safety;
  the execution projector owns permission to send. Provider health consequences
  are independent from both retryability and the shared control category.

  The record retains no message, response data, request parameters or credentials.
  Its scope is attribution, not qualified capability evidence or a learned bound.
  """

  alias Lasso.Core.Support.ErrorClassification

  @enforce_keys [
    :code,
    :category,
    :control_category,
    :shared_control?,
    :classification_path,
    :baseline_category,
    :baseline_path,
    :retriable?,
    :breaker_penalty?,
    :provider_health_failure?,
    :scope
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          code: integer() | nil,
          category: atom(),
          control_category: atom(),
          shared_control?: boolean(),
          classification_path: atom(),
          baseline_category: atom(),
          baseline_path: atom(),
          retriable?: boolean(),
          breaker_penalty?: boolean(),
          provider_health_failure?: boolean(),
          scope: %{
            profile: binary() | nil,
            chain_id: integer() | nil,
            provider_id: binary() | nil
          }
        }

  @doc "Projects the compatible classifier result without exposing resolution metadata."
  @spec classification(t()) :: map()
  def classification(%__MODULE__{} = resolution) do
    Map.take(resolution, [:category, :control_category, :retriable?, :breaker_penalty?])
  end

  @doc "Maps a resolved control category into the canonical application-error vocabulary."
  @spec application_category(atom()) :: atom()
  def application_category(:rate_limit), do: :quota
  def application_category(:local_capacity_rejection), do: :local_safety

  def application_category(category)
      when category in [:unclassified_server_error, :unknown_error],
      do: :ambiguous

  def application_category(category)
      when category in [
             :deterministic,
             :ambiguous,
             :quota,
             :capability,
             :provider_failure,
             :local_safety
           ],
      do: category

  def application_category(category) do
    cond do
      ErrorClassification.breaker_penalty?(category) -> :provider_failure
      ErrorClassification.retriable_for_category?(category) -> :capability
      true -> :deterministic
    end
  end
end

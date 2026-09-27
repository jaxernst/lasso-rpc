defmodule Lasso.Observations.HeadSnapshot do
  @moduledoc """
  An immutable comparison of recent head observations for one chain.

  Lag comparisons require `qualification` to be `:qualified`. Archive eligibility
  may estimate block age from one fresh observation without qualifying it as a
  corroborated reference. `latest_observed_height` is diagnostic and
  never qualifies another observation. Reference provenance identifies the
  concrete fact selected from the supporting observations.
  """

  alias Lasso.Observations.{HeadObservation, HeadReference}

  @enforce_keys [
    :chain_id,
    :reference_height,
    :latest_observed_height,
    :qualification,
    :support,
    :voter_count,
    :spread,
    :computed_at_ms,
    :valid_through_ms,
    :revision,
    :supporting_instances,
    :dissenting_instances
  ]
  defstruct @enforce_keys ++
              [
                :scope_id,
                :reference_observed_at_ms,
                :reference_instance_id,
                :reference_transport,
                :latest_observed_at_ms,
                :latest_observed_instance_id,
                :latest_observed_transport
              ]

  @type qualification :: :qualified | :uncorroborated | :ambiguous | :unavailable

  @type t :: %__MODULE__{
          chain_id: pos_integer(),
          reference_height: non_neg_integer() | nil,
          latest_observed_height: non_neg_integer() | nil,
          qualification: qualification(),
          support: non_neg_integer(),
          voter_count: non_neg_integer(),
          spread: non_neg_integer() | nil,
          computed_at_ms: integer(),
          valid_through_ms: integer(),
          revision: non_neg_integer(),
          supporting_instances: [String.t()],
          dissenting_instances: [String.t()],
          scope_id: tuple() | nil,
          reference_observed_at_ms: integer() | nil,
          reference_instance_id: String.t() | nil,
          reference_transport: HeadObservation.transport() | nil,
          latest_observed_at_ms: integer() | nil,
          latest_observed_instance_id: String.t() | nil,
          latest_observed_transport: HeadObservation.transport() | nil
        }

  @spec qualified?(t()) :: boolean()
  def qualified?(%__MODULE__{qualification: :qualified}), do: true
  def qualified?(%__MODULE__{}), do: false

  @doc "A fresh height for archive eligibility; it does not establish consensus or available state."
  @spec archive_reference_height(t() | :unavailable, integer()) :: non_neg_integer() | nil
  def archive_reference_height(snapshot, now_ms \\ System.system_time(:millisecond))

  def archive_reference_height(
        %__MODULE__{
          qualification: qualification,
          reference_height: height,
          valid_through_ms: valid_through_ms
        },
        now_ms
      )
      when qualification in [:qualified, :uncorroborated] and is_integer(height) and
             now_ms <= valid_through_ms,
      do: height

  def archive_reference_height(_snapshot, _now_ms), do: nil

  @spec reference(t()) :: {:ok, HeadReference.t()} | {:error, :unqualified}
  def reference(%__MODULE__{
        chain_id: chain_id,
        scope_id: scope_id,
        qualification: :qualified,
        reference_height: height,
        revision: revision,
        computed_at_ms: captured_at_ms,
        reference_observed_at_ms: observed_at_ms,
        reference_instance_id: instance_id,
        reference_transport: transport
      })
      when is_integer(height) do
    {:ok,
     %HeadReference{
       chain_id: chain_id,
       height: height,
       revision: revision,
       captured_at_ms: captured_at_ms,
       observed_at_ms: observed_at_ms,
       instance_id: instance_id,
       transport: transport,
       scope_id: scope_id
     }}
  end

  def reference(%__MODULE__{}), do: {:error, :unqualified}
end

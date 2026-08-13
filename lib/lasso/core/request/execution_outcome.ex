defmodule Lasso.RPC.ExecutionOutcome do
  @moduledoc """
  Versioned execution facts shared by admission, attempt, and request consumers.
  """

  @schema_version 1
  @stages [:admission, :attempt, :request]
  @causes [
    :success,
    :application,
    :capability,
    :capacity,
    :provider_health,
    :auth_config,
    :policy,
    :deadline,
    :cancellation,
    :unknown
  ]
  @completions [:not_dispatched, :responded, :possibly_applied, :cancelled_censored]
  @dispositions [:returned, :failover, :profile_fallback, :degraded, :exhausted]
  @evidence_effects [
    :usable_success,
    :reliability_failure,
    :capacity_signal,
    :capability_signal,
    :neutral,
    :censored
  ]

  @type t :: %__MODULE__{
          schema_version: 1,
          stage: :admission | :attempt | :request,
          cause: atom(),
          completion: atom(),
          disposition: atom(),
          evidence_effect: atom(),
          request_id: String.t(),
          attempt_id: String.t() | nil,
          upstream_instance_id: String.t() | nil,
          chain_id: pos_integer() | nil,
          transport: :http | :ws | nil,
          routing_intent: atom() | nil,
          route_generation: non_neg_integer() | nil,
          circuit_scope: :broad | :intent | nil,
          circuit_epoch: non_neg_integer() | nil,
          deadline_us: integer(),
          dispatched_at_us: integer() | nil,
          terminal_at_us: integer(),
          io_duration_ms: number() | nil,
          censoring_boundary_ms: number() | nil
        }

  @enforce_keys [
    :stage,
    :cause,
    :completion,
    :disposition,
    :evidence_effect,
    :request_id,
    :deadline_us,
    :terminal_at_us
  ]
  @derive Jason.Encoder
  defstruct @enforce_keys ++
              [
                schema_version: @schema_version,
                attempt_id: nil,
                upstream_instance_id: nil,
                chain_id: nil,
                transport: nil,
                routing_intent: nil,
                route_generation: nil,
                circuit_scope: nil,
                circuit_epoch: nil,
                dispatched_at_us: nil,
                io_duration_ms: nil,
                censoring_boundary_ms: nil
              ]

  @spec new(keyword()) :: t()
  def new(attrs) do
    outcome = struct!(__MODULE__, attrs)
    validate!(outcome)
  end

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = outcome) do
    validate_member!(:stage, outcome.stage, @stages)
    validate_member!(:cause, outcome.cause, @causes)
    validate_member!(:completion, outcome.completion, @completions)
    validate_member!(:disposition, outcome.disposition, @dispositions)
    validate_member!(:evidence_effect, outcome.evidence_effect, @evidence_effects)

    validate_attempt!(outcome)
    validate_admission!(outcome)
    validate_timing!(outcome)

    outcome
  end

  defp validate_attempt!(%__MODULE__{stage: stage}) when stage != :attempt, do: :ok

  defp validate_attempt!(outcome) do
    if is_nil(outcome.attempt_id), do: raise(ArgumentError, "attempt outcomes require attempt_id")

    if is_nil(outcome.upstream_instance_id) or is_nil(outcome.chain_id) or
         is_nil(outcome.transport) or is_nil(outcome.routing_intent) or
         is_nil(outcome.route_generation) or is_nil(outcome.circuit_scope) or
         is_nil(outcome.circuit_epoch) or is_nil(outcome.dispatched_at_us) do
      raise ArgumentError, "attempt outcomes require bounded routing and dispatch identity"
    end

    if outcome.evidence_effect == :usable_success and is_nil(outcome.io_duration_ms),
      do: raise(ArgumentError, "usable success requires io_duration_ms")

    if outcome.cause in [:deadline, :cancellation] and is_nil(outcome.censoring_boundary_ms),
      do: raise(ArgumentError, "deadline and cancellation attempts require a censoring boundary")

    if is_nil(outcome.io_duration_ms) == is_nil(outcome.censoring_boundary_ms),
      do: raise(ArgumentError, "attempt outcomes require exactly one timing observation")
  end

  defp validate_admission!(%__MODULE__{stage: stage}) when stage != :admission, do: :ok

  defp validate_admission!(outcome) do
    if outcome.completion != :not_dispatched,
      do: raise(ArgumentError, "admission outcomes must be not_dispatched")

    if outcome.evidence_effect != :neutral,
      do: raise(ArgumentError, "admission outcomes cannot fabricate attempt evidence")
  end

  defp validate_timing!(outcome) do
    if outcome.dispatched_at_us && outcome.terminal_at_us < outcome.dispatched_at_us,
      do: raise(ArgumentError, "terminal time cannot precede dispatch time")
  end

  defp validate_member!(field, value, allowed) do
    if value not in allowed, do: raise(ArgumentError, "invalid #{field}: #{inspect(value)}")
  end
end

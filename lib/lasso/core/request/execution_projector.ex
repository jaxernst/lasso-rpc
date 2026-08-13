defmodule Lasso.RPC.ExecutionProjector do
  @moduledoc """
  Canonical versioned policy projection for tagged execution facts.
  """

  alias Lasso.RPC.{AdmissionTerminal, AttemptTerminal, RequestTerminal}

  @version 1
  @enforce_keys [
    :version,
    :fallback_eligible,
    :recommended_action,
    :breaker_effect,
    :evidence_qualification,
    :diagnostic
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec project(struct(), 1) :: t()
  def project(fact, version \\ @version)

  def project(%AdmissionTerminal{reason: reason}, 1) do
    fallback? =
      reason in [
        :circuit_open,
        :admission_unavailable,
        :local_capacity,
        :unsupported_transport
      ]

    projection(
      fallback?,
      if(fallback?, do: :try_next_candidate, else: :finish_request),
      :none,
      admission_evidence(reason),
      :admission_rejected
    )
  end

  def project(%AttemptTerminal.PredispatchFailure{}, 1),
    do: projection(true, :try_next_candidate, :none, :neutral, :predispatch_failure)

  def project(%AttemptTerminal.Response{kind: :success}, 1),
    do: projection(false, :return_response, :success, :usable_success, :upstream_success)

  def project(%AttemptTerminal.Response{kind: :application_error}, 1),
    do:
      projection(
        false,
        :return_response,
        :none,
        :application_response,
        :upstream_application_error
      )

  def project(%AttemptTerminal.InvalidResponse{identity: identity}, 1) do
    retryable_projection(
      identity.execution_safety,
      :failure,
      :reliability_failure,
      :invalid_response
    )
  end

  def project(%AttemptTerminal.TransportFailure{} = terminal, 1) do
    breaker = if terminal.dispatch_certainty == :dispatched, do: :failure, else: :none

    evidence =
      if terminal.dispatch_certainty == :dispatched, do: :reliability_failure, else: :neutral

    retryable_projection(
      terminal.identity.execution_safety,
      terminal.dispatch_certainty,
      breaker,
      evidence,
      :transport_failure
    )
  end

  def project(%AttemptTerminal.Deadline{} = terminal, 1) do
    breaker = if terminal.dispatch_certainty == :dispatched, do: :failure, else: :none
    projection(false, :finish_request, breaker, :censored, :deadline)
  end

  def project(%AttemptTerminal.Cancelled{}, 1),
    do: projection(false, :finish_request, :none, :censored, :cancelled)

  def project(%RequestTerminal.UpstreamResponse{}, 1),
    do: projection(false, :return_response, :none, :neutral, :request_returned)

  def project(%RequestTerminal.LocalFailure{}, 1),
    do: projection(false, :return_local_error, :none, :neutral, :local_failure)

  def project(%RequestTerminal.Deadline{}, 1),
    do: projection(false, :return_deadline, :none, :neutral, :request_deadline)

  def project(%RequestTerminal.CallerAbandonment{}, 1),
    do: projection(false, :drop_response, :none, :neutral, :caller_abandoned)

  def project(%RequestTerminal.UnsafeIndeterminateExhaustion{}, 1),
    do: projection(false, :return_indeterminate_error, :none, :neutral, :unsafe_indeterminate)

  def project(%RequestTerminal.OrdinaryExhaustion{}, 1),
    do: projection(false, :return_exhaustion_error, :none, :neutral, :ordinary_exhaustion)

  def project(_fact, version),
    do: raise(ArgumentError, "unsupported projector version: #{inspect(version)}")

  defp retryable_projection(safety, breaker, evidence, diagnostic),
    do: retryable_projection(safety, :dispatched, breaker, evidence, diagnostic)

  defp retryable_projection(safety, certainty, breaker, evidence, diagnostic) do
    fallback? = certainty == :not_dispatched or safety == :replay_safe

    projection(
      fallback?,
      if(fallback?, do: :try_next_candidate, else: :finish_unsafe_indeterminate),
      breaker,
      evidence,
      diagnostic
    )
  end

  defp admission_evidence(:local_capacity), do: :capacity_signal
  defp admission_evidence(:unsupported_transport), do: :capability_signal
  defp admission_evidence(_reason), do: :neutral

  defp projection(fallback?, action, breaker, evidence, diagnostic) do
    %__MODULE__{
      version: @version,
      fallback_eligible: fallback?,
      recommended_action: action,
      breaker_effect: breaker,
      evidence_qualification: evidence,
      diagnostic: diagnostic
    }
  end
end

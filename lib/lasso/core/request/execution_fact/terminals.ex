defmodule Lasso.RPC.AdmissionTerminal do
  @moduledoc "A rejection before an upstream attempt is authorized."

  alias Lasso.RPC.ExecutionFact

  @reasons [
    :deadline,
    :candidate_budget_exhausted,
    :dispatch_budget_exhausted,
    :duplicate_dispatch,
    :circuit_open,
    :admission_unavailable,
    :local_capacity,
    :policy,
    :unsupported_transport,
    :invalid_request,
    :caller_abandoned
  ]

  @enforce_keys [
    :request_id,
    :profile,
    :chain_id,
    :routing_intent,
    :workload_key,
    :reason,
    :candidate_admission_count,
    :dispatch_count,
    :elapsed_us
  ]
  defstruct @enforce_keys ++ [:subject_token, :retry_after_ms, :observed_at]

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(attrs) do
    terminal = struct!(__MODULE__, attrs)

    normalized = %{
      terminal
      | request_id: ExecutionFact.bounded!(terminal.request_id, :request_id),
        profile: ExecutionFact.bounded!(terminal.profile, :profile),
        subject_token: ExecutionFact.optional_bounded!(terminal.subject_token, :subject_token),
        chain_id: ExecutionFact.positive!(terminal.chain_id, :chain_id),
        routing_intent: ExecutionFact.bounded!(terminal.routing_intent, :routing_intent),
        workload_key: ExecutionFact.bounded!(terminal.workload_key, :workload_key),
        reason: ExecutionFact.member!(terminal.reason, :reason, @reasons),
        candidate_admission_count:
          ExecutionFact.candidate_count!(terminal.candidate_admission_count),
        dispatch_count: ExecutionFact.dispatch_count!(terminal.dispatch_count),
        elapsed_us: ExecutionFact.non_negative!(terminal.elapsed_us, :elapsed_us),
        retry_after_ms:
          ExecutionFact.optional_duration!(terminal.retry_after_ms, :retry_after_ms),
        observed_at: ExecutionFact.optional_bounded!(terminal.observed_at, :observed_at)
    }

    if normalized.dispatch_count > normalized.candidate_admission_count,
      do: raise(ArgumentError, "dispatch_count cannot exceed candidate admissions")

    normalized
  end
end

defmodule Lasso.RPC.AttemptTerminal do
  @moduledoc "Tagged terminal facts for an authorized upstream attempt."

  @type t ::
          Lasso.RPC.AttemptTerminal.PredispatchFailure.t()
          | Lasso.RPC.AttemptTerminal.Response.t()
          | Lasso.RPC.AttemptTerminal.InvalidResponse.t()
          | Lasso.RPC.AttemptTerminal.TransportFailure.t()
          | Lasso.RPC.AttemptTerminal.Deadline.t()
          | Lasso.RPC.AttemptTerminal.Cancelled.t()
end

defmodule Lasso.RPC.AttemptTerminal.PredispatchFailure do
  @moduledoc false
  alias Lasso.RPC.{AttemptIdentity, ExecutionFact}

  @reasons [:encode, :request_build, :pool_unavailable, :not_connected, :invalid_frame, :local]
  @enforce_keys [:identity, :reason, :elapsed_us]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          identity: AttemptIdentity.t(),
          reason: atom(),
          elapsed_us: non_neg_integer()
        }

  @spec new(AttemptIdentity.t(), atom(), non_neg_integer()) :: t()
  def new(%AttemptIdentity{} = identity, reason, elapsed_us) do
    %__MODULE__{
      identity: identity,
      reason: ExecutionFact.member!(reason, :reason, @reasons),
      elapsed_us: ExecutionFact.non_negative!(elapsed_us, :elapsed_us)
    }
  end
end

defmodule Lasso.RPC.AttemptTerminal.Response do
  @moduledoc false
  alias Lasso.RPC.{AttemptIdentity, ExecutionFact}

  @kinds [:success, :application_error]
  @error_categories [:deterministic, :quota, :capability, :provider_failure]
  @enforce_keys [:identity, :kind, :io_duration_us]
  defstruct @enforce_keys ++ [:error_code, :error_category, :retry_after_ms]
  @type t :: %__MODULE__{}

  @spec new(AttemptIdentity.t(), atom(), non_neg_integer(), keyword()) :: t()
  def new(%AttemptIdentity{} = identity, kind, io_duration_us, opts \\ []) do
    kind = ExecutionFact.member!(kind, :kind, @kinds)
    error_code = Keyword.get(opts, :error_code)
    error_category = Keyword.get(opts, :error_category)
    retry_after_ms = Keyword.get(opts, :retry_after_ms)

    if kind == :success and (error_code != nil or error_category != nil or retry_after_ms != nil),
      do: raise(ArgumentError, "successful responses cannot carry error classification")

    if kind == :application_error and is_nil(error_code),
      do: raise(ArgumentError, "application errors require an error code")

    if kind == :application_error and is_nil(error_category),
      do: raise(ArgumentError, "application errors require a normalized category")

    if error_code != nil and
         (not is_integer(error_code) or error_code < -2_147_483_648 or
            error_code > 2_147_483_647),
       do: raise(ArgumentError, "error_code must be a signed 32-bit integer")

    %__MODULE__{
      identity: identity,
      kind: kind,
      io_duration_us: ExecutionFact.non_negative!(io_duration_us, :io_duration_us),
      error_code: error_code,
      error_category:
        if(error_category,
          do: ExecutionFact.member!(error_category, :error_category, @error_categories)
        ),
      retry_after_ms: ExecutionFact.optional_duration!(retry_after_ms, :retry_after_ms)
    }
  end
end

defmodule Lasso.RPC.AttemptTerminal.InvalidResponse do
  @moduledoc false
  alias Lasso.RPC.{AttemptIdentity, ExecutionFact}

  @reasons [
    :invalid_json,
    :invalid_envelope,
    :unsupported_version,
    :id_mismatch,
    :unexpected_notification,
    :unexpected_batch
  ]
  @enforce_keys [:identity, :reason, :io_duration_us]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  @spec new(AttemptIdentity.t(), atom(), non_neg_integer()) :: t()
  def new(%AttemptIdentity{} = identity, reason, io_duration_us) do
    %__MODULE__{
      identity: identity,
      reason: ExecutionFact.member!(reason, :reason, @reasons),
      io_duration_us: ExecutionFact.non_negative!(io_duration_us, :io_duration_us)
    }
  end
end

defmodule Lasso.RPC.AttemptTerminal.TransportFailure do
  @moduledoc false
  alias Lasso.RPC.{AttemptIdentity, ExecutionFact}

  @reasons [:connection, :closed, :timeout, :protocol, :tls, :dns, :local_capacity, :unknown]
  @enforce_keys [:identity, :reason, :dispatch_certainty]
  defstruct @enforce_keys ++ [:io_duration_us]
  @type t :: %__MODULE__{}

  @spec new(AttemptIdentity.t(), atom(), ExecutionFact.dispatch_certainty(), keyword()) :: t()
  def new(%AttemptIdentity{} = identity, reason, certainty, opts \\ []) do
    certainty = ExecutionFact.certainty!(certainty)

    if certainty == :not_dispatched,
      do: raise(ArgumentError, "transport failure requires an attempted dispatch")

    %__MODULE__{
      identity: identity,
      reason: ExecutionFact.member!(reason, :reason, @reasons),
      dispatch_certainty: certainty,
      io_duration_us:
        ExecutionFact.optional_duration!(Keyword.get(opts, :io_duration_us), :io_duration_us)
    }
  end
end

defmodule Lasso.RPC.AttemptTerminal.Deadline do
  @moduledoc false
  alias Lasso.RPC.{AttemptIdentity, ExecutionFact}

  @enforce_keys [:identity, :dispatch_certainty, :censoring_boundary_us]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  @spec new(AttemptIdentity.t(), ExecutionFact.dispatch_certainty(), non_neg_integer()) :: t()
  def new(%AttemptIdentity{} = identity, certainty, censoring_boundary_us) do
    certainty = ExecutionFact.certainty!(certainty)

    if certainty == :not_dispatched and censoring_boundary_us != 0,
      do: raise(ArgumentError, "not-dispatched deadline must have a zero censoring boundary")

    %__MODULE__{
      identity: identity,
      dispatch_certainty: certainty,
      censoring_boundary_us:
        ExecutionFact.non_negative!(censoring_boundary_us, :censoring_boundary_us)
    }
  end
end

defmodule Lasso.RPC.AttemptTerminal.Cancelled do
  @moduledoc false
  alias Lasso.RPC.{AttemptIdentity, ExecutionFact}

  @reasons [:caller_abandoned, :socket_closed, :owner_shutdown, :superseded]
  @enforce_keys [:identity, :reason, :dispatch_certainty, :censoring_boundary_us]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  @spec new(AttemptIdentity.t(), atom(), ExecutionFact.dispatch_certainty(), non_neg_integer()) ::
          t()
  def new(%AttemptIdentity{} = identity, reason, certainty, censoring_boundary_us) do
    certainty = ExecutionFact.certainty!(certainty)

    if certainty == :not_dispatched and censoring_boundary_us != 0,
      do: raise(ArgumentError, "not-dispatched cancellation must have a zero censoring boundary")

    %__MODULE__{
      identity: identity,
      reason: ExecutionFact.member!(reason, :reason, @reasons),
      dispatch_certainty: certainty,
      censoring_boundary_us:
        ExecutionFact.non_negative!(censoring_boundary_us, :censoring_boundary_us)
    }
  end
end

defmodule Lasso.RPC.RequestTerminal do
  @moduledoc "Tagged terminal facts for one logical JSON-RPC request item."

  @type t ::
          Lasso.RPC.RequestTerminal.UpstreamResponse.t()
          | Lasso.RPC.RequestTerminal.LocalFailure.t()
          | Lasso.RPC.RequestTerminal.Deadline.t()
          | Lasso.RPC.RequestTerminal.CallerAbandonment.t()
          | Lasso.RPC.RequestTerminal.UnsafeIndeterminateExhaustion.t()
          | Lasso.RPC.RequestTerminal.OrdinaryExhaustion.t()
end

defmodule Lasso.RPC.RequestTerminal.Common do
  @moduledoc false
  alias Lasso.RPC.ExecutionFact

  @spec normalize(keyword()) :: map()
  def normalize(attrs) do
    normalized = %{
      request_id: ExecutionFact.bounded!(Keyword.fetch!(attrs, :request_id), :request_id),
      profile: ExecutionFact.bounded!(Keyword.fetch!(attrs, :profile), :profile),
      subject_token:
        ExecutionFact.optional_bounded!(Keyword.get(attrs, :subject_token), :subject_token),
      chain_id: ExecutionFact.positive!(Keyword.fetch!(attrs, :chain_id), :chain_id),
      execution_safety: ExecutionFact.execution_safety!(Keyword.fetch!(attrs, :execution_safety)),
      routing_intent:
        ExecutionFact.bounded!(Keyword.fetch!(attrs, :routing_intent), :routing_intent),
      workload_key: ExecutionFact.bounded!(Keyword.fetch!(attrs, :workload_key), :workload_key),
      elapsed_us: ExecutionFact.non_negative!(Keyword.fetch!(attrs, :elapsed_us), :elapsed_us),
      candidate_admission_count:
        ExecutionFact.candidate_count!(Keyword.fetch!(attrs, :candidate_admission_count)),
      dispatch_count: ExecutionFact.dispatch_count!(Keyword.fetch!(attrs, :dispatch_count)),
      observed_at: ExecutionFact.optional_bounded!(Keyword.get(attrs, :observed_at), :observed_at)
    }

    if normalized.dispatch_count > normalized.candidate_admission_count,
      do: raise(ArgumentError, "dispatch_count cannot exceed candidate admissions")

    normalized
  end
end

defmodule Lasso.RPC.RequestTerminal.UpstreamResponse do
  @moduledoc false
  alias Lasso.RPC.{AttemptTerminal.Response, RequestTerminal.Common}

  @enforce_keys [
    :request_id,
    :profile,
    :chain_id,
    :execution_safety,
    :routing_intent,
    :workload_key,
    :elapsed_us,
    :candidate_admission_count,
    :dispatch_count,
    :attempt
  ]
  defstruct @enforce_keys ++ [:subject_token, :observed_at]
  @type t :: %__MODULE__{}

  @spec new(keyword(), Response.t()) :: t()
  def new(attrs, %Response{} = attempt) do
    normalized = Common.normalize(attrs)
    identity = attempt.identity

    coherent? =
      normalized.request_id == identity.request_id and
        normalized.profile == identity.profile and
        normalized.subject_token == identity.subject_token and
        normalized.chain_id == identity.chain_id and
        normalized.execution_safety == identity.execution_safety and
        normalized.routing_intent == identity.routing_intent and
        normalized.workload_key == identity.workload_key and
        normalized.candidate_admission_count == identity.candidate_admission_count and
        normalized.dispatch_count == identity.dispatch_count

    unless coherent?, do: raise(ArgumentError, "request terminal and attempt identity disagree")
    struct!(__MODULE__, Map.put(normalized, :attempt, attempt))
  end
end

defmodule Lasso.RPC.RequestTerminal.LocalFailure do
  @moduledoc false
  alias Lasso.RPC.{ExecutionFact, RequestTerminal.Common}
  @reasons [:invalid_request, :unsupported_method, :configuration, :capacity, :internal]
  @enforce_keys [
    :request_id,
    :profile,
    :chain_id,
    :execution_safety,
    :routing_intent,
    :workload_key,
    :elapsed_us,
    :candidate_admission_count,
    :dispatch_count,
    :reason
  ]
  defstruct @enforce_keys ++ [:subject_token, :observed_at]
  @type t :: %__MODULE__{}

  @spec new(keyword(), atom()) :: t()
  def new(attrs, reason),
    do:
      struct!(
        __MODULE__,
        Map.put(
          Common.normalize(attrs),
          :reason,
          ExecutionFact.member!(reason, :reason, @reasons)
        )
      )
end

defmodule Lasso.RPC.RequestTerminal.Deadline do
  @moduledoc false
  alias Lasso.RPC.{ExecutionFact, RequestTerminal.Common}

  @enforce_keys [
    :request_id,
    :profile,
    :chain_id,
    :execution_safety,
    :routing_intent,
    :workload_key,
    :elapsed_us,
    :candidate_admission_count,
    :dispatch_count,
    :dispatch_certainty
  ]
  defstruct @enforce_keys ++ [:subject_token, :observed_at]
  @type t :: %__MODULE__{}

  @spec new(keyword(), ExecutionFact.dispatch_certainty()) :: t()
  def new(attrs, certainty) do
    normalized = Common.normalize(attrs)
    certainty = ExecutionFact.certainty!(certainty)
    ensure_request_certainty!(normalized, certainty)
    struct!(__MODULE__, Map.put(normalized, :dispatch_certainty, certainty))
  end

  defp ensure_request_certainty!(%{dispatch_count: 0}, :not_dispatched), do: :ok

  defp ensure_request_certainty!(%{dispatch_count: count}, certainty)
       when count > 0 and certainty != :not_dispatched,
       do: :ok

  defp ensure_request_certainty!(_, _),
    do: raise(ArgumentError, "dispatch count and certainty disagree")
end

defmodule Lasso.RPC.RequestTerminal.CallerAbandonment do
  @moduledoc false
  alias Lasso.RPC.{ExecutionFact, RequestTerminal.Common}

  @enforce_keys [
    :request_id,
    :profile,
    :chain_id,
    :execution_safety,
    :routing_intent,
    :workload_key,
    :elapsed_us,
    :candidate_admission_count,
    :dispatch_count,
    :dispatch_certainty
  ]
  defstruct @enforce_keys ++ [:subject_token, :observed_at]
  @type t :: %__MODULE__{}

  @spec new(keyword(), ExecutionFact.dispatch_certainty()) :: t()
  def new(attrs, certainty) do
    normalized = Common.normalize(attrs)
    certainty = ExecutionFact.certainty!(certainty)
    ensure_request_certainty!(normalized, certainty)
    struct!(__MODULE__, Map.put(normalized, :dispatch_certainty, certainty))
  end

  defp ensure_request_certainty!(%{dispatch_count: 0}, :not_dispatched), do: :ok

  defp ensure_request_certainty!(%{dispatch_count: count}, certainty)
       when count > 0 and certainty != :not_dispatched,
       do: :ok

  defp ensure_request_certainty!(_, _),
    do: raise(ArgumentError, "dispatch count and certainty disagree")
end

defmodule Lasso.RPC.RequestTerminal.UnsafeIndeterminateExhaustion do
  @moduledoc false
  alias Lasso.RPC.RequestTerminal.Common

  @enforce_keys [
    :request_id,
    :profile,
    :chain_id,
    :execution_safety,
    :routing_intent,
    :workload_key,
    :elapsed_us,
    :candidate_admission_count,
    :dispatch_count
  ]
  defstruct @enforce_keys ++ [:subject_token, :observed_at]
  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()

  def new(attrs) do
    normalized = Common.normalize(attrs)

    if normalized.execution_safety == :replay_safe,
      do: raise(ArgumentError, "replay-safe work cannot end as unsafe indeterminate exhaustion")

    if normalized.dispatch_count == 0,
      do: raise(ArgumentError, "unsafe indeterminate exhaustion requires a dispatch")

    struct!(__MODULE__, normalized)
  end
end

defmodule Lasso.RPC.RequestTerminal.OrdinaryExhaustion do
  @moduledoc false
  alias Lasso.RPC.{ExecutionFact, RequestTerminal.Common}

  @reasons [
    :providers_exhausted,
    :candidate_budget_exhausted,
    :dispatch_budget_exhausted,
    :admission_unavailable
  ]
  @enforce_keys [
    :request_id,
    :profile,
    :chain_id,
    :execution_safety,
    :routing_intent,
    :workload_key,
    :elapsed_us,
    :candidate_admission_count,
    :dispatch_count,
    :reason
  ]
  defstruct @enforce_keys ++ [:subject_token, :observed_at]
  @type t :: %__MODULE__{}

  @spec new(keyword(), atom()) :: t()
  def new(attrs, reason),
    do:
      struct!(
        __MODULE__,
        Map.put(
          Common.normalize(attrs),
          :reason,
          ExecutionFact.member!(reason, :reason, @reasons)
        )
      )
end

defmodule Lasso.RPC.LateObservation do
  @moduledoc "A correlated diagnostic that cannot revise terminal execution truth."
  alias Lasso.RPC.ExecutionFact

  @kinds [
    :send_started,
    :send_confirmed,
    :not_dispatched,
    :response,
    :invalid_response,
    :transport_failure,
    :predispatch_failure,
    :cancelled,
    :task_exit
  ]
  @enforce_keys [:request_id, :attempt_id, :kind, :elapsed_us]
  defstruct @enforce_keys ++ [:detail]
  @type t :: %__MODULE__{}

  def new(attrs) do
    observation = struct!(__MODULE__, attrs)

    %{
      observation
      | request_id: ExecutionFact.bounded!(observation.request_id, :request_id),
        attempt_id: ExecutionFact.bounded!(observation.attempt_id, :attempt_id),
        kind: ExecutionFact.member!(observation.kind, :kind, @kinds),
        elapsed_us: ExecutionFact.non_negative!(observation.elapsed_us, :elapsed_us),
        detail: ExecutionFact.optional_bounded!(observation.detail, :detail)
    }
  end
end

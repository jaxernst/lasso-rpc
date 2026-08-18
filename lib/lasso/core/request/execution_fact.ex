defmodule Lasso.RPC.ExecutionFact do
  @moduledoc """
  Shared vocabulary and validation for tagged execution facts.

  Internal monotonic timestamps remain node-local and are intentionally excluded
  from the external codec.
  """

  alias Lasso.RPC.BoundedIdentifier

  @dispatch_certainties [:not_dispatched, :indeterminate, :dispatched]
  @max_portable_integer 9_223_372_036_854_775_807
  @transports [:http, :ws]
  @execution_safeties [
    :replay_safe,
    :raw_transaction_broadcast,
    :upstream_signed,
    :filter_create,
    :filter_affine_read,
    :filter_affine_consume,
    :filter_affine_uninstall,
    :subscription,
    :unknown
  ]

  @type dispatch_certainty :: :not_dispatched | :indeterminate | :dispatched

  @spec bounded!(term(), atom()) :: binary()
  def bounded!(value, _field) when is_binary(value), do: BoundedIdentifier.encode(value)

  def bounded!(_value, field), do: raise(ArgumentError, "#{field} must be a string")

  @spec optional_bounded!(term(), atom()) :: binary() | nil
  def optional_bounded!(nil, _field), do: nil
  def optional_bounded!(value, field), do: bounded!(value, field)

  @spec non_negative!(term(), atom()) :: non_neg_integer()
  def non_negative!(value, _field)
      when is_integer(value) and value >= 0 and value <= @max_portable_integer,
      do: value

  def non_negative!(_value, field), do: raise(ArgumentError, "#{field} must be non-negative")

  @spec positive!(term(), atom()) :: pos_integer()
  def positive!(value, _field)
      when is_integer(value) and value > 0 and value <= @max_portable_integer,
      do: value

  def positive!(_value, field), do: raise(ArgumentError, "#{field} must be positive")

  @spec candidate_count!(term()) :: 0..16
  def candidate_count!(value) when is_integer(value) and value in 0..16, do: value

  def candidate_count!(_value),
    do: raise(ArgumentError, "candidate_admission_count must be 0..16")

  @spec dispatch_count!(term()) :: 0..3
  def dispatch_count!(value) when is_integer(value) and value in 0..3, do: value
  def dispatch_count!(_value), do: raise(ArgumentError, "dispatch_count must be 0..3")

  @spec member!(term(), atom(), [term()]) :: term()
  def member!(value, field, allowed) do
    if value in allowed,
      do: value,
      else: raise(ArgumentError, "invalid #{field}: #{inspect(value)}")
  end

  @spec certainty!(term()) :: dispatch_certainty()
  def certainty!(value), do: member!(value, :dispatch_certainty, @dispatch_certainties)

  @spec transport!(term()) :: :http | :ws
  def transport!(value), do: member!(value, :transport, @transports)

  @spec execution_safety!(term()) :: atom()
  def execution_safety!(value), do: member!(value, :execution_safety, @execution_safeties)

  @spec optional_duration!(term(), atom()) :: non_neg_integer() | nil
  def optional_duration!(nil, _field), do: nil
  def optional_duration!(value, field), do: non_negative!(value, field)
end

defmodule Lasso.RPC.AttemptIdentity do
  @moduledoc """
  Immutable bounded identity and policy captured when an attempt is authorized.
  """

  alias Lasso.RPC.ExecutionFact

  @circuit_scopes [:broad, :intent]

  @enforce_keys [
    :request_id,
    :attempt_id,
    :profile,
    :chain_id,
    :upstream_instance_id,
    :transport,
    :route_generation,
    :circuit_scope,
    :circuit_epoch,
    :execution_safety,
    :routing_intent,
    :workload_key,
    :request_budget_ms,
    :candidate_admission_count,
    :dispatch_count
  ]
  defstruct @enforce_keys ++ [:subject_token]

  @type t :: %__MODULE__{
          request_id: binary(),
          attempt_id: binary(),
          profile: binary(),
          subject_token: binary() | nil,
          chain_id: pos_integer(),
          upstream_instance_id: binary(),
          transport: :http | :ws,
          route_generation: non_neg_integer(),
          circuit_scope: :broad | :intent,
          circuit_epoch: non_neg_integer(),
          execution_safety: atom(),
          routing_intent: binary(),
          workload_key: binary(),
          request_budget_ms: non_neg_integer(),
          candidate_admission_count: non_neg_integer(),
          dispatch_count: pos_integer()
        }

  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    normalize(struct!(__MODULE__, attrs))
  end

  @doc false
  @spec new_runtime(map()) :: t()
  def new_runtime(
        %{
          request_id: _,
          attempt_id: _,
          profile: _,
          subject_token: _,
          chain_id: _,
          upstream_instance_id: _,
          transport: _,
          route_generation: _,
          circuit_scope: _,
          circuit_epoch: _,
          execution_safety: _,
          routing_intent: _,
          workload_key: _,
          request_budget_ms: _,
          candidate_admission_count: _,
          dispatch_count: _
        } = attrs
      )
      when map_size(attrs) == 16,
      do: normalize(attrs)

  def new_runtime(_attrs), do: raise(ArgumentError, "invalid attempt identity attributes")

  defp normalize(identity) do
    normalized = %__MODULE__{
      request_id: ExecutionFact.bounded!(identity.request_id, :request_id),
      attempt_id: ExecutionFact.bounded!(identity.attempt_id, :attempt_id),
      profile: ExecutionFact.bounded!(identity.profile, :profile),
      subject_token: ExecutionFact.optional_bounded!(identity.subject_token, :subject_token),
      chain_id: ExecutionFact.positive!(identity.chain_id, :chain_id),
      upstream_instance_id:
        ExecutionFact.bounded!(identity.upstream_instance_id, :upstream_instance_id),
      transport: ExecutionFact.transport!(identity.transport),
      route_generation: ExecutionFact.non_negative!(identity.route_generation, :route_generation),
      circuit_scope:
        ExecutionFact.member!(identity.circuit_scope, :circuit_scope, @circuit_scopes),
      circuit_epoch: ExecutionFact.non_negative!(identity.circuit_epoch, :circuit_epoch),
      execution_safety: ExecutionFact.execution_safety!(identity.execution_safety),
      routing_intent: ExecutionFact.bounded!(identity.routing_intent, :routing_intent),
      workload_key: ExecutionFact.bounded!(identity.workload_key, :workload_key),
      request_budget_ms:
        ExecutionFact.non_negative!(identity.request_budget_ms, :request_budget_ms),
      candidate_admission_count:
        ExecutionFact.candidate_count!(identity.candidate_admission_count),
      dispatch_count:
        identity.dispatch_count
        |> ExecutionFact.dispatch_count!()
        |> ensure_positive_dispatch!()
    }

    if normalized.candidate_admission_count == 0 or
         normalized.dispatch_count > normalized.candidate_admission_count,
       do: raise(ArgumentError, "attempt counts are incoherent")

    normalized
  end

  defp ensure_positive_dispatch!(0),
    do: raise(ArgumentError, "attempt dispatch_count must be positive")

  defp ensure_positive_dispatch!(value), do: value
end

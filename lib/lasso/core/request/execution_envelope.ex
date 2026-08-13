defmodule Lasso.RPC.ExecutionEnvelope do
  @moduledoc """
  Immutable bounds and safety policy for one logical JSON-RPC item.

  Callers replace the envelope with the value returned by admission and dispatch
  accounting functions. The absolute monotonic deadline is never extended.
  """

  alias Lasso.RPC.MethodRegistry

  @minimum_attempt_ms 25
  @max_candidate_admissions 16
  @max_replay_safe_dispatches 3

  @type execution_safety ::
          :replay_safe
          | :raw_transaction_broadcast
          | :upstream_signed
          | :filter_create
          | :filter_affine_read
          | :filter_affine_consume
          | :filter_affine_uninstall
          | :subscription
          | :unknown

  @type t :: %__MODULE__{
          request_id: String.t(),
          started_at_us: integer(),
          deadline_us: integer(),
          original_timeout_ms: non_neg_integer(),
          execution_safety: execution_safety(),
          dispatch_limit: 1..3,
          dispatch_count: 0..3,
          candidate_admission_limit: 16,
          candidate_admission_count: 0..16,
          dispatched_channels: term()
        }

  @enforce_keys [
    :request_id,
    :started_at_us,
    :deadline_us,
    :original_timeout_ms,
    :execution_safety,
    :dispatch_limit
  ]
  defstruct @enforce_keys ++
              [
                dispatch_count: 0,
                candidate_admission_limit: @max_candidate_admissions,
                candidate_admission_count: 0,
                dispatched_channels: MapSet.new()
              ]

  @spec new(String.t(), String.t(), non_neg_integer(), keyword()) :: t()
  def new(request_id, method, timeout_ms, opts \\ [])
      when is_binary(request_id) and is_binary(method) and is_integer(timeout_ms) and
             timeout_ms >= 0 do
    started_at_us =
      case Keyword.get(opts, :started_at_us) do
        value when is_integer(value) -> value
        _ -> System.monotonic_time(:microsecond)
      end

    safety = classify(method)

    %__MODULE__{
      request_id: request_id,
      started_at_us: started_at_us,
      deadline_us: started_at_us + timeout_ms * 1_000,
      original_timeout_ms: timeout_ms,
      execution_safety: safety,
      dispatch_limit: dispatch_limit(safety)
    }
  end

  @spec classify(String.t()) :: execution_safety()
  def classify("eth_sendRawTransaction"), do: :raw_transaction_broadcast

  def classify(method)
      when method in [
             "eth_sendTransaction",
             "eth_sign",
             "eth_signTransaction",
             "personal_sign",
             "personal_sendTransaction"
           ],
      do: :upstream_signed

  def classify(method) when method in ["eth_newFilter", "eth_newBlockFilter"],
    do: :filter_create

  def classify("eth_newPendingTransactionFilter"), do: :filter_create
  def classify("eth_getFilterLogs"), do: :filter_affine_read
  def classify("eth_getFilterChanges"), do: :filter_affine_consume
  def classify("eth_uninstallFilter"), do: :filter_affine_uninstall
  def classify(method) when method in ["eth_subscribe", "eth_unsubscribe"], do: :subscription

  def classify(method) do
    if replay_safe_read?(method), do: :replay_safe, else: :unknown
  end

  @spec remaining_ms(t(), integer()) :: non_neg_integer()
  def remaining_ms(%__MODULE__{} = envelope, now_us \\ System.monotonic_time(:microsecond)) do
    max(0, div(envelope.deadline_us - now_us, 1_000))
  end

  @spec admit_candidate(t(), integer()) ::
          {:ok, t()} | {:error, :candidate_budget_exhausted | :deadline_exhausted}
  def admit_candidate(envelope, now_us \\ System.monotonic_time(:microsecond))

  def admit_candidate(%__MODULE__{} = envelope, now_us) when now_us >= envelope.deadline_us,
    do: {:error, :deadline_exhausted}

  def admit_candidate(%__MODULE__{candidate_admission_count: count} = envelope, _now_us)
      when count < envelope.candidate_admission_limit do
    {:ok, %{envelope | candidate_admission_count: count + 1}}
  end

  def admit_candidate(%__MODULE__{}, _now_us), do: {:error, :candidate_budget_exhausted}

  @spec reserve_dispatch(t(), String.t(), :http | :ws, integer()) ::
          {:ok, t(), pos_integer()}
          | {:error, :deadline_exhausted | :dispatch_budget_exhausted | :duplicate_dispatch}
  def reserve_dispatch(
        %__MODULE__{} = envelope,
        instance_id,
        transport,
        now_us \\ System.monotonic_time(:microsecond)
      ) do
    remaining_ms = remaining_ms(envelope, now_us)
    channel_key = {instance_id, transport}

    cond do
      remaining_ms < @minimum_attempt_ms ->
        {:error, :deadline_exhausted}

      envelope.dispatch_count >= envelope.dispatch_limit ->
        {:error, :dispatch_budget_exhausted}

      MapSet.member?(envelope.dispatched_channels, channel_key) ->
        {:error, :duplicate_dispatch}

      true ->
        updated = %{
          envelope
          | dispatch_count: envelope.dispatch_count + 1,
            dispatched_channels: MapSet.put(envelope.dispatched_channels, channel_key)
        }

        {:ok, updated, attempt_timeout_ms(updated, remaining_ms)}
    end
  end

  @spec release_dispatch(t(), String.t(), :http | :ws) :: t()
  def release_dispatch(%__MODULE__{} = envelope, instance_id, transport) do
    channel_key = {instance_id, transport}

    if MapSet.member?(envelope.dispatched_channels, channel_key) do
      %{
        envelope
        | dispatch_count: envelope.dispatch_count - 1,
          dispatched_channels: MapSet.delete(envelope.dispatched_channels, channel_key)
      }
    else
      envelope
    end
  end

  defp dispatch_limit(:replay_safe), do: @max_replay_safe_dispatches
  defp dispatch_limit(:raw_transaction_broadcast), do: 1
  defp dispatch_limit(_safety), do: 1

  defp attempt_timeout_ms(
         %__MODULE__{execution_safety: :replay_safe, dispatch_count: 1} = envelope,
         remaining_ms
       ) do
    min(remaining_ms, max(@minimum_attempt_ms, div(envelope.original_timeout_ms * 60, 100)))
  end

  defp attempt_timeout_ms(_envelope, remaining_ms), do: remaining_ms

  defp replay_safe_read?(method) do
    MethodRegistry.method_category(method) in [
      :core,
      :state,
      :network,
      :node_admin,
      :eip1559,
      :eip4844,
      :batch,
      :debug,
      :trace,
      :txpool
    ] or method == "eth_getLogs"
  end
end

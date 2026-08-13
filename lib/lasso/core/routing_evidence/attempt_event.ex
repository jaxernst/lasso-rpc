defmodule Lasso.RPC.RoutingEvidence.AttemptEvent do
  @moduledoc """
  Terminal evidence for one dispatched upstream attempt.

  Admission rejections never produce this event. Successful latency is exact upstream I/O time;
  timeout and cancellation observations carry a censoring boundary instead.
  """

  alias Lasso.Core.Support.ErrorClassification
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{Channel, RequestContext}

  @type outcome ::
          :usable_success
          | :service_failure
          | :timeout
          | :capacity_rejection
          | :neutral_error
          | :cancelled

  @type t :: %__MODULE__{
          request_id: String.t(),
          upstream_instance_id: String.t(),
          chain_id: pos_integer(),
          provider_id: String.t(),
          transport: :http | :ws,
          workload_key: atom(),
          observed_at_ms: integer(),
          outcome: outcome(),
          elapsed_io_ms: number() | nil,
          censoring_boundary_ms: number() | nil,
          error_category: atom() | nil
        }

  @enforce_keys [
    :request_id,
    :upstream_instance_id,
    :chain_id,
    :provider_id,
    :transport,
    :workload_key,
    :observed_at_ms,
    :outcome
  ]
  defstruct @enforce_keys ++
              [elapsed_io_ms: nil, censoring_boundary_ms: nil, error_category: nil]

  @doc """
  Builds a terminal event from a transport result.

  Returns `:not_dispatched` for transport preflight failures that did not reach an upstream.
  """
  @spec from_result(RequestContext.t(), Channel.t(), String.t(), term(), keyword()) ::
          {:ok, t()} | :not_dispatched
  def from_result(ctx, channel, upstream_instance_id, result, opts \\ [])

  def from_result(
        _ctx,
        _channel,
        _upstream_instance_id,
        {:error, :unsupported_method, _io_ms},
        _opts
      ),
      do: :not_dispatched

  def from_result(ctx, channel, upstream_instance_id, {:ok, _result, io_ms}, opts) do
    {:ok,
     build(ctx, channel, upstream_instance_id, :usable_success,
       elapsed_io_ms: io_ms,
       workload_key: Keyword.get(opts, :workload_key, :default)
     )}
  end

  def from_result(ctx, channel, upstream_instance_id, {:error, reason, io_ms}, opts) do
    category = error_category(reason)
    outcome = classify_error(category)

    timing =
      if outcome in [:timeout, :cancelled] do
        [censoring_boundary_ms: io_ms]
      else
        [elapsed_io_ms: io_ms]
      end

    {:ok,
     build(
       ctx,
       channel,
       upstream_instance_id,
       outcome,
       timing ++
         [
           error_category: category,
           workload_key: Keyword.get(opts, :workload_key, :default)
         ]
     )}
  end

  def from_result(ctx, channel, upstream_instance_id, {:exception, _exception}, opts) do
    {:ok,
     build(ctx, channel, upstream_instance_id, :service_failure,
       censoring_boundary_ms: Keyword.fetch!(opts, :censoring_boundary_ms),
       error_category: :internal_error,
       workload_key: Keyword.get(opts, :workload_key, :default)
     )}
  end

  @doc false
  @spec classify_error(atom()) :: outcome()
  def classify_error(category) when category in [:cancelled, :canceled, :client_cancelled],
    do: :cancelled

  def classify_error(:timeout), do: :timeout
  def classify_error(:rate_limit), do: :capacity_rejection

  def classify_error(category) do
    if ErrorClassification.breaker_penalty?(category),
      do: :service_failure,
      else: :neutral_error
  end

  defp build(ctx, channel, upstream_instance_id, outcome, opts) do
    %__MODULE__{
      request_id: ctx.request_id,
      upstream_instance_id: upstream_instance_id,
      chain_id: ctx.chain_id,
      provider_id: channel.provider_id,
      transport: channel.transport,
      workload_key: Keyword.fetch!(opts, :workload_key),
      observed_at_ms: System.monotonic_time(:millisecond),
      outcome: outcome,
      elapsed_io_ms: Keyword.get(opts, :elapsed_io_ms),
      censoring_boundary_ms: Keyword.get(opts, :censoring_boundary_ms),
      error_category: Keyword.get(opts, :error_category)
    }
  end

  defp error_category(%JError{category: category}), do: category || :unknown_error
  defp error_category(:timeout), do: :timeout
  defp error_category(:cancelled), do: :cancelled
  defp error_category(:canceled), do: :cancelled
  defp error_category(_reason), do: :unknown_error
end

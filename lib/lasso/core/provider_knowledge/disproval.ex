defmodule Lasso.RPC.ProviderKnowledge.Disproval do
  @moduledoc """
  One provider error that a peer then served for the same request.

  Built from the errored attempt's evidence once the witness answers, so the
  learner sees the credential, method and request shape that erred, the error's
  code and masked message fingerprint, and the provider that served instead.
  """

  alias Lasso.RPC.ProviderKnowledge.Evidence
  alias Lasso.RPC.RoutingEvidence.Workload

  @enforce_keys [
    :subject,
    :profile,
    :profile_class,
    :chain_id,
    :partition,
    :method,
    :shape,
    :epoch,
    :observed_at_ms,
    :error_code,
    :template,
    :witness
  ]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}

  @spec from_evidence(Evidence.t(), binary()) :: t()
  def from_evidence(%Evidence{} = evidence, witness) do
    struct!(
      __MODULE__,
      evidence
      |> Map.take([:subject, :profile, :profile_class, :chain_id, :partition, :method, :shape])
      |> Map.merge(%{
        epoch: evidence.epoch,
        observed_at_ms: System.system_time(:millisecond),
        error_code: evidence.error_code,
        template: evidence.template_fingerprint,
        witness: witness
      })
    )
  end

  @spec encode(t()) :: {:ok, binary()} | {:error, :invalid | :too_large}
  def encode(%__MODULE__{} = record) do
    if valid?(record) do
      payload = :erlang.term_to_binary({:disproval, record})
      if byte_size(payload) <= 2_048, do: {:ok, payload}, else: {:error, :too_large}
    else
      {:error, :invalid}
    end
  end

  @spec decode_record(term()) :: {:ok, t()} | {:error, :invalid}
  def decode_record({:disproval, %__MODULE__{} = record}) do
    if valid?(record), do: {:ok, record}, else: {:error, :invalid}
  end

  def decode_record(_), do: {:error, :invalid}

  @doc "Whether a decoded or restored record keeps the bounded wire contract."
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = record) do
    Enum.all?([record.subject, record.profile, record.witness], &bounded?/1) and
      record.profile_class in [:managed, :custom] and
      is_integer(record.chain_id) and record.chain_id > 0 and
      record.partition in Workload.partitions() and
      Lasso.RPC.BoundedIdentifier.valid?(record.method) and valid_shape?(record.shape) and
      is_integer(record.epoch) and record.epoch >= 0 and
      is_integer(record.observed_at_ms) and record.observed_at_ms >= 0 and
      (is_nil(record.error_code) or is_integer(record.error_code)) and
      (is_nil(record.template) or
         (is_binary(record.template) and byte_size(record.template) == 64))
  end

  def valid?(_), do: false

  @spec valid_shape?(term()) :: boolean()
  def valid_shape?(:other), do: true

  def valid_shape?({:logs_span, anchor, band}),
    do: anchor in [:hash, :latest, :number] and valid_band?(band)

  def valid_shape?({:historical_age, resource, band}),
    do:
      resource in [:blocks, :balance, :state, :logs, :receipts, :proofs, :traces] and
        valid_band?(band)

  def valid_shape?(_), do: false

  defp valid_band?(band), do: band == :unknown or band in 0..31
  defp bounded?(value), do: is_binary(value) and byte_size(value) in 1..128
end

defmodule Lasso.RPC.ProviderKnowledge.Learner do
  @moduledoc "Pure, bounded reducer from attempt evidence to mergeable knowledge."

  alias Lasso.RPC.ProviderKnowledge.Evidence

  @callback key(Evidence.t()) :: term() | :skip
  @callback init(term()) :: term()
  @callback observe(term(), Evidence.t()) :: term()
  @callback decay(term(), non_neg_integer()) :: term() | :expired
  @callback merge(term(), term()) :: term()
  @callback hints(term(), term()) :: [map()]
  @callback encode(term()) :: {:ok, binary()} | {:error, term()}
  @doc """
  Decodes a state written by `encode/1` as a `{version, state}` term.

  A recognized retired version returns `{:error, {:unsupported_version, version}}`
  so snapshot readers can discard it explicitly. A newer version is any other
  error here; readers classify it from its frame with `envelope_version/1`.
  Malformed or semantically invalid content is any other error.
  """
  @callback decode(binary()) ::
              {:ok, term()} | {:error, {:unsupported_version, pos_integer()}} | {:error, term()}
  @callback bounds() :: %{
              max_keys: pos_integer(),
              max_state_bytes: pos_integer(),
              version: pos_integer()
            }

  @doc "Whether this learner's state may cross serving-node boundaries."
  @callback exchange_scope() :: :shared | :local
  @doc """
  Publication fingerprint and refresh interval for a decayed shared state.

  Shared learners implement this callback. The fingerprint contains only facts
  whose change should publish a complete image, including recovery evidence.
  The interval is nil when no serving hint needs a periodic freshness refresh.
  Local learners are never asked for a publication decision.
  """
  @callback publication(term()) :: {term(), pos_integer() | nil}
  @doc "A learner may explicitly attribute a validated system check to a retained knowledge partition."
  @callback evidence_partition(Evidence.t()) :: atom()
  @doc """
  Conservative byte bound for the exact payload returned by `encode/1`.

  A bound within `bounds().max_state_bytes` admits in-memory updates without
  encoding. An absent callback or a larger bound uses the exact encoder instead.
  The callback must include its codec envelope and options, and must not omit
  semantic validation performed by `encode/1`.
  """
  @callback encoded_size_upper_bound(term()) :: non_neg_integer()
  @optional_callbacks exchange_scope: 0,
                      publication: 1,
                      evidence_partition: 1,
                      encoded_size_upper_bound: 1

  @spec partition(module(), Evidence.t()) :: atom()
  def partition(learner, evidence) do
    if function_exported?(learner, :evidence_partition, 1),
      do: learner.evidence_partition(evidence),
      else: evidence.partition
  end

  @doc """
  Reads the version of an encoded `{version, state}` envelope without decoding
  its state, so a newer state holding terms this VM cannot represent is still
  classifiable.

  The frame is validated: the external-term tag, a compressed stream that
  inflates completely to exactly its declared size, a two-element tuple, an
  integer version and a non-empty state term. The state term's contents are
  opaque. Callers bound the declared expanded size before calling.
  """
  @spec envelope_version(binary()) :: {:ok, non_neg_integer()} | :error
  def envelope_version(<<131, 80, size::32, compressed::binary>>) do
    case inflate(compressed, size) do
      {:ok, term} -> envelope_header(term)
      :error -> :error
    end
  end

  def envelope_version(<<131, term::binary>>), do: envelope_header(term)
  def envelope_version(_payload), do: :error

  defp envelope_header(<<104, 2, 97, version, state::binary>>) when state != <<>>,
    do: {:ok, version}

  defp envelope_header(<<104, 2, 98, version::signed-32, state::binary>>)
       when version >= 0 and state != <<>>,
       do: {:ok, version}

  defp envelope_header(_term), do: :error

  defp inflate(compressed, size) do
    zlib = :zlib.open()

    try do
      :ok = :zlib.inflateInit(zlib)
      inflated(zlib, :zlib.safeInflate(zlib, compressed), [], size)
    catch
      _kind, _reason -> :error
    after
      :zlib.close(zlib)
    end
  end

  defp inflated(zlib, {status, output}, acc, remaining) do
    remaining = remaining - IO.iodata_length(output)

    cond do
      remaining < 0 -> :error
      status == :finished and remaining == 0 -> complete(zlib, [acc | output])
      status == :finished or output == [] -> :error
      true -> inflated(zlib, :zlib.safeInflate(zlib, []), [acc | output], remaining)
    end
  end

  # inflateEnd verifies the stream's trailing checksum.
  defp complete(zlib, output) do
    :ok = :zlib.inflateEnd(zlib)
    {:ok, IO.iodata_to_binary(output)}
  end

  @spec exchangeable?(module()) :: boolean()
  def exchangeable?(learner) do
    not function_exported?(learner, :exchange_scope, 0) or learner.exchange_scope() == :shared
  end
end

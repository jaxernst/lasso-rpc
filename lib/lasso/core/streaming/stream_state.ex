defmodule Lasso.Core.Streaming.StreamState do
  @moduledoc """
  Per-key stream state helpers: markers, dedupe, and ingestion helpers.

  Keeps hot-path operations O(1) using DedupeCache.
  """

  alias Lasso.Core.Support.DedupeCache

  @enforce_keys [:markers, :dedupe]
  defstruct markers: %{last_block_num: nil, last_log_block: nil},
            dedupe: DedupeCache.new(max_items: 256, max_age_ms: 30_000)

  @type t :: %__MODULE__{
          markers: %{
            last_block_num: integer() | nil,
            last_log_block: integer() | nil
          },
          dedupe: DedupeCache.t()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      markers: %{last_block_num: nil, last_log_block: nil},
      dedupe:
        DedupeCache.new(
          max_items: Keyword.get(opts, :dedupe_max_items, 256),
          max_age_ms: Keyword.get(opts, :dedupe_max_age_ms, 30_000)
        )
    }
  end

  # Public API for ingestion

  @spec ingest_new_head(t(), map()) :: {t(), :emit | :skip}
  def ingest_new_head(state = %__MODULE__{}, %{"hash" => hash} = payload) when is_binary(hash) do
    if DedupeCache.member?(state.dedupe, {:block, hash}) do
      {state, :skip}
    else
      num = decode_hex(Map.get(payload, "number"))
      now = System.monotonic_time(:millisecond)
      dedupe1 = state.dedupe |> DedupeCache.put({:block, hash}, now) |> DedupeCache.cleanup(now)
      markers1 = %{state.markers | last_block_num: num}
      {%{state | dedupe: dedupe1, markers: markers1}, :emit}
    end
  end

  @spec ingest_log(t(), map()) :: {t(), :emit | :skip}
  def ingest_log(%__MODULE__{} = state, payload) do
    key = {Map.get(payload, "blockHash"), Map.get(payload, "logIndex")}

    if DedupeCache.member?(state.dedupe, {:log, key}) do
      {state, :skip}
    else
      num = decode_hex(Map.get(payload, "blockNumber"))
      now = System.monotonic_time(:millisecond)
      dedupe1 = state.dedupe |> DedupeCache.put({:log, key}, now) |> DedupeCache.cleanup(now)
      markers1 = %{state.markers | last_log_block: num}
      {%{state | dedupe: dedupe1, markers: markers1}, :emit}
    end
  end

  @spec last_block_num(t()) :: integer() | nil
  def last_block_num(%__MODULE__{markers: %{last_block_num: n}}), do: n

  @spec last_log_block(t()) :: integer() | nil
  def last_log_block(%__MODULE__{markers: %{last_log_block: n}}), do: n

  # Utilities
  defp decode_hex(nil), do: nil
  defp decode_hex("0x" <> rest), do: String.to_integer(rest, 16)
  defp decode_hex(num) when is_integer(num), do: num
end

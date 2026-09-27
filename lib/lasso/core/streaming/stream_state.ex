defmodule Lasso.Core.Streaming.StreamState do
  @moduledoc """
  Per-key stream state helpers: markers, bounded continuity history, dedupe, and
  ingestion helpers.

  Keeps hot-path operations O(1) using DedupeCache.
  """

  alias Lasso.Core.Support.DedupeCache
  alias Lasso.JSONRPC.Quantity

  @enforce_keys [:markers, :dedupe, :history_blocks, :history_max_items]
  defstruct markers: %{last_block_num: nil, last_log_block: nil},
            dedupe: DedupeCache.new(max_items: 256, max_age_ms: 30_000),
            history_blocks: 32,
            history_max_items: 4_096,
            retained_bytes: 0,
            history_overflowed: false,
            history_overflow_block: nil,
            head_history: %{},
            head_history_bytes: %{},
            log_history: %{},
            log_history_bytes: %{}

  @type t :: %__MODULE__{
          markers: %{
            last_block_num: integer() | nil,
            last_log_block: integer() | nil
          },
          dedupe: DedupeCache.t(),
          history_blocks: pos_integer(),
          history_max_items: pos_integer(),
          retained_bytes: non_neg_integer(),
          history_overflowed: boolean(),
          history_overflow_block: non_neg_integer() | nil,
          head_history: %{optional(non_neg_integer()) => map()},
          head_history_bytes: %{optional(non_neg_integer()) => non_neg_integer()},
          log_history: %{optional(tuple()) => map()},
          log_history_bytes: %{optional(tuple()) => non_neg_integer()}
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      markers: %{last_block_num: nil, last_log_block: nil},
      history_blocks: Keyword.get(opts, :history_blocks, 32),
      history_max_items: Keyword.get(opts, :history_max_items, 4_096),
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
    num = decode_hex(Map.get(payload, "number"))
    retained_hash = state.head_history |> Map.get(num, %{}) |> Map.get("hash")
    seen_hash? = DedupeCache.member?(state.dedupe, {:block, hash})

    if retained_hash == hash or (seen_hash? and is_nil(retained_hash)) do
      {state, :skip}
    else
      now = System.monotonic_time(:millisecond)
      dedupe1 = state.dedupe |> DedupeCache.put({:block, hash}, now) |> DedupeCache.cleanup(now)

      markers1 = %{
        state.markers
        | last_block_num: advance_marker(state.markers.last_block_num, num)
      }

      head_history =
        state.head_history
        |> maybe_put(num, payload)
        |> prune_heads(markers1.last_block_num, state.history_blocks)

      payload_bytes = if is_integer(num), do: event_bytes(payload), else: 0

      head_history_bytes =
        state.head_history_bytes
        |> maybe_put(num, payload_bytes)
        |> Map.take(Map.keys(head_history))

      retained_bytes =
        retained_total(
          state.retained_bytes,
          state.head_history_bytes,
          head_history_bytes,
          num,
          payload_bytes
        )

      {%{
         state
         | dedupe: dedupe1,
           markers: markers1,
           head_history: head_history,
           head_history_bytes: head_history_bytes,
           retained_bytes: max(retained_bytes, 0)
       }, :emit}
    end
  end

  @spec ingest_log(t(), map()) :: {t(), :emit | :skip}
  def ingest_log(%__MODULE__{} = state, payload) do
    removed? = Map.get(payload, "removed", false) == true
    identity = log_identity(payload)
    key = {Map.get(payload, "blockHash"), Map.get(payload, "logIndex"), removed?}
    active? = Map.has_key?(state.log_history, identity)
    seen? = DedupeCache.member?(state.dedupe, {:log, key})
    num = decode_hex(Map.get(payload, "blockNumber"))

    if skip_log?(state, removed?, active?, seen?, num) do
      {state, :skip}
    else
      now = System.monotonic_time(:millisecond)
      dedupe1 = state.dedupe |> DedupeCache.put({:log, key}, now) |> DedupeCache.cleanup(now)

      markers1 = %{
        state.markers
        | last_log_block: advance_marker(state.markers.last_log_block, num)
      }

      payload_bytes = event_bytes(payload)
      log_history = update_log_history(state.log_history, payload)

      log_history_bytes =
        update_log_history_bytes(state.log_history_bytes, payload, payload_bytes)

      log_history = prune_logs(log_history, markers1.last_log_block, state.history_blocks)
      log_history_bytes = Map.take(log_history_bytes, Map.keys(log_history))
      overflowed = map_size(log_history) > state.history_max_items
      log_history = retain_newest_logs(log_history, state.history_max_items)
      log_history_bytes = Map.take(log_history_bytes, Map.keys(log_history))
      overflow_block = overflow_block(state, markers1.last_log_block, overflowed)

      retained_bytes =
        retained_total(
          state.retained_bytes,
          state.log_history_bytes,
          log_history_bytes,
          identity,
          if(removed?, do: 0, else: payload_bytes)
        )

      {%{
         state
         | dedupe: dedupe1,
           markers: markers1,
           log_history: log_history,
           log_history_bytes: log_history_bytes,
           retained_bytes: max(retained_bytes, 0),
           history_overflowed: is_integer(overflow_block),
           history_overflow_block: overflow_block
       }, :emit}
    end
  end

  @spec log_continuity(t(), map()) ::
          :continuous | {:discontinuous, map()} | {:error, :invalid_log}
  def log_continuity(%__MODULE__{}, %{"removed" => true}), do: :continuous

  def log_continuity(%__MODULE__{} = state, payload) when is_map(payload) do
    with number when is_integer(number) <- decode_hex(Map.get(payload, "blockNumber")),
         hash when is_binary(hash) <- Map.get(payload, "blockHash") do
      conflicting_hashes =
        state.log_history
        |> Map.values()
        |> Enum.filter(&(decode_hex(Map.get(&1, "blockNumber")) == number))
        |> Enum.map(&Map.get(&1, "blockHash"))
        |> Enum.reject(&(&1 == hash))
        |> Enum.uniq()

      case conflicting_hashes do
        [] ->
          :continuous

        hashes ->
          {:discontinuous,
           %{
             latest_number: state.markers.last_log_block,
             observed_number: number,
             observed_hash: hash,
             conflicting_hashes: hashes
           }}
      end
    else
      _invalid -> {:error, :invalid_log}
    end
  end

  @spec last_block_num(t()) :: integer() | nil
  def last_block_num(%__MODULE__{markers: %{last_block_num: n}}), do: n

  @spec last_log_block(t()) :: integer() | nil
  def last_log_block(%__MODULE__{markers: %{last_log_block: n}}), do: n

  @spec retained_bytes(t()) :: non_neg_integer()
  def retained_bytes(%__MODULE__{retained_bytes: bytes}), do: bytes

  @spec new_head_continuity(t(), map()) ::
          :continuous | :duplicate | {:discontinuous, map()} | {:error, :invalid_header}
  def new_head_continuity(%__MODULE__{} = state, payload) when is_map(payload) do
    with {:ok, number, hash, parent_hash} <- header_identity(payload) do
      latest_number = state.markers.last_block_num
      latest = Map.get(state.head_history, latest_number)

      classify_new_head(state.head_history, latest_number, latest, number, hash, parent_hash)
    end
  end

  @spec event_bytes(term()) :: non_neg_integer()
  def event_bytes(payload), do: :erlang.external_size(payload)

  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = state) do
    %{
      state
      | markers: %{last_block_num: nil, last_log_block: nil},
        dedupe:
          DedupeCache.new(
            max_items: state.dedupe.max_items,
            max_age_ms: state.dedupe.max_age_ms
          ),
        retained_bytes: 0,
        history_overflowed: false,
        history_overflow_block: nil,
        head_history: %{},
        head_history_bytes: %{},
        log_history: %{},
        log_history_bytes: %{}
    }
  end

  @spec clear_history(t()) :: t()
  def clear_history(%__MODULE__{} = state) do
    %{
      state
      | retained_bytes: 0,
        history_overflowed: false,
        history_overflow_block: nil,
        head_history: %{},
        head_history_bytes: %{},
        log_history: %{},
        log_history_bytes: %{}
    }
  end

  @spec continuity_snapshot(t()) :: map()
  def continuity_snapshot(%__MODULE__{} = state) do
    %{
      last_block_num: state.markers.last_block_num,
      last_log_block: state.markers.last_log_block,
      head_history: state.head_history,
      logs: Map.values(state.log_history),
      history_blocks: state.history_blocks,
      history_overflowed: state.history_overflowed
    }
  end

  # Utilities
  defp decode_hex(nil), do: nil
  defp decode_hex(num) when is_integer(num), do: num

  defp decode_hex(value) do
    case Quantity.decode(value) do
      {:ok, decoded} -> decoded
      {:error, :invalid_quantity} -> nil
    end
  end

  defp header_identity(payload) do
    number = decode_hex(Map.get(payload, "number"))
    hash = Map.get(payload, "hash")
    parent_hash = Map.get(payload, "parentHash")

    if is_integer(number) and number >= 0 and is_binary(hash) and is_binary(parent_hash),
      do: {:ok, number, hash, parent_hash},
      else: {:error, :invalid_header}
  rescue
    ArgumentError -> {:error, :invalid_header}
  end

  defp classify_new_head(_history, nil, _latest, _number, _hash, _parent_hash),
    do: :continuous

  defp classify_new_head(
         _history,
         latest_number,
         %{"hash" => hash},
         latest_number,
         hash,
         _parent
       ),
       do: :duplicate

  defp classify_new_head(
         _history,
         latest_number,
         %{"hash" => latest_hash},
         number,
         _hash,
         latest_hash
       )
       when number == latest_number + 1,
       do: :continuous

  defp classify_new_head(history, latest_number, _latest, number, hash, parent_hash) do
    retained_hash = history |> Map.get(number, %{}) |> Map.get("hash")

    if retained_hash == hash do
      :duplicate
    else
      {:discontinuous,
       %{
         latest_number: latest_number,
         observed_number: number,
         observed_hash: hash,
         observed_parent_hash: parent_hash
       }}
    end
  end

  defp advance_marker(nil, next), do: next
  defp advance_marker(current, nil), do: current
  defp advance_marker(current, next), do: max(current, next)

  defp maybe_put(history, number, payload) when is_integer(number),
    do: Map.put(history, number, payload)

  defp maybe_put(history, _number, _payload), do: history

  defp prune_heads(history, latest, history_blocks) when is_integer(latest) do
    cutoff = latest - history_blocks + 1
    Map.reject(history, fn {number, _payload} -> number < cutoff end)
  end

  defp prune_heads(history, _latest, _history_blocks), do: history

  defp update_log_history(history, payload) do
    identity = log_identity(payload)

    if Map.get(payload, "removed", false) == true do
      Map.delete(history, identity)
    else
      Map.put(history, identity, payload)
    end
  end

  defp update_log_history_bytes(history, payload, payload_bytes) do
    identity = log_identity(payload)

    if Map.get(payload, "removed", false) == true do
      Map.delete(history, identity)
    else
      Map.put(history, identity, payload_bytes)
    end
  end

  defp skip_log?(_state, false, true, _seen?, _num), do: true
  defp skip_log?(_state, true, true, _seen?, _num), do: false
  defp skip_log?(_state, true, false, true, _num), do: true
  defp skip_log?(_state, _removed?, _active?, false, _num), do: false

  defp skip_log?(state, false, false, true, num) when is_integer(num) do
    case state.markers.last_log_block do
      latest when is_integer(latest) -> num < latest - state.history_blocks + 1
      _ -> true
    end
  end

  defp skip_log?(_state, false, false, true, _num), do: true

  defp log_identity(payload) do
    {
      Map.get(payload, "blockHash"),
      Map.get(payload, "transactionHash"),
      Map.get(payload, "logIndex")
    }
  end

  defp prune_logs(history, latest, history_blocks) when is_integer(latest) do
    cutoff = latest - history_blocks + 1

    Map.reject(history, fn {_identity, log} ->
      case decode_hex(Map.get(log, "blockNumber")) do
        number when is_integer(number) -> number < cutoff
        _ -> true
      end
    end)
  end

  defp prune_logs(history, _latest, _history_blocks), do: history

  defp overflow_block(_state, latest, true), do: latest

  defp overflow_block(%{history_overflow_block: nil}, _latest, false), do: nil

  defp overflow_block(state, latest, false) when is_integer(latest) do
    cutoff = latest - state.history_blocks + 1

    if state.history_overflow_block < cutoff,
      do: nil,
      else: state.history_overflow_block
  end

  defp overflow_block(state, _latest, false), do: state.history_overflow_block

  defp retain_newest_logs(history, max_items) when map_size(history) <= max_items, do: history

  defp retain_newest_logs(history, max_items) do
    history
    |> Enum.sort_by(
      fn {_identity, log} ->
        {decode_hex(Map.get(log, "blockNumber")), decode_hex(Map.get(log, "logIndex"))}
      end,
      :desc
    )
    |> Enum.take(max_items)
    |> Map.new()
  end

  defp removed_bytes(before, retained) do
    Enum.reduce(before, 0, fn {key, bytes}, removed ->
      if Map.has_key?(retained, key), do: removed, else: removed + bytes
    end)
  end

  defp retained_total(total, before, retained, event_key, event_bytes) do
    removed = removed_bytes(before, retained)

    replaced =
      if Map.has_key?(before, event_key) and Map.has_key?(retained, event_key) do
        Map.fetch!(before, event_key)
      else
        0
      end

    inserted = if Map.has_key?(retained, event_key), do: event_bytes, else: 0
    max(total - removed - replaced + inserted, 0)
  end
end

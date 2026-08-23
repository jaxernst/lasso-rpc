defmodule Lasso.Core.Streaming.StreamStateTest do
  use ExUnit.Case, async: true

  alias Lasso.Core.Streaming.StreamState

  test "an out-of-order head does not move the continuity marker backward" do
    state = StreamState.new()

    {state, :emit} = StreamState.ingest_new_head(state, head(102, "0x102"))
    {state, :emit} = StreamState.ingest_new_head(state, head(101, "0x101"))

    assert StreamState.last_block_num(state) == 102
  end

  test "a removed log is emitted after the canonical log" do
    state = StreamState.new()
    log = log(101, "0xblock", "0x0")

    {state, :emit} = StreamState.ingest_log(state, Map.put(log, "removed", false))
    {_state, decision} = StreamState.ingest_log(state, Map.put(log, "removed", true))

    assert decision == :emit
  end

  test "an out-of-order log does not move the continuity marker backward" do
    state = StreamState.new()

    {state, :emit} = StreamState.ingest_log(state, log(102, "0x102", "0x0"))
    {state, :emit} = StreamState.ingest_log(state, log(101, "0x101", "0x0"))

    assert StreamState.last_log_block(state) == 102
  end

  defp head(number, hash) do
    %{"number" => encode_hex(number), "hash" => hash}
  end

  defp log(number, block_hash, log_index) do
    %{
      "blockNumber" => encode_hex(number),
      "blockHash" => block_hash,
      "logIndex" => log_index
    }
  end

  defp encode_hex(number), do: "0x" <> Integer.to_string(number, 16)
end

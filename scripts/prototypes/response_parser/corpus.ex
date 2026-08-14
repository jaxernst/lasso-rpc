defmodule LassoPrototype.ResponseCorpus do
  @moduledoc """
  PROTOTYPE: deterministic synthetic EVM response corpus.

  The weights are a provisional request-frequency model, not production
  telemetry. They deliberately include large-tail responses so parser costs do
  not disappear behind a small-response average.
  """

  @kib 1024
  @mib 1024 * 1024

  @spec entries() :: [map()]
  def entries do
    [
      entry(:large_hex, "1KiB", @kib, 1_750),
      entry(:large_hex, "100KiB", 100 * @kib, 1_225),
      entry(:large_hex, "1MiB", @mib, 420),
      entry(:large_hex, "10MiB", 10 * @mib, 105),
      entry(:receipt, "1KiB", @kib, 1_700),
      entry(:receipt, "100KiB", 100 * @kib, 300),
      entry(:block, "1KiB", @kib, 150),
      entry(:block, "100KiB", 100 * @kib, 900),
      entry(:block, "1MiB", @mib, 375),
      entry(:block, "10MiB", 10 * @mib, 75),
      entry(:logs, "1KiB", @kib, 600),
      entry(:logs, "100KiB", 100 * @kib, 525),
      entry(:logs, "1MiB", @mib, 300),
      entry(:logs, "10MiB", 10 * @mib, 75),
      entry(:trace, "1KiB", @kib, 100),
      entry(:trace, "100KiB", 100 * @kib, 450),
      entry(:trace, "1MiB", @mib, 350),
      entry(:trace, "10MiB", 10 * @mib, 100),
      entry(:error, "1KiB", @kib, 475),
      entry(:error, "100KiB", 100 * @kib, 25)
    ]
  end

  @spec weighted_entry_at([map()], non_neg_integer()) :: map()
  def weighted_entry_at(entries, position) when position in 0..9_999 do
    Enum.reduce_while(entries, position, fn entry, remaining ->
      if remaining < entry.weight_bp do
        {:halt, entry}
      else
        {:cont, remaining - entry.weight_bp}
      end
    end)
  end

  defp entry(shape, size_label, target_bytes, weight_bp) do
    bytes = build(shape, target_bytes)

    %{
      shape: shape,
      size_label: size_label,
      target_bytes: target_bytes,
      actual_bytes: byte_size(bytes),
      weight_bp: weight_bp,
      bytes: bytes
    }
  end

  defp build(:large_hex, target_bytes) do
    prefix = ~s({"jsonrpc":"2.0","id":7,"result":"0x)
    suffix = ~s("})
    payload_bytes = max(target_bytes - byte_size(prefix) - byte_size(suffix), 2)
    IO.iodata_to_binary([prefix, :binary.copy("a", payload_bytes), suffix])
  end

  defp build(:receipt, target_bytes) do
    prefix =
      ~s({"jsonrpc":"2.0","id":7,"result":{"transactionHash":"0x) <>
        :binary.copy("a", 64) <>
        ~s(","transactionIndex":"0x1","blockHash":"0x) <>
        :binary.copy("b", 64) <>
        ~s(","blockNumber":"0x123","from":"0x) <>
        :binary.copy("1", 40) <>
        ~s(","to":"0x) <>
        :binary.copy("2", 40) <>
        ~s(","cumulativeGasUsed":"0x5208","gasUsed":"0x5208","contractAddress":null,"logs":[)

    suffix =
      ~s(],"logsBloom":"0x) <>
        :binary.copy("0", 512) <>
        ~s(","status":"0x1","type":"0x2","effectiveGasPrice":"0x3b9aca00"}})

    repeated_array(prefix, log_item(), suffix, target_bytes)
  end

  defp build(:block, target_bytes) do
    prefix =
      ~s({"jsonrpc":"2.0","id":7,"result":{"number":"0x123","hash":"0x) <>
        :binary.copy("a", 64) <>
        ~s(","parentHash":"0x) <>
        :binary.copy("b", 64) <>
        ~s(","stateRoot":"0x) <>
        :binary.copy("c", 64) <>
        ~s(","receiptsRoot":"0x) <>
        :binary.copy("d", 64) <>
        ~s(","transactionsRoot":"0x) <>
        :binary.copy("e", 64) <>
        ~s(","gasLimit":"0x1c9c380","gasUsed":"0x989680","timestamp":"0x66b","transactions":[)

    suffix = ~s(],"uncles":[]}})
    repeated_array(prefix, transaction_item(), suffix, target_bytes)
  end

  defp build(:logs, target_bytes) do
    repeated_array(~s({"jsonrpc":"2.0","id":7,"result":[), log_item(), ~s(]}), target_bytes)
  end

  defp build(:trace, target_bytes) do
    repeated_array(
      ~s({"jsonrpc":"2.0","id":7,"result":[),
      trace_item(),
      ~s(]}),
      target_bytes
    )
  end

  defp build(:error, target_bytes) do
    prefix =
      ~s({"jsonrpc":"2.0","id":7,"error":{"code":-32000,"message":"execution reverted","data":"0x)

    suffix = ~s("}})
    payload_bytes = max(target_bytes - byte_size(prefix) - byte_size(suffix), 2)
    IO.iodata_to_binary([prefix, :binary.copy("d", payload_bytes), suffix])
  end

  defp repeated_array(prefix, item, suffix, target_bytes) do
    base_bytes = IO.iodata_length([prefix, suffix])
    item_bytes = byte_size(item)
    count = max(div(max(target_bytes - base_bytes + 1, item_bytes), item_bytes + 1), 1)
    body = [item | List.duplicate([",", item], count - 1)]
    IO.iodata_to_binary([prefix, body, suffix])
  end

  defp log_item do
    ~s({"removed":false,"logIndex":"0x1","transactionIndex":"0x2","transactionHash":"0x) <>
      :binary.copy("a", 64) <>
      ~s(","blockHash":"0x) <>
      :binary.copy("b", 64) <>
      ~s(","blockNumber":"0x123","address":"0x) <>
      :binary.copy("1", 40) <>
      ~s(","data":"0x) <>
      :binary.copy("d", 256) <>
      ~s(","topics":["0x) <>
      :binary.copy("e", 64) <>
      ~s(","0x) <>
      :binary.copy("f", 64) <>
      ~s("]})
  end

  defp transaction_item do
    ~s({"blockHash":"0x) <>
      :binary.copy("b", 64) <>
      ~s(","blockNumber":"0x123","from":"0x) <>
      :binary.copy("1", 40) <>
      ~s(","gas":"0x5208","gasPrice":"0x3b9aca00","hash":"0x) <>
      :binary.copy("a", 64) <>
      ~s(","input":"0x) <>
      :binary.copy("d", 256) <>
      ~s(","nonce":"0x1","to":"0x) <>
      :binary.copy("2", 40) <>
      ~s(","transactionIndex":"0x1","value":"0x0","type":"0x2","chainId":"0x1","v":"0x1","r":"0x) <>
      :binary.copy("3", 64) <>
      ~s(","s":"0x) <>
      :binary.copy("4", 64) <>
      ~s("})
  end

  defp trace_item do
    ~s({"action":{"callType":"call","from":"0x) <>
      :binary.copy("1", 40) <>
      ~s(","gas":"0x989680","input":"0x) <>
      :binary.copy("a", 192) <>
      ~s(","to":"0x) <>
      :binary.copy("2", 40) <>
      ~s(","value":"0x0"},"blockHash":"0x) <>
      :binary.copy("b", 64) <>
      ~s(","blockNumber":123,"result":{"gasUsed":"0x5208","output":"0x) <>
      :binary.copy("c", 192) <>
      ~s("},"subtraces":0,"traceAddress":[0,1],"transactionHash":"0x) <>
      :binary.copy("d", 64) <>
      ~s(","transactionPosition":2,"type":"call"})
  end
end

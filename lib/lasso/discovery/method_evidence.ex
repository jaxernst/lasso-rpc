defmodule Lasso.Discovery.MethodEvidence do
  @moduledoc """
  Validates the result shape of bounded discovery calls. A recognized method
  without a validated result remains distinct from a verified read.
  """

  alias Lasso.JSONRPC.Quantity

  @quantity_methods ~w(eth_blockNumber eth_chainId eth_gasPrice eth_maxPriorityFeePerGas
    eth_blobBaseFee eth_baseFee eth_getBalance eth_getTransactionCount
    eth_estimateGas eth_getBlockTransactionCountByNumber eth_getUncleCountByBlockNumber
    net_peerCount eth_protocolVersion)
  @nullable_quantities ~w(eth_getBlockTransactionCountByHash eth_getUncleCountByBlockHash)
  @block_methods ~w(eth_getBlockByNumber eth_getBlockByHash eth_getUncleByBlockHashAndIndex
    eth_getUncleByBlockNumberAndIndex)
  @transaction_methods ~w(eth_getTransactionByHash eth_getTransactionByBlockHashAndIndex
    eth_getTransactionByBlockNumberAndIndex eth_getTransactionReceipt)

  @spec classify(String.t(), term()) :: :supported | :recognized | :unknown
  def classify(method, value) when method in @quantity_methods do
    valid = quantity?(value) and (method != "eth_chainId" or positive_quantity?(value))
    verdict(valid)
  end

  def classify(method, nil) when method in @nullable_quantities, do: :recognized
  def classify(method, value) when method in @nullable_quantities, do: verdict(quantity?(value))
  def classify(method, nil) when method in @block_methods, do: :recognized

  def classify(method, value) when method in @block_methods do
    verdict(is_map(value) and quantity?(value["number"]) and data?(value["hash"], 32))
  end

  def classify(method, nil) when method in @transaction_methods, do: :recognized

  def classify(method, value) when method in @transaction_methods do
    hash_key = if method == "eth_getTransactionReceipt", do: "transactionHash", else: "hash"
    verdict(is_map(value) and data?(value[hash_key], 32))
  end

  def classify(method, value) when method in ~w(eth_call eth_getCode),
    do: verdict(data?(value))

  def classify(method, value) when method in ~w(eth_getStorageAt web3_sha3),
    do: verdict(data?(value, 32))

  def classify("web3_clientVersion", value), do: verdict(is_binary(value) and value != "")

  def classify("net_version", value) when is_binary(value) do
    verdict(value != "" and String.match?(value, ~r/\A[0-9]+\z/))
  end

  def classify("net_listening", value), do: verdict(is_boolean(value))
  def classify("eth_syncing", false), do: :supported

  def classify("eth_syncing", value) when is_map(value) do
    verdict(Enum.all?(~w(startingBlock currentBlock highestBlock), &quantity?(value[&1])))
  end

  def classify("eth_getLogs", value) when is_list(value),
    do: verdict(Enum.all?(value, &valid_log?/1))

  def classify("eth_feeHistory", value) when is_map(value) do
    verdict(
      quantity?(value["oldestBlock"]) and
        is_list(value["baseFeePerGas"]) and value["baseFeePerGas"] != [] and
        Enum.all?(value["baseFeePerGas"], &quantity?/1) and
        is_list(value["gasUsedRatio"]) and Enum.all?(value["gasUsedRatio"], &is_number/1)
    )
  end

  def classify("eth_getProof", value) when is_map(value) do
    verdict(
      quantity?(value["balance"]) and quantity?(value["nonce"]) and
        data?(value["codeHash"], 32) and data?(value["storageHash"], 32) and
        proof_nodes?(value["accountProof"]) and value["accountProof"] != [] and
        is_list(value["storageProof"]) and Enum.all?(value["storageProof"], &storage_proof?/1)
    )
  end

  def classify("eth_createAccessList", value) when is_map(value) do
    cond do
      is_binary(value["error"]) and value["error"] != "" ->
        :recognized

      value["error"] not in [nil, ""] ->
        :unknown

      true ->
        verdict(
          quantity?(value["gasUsed"]) and is_list(value["accessList"]) and
            Enum.all?(value["accessList"], &access_list_entry?/1)
        )
    end
  end

  def classify(method, _value)
      when method in ~w(net_version eth_syncing eth_getLogs eth_feeHistory eth_getProof eth_createAccessList),
      do: :unknown

  def classify(_method, _value), do: :recognized

  @spec valid_log?(term()) :: boolean()
  def valid_log?(value) when is_map(value) do
    data?(value["address"], 20) and data?(value["data"]) and
      is_list(value["topics"]) and Enum.all?(value["topics"], &data?(&1, 32)) and
      quantity?(value["blockNumber"])
  end

  def valid_log?(_value), do: false

  defp proof_nodes?(nodes),
    do: is_list(nodes) and Enum.all?(nodes, &(data?(&1) and &1 != "0x"))

  defp storage_proof?(value) when is_map(value) do
    (quantity?(value["key"]) or data?(value["key"], 32)) and
      quantity?(value["value"]) and proof_nodes?(value["proof"])
  end

  defp storage_proof?(_value), do: false

  defp access_list_entry?(value) when is_map(value) do
    data?(value["address"], 20) and is_list(value["storageKeys"]) and
      Enum.all?(value["storageKeys"], &data?(&1, 32))
  end

  defp access_list_entry?(_value), do: false

  @spec quantity?(term()) :: boolean()
  def quantity?(value), do: match?({:ok, _}, Quantity.decode(value))

  @spec data?(term(), non_neg_integer() | nil) :: boolean()
  def data?(value, bytes \\ nil)

  def data?("0x" <> hex, bytes) do
    rem(byte_size(hex), 2) == 0 and
      (is_nil(bytes) or byte_size(hex) == bytes * 2) and
      match?({:ok, _}, Base.decode16(hex, case: :mixed))
  end

  def data?(_value, _bytes), do: false

  defp positive_quantity?(value) do
    case Quantity.decode(value) do
      {:ok, number} -> number > 0
      _ -> false
    end
  end

  defp verdict(true), do: :supported
  defp verdict(false), do: :unknown
end

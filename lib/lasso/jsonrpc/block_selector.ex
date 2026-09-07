defmodule Lasso.JSONRPC.BlockSelector do
  @moduledoc "Reads block selectors by method position, independently of optional trailing parameters."

  @first ~w(debug_traceBlockByNumber eth_getBlockByNumber eth_getBlockReceipts eth_getBlockTransactionCountByNumber eth_getTransactionByBlockNumberAndIndex eth_getUncleByBlockNumberAndIndex eth_getUncleCountByBlockNumber trace_block trace_replayBlockTransactions)
  @second ~w(eth_call eth_createAccessList eth_estimateGas eth_getBalance eth_getCode eth_getTransactionCount eth_simulateV1 eth_feeHistory eth_getStorageValues)
  @third ~w(eth_getProof eth_getStorageAt)

  @spec extract(String.t(), term()) :: term()
  def extract(method, params) when is_list(params) do
    case method do
      method when method in @first -> Enum.at(params, 0)
      method when method in @second -> Enum.at(params, 1)
      method when method in @third -> Enum.at(params, 2)
      _ -> nil
    end
  end

  def extract(_method, _params), do: nil
end

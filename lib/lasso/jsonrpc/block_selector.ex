defmodule Lasso.JSONRPC.BlockSelector do
  @moduledoc "Reads block selectors by method position, independently of optional trailing parameters."

  @first ~w(debug_traceBlockByNumber eth_getBlockByNumber eth_getBlockReceipts eth_getBlockTransactionCountByNumber eth_getTransactionByBlockNumberAndIndex eth_getUncleByBlockNumberAndIndex eth_getUncleCountByBlockNumber trace_block trace_replayBlockTransactions)
  @second ~w(eth_call eth_createAccessList eth_estimateGas eth_getBalance eth_getCode eth_getTransactionCount eth_simulateV1 eth_feeHistory eth_getStorageValues)
  @third ~w(eth_getProof eth_getStorageAt)

  # Block-hash-only methods. Only request facts read this table: extract/2 and
  # the archival permission built on it keep their number-or-tag positions.
  @hash_first ~w(debug_traceBlockByHash debug_getModifiedAccountsByHash eth_getBlockByHash eth_getBlockTransactionCountByHash eth_getTransactionByBlockHashAndIndex eth_getUncleByBlockHashAndIndex eth_getUncleCountByBlockHash)

  @doc "The zero-based parameter position of the method's block selector."
  @spec position(String.t()) :: 0..2 | nil
  def position(method) when method in @first, do: 0
  def position(method) when method in @second, do: 1
  def position(method) when method in @third, do: 2
  def position(_method), do: nil

  @doc "The zero-based position of the block hash in a block-hash-only method."
  @spec hash_position(String.t()) :: 0 | nil
  def hash_position(method) when method in @hash_first, do: 0
  def hash_position(_method), do: nil

  @spec extract(String.t(), term()) :: term()
  def extract(method, params) when is_list(params) do
    case position(method) do
      nil -> nil
      position -> Enum.at(params, position)
    end
  end

  def extract(_method, _params), do: nil
end

defmodule Lasso.Discovery.TestParams do
  @moduledoc """
  Test parameters for RPC provider probing.

  Provides minimal valid parameters for each JSON-RPC method to test method
  support without triggering complex validation. Also provides chain-specific
  contract addresses for log-related tests.
  """

  # High-volume contracts for log testing (USDC contracts generate many Transfer events)
  @chain_contracts %{
    "ethereum" => "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    "base" => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    "arbitrum" => "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    "optimism" => "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
    "polygon" => "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359",
    # Testnets - use mainnet contracts as structural fallback
    "sepolia" => "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    "base_sepolia" => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  }

  # ERC-20 Transfer event signature
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  # Common placeholder values
  @zero_address "0x0000000000000000000000000000000000000000"
  @zero_hash "0x" <> String.duplicate("0", 64)

  @doc """
  Returns a busy contract address for the given chain.

  These contracts have high transaction volume and are useful for
  testing log-related endpoints with real data.
  """
  @spec busy_contract_for(String.t()) :: String.t() | nil
  def busy_contract_for(chain) do
    Map.get(@chain_contracts, chain)
  end

  @doc """
  Returns the ERC-20 Transfer event topic signature.
  """
  @spec transfer_topic() :: String.t()
  def transfer_topic, do: @transfer_topic

  @doc """
  Returns a zero address placeholder.
  """
  @spec zero_address() :: String.t()
  def zero_address, do: @zero_address

  @doc """
  Returns a zero hash placeholder (64 hex chars).
  """
  @spec zero_hash() :: String.t()
  def zero_hash, do: @zero_hash

  @doc """
  Converts a hex string to an integer.
  """
  @spec hex_to_int(String.t()) :: integer()
  def hex_to_int("0x" <> hex), do: String.to_integer(hex, 16)
  def hex_to_int(hex), do: String.to_integer(hex, 16)

  @doc """
  Converts an integer to a hex string with 0x prefix.
  """
  @spec int_to_hex(integer()) :: String.t()
  def int_to_hex(int), do: "0x" <> Integer.to_string(int, 16)

  @doc """
  Returns minimal valid parameters for probing the given method.

  These parameters are designed to:
  - Be syntactically valid (won't fail JSON-RPC parsing)
  - Trigger -32601 (method not found) if method is unsupported
  - Trigger -32602 (invalid params) or success if method is supported
  - Avoid expensive operations (use zero addresses, "latest" blocks)
  """
  @spec minimal_params_for(String.t()) :: list()

  # Core methods - no params
  def minimal_params_for("eth_blockNumber"), do: []
  def minimal_params_for("eth_chainId"), do: []
  def minimal_params_for("eth_gasPrice"), do: []
  def minimal_params_for("eth_syncing"), do: []
  def minimal_params_for("eth_protocolVersion"), do: []

  # EIP-1559
  def minimal_params_for("eth_maxPriorityFeePerGas"), do: []

  # EIP-4844
  def minimal_params_for("eth_getBlobBaseFee"), do: []

  # Network methods
  def minimal_params_for("net_version"), do: []
  def minimal_params_for("net_listening"), do: []
  def minimal_params_for("net_peerCount"), do: []
  def minimal_params_for("web3_clientVersion"), do: []
  def minimal_params_for("web3_sha3"), do: ["0x68656c6c6f"]

  # State query methods
  def minimal_params_for("eth_call") do
    [%{to: @zero_address, data: "0x"}, "latest"]
  end

  def minimal_params_for("eth_estimateGas") do
    [%{to: @zero_address, data: "0x"}]
  end

  def minimal_params_for("eth_getBalance") do
    [@zero_address, "latest"]
  end

  def minimal_params_for("eth_getCode") do
    [@zero_address, "latest"]
  end

  def minimal_params_for("eth_getTransactionCount") do
    [@zero_address, "latest"]
  end

  def minimal_params_for("eth_getStorageAt") do
    [@zero_address, "0x0", "latest"]
  end

  def minimal_params_for("eth_getProof") do
    [@zero_address, [], "latest"]
  end

  # Transaction methods
  def minimal_params_for("eth_getTransactionByHash") do
    [@zero_hash]
  end

  def minimal_params_for("eth_getTransactionReceipt") do
    [@zero_hash]
  end

  def minimal_params_for("eth_sendRawTransaction") do
    ["0x"]
  end

  # Block methods
  def minimal_params_for("eth_getBlockByNumber"), do: ["latest", false]

  def minimal_params_for("eth_getBlockByHash") do
    [@zero_hash, false]
  end

  def minimal_params_for("eth_getBlockReceipts"), do: ["latest"]

  def minimal_params_for("eth_getBlockTransactionCountByHash") do
    [@zero_hash]
  end

  def minimal_params_for("eth_getBlockTransactionCountByNumber"), do: ["latest"]

  def minimal_params_for("eth_getTransactionByBlockHashAndIndex") do
    [@zero_hash, "0x0"]
  end

  def minimal_params_for("eth_getTransactionByBlockNumberAndIndex") do
    ["latest", "0x0"]
  end

  # Uncle methods
  def minimal_params_for("eth_getUncleCountByBlockHash") do
    [@zero_hash]
  end

  def minimal_params_for("eth_getUncleCountByBlockNumber"), do: ["latest"]

  def minimal_params_for("eth_getUncleByBlockHashAndIndex") do
    [@zero_hash, "0x0"]
  end

  def minimal_params_for("eth_getUncleByBlockNumberAndIndex") do
    ["latest", "0x0"]
  end

  # Fee history
  def minimal_params_for("eth_feeHistory"), do: [4, "latest", []]

  # Log/filter methods
  def minimal_params_for("eth_getLogs") do
    [%{fromBlock: "latest", toBlock: "latest"}]
  end

  def minimal_params_for("eth_newFilter") do
    [%{fromBlock: "latest", toBlock: "latest"}]
  end

  def minimal_params_for("eth_newBlockFilter"), do: []
  def minimal_params_for("eth_newPendingTransactionFilter"), do: []
  def minimal_params_for("eth_getFilterChanges"), do: ["0x1"]
  def minimal_params_for("eth_getFilterLogs"), do: ["0x1"]
  def minimal_params_for("eth_uninstallFilter"), do: ["0x1"]

  # Debug/trace methods
  def minimal_params_for("debug_traceTransaction") do
    [@zero_hash, %{}]
  end

  def minimal_params_for("debug_traceBlockByNumber"), do: ["latest", %{}]
  def minimal_params_for("trace_block"), do: ["latest"]

  def minimal_params_for("trace_transaction") do
    [@zero_hash]
  end

  # Subscription methods (WS only)
  def minimal_params_for("eth_subscribe"), do: ["newHeads"]
  def minimal_params_for("eth_unsubscribe"), do: ["0x1"]

  # Fallback for unknown methods
  def minimal_params_for(_method), do: []
end

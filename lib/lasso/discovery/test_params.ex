defmodule Lasso.Discovery.TestParams do
  @moduledoc """
  Test parameters for RPC provider probing.

  Provides minimal valid parameters for each JSON-RPC method to test method
  support without triggering complex validation. Also provides chain-specific
  contract addresses for log-related tests.
  """

  alias Lasso.JSONRPC.Quantity

  # High-volume contracts for log testing (USDC contracts generate many Transfer events)
  @chain_contracts %{
    "ethereum" => "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    "base" => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    "arbitrum" => "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    "optimism" => "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
    "polygon" => "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359",
    "ethereum-sepolia" => "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238",
    "base-sepolia" => "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    "arbitrum-sepolia" => "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d"
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
  @spec int_to_hex(non_neg_integer()) :: String.t()
  def int_to_hex(int), do: Quantity.encode(int)

  @doc "Builds read probes from one recent block when the endpoint provides a valid fixture."
  @spec params_for(String.t(), map()) :: list()
  def params_for(method, context) do
    params = minimal_params_for(method)
    block_hash = context[:block_hash] || @zero_hash
    transaction_hash = context[:transaction_hash] || @zero_hash

    case {method, params} do
      {m, [_hash | rest]}
      when m in ~w(eth_getTransactionByHash eth_getTransactionReceipt debug_traceTransaction trace_transaction trace_replayTransaction trace_get) ->
        [transaction_hash | rest]

      {m, [_hash | rest]}
      when m in ~w(eth_getBlockByHash eth_getBlockTransactionCountByHash eth_getUncleCountByBlockHash eth_getTransactionByBlockHashAndIndex) ->
        [block_hash | rest]

      _ ->
        params
    end
  end

  @doc """
  Returns minimal valid parameters for probing the given method.

  These parameters are designed to:
  - Be syntactically valid (won't fail JSON-RPC parsing)
  - Trigger -32601 (method not found) if method is unsupported
  - Keep rejected parameters distinct from a validated read
  - Bound simulations and avoid broadcasting transactions
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
  def minimal_params_for("eth_blobBaseFee"), do: []

  # Extended reads from the pinned execution-apis baseline
  def minimal_params_for("eth_baseFee"), do: []
  def minimal_params_for("eth_capabilities"), do: []
  def minimal_params_for("eth_config"), do: []
  def minimal_params_for("eth_fillTransaction"), do: [%{}]
  def minimal_params_for("eth_getStorageValues"), do: [%{@zero_address => [@zero_hash]}, "latest"]
  def minimal_params_for("eth_simulateV1"), do: [%{blockStateCalls: []}, "latest"]

  # Network methods
  def minimal_params_for("net_version"), do: []
  def minimal_params_for("net_listening"), do: []
  def minimal_params_for("net_peerCount"), do: []
  def minimal_params_for("web3_clientVersion"), do: []
  def minimal_params_for("web3_sha3"), do: ["0x68656c6c6f"]

  # State query methods
  def minimal_params_for("eth_call") do
    [%{to: @zero_address, data: "0x", gas: "0x186a0"}, "latest"]
  end

  def minimal_params_for("eth_estimateGas") do
    [%{to: @zero_address, data: "0x", gas: "0x186a0"}, "latest"]
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

  def minimal_params_for("eth_createAccessList") do
    [%{to: @zero_address, data: "0x", gas: "0x186a0"}, "latest"]
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
  def minimal_params_for("eth_feeHistory"), do: ["0x4", "latest", []]

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

  # Debug methods
  def minimal_params_for("debug_traceTransaction") do
    [
      @zero_hash,
      %{tracer: "callTracer", timeout: "1s", reexec: 0, tracerConfig: %{onlyTopCall: true}}
    ]
  end

  def minimal_params_for("debug_traceBlockByNumber"),
    do: [
      "0x0",
      %{tracer: "callTracer", timeout: "1s", reexec: 0, tracerConfig: %{onlyTopCall: true}}
    ]

  def minimal_params_for("debug_traceBlockByHash") do
    [
      @zero_hash,
      %{tracer: "callTracer", timeout: "1s", reexec: 0, tracerConfig: %{onlyTopCall: true}}
    ]
  end

  def minimal_params_for("debug_traceCall") do
    [
      %{to: @zero_address, data: "0x", gas: "0x186a0"},
      "latest",
      %{tracer: "callTracer", timeout: "1s", reexec: 0, tracerConfig: %{onlyTopCall: true}}
    ]
  end

  def minimal_params_for("debug_getBadBlocks"), do: []

  def minimal_params_for("debug_storageRangeAt") do
    [@zero_hash, 0, @zero_address, "0x0", 1]
  end

  def minimal_params_for("debug_getModifiedAccountsByNumber") do
    ["latest", "latest"]
  end

  def minimal_params_for("debug_getModifiedAccountsByHash") do
    [@zero_hash, @zero_hash]
  end

  # Trace methods
  def minimal_params_for("trace_block"), do: ["0x0"]

  def minimal_params_for("trace_transaction") do
    [@zero_hash]
  end

  def minimal_params_for("trace_call") do
    [%{to: @zero_address, data: "0x", gas: "0x186a0"}, ["trace"], "latest"]
  end

  def minimal_params_for("trace_callMany") do
    [[[%{to: @zero_address, data: "0x", gas: "0x186a0"}, ["trace"]]], "latest"]
  end

  def minimal_params_for("trace_rawTransaction") do
    ["0x", ["trace"]]
  end

  def minimal_params_for("trace_replayBlockTransactions") do
    ["0x0", ["trace"]]
  end

  def minimal_params_for("trace_replayTransaction") do
    [@zero_hash, ["trace"]]
  end

  def minimal_params_for("trace_filter") do
    [%{"fromBlock" => "latest", "toBlock" => "latest"}]
  end

  def minimal_params_for("trace_get") do
    [@zero_hash, ["0x0"]]
  end

  # Txpool methods
  def minimal_params_for("txpool_status"), do: []
  def minimal_params_for("txpool_content"), do: []
  def minimal_params_for("txpool_inspect"), do: []

  # Subscription methods (WS only)
  def minimal_params_for("eth_subscribe"), do: ["newHeads"]
  def minimal_params_for("eth_unsubscribe"), do: ["0x1"]

  # Fallback for unknown methods
  def minimal_params_for(_method), do: []
end

defmodule Lasso.RPC.MethodRegistry do
  @moduledoc """
  Canonical registry of Ethereum JSON-RPC methods categorized by
  support patterns across hosted providers.

  Categories reflect real-world availability:
  - :core - Universal support (99%+ providers)
  - :state - Common support (90%+ providers)
  - :filters - Restricted support (60% providers, often limited)
  - :debug/:trace - Rare support (<10% providers)
  - :local_only - Never supported on hosted providers
  """

  @standard_methods %{
    # Universal support - all hosted providers
    core: [
      "eth_blockNumber",
      "eth_chainId",
      "eth_gasPrice",
      "eth_getBalance",
      "eth_getCode",
      "eth_getTransactionByHash",
      "eth_getTransactionReceipt",
      "eth_getBlockByNumber",
      "eth_getBlockByHash",
      "eth_getBlockTransactionCountByHash",
      "eth_getBlockTransactionCountByNumber",
      "eth_getUncleCountByBlockHash",
      "eth_getUncleCountByBlockNumber",
      "eth_getUncleByBlockHashAndIndex",
      "eth_getUncleByBlockNumberAndIndex",
      "eth_getTransactionByBlockHashAndIndex",
      "eth_getTransactionByBlockNumberAndIndex"
    ],

    # Common support - may have archive restrictions
    state: [
      "eth_call",
      "eth_estimateGas",
      "eth_getStorageAt",
      "eth_getTransactionCount",
      # EIP-1186 - archive nodes
      "eth_getProof"
    ],

    # Network/utility methods
    network: [
      "net_version",
      "net_listening",
      "net_peerCount",
      "web3_clientVersion",
      "web3_sha3",
      "eth_protocolVersion",
      "eth_syncing"
    ],

    # EIP-1559 methods (post-London fork)
    eip1559: [
      "eth_maxPriorityFeePerGas",
      "eth_feeHistory"
    ],

    # EIP-4844 methods (post-Dencun, blob transactions)
    eip4844: [
      "eth_getBlobBaseFee"
    ],

    # Mempool/pending transaction methods
    mempool: [
      "eth_sendRawTransaction"
    ],

    # Filter/log methods - HIGHEST FAILURE RATE
    # Most providers restrict block ranges, address counts
    filters: [
      "eth_getLogs",
      "eth_newFilter",
      "eth_getFilterChanges",
      "eth_getFilterLogs",
      "eth_uninstallFilter",
      "eth_newBlockFilter",
      "eth_newPendingTransactionFilter"
    ],

    # WebSocket subscriptions (transport-dependent)
    subscriptions: [
      "eth_subscribe",
      "eth_unsubscribe"
    ],

    # Batch methods (provider-specific)
    batch: [
      # Parity/Erigon/Alchemy enhanced
      "eth_getBlockReceipts"
    ],

    # Debug methods (rarely supported, requires debug flag)
    debug: [
      "debug_traceTransaction",
      "debug_traceBlockByNumber",
      "debug_traceBlockByHash",
      "debug_traceCall",
      "debug_getBadBlocks",
      "debug_storageRangeAt",
      "debug_getModifiedAccountsByNumber",
      "debug_getModifiedAccountsByHash"
    ],

    # Trace methods (Parity/Erigon - rare)
    trace: [
      "trace_block",
      "trace_transaction",
      "trace_call",
      "trace_callMany",
      "trace_rawTransaction",
      "trace_replayBlockTransactions",
      "trace_replayTransaction",
      "trace_filter",
      "trace_get"
    ],

    # Never available on hosted providers
    local_only: [
      "eth_accounts",
      "eth_sign",
      "eth_signTransaction",
      "eth_sendTransaction",
      "eth_coinbase",
      "eth_mining",
      "eth_hashrate",
      "eth_getWork",
      "eth_submitWork",
      "eth_submitHashrate"
    ],

    # TxPool inspection (rarely available)
    txpool: [
      "txpool_status",
      "txpool_content",
      "txpool_inspect"
    ]
  }

  @doc "Returns all standard method categories"
  @spec categories() :: %{atom() => [String.t()]}
  def categories, do: @standard_methods

  @doc "Returns flattened list of all standard methods"
  @spec all_methods() :: [String.t()]
  def all_methods do
    @standard_methods
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc "Returns methods in a specific category"
  @spec category_methods(atom()) :: [String.t()]
  def category_methods(category), do: Map.get(@standard_methods, category, [])

  @doc "Returns the category for a given method"
  @spec method_category(String.t()) :: atom()
  def method_category(method) do
    Enum.find_value(@standard_methods, :unknown, fn {cat, methods} ->
      if method in methods, do: cat
    end)
  end

  @doc """
  Returns default support assumption for unknown methods.

  Conservative assumptions:
  - Standard methods (core, state, network): Assume supported
  - Experimental/new methods (eip4844): Assume unsupported
  - Archive methods (debug, trace): Assume unsupported
  - Deprecated methods: Assume unsupported
  """
  @spec default_support_assumption(String.t()) :: boolean()
  def default_support_assumption(method) do
    case method_category(method) do
      cat when cat in [:core, :state, :network, :eip1559, :mempool] -> true
      cat when cat in [:debug, :trace, :local_only, :txpool] -> false
      # New, conservative
      :eip4844 -> false
      # Conservative for unknown
      :unknown -> false
    end
  end
end

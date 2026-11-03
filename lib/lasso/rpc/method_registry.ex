defmodule Lasso.RPC.MethodRegistry do
  @moduledoc """
  Canonical registry of Ethereum JSON-RPC methods categorized by routing and
  capability concerns.

  A method's category informs execution safety and capability handling; it does
  not claim that every provider or chain exposes it. Provider support remains
  explicit capability evidence.
  """

  @send_methods ~w(eth_sendRawTransaction eth_sendRawTransactionSync
    eth_sendRawTransactionConditional eth_sendPrivateRawTransaction
    eth_sendPrivateTransaction eth_cancelPrivateTransaction eth_sendBundle
    mev_sendBundle eth_cancelBundle eth_callBundle mev_simBundle trace_rawTransaction)

  # A probe cannot submit a real transaction, so a rejection says nothing about
  # support for one; discovery reports these instead of dispatching them.
  # Simulations stay probeable because their probe submits nothing.
  @unverifiable_methods (@send_methods -- ~w(eth_callBundle mev_simBundle trace_rawTransaction)) ++
                          ["eth_sendTransaction"]

  @standard_methods %{
    # Common application reads
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

    # State reads that may have archive restrictions
    state: [
      "eth_call",
      "eth_estimateGas",
      "eth_getStorageAt",
      "eth_getTransactionCount",
      # EIP-2930
      "eth_createAccessList",
      # EIP-1186 - archive nodes
      "eth_getProof"
    ],

    # Endpoint identification an application can rely on.
    network: [
      "net_version",
      "web3_clientVersion",
      "web3_sha3",
      "eth_syncing"
    ],

    # Node-operator introspection. Hosted providers deliberately withhold these
    # because they leak infrastructure detail, so a missing one says nothing
    # about the endpoint's usefulness. Grouped separately and left out of the
    # default probe set so their absence stops dragging `network` to partial.
    node_admin: [
      "net_listening",
      "net_peerCount",
      "eth_protocolVersion"
    ],

    # EIP-1559 methods (post-London fork)
    eip1559: [
      "eth_maxPriorityFeePerGas",
      "eth_feeHistory"
    ],

    # EIP-4844 methods (post-Dencun, blob transactions)
    eip4844: [
      "eth_blobBaseFee"
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

    # Reads in the pinned execution-apis baseline whose deployment, fork, cost,
    # or access policy still varies materially across providers.
    extended_reads: [
      "eth_baseFee",
      "eth_capabilities",
      "eth_config",
      "eth_fillTransaction",
      "eth_getStorageValues",
      "eth_simulateV1",
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

  @method_categories for {category, methods} <- @standard_methods,
                         method <- methods,
                         into: %{},
                         do: {method, category}

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
  def method_category(method), do: Map.get(@method_categories, method, :unknown)

  @doc "Methods whose payload or service state requires transaction routing."
  @spec send_methods() :: [String.t()]
  def send_methods, do: @send_methods
  @doc "Whether a method's support can be established by probing."
  @spec unverifiable?(String.t()) :: boolean()
  def unverifiable?(method), do: method in @unverifiable_methods
  @spec unverifiable_methods() :: [String.t()]
  def unverifiable_methods, do: @unverifiable_methods

  @doc "Classify effects independently of provider support."
  @spec classify(String.t(), term()) ::
          {Lasso.RPC.ExecutionEnvelope.execution_safety(), :registry | :signed_bytes | :default}
  def classify(method, params \\ []) do
    cond do
      method in @send_methods ->
        {:raw_transaction_broadcast, :registry}

      method_category(method) == :subscriptions ->
        {:subscription, :registry}

      method == "eth_getLogs" ->
        {:replay_safe, :registry}

      method_category(method) not in [:unknown, :filters, :local_only] ->
        {:replay_safe, :registry}

      method_category(method) == :unknown and signed_bytes?([params]) ->
        {:raw_transaction_broadcast, :signed_bytes}

      true ->
        {:unknown, :default}
    end
  end

  # Tail-recursive work list visits every decoded value once, regardless of
  # parameter nesting. The request body limit already bounds the input.
  defp signed_bytes?([]), do: false
  defp signed_bytes?([[] | pending]), do: signed_bytes?(pending)

  defp signed_bytes?([[value | rest] | pending]),
    do: signed_bytes?([value, rest | pending])

  defp signed_bytes?([value | pending]) when is_map(value),
    do: signed_bytes?([Map.values(value) | pending])

  defp signed_bytes?([value | pending]) when is_binary(value),
    do: signed_envelope?(value) or signed_bytes?(pending)

  defp signed_bytes?([_ | pending]), do: signed_bytes?(pending)

  defp signed_envelope?(value) do
    hex =
      case value do
        "0x" <> hex -> hex
        hex -> hex
      end

    case Base.decode16(hex, case: :mixed) do
      {:ok, <<1, rest::binary>>} -> complete_list?(rest, 11)
      {:ok, <<2, rest::binary>>} -> complete_list?(rest, 12)
      {:ok, <<3, rest::binary>>} -> complete_list?(rest, 14) or blob_wrapper?(rest)
      {:ok, <<4, rest::binary>>} -> complete_list?(rest, 13)
      {:ok, bytes} -> complete_list?(bytes, 9)
      :error -> false
    end
  end

  # Blob gossip carries the signed payload plus sidecar lists. PeerDAS adds
  # wrapper version 1 before those lists (EIP-4844 and EIP-7594).
  defp blob_wrapper?(bytes) do
    with {:list, payload, <<>>} <- rlp_item(bytes),
         {:list, transaction, sidecar} <- rlp_item(payload) do
      count_items(transaction, 14, 0) and
        (sidecar_lists?(sidecar, 3) or
           case sidecar do
             <<1, rest::binary>> -> sidecar_lists?(rest, 3)
             _ -> false
           end) and valid_lists?([{payload, 1}])
    else
      _ -> false
    end
  end

  defp sidecar_lists?(<<>>, 0), do: true

  defp sidecar_lists?(bytes, remaining) when remaining > 0 do
    case rlp_item(bytes) do
      {:list, _, rest} -> sidecar_lists?(rest, remaining - 1)
      _ -> false
    end
  end

  defp sidecar_lists?(_, _), do: false

  # Walk only the outer list's items, without allocating decoded nested terms.
  defp complete_list?(bytes, count) do
    case rlp_item(bytes) do
      {:list, payload, <<>>} -> count_items(payload, count, 0)
      _ -> false
    end
  end

  defp count_items(<<>>, expected, actual), do: expected == actual

  defp count_items(bytes, expected, actual) do
    case rlp_item(bytes) do
      {:list, payload, rest} ->
        valid_lists?([{payload, 2}]) and count_items(rest, expected, actual + 1)

      {:string, _, rest} ->
        count_items(rest, expected, actual + 1)

      _ ->
        false
    end
  end

  # Retain at most eight list levels, including the outer transaction list.
  defp valid_lists?([]), do: true
  defp valid_lists?([{_, depth} | _]) when depth > 8, do: false
  defp valid_lists?([{<<>>, _} | rest]), do: valid_lists?(rest)

  defp valid_lists?([{bytes, depth} | pending]) do
    case rlp_item(bytes) do
      {:list, payload, rest} -> valid_lists?([{payload, depth + 1}, {rest, depth} | pending])
      {:string, _, rest} -> valid_lists?([{rest, depth} | pending])
      _ -> false
    end
  end

  defp rlp_item(<<prefix, rest::binary>>) when prefix < 128,
    do: {:string, <<prefix>>, rest}

  defp rlp_item(<<prefix, rest::binary>>) when prefix <= 183,
    do: take_rlp(rest, prefix - 128, :string)

  defp rlp_item(<<prefix, rest::binary>>) when prefix <= 191,
    do: long_rlp(rest, prefix - 183, :string)

  defp rlp_item(<<prefix, rest::binary>>) when prefix <= 247,
    do: take_rlp(rest, prefix - 192, :list)

  defp rlp_item(<<prefix, rest::binary>>), do: long_rlp(rest, prefix - 247, :list)
  defp rlp_item(_), do: :error

  defp long_rlp(bytes, length_bytes, kind) do
    case bytes do
      <<length::binary-size(length_bytes), rest::binary>> ->
        take_rlp(rest, :binary.decode_unsigned(length), kind)

      _ ->
        :error
    end
  end

  defp take_rlp(bytes, size, kind) do
    case bytes do
      <<payload::binary-size(size), rest::binary>> -> {kind, payload, rest}
      _ -> :error
    end
  end
end

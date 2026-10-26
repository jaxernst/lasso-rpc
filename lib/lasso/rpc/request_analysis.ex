defmodule Lasso.RPC.RequestAnalysis do
  @moduledoc """
  Analyzes RPC requests to extract capability requirements.

  Block facts are captured at request entry and reused by selection and terminal
  metrics. Capability analysis runs at selection time for config-based provider
  filtering. Both keep parameter parsing out of per-provider adapters.
  """

  alias Lasso.Config.ChainConfig
  alias Lasso.JSONRPC.{BlockSelector, MethodParamsValidator}

  @type requirements :: %{
          requires_archival: boolean(),
          historical_resource: Lasso.RPC.HistoricalCoverage.resource(),
          historical_height: non_neg_integer() | nil,
          block_range: non_neg_integer() | nil,
          address_count: non_neg_integer() | nil
        }

  @typedoc """
  A block selector as the request states it. `earliest` keeps its tag with
  height zero, and a block hash keeps an unknown height. `:omitted` is an
  absent parameter. `:unusable` is malformed or ambiguous input, which supplies
  no historical fact; request validation and responses are unaffected.
  """
  @type selector ::
          {:number, non_neg_integer()}
          | {:tag, :earliest, 0}
          | {:tag, :latest | :pending | :safe | :finalized, nil}
          | {:hash, :unknown}
          | :omitted
          | :unusable

  @typedoc """
  Block facts independent of archival permission. `block` is the method's
  positional selector, the block hash of a block-hash-only method, or an
  `eth_getLogs` block hash; `range` holds both `eth_getLogs` endpoints. `nil`
  means no recognized block selector: transaction-hash reads and block-hash
  methods outside `BlockSelector.hash_position/1` carry none.
  """
  @type block_facts ::
          %{
            resource: Lasso.RPC.HistoricalCoverage.resource(),
            block: selector() | nil,
            range: {selector(), selector()} | nil
          }
          | nil

  # EIP-1898 objects follow ingress validation's method table. The
  # execution-apis BlockNumberOrTagOrHash parameters of those methods and of
  # eth_getBlockReceipts also accept a bare block hash; every other block
  # parameter takes only a number or tag.
  @bare_hash_methods ["eth_getBlockReceipts" | MethodParamsValidator.eip1898_methods()]
  @max_height 9_223_372_036_854_775_807

  @doc """
  Analyze request and return capability requirements.

  ## Options

    * `:consensus_height` - Fresh reference height for age calculation. Unknown age
      does not establish an archival requirement for numeric selectors. EIP-1898
      state selectors by hash require an archival provider because their age cannot
      be established before dispatch.
    * `:archival_threshold` - Blocks older than this require archival (default: #{ChainConfig.Selection.default_archival_threshold()})

  ## Examples

      iex> RequestAnalysis.analyze("eth_getLogs", [%{"fromBlock" => "earliest"}])
      %{requires_archival: true, block_range: nil, address_count: 1}

      iex> RequestAnalysis.analyze("eth_getLogs", [%{"fromBlock" => "latest"}])
      %{requires_archival: false, block_range: nil, address_count: 1}

      iex> RequestAnalysis.analyze("eth_call", [%{}, "0x64"], consensus_height: 20_000_000)
      %{requires_archival: true, block_range: nil, address_count: nil}
  """
  @spec analyze(String.t(), list() | map(), keyword()) :: requirements()
  def analyze(method, params, opts \\ []) do
    requires_archival = requires_archival?(method, params, opts)

    %{
      requires_archival: requires_archival,
      historical_resource: if(requires_archival, do: historical_resource(method), else: nil),
      historical_height: if(requires_archival, do: historical_height(method, params), else: nil),
      block_range: extract_block_range(method, params),
      address_count: extract_address_count(method, params)
    }
  end

  @typedoc """
  The shape of the block a request names, for workload census: `moving`
  (`latest`, `pending`, `safe`, `finalized`, an omitted selector, and
  `eth_blockNumber`), `number` (a numeric block or `earliest`), `hash`, `range`
  (an `eth_getLogs` block range), `unusable` (malformed or ambiguous), or
  `none` (no block selector).
  """
  @type selector_class :: :moving | :number | :hash | :range | :unusable | :none

  @doc "Classifies the block a request names, from its block facts."
  @spec selector_class(String.t(), block_facts()) :: selector_class()
  def selector_class("eth_blockNumber", _facts), do: :moving

  def selector_class(_method, facts) do
    case facts do
      %{range: {:unusable, _to}} -> :unusable
      %{range: {_from, :unusable}} -> :unusable
      %{range: {_from, _to}} -> :range
      %{block: block} -> block_class(block)
      nil -> :none
    end
  end

  defp block_class({:number, _height}), do: :number
  defp block_class({:tag, :earliest, 0}), do: :number
  defp block_class({:tag, _moving, nil}), do: :moving
  defp block_class({:hash, :unknown}), do: :hash
  defp block_class(:omitted), do: :moving
  defp block_class(:unusable), do: :unusable
  defp block_class(nil), do: :none

  @doc """
  Method-aware block facts, captured whether or not archival permission applies.
  Selector shapes follow ingress validation; an explicit JSON null is unusable,
  while an absent parameter is omitted.
  """
  @spec block_facts(String.t(), list() | map()) :: block_facts()
  def block_facts(method, [filter])
      when method in ["eth_getLogs", "trace_filter"] and is_map(filter),
      do: filter_facts(historical_resource(method), filter)

  def block_facts(method, _params) when method in ["eth_getLogs", "trace_filter"],
    do: %{resource: historical_resource(method), block: :unusable, range: nil}

  # Geth uses JSON uint64 values and an optional end, unlike quantity selectors:
  # github.com/ethereum/go-ethereum/blob/v1.16.4/eth/api_debug.go#L253-L276
  def block_facts("debug_getModifiedAccountsByNumber", [block]),
    do: %{resource: :traces, block: trace_number_selector(block), range: nil}

  def block_facts("debug_getModifiedAccountsByNumber", [from, to]),
    do: %{
      resource: :traces,
      block: nil,
      range: {trace_number_selector(from), trace_number_selector(to)}
    }

  def block_facts("debug_getModifiedAccountsByNumber", _params),
    do: %{resource: :traces, block: :unusable, range: nil}

  def block_facts(method, params) do
    case {facts_position(method), BlockSelector.hash_position(method)} do
      {nil, nil} ->
        nil

      {nil, position} ->
        %{resource: :blocks, block: selector_at(params, position, &hash_selector/1), range: nil}

      {position, _hash_position} ->
        %{
          resource: historical_resource(method),
          block: selector_at(params, position, &selector(method, &1)),
          range: nil
        }
    end
  end

  # Facts-only trace positions follow Discovery.TestParams. Keep extract/2 and
  # archival admission unchanged: learning describes targets, not permissions.
  defp facts_position(method) when method in ["debug_traceCall", "trace_callMany"], do: 1
  defp facts_position("trace_call"), do: 2
  defp facts_position("debug_storageRangeAt"), do: 0
  defp facts_position(method), do: BlockSelector.position(method)

  defp trace_number_selector(height)
       when is_integer(height) and height >= 0 and height <= @max_height,
       do: {:number, height}

  defp trace_number_selector(_height), do: :unusable

  defp selector_at(params, position, classify) when is_list(params) do
    case Enum.fetch(params, position) do
      {:ok, value} -> classify.(value)
      :error -> :omitted
    end
  end

  defp selector_at(_params, _position, _classify), do: :unusable

  defp filter_facts(resource, %{"blockHash" => _hash} = filter)
       when is_map_key(filter, "fromBlock") or is_map_key(filter, "toBlock"),
       do: %{resource: resource, block: :unusable, range: nil}

  defp filter_facts(resource, %{"blockHash" => hash}),
    do: %{resource: resource, block: hash_selector(hash), range: nil}

  defp filter_facts(resource, filter),
    do: %{
      resource: resource,
      block: nil,
      range: {filter_bound(filter, "fromBlock"), filter_bound(filter, "toBlock")}
    }

  defp filter_bound(filter, key) do
    case Map.fetch(filter, key) do
      {:ok, value} -> quantity_selector(value)
      :error -> :omitted
    end
  end

  defp selector(method, object) when is_map(object) do
    if method in MethodParamsValidator.eip1898_methods() do
      case MethodParamsValidator.eip1898_selector(object) do
        {:number, quantity} -> number_selector(quantity)
        {:hash, hash} -> hash_selector(hash)
        _ambiguous_or_invalid -> :unusable
      end
    else
      :unusable
    end
  end

  defp selector(method, "0x" <> hex = value) when byte_size(hex) == 64 do
    if method in @bare_hash_methods, do: hash_selector(value), else: :unusable
  end

  defp selector(_method, value), do: quantity_selector(value)

  # Validation's anchored patterns also match before a final newline, so facts
  # additionally require the exact length and a fully consumed hex quantity.
  defp hash_selector(value) when byte_size(value) == 66 do
    if MethodParamsValidator.hash32?(value), do: {:hash, :unknown}, else: :unusable
  end

  defp hash_selector(_value), do: :unusable

  defp quantity_selector("earliest"), do: {:tag, :earliest, 0}
  defp quantity_selector("latest"), do: {:tag, :latest, nil}
  defp quantity_selector("pending"), do: {:tag, :pending, nil}
  defp quantity_selector("safe"), do: {:tag, :safe, nil}
  defp quantity_selector("finalized"), do: {:tag, :finalized, nil}
  defp quantity_selector(value), do: number_selector(value)

  # Learning accepts canonical quantities that fit a signed 64-bit block number.
  defp number_selector("0x" <> hex = value) when byte_size(hex) <= 16 do
    with true <- MethodParamsValidator.quantity?(value),
         {height, ""} when height <= @max_height <- Integer.parse(hex, 16) do
      {:number, height}
    else
      _ -> :unusable
    end
  end

  defp number_selector(_value), do: :unusable

  defp historical_resource("eth_getLogs"), do: :logs
  defp historical_resource("eth_getBalance"), do: :balance
  defp historical_resource("eth_getBlockReceipts"), do: :receipts
  defp historical_resource("eth_getProof"), do: :proofs
  defp historical_resource("debug_" <> _), do: :traces
  defp historical_resource("trace_" <> _), do: :traces

  defp historical_resource(method)
       when method in ~w(eth_getBlockByNumber eth_getBlockTransactionCountByNumber eth_getTransactionByBlockNumberAndIndex eth_getUncleByBlockNumberAndIndex eth_getUncleCountByBlockNumber) do
    :blocks
  end

  defp historical_resource(_method), do: :state

  @doc "Returns an explicit numeric historical selector without requiring a head estimate."
  @spec historical_height(String.t(), list() | map()) :: non_neg_integer() | nil
  def historical_height("eth_getLogs", [filter]) when is_map(filter) do
    case parse_block_number(filter["fromBlock"]) do
      {:ok, height} when is_integer(height) -> height
      _ -> nil
    end
  end

  def historical_height(method, params) do
    case BlockSelector.extract(method, params) do
      %{"blockNumber" => number} -> quantity_height(number)
      number -> quantity_height(number)
    end
  end

  defp quantity_height(number) do
    case parse_block_number(number) do
      {:ok, height} when is_integer(height) -> height
      _ -> nil
    end
  end

  # Archival detection for eth_getLogs with fromBlock/toBlock in filter
  defp requires_archival?("eth_getLogs", params, opts) do
    case params do
      [filter] when is_map(filter) ->
        if is_binary(filter["blockHash"]) do
          true
        else
          from_block = filter["fromBlock"] || "latest"
          to_block = filter["toBlock"] || "latest"
          archival_block?(from_block, opts) or archival_block?(to_block, opts)
        end

      _ ->
        false
    end
  end

  defp requires_archival?(method, params, opts) do
    archival_block?(BlockSelector.extract(method, params), opts)
  end

  # Block parameter evaluation
  defp archival_block?("earliest", _opts), do: true
  defp archival_block?("latest", _opts), do: false
  defp archival_block?("pending", _opts), do: false
  defp archival_block?("safe", _opts), do: false
  defp archival_block?("finalized", _opts), do: false
  defp archival_block?(nil, _opts), do: false

  defp archival_block?(%{"blockNumber" => block_number}, opts),
    do: archival_block?(block_number, opts)

  defp archival_block?(%{"blockHash" => block_hash}, _opts) when is_binary(block_hash), do: true

  defp archival_block?("0x" <> hex, _opts) when byte_size(hex) == 64 do
    case Integer.parse(hex, 16) do
      {_block_hash, ""} -> false
      _invalid -> false
    end
  end

  defp archival_block?("0x" <> hex, opts) do
    case Integer.parse(hex, 16) do
      {block_num, ""} ->
        case Keyword.get(opts, :consensus_height) do
          nil ->
            false

          consensus_height ->
            default_threshold = ChainConfig.Selection.default_archival_threshold()
            threshold = Keyword.get(opts, :archival_threshold, default_threshold)
            age = consensus_height - block_num
            age > threshold
        end

      _ ->
        false
    end
  end

  defp archival_block?(_other, _opts), do: false

  defp extract_block_range("eth_getLogs", [filter]) when is_map(filter) do
    with {:ok, from_num} when is_integer(from_num) <- parse_block_number(filter["fromBlock"]),
         {:ok, to_num} when is_integer(to_num) <- parse_block_number(filter["toBlock"]) do
      abs(to_num - from_num)
    else
      _ -> nil
    end
  end

  defp extract_block_range(_method, _params), do: nil

  defp extract_address_count("eth_getLogs", [%{"address" => addresses}])
       when is_list(addresses) do
    length(addresses)
  end

  defp extract_address_count("eth_getLogs", [%{"address" => address}]) when is_binary(address) do
    1
  end

  defp extract_address_count(_method, _params), do: nil

  defp parse_block_number("earliest"), do: {:ok, 0}
  defp parse_block_number("latest"), do: {:ok, :latest}
  defp parse_block_number("pending"), do: {:ok, :pending}
  defp parse_block_number("safe"), do: {:ok, :safe}
  defp parse_block_number("finalized"), do: {:ok, :finalized}

  defp parse_block_number("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {num, ""} -> {:ok, num}
      _ -> :error
    end
  end

  defp parse_block_number(_), do: :error
end

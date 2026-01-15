defmodule Lasso.RPC.RequestAnalysis do
  @moduledoc """
  Analyzes RPC requests to extract capability requirements.

  Called once at selection time to enable config-based provider filtering.
  This centralized approach avoids duplicating parameter parsing logic across
  per-provider adapters.
  """

  alias Lasso.Config.ChainConfig

  @type requirements :: %{
          requires_archival: boolean(),
          block_range: non_neg_integer() | nil,
          address_count: non_neg_integer() | nil
        }

  @doc """
  Analyze request and return capability requirements.

  ## Options

    * `:consensus_height` - Current blockchain height for age calculation
    * `:archival_threshold` - Blocks older than this require archival (default: #{ChainConfig.Selection.default_archival_threshold()})

  ## Examples

      iex> RequestAnalysis.analyze("eth_getLogs", [%{"fromBlock" => "earliest"}])
      %{requires_archival: true, block_range: nil, address_count: 1}

      iex> RequestAnalysis.analyze("eth_getLogs", [%{"fromBlock" => "latest"}])
      %{requires_archival: false, block_range: nil, address_count: 1}

      iex> RequestAnalysis.analyze("eth_call", [%{}, "0x64"], consensus_height: 20_000_000)
      %{requires_archival: true, block_range: nil, address_count: nil}
  """
  @spec analyze(String.t(), list(), keyword()) :: requirements()
  def analyze(method, params, opts \\ []) do
    %{
      requires_archival: requires_archival?(method, params, opts),
      block_range: extract_block_range(method, params),
      address_count: extract_address_count(method, params)
    }
  end

  # Archival detection for state methods that take block parameter as last argument
  defp requires_archival?(method, params, opts)
       when method in ~w(eth_call eth_getBalance eth_getCode eth_getTransactionCount eth_getStorageAt) do
    block_param = List.last(params)
    archival_block?(block_param, opts)
  end

  # Archival detection for eth_getLogs with fromBlock/toBlock in filter
  defp requires_archival?("eth_getLogs", params, opts) do
    case params do
      [filter] when is_map(filter) ->
        from_block = filter["fromBlock"] || "latest"
        to_block = filter["toBlock"] || "latest"
        archival_block?(from_block, opts) or archival_block?(to_block, opts)

      _ ->
        false
    end
  end

  # Archival detection for eth_getBlockByNumber
  defp requires_archival?("eth_getBlockByNumber", [block | _], opts) do
    archival_block?(block, opts)
  end

  # All other methods don't require archival
  defp requires_archival?(_method, _params, _opts), do: false

  # Block parameter evaluation
  defp archival_block?("earliest", _opts), do: true
  defp archival_block?("latest", _opts), do: false
  defp archival_block?("pending", _opts), do: false
  defp archival_block?("safe", _opts), do: false
  defp archival_block?("finalized", _opts), do: false
  defp archival_block?(nil, _opts), do: false

  defp archival_block?("0x" <> hex, opts) do
    with {block_num, ""} <- Integer.parse(hex, 16) do
      case Keyword.get(opts, :consensus_height) do
        nil ->
          # Conservative: assume archival when consensus height is unknown
          true

        consensus_height ->
          default_threshold = ChainConfig.Selection.default_archival_threshold()
          threshold = Keyword.get(opts, :archival_threshold, default_threshold)
          age = consensus_height - block_num
          age > threshold
      end
    else
      _ -> false
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

  defp extract_address_count("eth_getLogs", [%{"address" => addresses}]) when is_list(addresses) do
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

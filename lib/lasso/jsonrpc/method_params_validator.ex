defmodule Lasso.JSONRPC.MethodParamsValidator do
  @moduledoc false

  alias Lasso.JSONRPC.Error, as: JError

  @eip1898_positions %{
    "eth_getBalance" => 1,
    "eth_getStorageAt" => 2,
    "eth_getTransactionCount" => 1,
    "eth_getCode" => 1,
    "eth_call" => 1,
    "eth_getProof" => 2
  }

  @quantity ~r/^0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)$/
  @hash32 ~r/^0x[0-9a-fA-F]{64}$/

  @spec validate(String.t(), list() | map()) :: :ok | {:error, JError.t()}
  def validate(method, params) when is_binary(method) do
    with :ok <- validate_eip1898(method, params) do
      validate_eip234(method, params)
    end
  end

  defp validate_eip1898(method, params) when is_list(params) do
    case Map.fetch(@eip1898_positions, method) do
      {:ok, position} -> validate_block_selector(Enum.at(params, position))
      :error -> :ok
    end
  end

  defp validate_eip1898(_method, _params), do: :ok

  defp validate_block_selector(selector) when not is_map(selector), do: :ok

  defp validate_block_selector(selector) do
    case eip1898_selector(selector) do
      {kind, _value} when kind in [:number, :hash] ->
        :ok

      :ambiguous ->
        invalid("blockNumber and blockHash are mutually exclusive")

      :invalid ->
        invalid("invalid EIP-1898 block selector")
    end
  end

  @doc "Methods whose block parameter accepts an EIP-1898 selector object."
  @spec eip1898_methods() :: [String.t()]
  def eip1898_methods, do: Map.keys(@eip1898_positions)

  @doc """
  Classifies an EIP-1898 selector object under the rules ingress validation
  enforces: `blockNumber` is a quantity without `requireCanonical`, and
  `blockHash` is 32-byte data with an optional boolean `requireCanonical`.
  """
  @spec eip1898_selector(map()) ::
          {:number, String.t()} | {:hash, String.t()} | :ambiguous | :invalid
  def eip1898_selector(selector) when is_map(selector) do
    canonical = Map.get(selector, "requireCanonical", :absent)

    case selector do
      %{"blockNumber" => _, "blockHash" => _} ->
        :ambiguous

      %{"blockNumber" => number} when is_binary(number) and canonical == :absent ->
        if quantity?(number), do: {:number, number}, else: :invalid

      %{"blockHash" => hash}
      when is_binary(hash) and (canonical == :absent or is_boolean(canonical)) ->
        if hash32?(hash), do: {:hash, hash}, else: :invalid

      _ ->
        :invalid
    end
  end

  @doc "Whether a value is a canonical JSON-RPC quantity: hex without leading zeros."
  @spec quantity?(term()) :: boolean()
  def quantity?(value), do: is_binary(value) and Regex.match?(@quantity, value)

  @doc "Whether a value is 32-byte hex data."
  @spec hash32?(term()) :: boolean()
  def hash32?(value), do: is_binary(value) and Regex.match?(@hash32, value)

  defp validate_eip234("eth_getLogs", [filter]) when is_map(filter) do
    case Map.fetch(filter, "blockHash") do
      :error ->
        :ok

      {:ok, block_hash} ->
        cond do
          Map.has_key?(filter, "fromBlock") or Map.has_key?(filter, "toBlock") ->
            invalid("blockHash is mutually exclusive with fromBlock and toBlock")

          hash32?(block_hash) ->
            :ok

          true ->
            invalid("blockHash must be 32-byte hex data")
        end
    end
  end

  defp validate_eip234(_method, _params), do: :ok

  defp invalid(detail) do
    {:error, JError.new(-32_602, "Invalid params: " <> detail, category: :invalid_params)}
  end
end

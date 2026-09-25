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
    has_block_number? = Map.has_key?(selector, "blockNumber")
    has_block_hash? = Map.has_key?(selector, "blockHash")
    block_number = Map.get(selector, "blockNumber")
    block_hash = Map.get(selector, "blockHash")
    canonical = Map.get(selector, "requireCanonical", :absent)

    cond do
      has_block_number? and has_block_hash? ->
        invalid("blockNumber and blockHash are mutually exclusive")

      has_block_number? and is_binary(block_number) and Regex.match?(@quantity, block_number) and
          canonical == :absent ->
        :ok

      has_block_hash? and is_binary(block_hash) and Regex.match?(@hash32, block_hash) and
          (canonical == :absent or is_boolean(canonical)) ->
        :ok

      true ->
        invalid("invalid EIP-1898 block selector")
    end
  end

  defp validate_eip234("eth_getLogs", [filter]) when is_map(filter) do
    case Map.fetch(filter, "blockHash") do
      :error ->
        :ok

      {:ok, block_hash} ->
        cond do
          Map.has_key?(filter, "fromBlock") or Map.has_key?(filter, "toBlock") ->
            invalid("blockHash is mutually exclusive with fromBlock and toBlock")

          is_binary(block_hash) and Regex.match?(@hash32, block_hash) ->
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

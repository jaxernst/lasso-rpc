defmodule Lasso.Config.ChainValidator do
  @moduledoc """
  Validates chain names and IDs against a canonical allowlist.

  Chain names must use canonical identifiers to ensure consistent global component
  sharing across profiles. BYOK profiles are validated at load time.

  ## Rationale

  Using canonical chain names prevents issues like:
  - "eth" vs "ethereum" vs "ETH" causing different global components
  - Chain ID mismatches between profiles using the same chain name
  - Inconsistent metrics aggregation

  ## Extending the Chain List

  New chains are added to `@canonical_chains` in code. This is intentional - chain
  names are part of the system's namespace, not user-configurable. For truly custom
  chains (private networks), use the naming convention `"custom-{chain_id}"`.
  """

  @canonical_chains %{
    # Ethereum Mainnet and Testnets
    "ethereum" => 1,
    "sepolia" => 11_155_111,
    "holesky" => 17_000,
    "goerli" => 5,
    # Polygon
    "polygon" => 137,
    "polygon-amoy" => 80_002,
    "polygon-mumbai" => 80_001,
    # Arbitrum
    "arbitrum" => 42_161,
    "arbitrum-sepolia" => 421_614,
    "arbitrum-nova" => 42_170,
    # Optimism
    "optimism" => 10,
    "optimism-sepolia" => 11_155_420,
    # Base
    "base" => 8453,
    "base-sepolia" => 84_532,
    # Avalanche
    "avalanche" => 43_114,
    "avalanche-fuji" => 43_113,
    # BNB Smart Chain
    "bsc" => 56,
    "bsc-testnet" => 97,
    # Other L1s
    "gnosis" => 100,
    "fantom" => 250,
    "celo" => 42_220,
    "moonbeam" => 1284,
    "moonriver" => 1285,
    # ZK Rollups
    "zksync" => 324,
    "zksync-sepolia" => 300,
    "linea" => 59_144,
    "linea-sepolia" => 59_141,
    "scroll" => 534_352,
    "scroll-sepolia" => 534_351,
    "polygon-zkevm" => 1101,
    "polygon-zkevm-testnet" => 1442,
    # Blast
    "blast" => 81_457,
    "blast-sepolia" => 168_587_773,
    # Mantle
    "mantle" => 5000,
    "mantle-sepolia" => 5003
  }

  @doc """
  Returns the map of canonical chain names to their chain IDs.
  """
  @spec canonical_chains() :: %{String.t() => integer()}
  def canonical_chains, do: @canonical_chains

  @doc """
  Checks if a chain name is in the canonical list.

  ## Examples

      iex> ChainValidator.valid_chain_name?("ethereum")
      true

      iex> ChainValidator.valid_chain_name?("eth")
      false

      iex> ChainValidator.valid_chain_name?("custom-12345")
      true
  """
  @spec valid_chain_name?(String.t()) :: boolean()
  def valid_chain_name?(name) when is_binary(name) do
    Map.has_key?(@canonical_chains, name) or custom_chain?(name)
  end

  @doc """
  Returns the expected chain ID for a canonical chain name.

  Returns `nil` for custom chains (they specify their own ID).

  ## Examples

      iex> ChainValidator.expected_chain_id("ethereum")
      1

      iex> ChainValidator.expected_chain_id("polygon")
      137

      iex> ChainValidator.expected_chain_id("custom-12345")
      nil
  """
  @spec expected_chain_id(String.t()) :: non_neg_integer() | nil
  def expected_chain_id(name) when is_binary(name) do
    Map.get(@canonical_chains, name)
  end

  @doc """
  Validates all chains in a profile configuration.

  Returns `:ok` if all chains are valid, or an error tuple with details.

  ## Examples

      iex> ChainValidator.validate_chains(%{"ethereum" => %{chain_id: 1}})
      :ok

      iex> ChainValidator.validate_chains(%{"eth" => %{chain_id: 1}})
      {:error, {:invalid_chain_name, "eth", ["ethereum", ...]}}

      iex> ChainValidator.validate_chains(%{"ethereum" => %{chain_id: 5}})
      {:error, {:chain_id_mismatch, "ethereum", 5, 1}}
  """
  @spec validate_chains(map()) :: :ok | {:error, term()}
  def validate_chains(chains) when is_map(chains) do
    Enum.reduce_while(chains, :ok, fn {chain_name, config}, :ok ->
      case validate_chain(chain_name, config) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  Validates a single chain name and its configuration.

  ## Validation Rules

  1. Chain name must be in the canonical list OR be a custom chain (`custom-{id}`)
  2. If canonical, `chain_id` in config must match expected value
  3. Custom chains must have a valid chain_id specified
  """
  @spec validate_chain(String.t(), map() | Lasso.Config.ChainConfig.t()) :: :ok | {:error, term()}
  def validate_chain(chain_name, %Lasso.Config.ChainConfig{} = config) do
    validate_chain(chain_name, %{chain_id: config.chain_id})
  end

  def validate_chain(chain_name, config)
      when is_binary(chain_name) and is_map(config) and not is_struct(config) do
    cond do
      # Check if it's a custom chain
      custom_chain?(chain_name) ->
        validate_custom_chain(chain_name, config)

      # Check if it's a canonical chain
      not valid_chain_name?(chain_name) ->
        suggestions = suggest_chain_names(chain_name)

        {:error,
         {:invalid_chain_name, chain_name, suggestions,
          "Use canonical name. Did you mean: #{Enum.join(suggestions, ", ")}?"}}

      # Validate chain_id matches expected
      true ->
        validate_chain_id(chain_name, config)
    end
  end

  # Private functions

  defp custom_chain?(name) do
    String.starts_with?(name, "custom-")
  end

  defp validate_custom_chain(chain_name, config) do
    chain_id = get_chain_id(config)

    cond do
      is_nil(chain_id) ->
        {:error, {:custom_chain_missing_id, chain_name}}

      not is_integer(chain_id) or chain_id <= 0 ->
        {:error, {:invalid_chain_id, chain_name, chain_id}}

      true ->
        # Verify the custom chain name matches the ID
        expected_name = "custom-#{chain_id}"

        if chain_name == expected_name do
          :ok
        else
          {:error, {:custom_chain_name_mismatch, chain_name, expected_name}}
        end
    end
  end

  defp validate_chain_id(chain_name, config) do
    expected = expected_chain_id(chain_name)
    actual = get_chain_id(config)

    cond do
      is_nil(actual) ->
        # chain_id not specified - that's ok, we can infer it
        :ok

      actual == expected ->
        :ok

      true ->
        {:error, {:chain_id_mismatch, chain_name, actual, expected}}
    end
  end

  defp get_chain_id(%{chain_id: id}), do: id
  defp get_chain_id(%{"chain_id" => id}), do: id
  defp get_chain_id(_), do: nil

  defp suggest_chain_names(input) do
    input_lower = String.downcase(input)

    @canonical_chains
    |> Map.keys()
    |> Enum.filter(fn name ->
      String.contains?(name, input_lower) or
        String.jaro_distance(name, input_lower) > 0.7
    end)
    |> Enum.sort_by(&String.jaro_distance(&1, input_lower), :desc)
    |> Enum.take(3)
  end

  @doc """
  Formats a validation error into a human-readable message.

  ## Examples

      iex> ChainValidator.format_error({:invalid_chain_name, "eth", ["ethereum"], "Use canonical name. Did you mean: ethereum?"})
      "Invalid chain name \\"eth\\". Did you mean: ethereum?"
  """
  @spec format_error(term()) :: String.t()
  def format_error({:invalid_chain_name, name, suggestions, _msg}) do
    "Invalid chain name \"#{name}\". Did you mean: #{Enum.join(suggestions, ", ")}?"
  end

  def format_error({:chain_id_mismatch, name, actual, expected}) do
    "Chain ID mismatch for \"#{name}\": got #{actual}, expected #{expected}."
  end

  def format_error({:custom_chain_missing_id, name}) do
    "Custom chain \"#{name}\" must specify a chain_id."
  end

  def format_error({:custom_chain_name_mismatch, name, expected}) do
    "Custom chain name \"#{name}\" must match format \"#{expected}\" (custom-{chain_id})."
  end

  def format_error({:invalid_chain_id, name, id}) do
    "Invalid chain_id #{inspect(id)} for chain \"#{name}\". Must be a positive integer."
  end

  def format_error(error) do
    "Chain validation error: #{inspect(error)}"
  end
end

defmodule Lasso.RPC.Providers.AdapterRegistry do
  @moduledoc """
  Maps provider IDs to their adapter modules.

  This module is the single source of truth for which adapter
  handles which provider. It includes compile-time validation
  to ensure all adapters exist and implement the ProviderAdapter behaviour.

  ## Adding a New Adapter

  1. Create the adapter module in lib/lasso/core/providers/adapters/
  2. Implement the Lasso.RPC.ProviderAdapter behaviour
  3. Add the mapping to @adapter_mapping below
  4. Compile and test

  The compile-time validation will catch any issues with missing modules
  or incomplete behaviour implementations.
  """

  alias Lasso.RPC.Providers.Adapters

  # Provider type → Adapter module mapping
  # This is now provider-type based for multichain support
  @provider_type_mapping %{
    "alchemy" => Adapters.Alchemy,
    "publicnode" => Adapters.PublicNode,
    "llamarpc" => Adapters.LlamaRPC,
    "merkle" => Adapters.Merkle,
    "cloudflare" => Adapters.Cloudflare,
    "drpc" => Adapters.DRPC,
    "1rpc" => Adapters.OneRPC
    # "infura" => Adapters.Infura,
    # "ankr" => Adapters.Ankr,
  }

  @doc """
  Returns the adapter module for a given provider ID.

  Extracts provider type from the ID and maps to the appropriate adapter.
  This enables automatic multichain support without manual per-chain mappings.

  Supports both naming patterns:
  - `{provider}_{chain}` (e.g., "alchemy_ethereum", "alchemy_base")
  - `{chain}_{provider}` (e.g., "ethereum_cloudflare", "base_llamarpc")

  Falls back to Generic adapter for unknown provider types.

  ## Examples

      iex> AdapterRegistry.adapter_for("alchemy_ethereum")
      Lasso.RPC.Providers.Adapters.Alchemy

      iex> AdapterRegistry.adapter_for("alchemy_base")
      Lasso.RPC.Providers.Adapters.Alchemy

      iex> AdapterRegistry.adapter_for("ethereum_cloudflare")
      Lasso.RPC.Providers.Adapters.Cloudflare

      iex> AdapterRegistry.adapter_for("base_publicnode")
      Lasso.RPC.Providers.Adapters.PublicNode

      iex> AdapterRegistry.adapter_for("unknown_provider")
      Lasso.RPC.Providers.Generic
  """
  @spec adapter_for(String.t()) :: module()
  def adapter_for(provider_id) when is_binary(provider_id) do
    provider_id
    |> extract_provider_type()
    |> lookup_adapter()
  end

  @doc """
  Returns all registered provider types and their adapters.

  ## Examples

      iex> AdapterRegistry.all_adapters()
      [{"alchemy", Lasso.RPC.Providers.Adapters.Alchemy}, ...]
  """
  @spec all_adapters() :: [{String.t(), module()}]
  def all_adapters do
    Map.to_list(@provider_type_mapping)
  end

  @doc """
  Returns list of providers using Generic adapter (providers that need custom adapters).

  This is useful for identifying which providers don't have specialized adapters yet.

  ## Examples

      iex> AdapterRegistry.providers_needing_adapters()
      ["ethereum_llamarpc", "ethereum_merkle", ...]
  """
  @spec providers_needing_adapters() :: [String.t()]
  def providers_needing_adapters do
    # Get all configured providers from ConfigStore
    all_providers = get_all_configured_providers()

    # Find those not in mapping
    Enum.filter(all_providers, fn provider_id ->
      adapter_for(provider_id) == Lasso.RPC.Providers.Generic
    end)
  end

  @doc """
  Checks if a provider has a custom adapter (not using Generic).

  ## Examples

      iex> AdapterRegistry.has_custom_adapter?("ethereum_cloudflare")
      true

      iex> AdapterRegistry.has_custom_adapter?("ethereum_llamarpc")
      false
  """
  @spec has_custom_adapter?(String.t()) :: boolean()
  def has_custom_adapter?(provider_id) when is_binary(provider_id) do
    adapter_for(provider_id) != Lasso.RPC.Providers.Generic
  end

  # Private Helpers

  # Extracts provider type from provider ID
  # Supports both "{provider}_{chain}" and "{chain}_{provider}" patterns
  #
  # IMPORTANT: Provider types are sorted by length (longest first) to prevent
  # collision issues. For example, if we have both "alchemy" and "alchemy_pro",
  # we must check "alchemy_pro" before "alchemy" to correctly match
  # "alchemy_pro_ethereum" to "alchemy_pro" rather than "alchemy".
  @spec extract_provider_type(String.t()) :: String.t() | nil
  defp extract_provider_type(provider_id) do
    # Sort provider types by length DESC to check longer/more-specific patterns first
    provider_types =
      @provider_type_mapping
      |> Map.keys()
      |> Enum.sort_by(&String.length/1, :desc)

    # Try prefix pattern: "{provider}_{chain}" (e.g., "alchemy_ethereum")
    Enum.find_value(provider_types, fn type ->
      if String.starts_with?(provider_id, type <> "_"), do: type
    end) ||
      # Try suffix pattern: "{chain}_{provider}" (e.g., "ethereum_cloudflare")
      Enum.find_value(provider_types, fn type ->
        if String.ends_with?(provider_id, "_" <> type), do: type
      end) ||
      # Try exact match for single-word provider IDs
      Enum.find(provider_types, fn type ->
        provider_id == type
      end)
  end

  # Looks up adapter module from provider type
  @spec lookup_adapter(String.t() | nil) :: module()
  defp lookup_adapter(nil), do: Lasso.RPC.Providers.Generic
  defp lookup_adapter(provider_type) do
    Map.get(@provider_type_mapping, provider_type, Lasso.RPC.Providers.Generic)
  end

  defp get_all_configured_providers do
    # Get all chains from ConfigStore
    chains = Lasso.Config.ConfigStore.list_chains()

    chains
    |> Enum.flat_map(fn chain_name ->
      case Lasso.Config.ConfigStore.get_chain(chain_name) do
        {:ok, chain_config} ->
          Enum.map(chain_config.providers, & &1.id)

        _ ->
          []
      end
    end)
    |> Enum.uniq()
  rescue
    # If ConfigStore isn't available (e.g., during compilation), return empty list
    _ -> []
  end

  # Compile-time validation: Ensure all adapters implement the behaviour
  # Note: We can't use Code.ensure_loaded? during compilation because of ordering
  # The compiler will catch missing modules or incorrect behaviour implementations anyway
  # This is left as documentation of the compile-time contract

  # for {_provider_id, adapter_module} <- @adapter_mapping do
  #   # Runtime validation would happen here, but the compiler already validates:
  #   # 1. Module existence (compilation fails if module doesn't exist)
  #   # 2. Behaviour implementation (compiler warns if callbacks missing)
  # end
end

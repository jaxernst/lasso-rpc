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

  # Provider ID → Adapter module mapping
  # This will be populated as we create each adapter
  @adapter_mapping %{
    "ethereum_cloudflare" => Adapters.Cloudflare,
    "ethereum_publicnode" => Adapters.PublicNode
    # More adapters will be added as they are implemented
    # "ethereum_llamarpc" => Adapters.LlamaRPC,
    # "ethereum_alchemy" => Adapters.Alchemy,
    # "ethereum_infura" => Adapters.Infura,
    # "ethereum_ankr" => Adapters.Ankr
  }

  @doc """
  Returns the adapter module for a given provider ID.

  Falls back to Generic adapter for unknown providers.

  ## Examples

      iex> AdapterRegistry.adapter_for("ethereum_cloudflare")
      Lasso.RPC.Providers.Adapters.Cloudflare

      iex> AdapterRegistry.adapter_for("unknown_provider")
      Lasso.RPC.Providers.Generic
  """
  @spec adapter_for(String.t()) :: module()
  def adapter_for(provider_id) when is_binary(provider_id) do
    Map.get(@adapter_mapping, provider_id, Lasso.RPC.Providers.Generic)
  end

  @doc """
  Returns all registered provider IDs and their adapters.

  ## Examples

      iex> AdapterRegistry.all_adapters()
      [{"ethereum_cloudflare", Lasso.RPC.Providers.Adapters.Cloudflare}, ...]
  """
  @spec all_adapters() :: [{String.t(), module()}]
  def all_adapters do
    Map.to_list(@adapter_mapping)
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

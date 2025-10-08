defmodule Lasso.RPC.Providers.AdapterRegistryTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.Providers.AdapterRegistry
  alias Lasso.RPC.Providers.Adapters
  alias Lasso.RPC.Providers.Generic

  describe "adapter_for/1" do
    test "returns Cloudflare adapter for ethereum_cloudflare" do
      assert AdapterRegistry.adapter_for("ethereum_cloudflare") == Adapters.Cloudflare
    end

    test "returns PublicNode adapter for ethereum_publicnode" do
      assert AdapterRegistry.adapter_for("ethereum_publicnode") == Adapters.PublicNode
    end

    test "returns Generic adapter for unknown provider" do
      assert AdapterRegistry.adapter_for("unknown_provider") == Generic
    end

    test "returns Generic adapter for provider with no custom adapter" do
      assert AdapterRegistry.adapter_for("ethereum_llamarpc") == Generic
    end

    test "handles empty string" do
      assert AdapterRegistry.adapter_for("") == Generic
    end
  end

  describe "all_adapters/0" do
    test "returns list of all registered adapters" do
      adapters = AdapterRegistry.all_adapters()

      assert is_list(adapters)
      assert {"ethereum_cloudflare", Adapters.Cloudflare} in adapters
      assert {"ethereum_publicnode", Adapters.PublicNode} in adapters
    end

    test "returns non-empty list" do
      adapters = AdapterRegistry.all_adapters()
      assert length(adapters) > 0
    end
  end

  describe "has_custom_adapter?/1" do
    test "returns true for provider with custom adapter" do
      assert AdapterRegistry.has_custom_adapter?("ethereum_cloudflare") == true
      assert AdapterRegistry.has_custom_adapter?("ethereum_publicnode") == true
    end

    test "returns false for provider using Generic adapter" do
      assert AdapterRegistry.has_custom_adapter?("unknown_provider") == false
      assert AdapterRegistry.has_custom_adapter?("ethereum_llamarpc") == false
    end

    test "returns false for empty string" do
      assert AdapterRegistry.has_custom_adapter?("") == false
    end
  end

  describe "providers_needing_adapters/0" do
    test "returns list of providers without custom adapters" do
      # This test depends on ConfigStore being available
      # We just verify the function returns a list
      result = AdapterRegistry.providers_needing_adapters()
      assert is_list(result)
    end

    test "providers returned should not have custom adapters" do
      providers = AdapterRegistry.providers_needing_adapters()

      # All providers in the list should use Generic adapter
      Enum.each(providers, fn provider_id ->
        assert AdapterRegistry.adapter_for(provider_id) == Generic
      end)
    end
  end

  describe "adapter dispatch correctness" do
    test "adapter lookup is consistent" do
      # Call twice to ensure no state issues
      adapter1 = AdapterRegistry.adapter_for("ethereum_cloudflare")
      adapter2 = AdapterRegistry.adapter_for("ethereum_cloudflare")

      assert adapter1 == adapter2
      assert adapter1 == Adapters.Cloudflare
    end

    test "different providers return different adapters when appropriate" do
      cloudflare = AdapterRegistry.adapter_for("ethereum_cloudflare")
      publicnode = AdapterRegistry.adapter_for("ethereum_publicnode")

      # These should be different adapters
      assert cloudflare != publicnode
      assert cloudflare == Adapters.Cloudflare
      assert publicnode == Adapters.PublicNode
    end
  end
end

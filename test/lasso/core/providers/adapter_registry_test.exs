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

    test "returns LlamaRPC adapter for ethereum_llamarpc" do
      assert AdapterRegistry.adapter_for("ethereum_llamarpc") == Adapters.LlamaRPC
    end

    test "handles empty string" do
      assert AdapterRegistry.adapter_for("") == Generic
    end
  end

  describe "all_adapters/0" do
    test "returns list of all registered provider types and adapters" do
      adapters = AdapterRegistry.all_adapters()

      assert is_list(adapters)
      # Now returns provider types, not specific provider IDs
      assert {"cloudflare", Adapters.Cloudflare} in adapters
      assert {"publicnode", Adapters.PublicNode} in adapters
      assert {"alchemy", Adapters.Alchemy} in adapters
      assert {"llamarpc", Adapters.LlamaRPC} in adapters
      assert {"merkle", Adapters.Merkle} in adapters
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
      assert AdapterRegistry.has_custom_adapter?("ethereum_llamarpc") == true
    end

    test "returns false for provider using Generic adapter" do
      assert AdapterRegistry.has_custom_adapter?("unknown_provider") == false
    end

    test "returns false for empty string" do
      assert AdapterRegistry.has_custom_adapter?("") == false
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

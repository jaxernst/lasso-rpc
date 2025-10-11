defmodule Lasso.RPC.Providers.MultichainAdapterTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.Providers.AdapterRegistry
  alias Lasso.RPC.Providers.Adapters

  describe "AdapterRegistry multichain support" do
    test "resolves alchemy adapter for all chains" do
      assert AdapterRegistry.adapter_for("alchemy_ethereum") == Adapters.Alchemy
      assert AdapterRegistry.adapter_for("alchemy_base") == Adapters.Alchemy
      assert AdapterRegistry.adapter_for("alchemy_polygon") == Adapters.Alchemy
      assert AdapterRegistry.adapter_for("alchemy_arbitrum") == Adapters.Alchemy
    end

    test "handles provider types with shared prefixes correctly" do
      # Even though we only have "alchemy" now, test that the sorting works
      # If we add "alchemy_pro" in the future, this ensures longer matches first
      assert AdapterRegistry.adapter_for("alchemy_ethereum") == Adapters.Alchemy
      assert AdapterRegistry.adapter_for("alchemy_base") == Adapters.Alchemy

      # Verify that "publicnode" doesn't incorrectly match "public" if we had both
      assert AdapterRegistry.adapter_for("publicnode_ethereum") == Adapters.PublicNode
      assert AdapterRegistry.adapter_for("ethereum_publicnode") == Adapters.PublicNode
    end

    test "resolves publicnode adapter for all chains" do
      assert AdapterRegistry.adapter_for("ethereum_publicnode") == Adapters.PublicNode
      assert AdapterRegistry.adapter_for("base_publicnode") == Adapters.PublicNode
      assert AdapterRegistry.adapter_for("polygon_publicnode") == Adapters.PublicNode
    end

    test "resolves llamarpc adapter for all chains" do
      assert AdapterRegistry.adapter_for("ethereum_llamarpc") == Adapters.LlamaRPC
      assert AdapterRegistry.adapter_for("base_llamarpc") == Adapters.LlamaRPC
      assert AdapterRegistry.adapter_for("llamarpc_polygon") == Adapters.LlamaRPC
    end

    test "resolves merkle adapter for all chains" do
      assert AdapterRegistry.adapter_for("ethereum_merkle") == Adapters.Merkle
      assert AdapterRegistry.adapter_for("base_merkle") == Adapters.Merkle
    end

    test "resolves cloudflare adapter for all chains" do
      assert AdapterRegistry.adapter_for("ethereum_cloudflare") == Adapters.Cloudflare
      assert AdapterRegistry.adapter_for("base_cloudflare") == Adapters.Cloudflare
    end

    test "falls back to Generic for unknown providers" do
      assert AdapterRegistry.adapter_for("unknown_provider") == Lasso.RPC.Providers.Generic
      assert AdapterRegistry.adapter_for("ethereum_unknown") == Lasso.RPC.Providers.Generic
      assert AdapterRegistry.adapter_for("random_base") == Lasso.RPC.Providers.Generic
    end

    test "handles provider-first and chain-first naming patterns" do
      # Provider-first: alchemy_ethereum
      assert AdapterRegistry.adapter_for("alchemy_ethereum") == Adapters.Alchemy

      # Chain-first: ethereum_cloudflare
      assert AdapterRegistry.adapter_for("ethereum_cloudflare") == Adapters.Cloudflare

      # Both patterns work for same provider type
      assert AdapterRegistry.adapter_for("llamarpc_base") == Adapters.LlamaRPC
      assert AdapterRegistry.adapter_for("base_llamarpc") == Adapters.LlamaRPC
    end
  end

  describe "Alchemy adapter with per-chain config" do
    test "uses default block range when no adapter_config provided" do
      ctx = %{
        provider_id: "alchemy_ethereum",
        chain: "ethereum"
      }

      params = [%{"fromBlock" => "0x1", "toBlock" => "0x20"}]

      # Default is 10 blocks, range of 31 should fail
      assert {:error, {:param_limit, message}} =
               Adapters.Alchemy.validate_params("eth_getLogs", params, :http, ctx)

      assert message =~ "max 10 block range"
    end

    test "respects adapter_config for custom block range" do
      # Simulate provider config with custom limit
      provider_config = %Lasso.Config.ChainConfig.Provider{
        id: "alchemy_base",
        name: "Alchemy Base",
        url: "https://base.alchemy.com",
        adapter_config: %{eth_get_logs_block_range: 50}
      }

      ctx = %{
        provider_id: "alchemy_base",
        chain: "base",
        provider_config: provider_config
      }

      # Range of 31 should now pass with limit of 50
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x20"}]
      assert :ok = Adapters.Alchemy.validate_params("eth_getLogs", params, :http, ctx)

      # But 51 blocks should fail
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x34"}]

      assert {:error, {:param_limit, message}} =
               Adapters.Alchemy.validate_params("eth_getLogs", params, :http, ctx)

      assert message =~ "max 50 block range"
    end
  end

  describe "PublicNode adapter with per-chain config" do
    test "uses default address limits when no adapter_config provided" do
      ctx = %{
        provider_id: "base_publicnode",
        chain: "base"
      }

      # Generate 26 addresses (default HTTP limit is 25)
      addresses = Enum.map(1..26, fn i -> "0x#{Integer.to_string(i, 16)}" end)
      params = [%{"address" => addresses}]

      assert {:error, {:param_limit, message}} =
               Adapters.PublicNode.validate_params("eth_getLogs", params, :http, ctx)

      assert message =~ "max 25 addresses"
    end

    test "respects adapter_config for custom address limits" do
      provider_config = %Lasso.Config.ChainConfig.Provider{
        id: "base_publicnode",
        name: "PublicNode Base",
        url: "https://base.publicnode.com",
        adapter_config: %{
          max_addresses_http: 50,
          max_addresses_ws: 30
        }
      }

      ctx = %{
        provider_id: "base_publicnode",
        chain: "base",
        provider_config: provider_config
      }

      # 40 addresses should pass with HTTP limit of 50
      addresses = Enum.map(1..40, fn i -> "0x#{Integer.to_string(i, 16)}" end)
      params = [%{"address" => addresses}]
      assert :ok = Adapters.PublicNode.validate_params("eth_getLogs", params, :http, ctx)

      # But 51 should fail
      addresses = Enum.map(1..51, fn i -> "0x#{Integer.to_string(i, 16)}" end)
      params = [%{"address" => addresses}]

      assert {:error, {:param_limit, message}} =
               Adapters.PublicNode.validate_params("eth_getLogs", params, :http, ctx)

      assert message =~ "max 50 addresses"
    end

    test "uses different limits for WS transport" do
      provider_config = %Lasso.Config.ChainConfig.Provider{
        id: "base_publicnode",
        name: "PublicNode Base",
        url: "https://base.publicnode.com",
        adapter_config: %{
          max_addresses_http: 50,
          max_addresses_ws: 15
        }
      }

      ctx = %{
        provider_id: "base_publicnode",
        chain: "base",
        provider_config: provider_config
      }

      # 20 addresses should fail on WS (limit 15)
      addresses = Enum.map(1..20, fn i -> "0x#{Integer.to_string(i, 16)}" end)
      params = [%{"address" => addresses}]

      assert {:error, {:param_limit, message}} =
               Adapters.PublicNode.validate_params("eth_getLogs", params, :ws, ctx)

      assert message =~ "max 15 addresses"
    end
  end

  describe "LlamaRPC adapter with per-chain config" do
    test "uses default block range when no adapter_config provided" do
      ctx = %{
        provider_id: "base_llamarpc",
        chain: "base"
      }

      # Range of 1001 blocks should fail (default is 1000)
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x3EA"}]

      assert {:error, {:param_limit, message}} =
               Adapters.LlamaRPC.validate_params("eth_getLogs", params, :http, ctx)

      assert message =~ "max 1000 block range"
    end

    test "respects adapter_config for custom block range" do
      provider_config = %Lasso.Config.ChainConfig.Provider{
        id: "base_llamarpc",
        name: "LlamaRPC Base",
        url: "https://base.llamarpc.com",
        adapter_config: %{max_block_range: 2000}
      }

      ctx = %{
        provider_id: "base_llamarpc",
        chain: "base",
        provider_config: provider_config
      }

      # 1500 blocks should pass with limit of 2000
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x5DD"}]
      assert :ok = Adapters.LlamaRPC.validate_params("eth_getLogs", params, :http, ctx)

      # But 2001 should fail
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x7D2"}]

      assert {:error, {:param_limit, message}} =
               Adapters.LlamaRPC.validate_params("eth_getLogs", params, :http, ctx)

      assert message =~ "max 2000 block range"
    end
  end

  describe "Merkle adapter with per-chain config" do
    test "respects adapter_config for custom block range" do
      provider_config = %Lasso.Config.ChainConfig.Provider{
        id: "base_merkle",
        name: "Merkle Base",
        url: "https://base.merkle.io",
        adapter_config: %{max_block_range: 500}
      }

      ctx = %{
        provider_id: "base_merkle",
        chain: "base",
        provider_config: provider_config
      }

      # 400 blocks should pass with limit of 500
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x191"}]
      assert :ok = Adapters.Merkle.validate_params("eth_getLogs", params, :http, ctx)

      # But 501 should fail
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x1F6"}]

      assert {:error, {:param_limit, message}} =
               Adapters.Merkle.validate_params("eth_getLogs", params, :http, ctx)

      assert message =~ "max 500 block range"
    end
  end

  describe "Backward compatibility" do
    test "providers without adapter_config use defaults" do
      # Provider with explicitly nil adapter_config
      provider_config = %Lasso.Config.ChainConfig.Provider{
        id: "alchemy_ethereum",
        name: "Alchemy Ethereum",
        url: "https://eth.alchemy.com",
        adapter_config: nil
      }

      ctx = %{
        provider_id: "alchemy_ethereum",
        chain: "ethereum",
        provider_config: provider_config
      }

      # Should use default (10 blocks)
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x20"}]

      assert {:error, {:param_limit, message}} =
               Adapters.Alchemy.validate_params("eth_getLogs", params, :http, ctx)

      assert message =~ "max 10 block range"
    end

    test "providers with empty adapter_config use defaults" do
      provider_config = %Lasso.Config.ChainConfig.Provider{
        id: "base_llamarpc",
        name: "LlamaRPC Base",
        url: "https://base.llamarpc.com",
        adapter_config: %{}
      }

      ctx = %{
        provider_id: "base_llamarpc",
        chain: "base",
        provider_config: provider_config
      }

      # Should use default (1000 blocks)
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x3EA"}]

      assert {:error, {:param_limit, message}} =
               Adapters.LlamaRPC.validate_params("eth_getLogs", params, :http, ctx)

      assert message =~ "max 1000 block range"
    end

    test "providers without provider_config in context use defaults" do
      # Context with no provider_config at all
      ctx = %{
        provider_id: "alchemy_base",
        chain: "base"
      }

      # Should use default (10 blocks)
      params = [%{"fromBlock" => "0x1", "toBlock" => "0x20"}]

      assert {:error, {:param_limit, message}} =
               Adapters.Alchemy.validate_params("eth_getLogs", params, :http, ctx)

      assert message =~ "max 10 block range"
    end
  end

  describe "AdapterHelpers" do
    test "get_adapter_config reads from nested config" do
      alias Lasso.RPC.Providers.AdapterHelpers

      ctx = %{
        provider_config: %{
          adapter_config: %{max_block_range: 100}
        }
      }

      assert AdapterHelpers.get_adapter_config(ctx, :max_block_range, 50) == 100
    end

    test "get_adapter_config returns default when key missing" do
      alias Lasso.RPC.Providers.AdapterHelpers

      ctx = %{
        provider_config: %{
          adapter_config: %{}
        }
      }

      assert AdapterHelpers.get_adapter_config(ctx, :unknown_key, 42) == 42
    end

    test "get_adapter_config handles missing provider_config" do
      alias Lasso.RPC.Providers.AdapterHelpers

      ctx = %{}

      assert AdapterHelpers.get_adapter_config(ctx, :max_range, 50) == 50
    end

    test "get_adapter_config handles nil adapter_config" do
      alias Lasso.RPC.Providers.AdapterHelpers

      ctx = %{
        provider_config: %{
          adapter_config: nil
        }
      }

      assert AdapterHelpers.get_adapter_config(ctx, :max_range, 50) == 50
    end
  end
end

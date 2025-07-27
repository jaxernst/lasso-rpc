defmodule Livechain.Config.ChainConfigTest do
  @moduledoc """
  Tests for the Livechain.Config.ChainConfig module.
  """

  use ExUnit.Case, async: true

  alias Livechain.Config.ChainConfig

  describe "configuration loading" do
    test "load_config/1 successfully loads chains.yml" do
      {:ok, config} = ChainConfig.load_config("config/chains.yml")

      assert is_struct(config, ChainConfig.Config)
      assert is_map(config.chains)
      assert map_size(config.chains) > 0
    end

    test "load_config/1 returns error for non-existent file" do
      assert {:error, _reason} = ChainConfig.load_config("non_existent.yml")
    end
  end

  describe "chain configuration retrieval" do
    setup do
      {:ok, config} = ChainConfig.load_config("config/chains.yml")
      {:ok, config: config}
    end

    test "get_chain_config/2 returns config for existing chain", %{config: config} do
      {:ok, ethereum_config} = ChainConfig.get_chain_config(config, "ethereum")

      assert is_struct(ethereum_config, ChainConfig)
      assert ethereum_config.name == "Ethereum Mainnet"
      assert ethereum_config.chain_id == 1
    end

    test "get_chain_config/2 returns error for non-existent chain", %{config: config} do
      assert {:error, :chain_not_found} = ChainConfig.get_chain_config(config, "nonexistent")
    end

    test "get_chain_config/2 can find chain by chain_id", %{config: config} do
      {:ok, ethereum_config} = ChainConfig.get_chain_config(config, 1)

      assert ethereum_config.name == "Ethereum Mainnet"
      assert ethereum_config.chain_id == 1
    end
  end

  describe "provider management" do
    setup do
      {:ok, config} = ChainConfig.load_config("config/chains.yml")
      {:ok, ethereum_config} = ChainConfig.get_chain_config(config, "ethereum")
      {:ok, config: config, ethereum_config: ethereum_config}
    end

    test "get_providers_by_priority/1 returns sorted providers", %{ethereum_config: chain_config} do
      providers = ChainConfig.get_providers_by_priority(chain_config)

      assert is_list(providers)
      assert length(providers) > 0

      # Check that providers are sorted by priority
      priorities = Enum.map(providers, & &1.priority)
      assert priorities == Enum.sort(priorities)
    end

    test "get_available_providers/1 returns providers with valid URLs", %{
      ethereum_config: chain_config
    } do
      available = ChainConfig.get_available_providers(chain_config)

      assert is_list(available)

      # All available providers should have URLs
      Enum.each(available, fn provider ->
        assert is_binary(provider.url)
        assert String.length(provider.url) > 0
      end)
    end

    test "get_provider_by_id/2 returns specific provider", %{ethereum_config: chain_config} do
      # Get the first provider to test with
      [first_provider | _] = ChainConfig.get_providers_by_priority(chain_config)

      {:ok, found_provider} = ChainConfig.get_provider_by_id(chain_config, first_provider.id)

      assert found_provider.id == first_provider.id
      assert found_provider.name == first_provider.name
    end

    test "get_provider_by_id/2 returns error for non-existent provider", %{
      ethereum_config: chain_config
    } do
      assert {:error, :provider_not_found} =
               ChainConfig.get_provider_by_id(chain_config, "nonexistent")
    end
  end

  describe "configuration validation" do
    test "validate_chain_config/1 accepts valid config" do
      valid_config = %ChainConfig{
        chain_id: 1,
        name: "Test Chain",
        block_time: 1000,
        providers: [
          %ChainConfig.Provider{
            id: "test_provider",
            name: "Test Provider",
            priority: 1,
            type: "public",
            url: "https://test.example.com",
            ws_url: "wss://test.example.com",
            api_key_required: false,
            rate_limit: 1000,
            latency_target: 100,
            reliability: 0.99
          }
        ],
        connection: %ChainConfig.Connection{
          heartbeat_interval: 15000,
          reconnect_interval: 2000,
          max_reconnect_attempts: 10,
          subscription_topics: ["newHeads"]
        },
        aggregation: %ChainConfig.Aggregation{
          deduplication_window: 500,
          min_confirmations: 1,
          max_providers: 3
        }
      }

      assert :ok = ChainConfig.validate_chain_config(valid_config)
    end
  end
end

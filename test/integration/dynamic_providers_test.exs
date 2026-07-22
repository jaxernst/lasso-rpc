defmodule Lasso.Integration.DynamicProvidersTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Lasso.Providers
  alias Lasso.Testing.{ChainHelper, MockProvider}

  @test_chain 1

  # Use mock providers for deterministic testing
  @test_providers [
    %{
      id: "cloudflare_test",
      name: "Cloudflare Eth Test",
      url: "https://cloudflare-eth.com",
      ws_url: "wss://cloudflare-eth.com/ws",
      priority: 50
    },
    %{
      id: "ankr_test",
      name: "Ankr Test",
      url: "https://rpc.ankr.com/eth",
      priority: 60
    }
  ]

  setup do
    :ok = ChainHelper.ensure_chain_exists(@test_chain)
    :ok
  end

  describe "Dynamic Provider Management" do
    test "starts supervision for a runtime-registered chain" do
      chain_id = 900_000_000 + :rand.uniform(99_999_999)
      provider_id = "runtime-chain-provider-#{chain_id}"

      :ok =
        Lasso.Config.ConfigStore.register_chain_runtime("public", chain_id, %{
          display_name: "Runtime Chain",
          url_aliases: ["runtime-#{chain_id}"],
          providers: []
        })

      on_exit(fn ->
        Providers.remove_provider(chain_id, provider_id)
        Lasso.Config.ConfigStore.unregister_chain_runtime("public", chain_id)
      end)

      assert {:ok, ^provider_id} =
               Providers.add_provider(
                 chain_id,
                 %{
                   id: provider_id,
                   name: "Runtime Chain Provider",
                   url: "http://127.0.0.1:1",
                   priority: 1
                 },
                 validate: false
               )

      assert Lasso.ProfileChainSupervisor.running?("public", chain_id)
    end

    setup do
      # Use unique provider ID per test to avoid conflicts
      test_id = "test_dynamic_#{:erlang.unique_integer([:positive])}"

      # Use first test provider with unique ID
      provider_config =
        @test_providers
        |> List.first()
        |> Map.put(:id, test_id)
        |> Map.put(:name, "Dynamic Test Provider #{test_id}")

      on_exit(fn ->
        # Cleanup - try to remove, but don't fail if already gone or never added
        try do
          Providers.remove_provider(@test_chain, test_id)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, provider_config: provider_config, test_id: test_id}
    end

    test "can add a provider dynamically", %{provider_config: config, test_id: test_id} do
      # Add provider
      assert {:ok, provider_id} = Providers.add_provider(@test_chain, config)
      assert provider_id == test_id

      # Verify it appears in list
      assert {:ok, providers} = Providers.list_providers(@test_chain)
      dynamic_provider = Enum.find(providers, fn p -> p.id == test_id end)

      assert dynamic_provider != nil
      assert dynamic_provider.name == config.name
      assert dynamic_provider.has_http == true
      assert dynamic_provider.has_ws == true
    end

    test "removal unregisters before rebuilding routing and reaps an unreferenced instance", %{
      provider_config: config,
      test_id: test_id
    } do
      alias Lasso.BlockSync.Worker
      alias Lasso.Providers.{Catalog, InstanceSupervisor}

      assert {:ok, _id} = Providers.add_provider(@test_chain, config)
      instance_id = Catalog.lookup_instance_id("public", @test_chain, test_id)
      assert is_binary(instance_id)

      assert %{provider_id: ^test_id} =
               Enum.find(
                 Catalog.get_profile_providers("public", @test_chain),
                 &(&1.provider_id == test_id)
               )

      assert eventually(fn ->
               GenServer.whereis(InstanceSupervisor.via_name(instance_id)) != nil
             end)

      assert eventually(fn -> GenServer.whereis(Worker.via(@test_chain, instance_id)) != nil end)

      assert :ok = Providers.remove_provider(@test_chain, test_id)

      assert {:error, :not_found} = Providers.get_provider(@test_chain, test_id)

      refute Enum.any?(
               Catalog.get_profile_providers("public", @test_chain),
               &(&1.provider_id == test_id)
             )

      assert Catalog.get_instance_refs(instance_id) == []

      assert eventually(fn ->
               GenServer.whereis(InstanceSupervisor.via_name(instance_id)) == nil
             end)

      assert eventually(fn -> GenServer.whereis(Worker.via(@test_chain, instance_id)) == nil end)
    end

    test "prevents adding duplicate providers", %{provider_config: config, test_id: test_id} do
      # Add provider first time
      assert {:ok, _id} = Providers.add_provider(@test_chain, config)

      # Try to add again
      assert {:error, {:already_exists, ^test_id}} =
               Providers.add_provider(@test_chain, config)
    end

    test "can list all providers with status", %{provider_config: config} do
      # Add our test provider
      assert {:ok, _id} = Providers.add_provider(@test_chain, config)

      # List all providers
      assert {:ok, providers} = Providers.list_providers(@test_chain)

      # Should have at least our dynamic one plus any config-file providers
      assert length(providers) >= 1

      # Each provider should have required fields
      Enum.each(providers, fn provider ->
        assert is_binary(provider.id)
        assert is_binary(provider.name)

        assert provider.status in [
                 :healthy,
                 :unhealthy,
                 :connecting,
                 :disconnected,
                 :rate_limited
               ]

        assert provider.availability in [:up, :down, :limited]
        assert is_boolean(provider.has_http)
        assert is_boolean(provider.has_ws)
      end)
    end

    test "validates provider configuration" do
      # Missing required fields
      invalid_config = %{
        name: "Missing ID"
      }

      assert {:error, {:missing_required_fields, _fields}} =
               Providers.add_provider(@test_chain, invalid_config)

      # Invalid URL format
      bad_url_config = %{
        id: "bad_url_provider_#{:erlang.unique_integer([:positive])}",
        name: "Bad URL",
        url: "not-a-valid-url"
      }

      assert {:error, _reason} =
               Providers.add_provider(@test_chain, bad_url_config)
    end
  end

  describe "Provider Lifecycle" do
    setup do
      # Use unique provider ID per test to avoid conflicts
      test_id = "test_lifecycle_#{:erlang.unique_integer([:positive])}"

      # Use second test provider with unique ID
      provider_config =
        @test_providers
        |> Enum.at(1)
        |> Map.put(:id, test_id)
        |> Map.put(:name, "Lifecycle Test Provider #{test_id}")

      on_exit(fn ->
        # Cleanup - try to remove, but don't fail if already gone or never added
        try do
          Providers.remove_provider(@test_chain, test_id)
        catch
          :exit, _ -> :ok
        end
      end)

      {:ok, provider_config: provider_config, test_id: test_id}
    end

    test "dynamically added provider appears in routing", %{
      provider_config: config,
      test_id: test_id
    } do
      # Add provider
      assert {:ok, _id} = Providers.add_provider(@test_chain, config)

      # Give it a moment to stabilize
      Process.sleep(500)

      # Verify it's available for selection
      # This is tested indirectly by checking it appears in active candidates
      assert {:ok, providers} = Providers.list_providers(@test_chain)
      dynamic = Enum.find(providers, fn p -> p.id == test_id end)

      # Should be in connecting or healthy state
      assert dynamic.status in [:connecting, :healthy]
    end

    test "removed provider disappears from routing", %{provider_config: config, test_id: test_id} do
      # Add and then remove
      assert {:ok, _id} = Providers.add_provider(@test_chain, config)
      assert :ok = Providers.remove_provider(@test_chain, test_id)

      # Give cleanup a moment
      Process.sleep(300)

      # Should no longer appear
      assert {:error, :not_found} =
               Providers.get_provider(@test_chain, test_id)
    end

    test "can route RPC requests through dynamically added provider (mock)", %{
      test_id: test_id
    } do
      alias Lasso.RPC.RequestPipeline
      alias Lasso.RPC.RequestOptions

      # Use mock provider for deterministic testing
      assert {:ok, ^test_id} =
               MockProvider.start_mock(@test_chain, %{
                 id: test_id,
                 latency: 10,
                 reliability: 1.0,
                 block_number: 0x2000
               })

      # Give it a moment to initialize connections
      Process.sleep(300)

      # Verify provider is available
      assert {:ok, provider} = Providers.get_provider(@test_chain, test_id)
      assert provider.id == test_id

      # Route RPC request through the new provider using provider_override
      result =
        RequestPipeline.execute_via_channels(
          @test_chain,
          "eth_blockNumber",
          [],
          %RequestOptions{provider_override: test_id, strategy: :priority, timeout_ms: 5_000}
        )

      # Assert happy path - mock should succeed
      assert {:ok, response, _ctx} = result
      assert {:ok, block_number} = Lasso.RPC.Response.Success.decode_result(response)
      assert is_binary(block_number)
      # Verify we got a valid hex block number (relaxed assertion - routing works)
      assert String.starts_with?(block_number, "0x")

      # Additional verification: ensure provider appears in routing candidates
      assert {:ok, providers} = Providers.list_providers(@test_chain)
      dynamic_provider = Enum.find(providers, fn p -> p.id == test_id end)
      assert dynamic_provider != nil
      assert dynamic_provider.has_http == true
    end

    test "can route requests without provider override (mock)", %{test_id: test_id} do
      alias Lasso.RPC.RequestPipeline
      alias Lasso.RPC.RequestOptions

      # Add mock provider that will be selected by strategy
      assert {:ok, ^test_id} =
               MockProvider.start_mock(@test_chain, %{
                 id: test_id,
                 latency: 10,
                 reliability: 1.0,
                 block_number: 0x3000,
                 priority: 10
               })

      Process.sleep(300)

      # Verify provider is available and healthy
      {:ok, providers} = Providers.list_providers(@test_chain)
      mock_provider = Enum.find(providers, fn p -> p.id == test_id end)
      assert mock_provider != nil
      assert mock_provider.has_http == true

      # Route without override - let strategy select provider
      result =
        RequestPipeline.execute_via_channels(
          @test_chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :priority, timeout_ms: 5_000}
        )

      assert {:ok, response, _ctx} = result
      assert {:ok, block_number} = Lasso.RPC.Response.Success.decode_result(response)
      assert is_binary(block_number)
      assert String.starts_with?(block_number, "0x")
    end
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end
end

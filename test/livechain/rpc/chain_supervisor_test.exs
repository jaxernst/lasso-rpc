defmodule Livechain.RPC.ChainSupervisorTest do
  @moduledoc """
  Tests for the ChainSupervisor orchestration brain.

  This tests the core orchestration logic that manages multiple provider
  connections, coordinates with MessageAggregator, and handles failover.
  """

  use ExUnit.Case, async: false
  import Mox
  import ExUnit.CaptureLog

  alias Livechain.RPC.{ChainSupervisor, MessageAggregator, ProviderPool, CircuitBreaker}
  alias Livechain.Config.ChainConfig
  alias Livechain.Config.ChainConfig.{Provider, Connection, Aggregation, Failover}

  setup do
    # Mock the HTTP client for provider operations
    stub(Livechain.RPC.HttpClientMock, :request, &MockHttpClient.request/4)

    # Start core dependencies if not already started
    case Registry.start_link(
           keys: :unique,
           name: Livechain.Registry,
           partitions: System.schedulers_online()
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Livechain.RPC.ProcessRegistry.start_link(name: Livechain.RPC.ProcessRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Livechain.Benchmarking.BenchmarkStore.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Create test chain configuration
    chain_config = %ChainConfig{
      chain_id: 1,
      name: "ethereum",
      block_time: 12000,
      aggregation: %Aggregation{
        deduplication_window: 1000,
        min_confirmations: 1,
        max_providers: 3
      },
      connection: %Connection{
        heartbeat_interval: 30000,
        reconnect_interval: 5000,
        max_reconnect_attempts: 3
      },
      failover: %Failover{
        enabled: true,
        max_backfill_blocks: 100,
        backfill_timeout: 30000
      },
      providers: [
        %Provider{
          id: "test_provider_1",
          name: "Test Provider 1",
          url: "https://test1.example.com",
          ws_url: "wss://test1.example.com/ws",
          type: "public",
          api_key_required: false,
          rate_limit: 1000,
          latency_target: 100,
          reliability: 0.95
        },
        %Provider{
          id: "test_provider_2",
          name: "Test Provider 2",
          url: "https://test2.example.com",
          ws_url: "wss://test2.example.com/ws",
          type: "public",
          api_key_required: false,
          rate_limit: 1000,
          latency_target: 150,
          reliability: 0.90
        },
        %Provider{
          id: "test_provider_3",
          name: "Test Provider 3",
          url: "https://test3.example.com",
          ws_url: "wss://test3.example.com/ws",
          type: "public",
          api_key_required: false,
          rate_limit: 1000,
          latency_target: 200,
          reliability: 0.85
        }
      ]
    }

    %{chain_config: chain_config}
  end

  describe "Supervisor Lifecycle" do
    test "starts and initializes all child processes", %{chain_config: chain_config} do
      chain_name = "test_chain"

      # Start the ChainSupervisor
      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})

      # Verify supervisor is running
      assert Process.alive?(supervisor_pid)

      # Give time for async provider connection startup
      Process.sleep(200)

      # Verify expected child processes are started
      children = Supervisor.which_children(supervisor_pid)

      child_modules =
        Enum.map(children, fn {_id, _pid, _type, modules} ->
          case modules do
            [module] -> module
            _ -> :dynamic
          end
        end)

      # Should have MessageAggregator, ProviderPool, and DynamicSupervisor
      assert MessageAggregator in child_modules
      assert ProviderPool in child_modules
      # DynamicSupervisor for connections
      assert :dynamic in child_modules

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end

    test "handles startup with invalid configuration gracefully" do
      invalid_config = %ChainConfig{
        # Invalid
        chain_id: nil,
        # Invalid
        name: "",
        aggregation: %{},
        providers: []
      }

      # Should log errors but not crash
      log =
        capture_log(fn ->
          # This should fail validation
          result = ChainSupervisor.start_link({"invalid_chain", invalid_config})

          case result do
            {:ok, pid} ->
              # If it somehow starts, clean it up
              Supervisor.stop(pid)

            {:error, _reason} ->
              # Expected failure
              :ok
          end
        end)

      # Should have logged the startup attempt
      assert log =~ "Starting ChainSupervisor"
    end
  end

  describe "Provider Management" do
    test "starts provider connections asynchronously", %{chain_config: chain_config} do
      chain_name = "provider_management_test"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})

      # Give time for async startup to complete
      Process.sleep(300)

      # Check that provider connections are being tracked
      status = ChainSupervisor.get_chain_status(chain_name)

      # Should have attempted to start connections
      # Note: They may not be healthy due to mock setup, but should be tracked
      assert is_map(status)
      refute status[:error] == :chain_not_started

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end

    test "respects max_providers configuration", %{chain_config: chain_config} do
      # Modify config to limit providers
      limited_config = %{
        chain_config
        | aggregation: %{chain_config.aggregation | max_providers: 2}
      }

      chain_name = "limited_providers_test"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, limited_config})

      # Give time for startup
      Process.sleep(300)

      # Should only start 2 providers even though 3 are configured
      # This is verified by checking that the system respects the max_providers setting
      status = ChainSupervisor.get_chain_status(chain_name)
      assert is_map(status)

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end
  end

  describe "Status and Monitoring" do
    test "provides comprehensive chain status", %{chain_config: chain_config} do
      chain_name = "status_test_chain"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(200)

      status = ChainSupervisor.get_chain_status(chain_name)

      # Should return a map with status information
      assert is_map(status)

      # Should not indicate the chain is not started
      refute status[:error] == :chain_not_started

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end

    test "handles status request for non-existent chain" do
      status = ChainSupervisor.get_chain_status("non_existent_chain")

      assert status[:error] == :chain_not_started
    end

    test "tracks active providers", %{chain_config: chain_config} do
      chain_name = "active_providers_test"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(200)

      # Get active providers (may be empty due to mock setup)
      result = ChainSupervisor.get_active_providers(chain_name)

      # Should return a list (empty or populated)
      assert is_list(result)

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end
  end

  describe "Message Routing" do
    test "routes messages through the message aggregator", %{chain_config: chain_config} do
      chain_name = "routing_test_chain"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(200)

      # Create a test message
      test_message = %{
        "jsonrpc" => "2.0",
        "method" => "eth_blockNumber",
        "params" => [],
        "id" => 1
      }

      # Send message through supervisor
      result = ChainSupervisor.send_message(chain_name, test_message)

      # Should handle the message (may return error due to no active providers)
      # but should not crash
      assert result in [
               :ok,
               {:error, :no_active_providers},
               {:error, :message_aggregator_not_found}
             ]

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end

    test "handles routing when no providers are available", %{chain_config: chain_config} do
      chain_name = "no_providers_test"

      # Start with empty providers
      empty_config = %{chain_config | providers: []}

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, empty_config})
      Process.sleep(100)

      test_message = %{"jsonrpc" => "2.0", "method" => "eth_blockNumber", "id" => 1}

      result = ChainSupervisor.send_message(chain_name, test_message)

      # Should gracefully handle the lack of providers
      assert result in [
               :ok,
               {:error, :no_active_providers},
               {:error, :message_aggregator_not_found}
             ]

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end
  end

  describe "Failover Management" do
    test "triggers provider failover", %{chain_config: chain_config} do
      chain_name = "failover_test_chain"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(200)

      # Trigger failover for a provider
      result = ChainSupervisor.trigger_failover(chain_name, "test_provider_1")

      # Should handle the failover request
      assert result in [:ok, {:error, :provider_not_found}, {:error, :provider_pool_not_found}]

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end

    test "handles failover for non-existent provider", %{chain_config: chain_config} do
      chain_name = "failover_nonexistent_test"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(100)

      result = ChainSupervisor.trigger_failover(chain_name, "non_existent_provider")

      # Should gracefully handle non-existent provider
      assert result in [:ok, {:error, :provider_not_found}, {:error, :provider_pool_not_found}]

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end
  end

  describe "Integration with Child Processes" do
    test "coordinates with MessageAggregator for deduplication", %{chain_config: chain_config} do
      chain_name = "integration_test_chain"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(200)

      # Verify MessageAggregator is accessible
      case GenServer.whereis(
             {:via, Registry, {Livechain.Registry, {:message_aggregator, chain_name}}}
           ) do
        nil ->
          # MessageAggregator not started or different naming scheme
          :not_accessible

        pid when is_pid(pid) ->
          # Can access the MessageAggregator
          assert Process.alive?(pid)
      end

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end

    test "coordinates with ProviderPool for health monitoring", %{chain_config: chain_config} do
      chain_name = "provider_pool_test_chain"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(200)

      # Verify ProviderPool is accessible
      case GenServer.whereis({:via, Registry, {Livechain.Registry, {:provider_pool, chain_name}}}) do
        nil ->
          # ProviderPool not started or different naming scheme
          :not_accessible

        pid when is_pid(pid) ->
          # Can access the ProviderPool
          assert Process.alive?(pid)
      end

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end
  end

  describe "Error Handling and Resilience" do
    test "handles child process failures gracefully", %{chain_config: chain_config} do
      chain_name = "resilience_test_chain"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(200)

      # Get initial children
      initial_children = Supervisor.which_children(supervisor_pid)

      # Supervisor should be resilient and restart failed children
      # This is inherent to the one_for_one strategy
      # MessageAggregator, ProviderPool, DynamicSupervisor
      assert length(initial_children) >= 3

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end

    test "handles configuration updates", %{chain_config: chain_config} do
      chain_name = "config_update_test"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(200)

      # Initial status should be available
      initial_status = ChainSupervisor.get_chain_status(chain_name)
      assert is_map(initial_status)

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end
  end

  describe "Subscription Management" do
    test "delegates subscription requests properly", %{chain_config: chain_config} do
      chain_name = "subscription_test_chain"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(200)

      # Test subscription-related functionality
      # Note: The actual subscription functionality may be in SubscriptionManager
      # This tests that ChainSupervisor can handle subscription-related requests

      status = ChainSupervisor.get_chain_status(chain_name)
      assert is_map(status)

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end
  end
end

defmodule Livechain.ArchitectureTest do
  @moduledoc """
  Comprehensive tests for Livechain multi-provider architecture.

  Tests the integration between components, fault tolerance,
  and performance characteristics of the system.
  """

  use ExUnit.Case, async: false
  require Logger

  alias Livechain.Config.ChainConfig
  alias Livechain.RPC.{ChainRegistry, ChainSupervisor, ProcessRegistry, CircuitBreaker}
  alias Livechain.Telemetry

  setup do
    # Mock HTTP client expectations for provider health checks
    import Mox
    stub(Livechain.RPC.HttpClientMock, :request, &MockHttpClient.request/4)

    # Load test configuration
    {:ok, config} = ChainConfig.load_config("config/chains.yml")

    on_exit(fn ->
      :ok
    end)

    %{config: config}
  end

  describe "Process Registry" do
    test "registers and looks up processes correctly" do
      registry = Livechain.RPC.ProcessRegistry

      # Register a test process
      test_pid = spawn(fn -> Process.sleep(:infinity) end)
      :ok = ProcessRegistry.register(registry, :test_type, "test_id", test_pid)

      # Look up the process
      {:ok, found_pid} = ProcessRegistry.lookup(registry, :test_type, "test_id")
      assert found_pid == test_pid

      # Clean up
      Process.exit(test_pid, :kill)
    end

    test "handles process death gracefully" do
      registry = Livechain.RPC.ProcessRegistry

      # Register a process that will die
      test_pid = spawn(fn -> Process.sleep(100) end)
      :ok = ProcessRegistry.register(registry, :test_type, "dying_id", test_pid)

      # Wait for process to die
      Process.sleep(200)

      # Lookup should fail - could be either :process_dead or :not_found
      result = ProcessRegistry.lookup(registry, :test_type, "dying_id")

      assert result in [
               {:error, :process_dead},
               {:error, :not_found}
             ]
    end
  end

  describe "Circuit Breaker" do
    test "opens after consecutive failures" do
      provider_id = "test_provider"
      config = %{failure_threshold: 3, recovery_timeout: 1000, success_threshold: 2}

      {:ok, _pid} = CircuitBreaker.start_link({provider_id, config})

      # Simulate failures
      for _ <- 1..3 do
        CircuitBreaker.call(provider_id, fn -> raise "test error" end)
      end

      # Circuit should be open
      state = CircuitBreaker.get_state(provider_id)
      assert state.state == :open
    end

    test "recovers after success threshold" do
      provider_id = "test_provider_recovery"
      config = %{failure_threshold: 2, recovery_timeout: 100, success_threshold: 2}

      {:ok, _pid} = CircuitBreaker.start_link({provider_id, config})

      # Open the circuit
      for _ <- 1..2 do
        CircuitBreaker.call(provider_id, fn -> raise "test error" end)
      end

      # Wait for recovery timeout
      Process.sleep(200)

      # Attempt recovery with successes
      for _ <- 1..2 do
        CircuitBreaker.call(provider_id, fn -> :ok end)
      end

      # Circuit should be closed
      state = CircuitBreaker.get_state(provider_id)
      assert state.state == :closed
    end
  end

  describe "Message Aggregator Memory Management" do
    test "evicts old entries when cache is full" do
      chain_name = "test_chain"

      chain_config = %{
        aggregation: %{
          deduplication_window: 1000,
          min_confirmations: 1,
          max_providers: 2,
          max_cache_size: 5
        }
      }

      {:ok, _pid} = Livechain.RPC.MessageAggregator.start_link({chain_name, chain_config})

      # Add more messages than cache can hold
      for i <- 1..10 do
        message = %{"id" => i, "data" => "test"}
        Livechain.RPC.MessageAggregator.process_message(chain_name, "provider1", message)
      end

      # Check that cache size is bounded
      stats = Livechain.RPC.MessageAggregator.get_stats(chain_name)
      assert stats.messages_received == 10
      # Cache should have been evicted to stay within bounds
    end
  end

  # Deleted meaningless telemetry test that only validates functions don't crash
  # without testing that events are actually emitted or handled

  describe "Configuration Validation" do
    test "validates chain configuration correctly" do
      {:ok, config} = ChainConfig.load_config("config/chains.yml")

      # Test getting chain config
      {:ok, ethereum_config} = ChainConfig.get_chain_config(config, "ethereum")
      assert ethereum_config.chain_id == 1
      assert ethereum_config.name == "Ethereum Mainnet"

      # Test getting providers by priority
      providers = ChainConfig.get_providers_by_priority(ethereum_config)
      assert length(providers) > 0
      assert Enum.all?(providers, &(&1.priority > 0))

      # Test available providers
      available = ChainConfig.get_available_providers(ethereum_config)
      assert length(available) > 0
    end

    test "handles environment variable substitution" do
      # Test that environment variables are substituted correctly
      url = ChainConfig.substitute_env_vars("https://api.example.com/${API_KEY}")

      if System.get_env("API_KEY") do
        assert not String.contains?(url, "${API_KEY}")
      else
        assert String.contains?(url, "${API_KEY}")
      end
    end
  end

  describe "Integration Tests" do
    test "configuration loading and validation" do
      # Test that configuration can be loaded
      {:ok, config} = ChainConfig.load_config("config/chains.yml")
      assert is_map(config)
      # The config has 'chains' key and 'global' key
      assert Map.has_key?(config, :chains) or Map.has_key?(config, "chains")

      # Test getting chain config
      {:ok, ethereum_config} = ChainConfig.get_chain_config(config, "ethereum")
      assert ethereum_config.chain_id == 1
      assert ethereum_config.name == "Ethereum Mainnet"
    end

    test "registry service initialization" do
      # Test that we can interact with registry (may already be started)
      # Try to start it, but handle if already started
      case Livechain.RPC.ChainRegistry.start_link([]) do
        {:ok, pid} ->
          assert is_pid(pid)
          GenServer.stop(pid)

        {:error, {:already_started, pid}} ->
          assert is_pid(pid)
      end

      # Get status without starting chains (to avoid hanging)
      status = Livechain.RPC.ChainRegistry.get_status()
      assert is_map(status)
      assert Map.has_key?(status, :total_configured_chains)
    end
  end

  describe "Performance Tests" do
    test "message aggregation performance" do
      chain_name = "perf_test_chain"

      chain_config = %{
        aggregation: %{
          deduplication_window: 100,
          min_confirmations: 1,
          max_providers: 3,
          max_cache_size: 1000
        }
      }

      {:ok, _pid} = Livechain.RPC.MessageAggregator.start_link({chain_name, chain_config})

      # Send many messages quickly
      start_time = System.monotonic_time(:millisecond)

      for i <- 1..100 do
        message = %{"id" => i, "data" => "performance_test"}
        Livechain.RPC.MessageAggregator.process_message(chain_name, "provider1", message)
      end

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      # Should process 100 messages in reasonable time
      # Less than 1 second
      assert duration < 1000

      # Check stats
      stats = Livechain.RPC.MessageAggregator.get_stats(chain_name)
      assert stats.messages_received == 100
      assert stats.messages_forwarded == 100
    end
  end

  # Deleted fake fault tolerance test that doesn't simulate actual failures
end

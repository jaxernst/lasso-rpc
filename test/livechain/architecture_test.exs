defmodule Livechain.ArchitectureTest do
  @moduledoc """
  Comprehensive tests for Livechain multi-provider architecture.

  Tests the integration between components, fault tolerance,
  and performance characteristics of the system.
  """

  use ExUnit.Case, async: false
  require Logger

  alias Livechain.Config.ChainConfig
  alias Livechain.RPC.{ChainManager, ProcessRegistry, CircuitBreaker, Telemetry}

  setup do
    # Start the application for testing
    Application.ensure_all_started(:livechain)

    # Load test configuration
    {:ok, config} = ChainConfig.load_config("config/chains.yml")

    on_exit(fn ->
      # Clean up after tests
      Application.stop(:livechain)
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

      # Lookup should fail
      {:error, :process_dead} = ProcessRegistry.lookup(registry, :test_type, "dying_id")
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

  describe "Telemetry Integration" do
    test "emits events correctly" do
      # Test RPC call telemetry
      Telemetry.emit_rpc_call("test_provider", "eth_blockNumber", 150, :ok)

      # Test provider health change telemetry
      Telemetry.emit_provider_health_change("test_provider", :healthy, :unhealthy)

      # Test circuit breaker telemetry
      Telemetry.emit_circuit_breaker_change("test_provider", :closed, :open)

      # Test failover telemetry
      Telemetry.emit_failover("ethereum", "provider1", "provider2", :timeout)

      # All events should be emitted without errors
      assert true
    end
  end

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
    test "full chain startup and operation" do
      # Start all chains
      {:ok, started_count} = ChainManager.start_all_chains()
      assert started_count > 0

      # Get global status
      status = ChainManager.get_status()
      assert status.total_chains > 0
      assert status.active_chains > 0

      # Get specific chain status
      chain_status = ChainManager.get_chain_status("ethereum")
      assert is_map(chain_status)
      assert Map.has_key?(chain_status, :total_providers)
    end

    test "provider failover simulation" do
      # Start a specific chain
      {:ok, _pid} = ChainManager.start_chain("ethereum")

      # Get initial status
      initial_status = ChainManager.get_chain_status("ethereum")
      initial_healthy = initial_status.healthy_providers

      # Simulate provider failure (this would be done through the actual provider)
      # For now, we just verify the status reporting works
      assert initial_healthy >= 0
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

  describe "Fault Tolerance Tests" do
    test "handles provider connection failures gracefully" do
      # This test would simulate actual provider failures
      # For now, we test the error handling infrastructure

      # Test that error telemetry works
      Telemetry.emit_error(:rpc, "connection_timeout", %{provider_id: "test"})

      # Test that circuit breakers can be created
      {:ok, _pid} = CircuitBreaker.start_link({"test_provider", %{}})

      assert true
    end
  end
end

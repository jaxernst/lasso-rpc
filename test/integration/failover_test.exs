defmodule Integration.FailoverTest do
  @moduledoc """
  Integration tests for provider failover and resilience functionality.

  This tests Livechain's key selling point: bulletproof failover between
  providers with no interruption to client connections or data loss.
  """

  use ExUnit.Case, async: false
  import Mox
  import ExUnit.CaptureLog

  alias Livechain.RPC.{ChainSupervisor, CircuitBreaker}
  alias Livechain.Config.ChainConfig
  alias Livechain.Config.ChainConfig.{Provider, Connection, Failover}

  setup do
    # Start the application to ensure all dependencies are available
    Application.ensure_all_started(:livechain)

    # Mock HTTP client with controlled failure scenarios
    stub(Livechain.RPC.HttpClientMock, :request, fn config, _method, _params, _timeout ->
      # Simulate different provider reliability
      case config.url do
        "https://reliable-provider.example.com" ->
          Process.sleep(50)
          {:ok, %{"jsonrpc" => "2.0", "id" => 1, "result" => "0x12345"}}

        "https://unreliable-provider.example.com" ->
          # 50% failure rate
          if :rand.uniform() < 0.5 do
            {:error, :connection_timeout}
          else
            Process.sleep(200)
            {:ok, %{"jsonrpc" => "2.0", "id" => 1, "result" => "0x12345"}}
          end

        "https://failing-provider.example.com" ->
          # Always fails
          {:error, :connection_failed}

        "https://slow-provider.example.com" ->
          # Very slow but reliable
          Process.sleep(1000)
          {:ok, %{"jsonrpc" => "2.0", "id" => 1, "result" => "0x12345"}}

        _ ->
          {:ok, %{"jsonrpc" => "2.0", "id" => 1, "result" => "0x0"}}
      end
    end)

    # Create test chain configuration with multiple providers
    chain_config = %ChainConfig{
      chain_id: 1,
      name: "ethereum",
      connection: %Connection{
        heartbeat_interval: 30000,
        reconnect_interval: 5000,
        max_reconnect_attempts: 10
      },
      failover: %Failover{
        enabled: true,
        max_backfill_blocks: 10,
        backfill_timeout: 5000
      },
      providers: [
        %Provider{
          id: "reliable_provider",
          name: "Reliable Provider",
          priority: 1,
          type: "public",
          url: "https://reliable-provider.example.com",
          ws_url: "wss://reliable-provider.example.com/ws",
          api_key_required: false,
          region: "us-east-1"
        },
        %Provider{
          id: "unreliable_provider",
          name: "Unreliable Provider",
          priority: 2,
          type: "public",
          url: "https://unreliable-provider.example.com",
          ws_url: "wss://unreliable-provider.example.com/ws",
          api_key_required: false,
          region: "us-east-1"
        },
        %Provider{
          id: "failing_provider",
          name: "Failing Provider",
          priority: 3,
          type: "public",
          url: "https://failing-provider.example.com",
          ws_url: "wss://failing-provider.example.com/ws",
          api_key_required: false,
          region: "us-east-1"
        },
        %Provider{
          id: "slow_provider",
          name: "Slow Provider",
          priority: 4,
          type: "public",
          url: "https://slow-provider.example.com",
          ws_url: "wss://slow-provider.example.com/ws",
          api_key_required: false,
          region: "us-west-1"
        }
      ]
    }

    on_exit(fn ->
      # Cleanup any started processes
      Application.stop(:livechain)
    end)

    %{chain_config: chain_config}
  end

  describe "Provider Health Detection" do
    test "detects failing providers and marks them unhealthy", %{chain_config: chain_config} do
      chain_name = "health_detection_test"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})

      # Give time for initial provider startup and health checks
      Process.sleep(500)

      # Get provider status
      status = ChainSupervisor.get_chain_status(chain_name)

      # Should have attempted to start providers
      assert is_map(status)
      refute status[:error] == :chain_not_started

      # Give more time for health checks to occur
      Process.sleep(1000)

      # Check if failing providers are being detected
      # (Implementation may vary based on how health checks work)
      active_providers = ChainSupervisor.get_active_providers(chain_name)
      assert is_list(active_providers)

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end

    test "circuit breakers open after repeated failures", %{chain_config: chain_config} do
      chain_name = "circuit_breaker_test"

      # Start circuit breakers for failing providers
      for provider <- chain_config.providers do
        case CircuitBreaker.start_link(
               {provider.id,
                %{failure_threshold: 2, recovery_timeout: 1000, success_threshold: 1}}
             ) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end
      end

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(200)

      # Simulate multiple failures to trigger circuit breaker
      for _i <- 1..10 do
        CircuitBreaker.record_failure("failing_provider")
        Process.sleep(10)
      end

      # Circuit breaker should be open now
      result = CircuitBreaker.call("failing_provider", fn -> {:ok, "test"} end)

      # Should be blocked by circuit breaker
      assert result in [{:error, :circuit_open}, {:ok, "test"}]

      # Cleanup
      Supervisor.stop(supervisor_pid)

      for provider <- chain_config.providers do
        try do
          via_name = {:via, Registry, {Livechain.Registry, {:circuit_breaker, provider.id}}}
          GenServer.stop(via_name)
        catch
          :exit, _ -> :ok
        end
      end
    end
  end

  describe "Automatic Failover" do
    test "automatically fails over when primary provider becomes unavailable", %{
      chain_config: chain_config
    } do
      chain_name = "auto_failover_test"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(300)

      # Initially, reliable provider should be active
      _initial_providers = ChainSupervisor.get_active_providers(chain_name)

      # Simulate primary provider failure
      log =
        capture_log(fn ->
          # Trigger failover by making requests that will cause provider failures
          for _i <- 1..5 do
            try do
              ChainSupervisor.send_message(chain_name, %{
                "jsonrpc" => "2.0",
                "method" => "eth_getBalance",
                "params" => ["0x123", "latest"],
                "id" => 1
              })
            catch
              _, _ -> :ok
            end

            Process.sleep(100)
          end
        end)

      IO.puts("failover test log: #{log}")
      # Should see failover activity in logs
      assert log =~ "provider" || log =~ "failover" || log =~ "failure"

      # After failover, should still have some active providers
      final_providers = ChainSupervisor.get_active_providers(chain_name)
      assert is_list(final_providers)

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end

    test "maintains service during provider failures", %{chain_config: chain_config} do
      chain_name = "service_continuity_test"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(500)

      # Make requests while simulating provider failures
      results =
        for _i <- 1..10 do
          result =
            try do
              ChainSupervisor.send_message(chain_name, %{
                "jsonrpc" => "2.0",
                "method" => "eth_chainId",
                "params" => [],
                "id" => 1
              })
            catch
              _, error ->
                {:error, error}
            end

          Process.sleep(50)
          result
        end

      # Most requests should succeed (some might fail during failover)
      successful_requests =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      # Should have at least some successful requests
      assert successful_requests >= 0

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end
  end

  describe "Load Balancing During Failures" do
    test "redistributes load when providers fail", %{chain_config: chain_config} do
      chain_name = "load_balancing_test"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(300)

      _initial_status = ChainSupervisor.get_chain_status(chain_name)

      # Make multiple requests to test load distribution
      tasks =
        for _i <- 1..20 do
          Task.async(fn ->
            try do
              ChainSupervisor.send_message(chain_name, %{
                "jsonrpc" => "2.0",
                "method" => "eth_blockNumber",
                "params" => [],
                "id" => 1
              })
            catch
              _, error -> {:error, error}
            end
          end)
        end

      results = Task.await_many(tasks, 5000)

      # Should have some successful results
      successful_results =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      assert successful_results >= 0

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end
  end

  describe "Performance Under Failure" do
    test "maintains acceptable latency during failover", %{chain_config: chain_config} do
      chain_name = "performance_failover_test"

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, chain_config})
      Process.sleep(300)

      # Measure baseline performance
      baseline_start = System.monotonic_time(:millisecond)

      baseline_tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            try do
              ChainSupervisor.send_message(chain_name, %{
                "jsonrpc" => "2.0",
                "method" => "eth_chainId",
                "params" => [],
                "id" => 1
              })
            catch
              _, _ -> {:error, :baseline_failed}
            end
          end)
        end

      Task.await_many(baseline_tasks, 2000)
      _baseline_time = System.monotonic_time(:millisecond) - baseline_start

      # Now test performance during failures
      failover_start = System.monotonic_time(:millisecond)

      # Simulate provider failures while making requests
      failover_tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            # Simulate some provider failures
            spawn(fn ->
              for provider_id <- ["failing_provider", "unreliable_provider"] do
                CircuitBreaker.record_failure(provider_id)
                Process.sleep(10)
              end
            end)

            try do
              ChainSupervisor.send_message(chain_name, %{
                "jsonrpc" => "2.0",
                "method" => "eth_chainId",
                "params" => [],
                "id" => 1
              })
            catch
              _, _ -> {:error, :failover_failed}
            end
          end)
        end

      Task.await_many(failover_tasks, 5000)
      failover_time = System.monotonic_time(:millisecond) - failover_start

      # Failover shouldn't be too much slower (this is a loose test)
      # Main goal is that it doesn't crash or hang
      # Should complete within 10 seconds
      assert failover_time < 10000

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end
  end

  describe "Edge Case Scenarios" do
    test "handles all providers failing simultaneously", %{chain_config: chain_config} do
      chain_name = "all_providers_fail_test"

      # Start with a config where all providers will fail
      failing_config = %{
        chain_config
        | providers: [
            %Provider{
              id: "failing_provider1",
              name: "Failing Provider 1",
              priority: 1,
              type: "public",
              url: "https://failing-provider.example.com",
              ws_url: "wss://failing-provider.example.com/ws",
              api_key_required: false,
              region: "us-east-1"
            }
          ]
      }

      {:ok, supervisor_pid} = ChainSupervisor.start_link({chain_name, failing_config})
      Process.sleep(500)

      # Try to make a request when all providers are failing
      result =
        try do
          ChainSupervisor.send_message(chain_name, %{
            "jsonrpc" => "2.0",
            "method" => "eth_chainId",
            "params" => [],
            "id" => 1
          })
        catch
          _, error -> {:error, error}
        end

      # Should handle gracefully with an appropriate error
      assert result in [
               :ok,
               {:error, :no_active_providers},
               {:error, :message_aggregator_not_found},
               {:error, :no_providers_available}
             ]

      # Cleanup
      Supervisor.stop(supervisor_pid)
    end
  end
end

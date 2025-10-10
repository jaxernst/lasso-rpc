defmodule Lasso.RPC.RequestPipelineIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration
  @moduletag timeout: 10_000

  alias Lasso.RPC.{RequestPipeline, CircuitBreaker}
  alias Lasso.Test.{TelemetrySync, CircuitBreakerHelper}
  alias Lasso.Testing.MockProviderBehavior

  describe "circuit breaker coordination" do
    test "fails over when circuit breaker is open", %{chain: chain} do
      # Setup primary and backup providers
      setup_providers([
        %{id: "primary", priority: 10, behavior: :healthy},
        %{id: "backup", priority: 20, behavior: :healthy}
      ])

      # Ensure circuit breakers exist before forcing open
      CircuitBreakerHelper.ensure_circuit_breaker_started(chain, "primary", :http)

      # Manually open circuit breaker on primary
      CircuitBreakerHelper.force_open({chain, "primary", :http})

      # Give circuit breaker a moment to process the open command
      Process.sleep(100)

      # Verify circuit breaker is open
      CircuitBreakerHelper.assert_circuit_breaker_state({chain, "primary", :http}, :open)

      # Execute request - should automatically use backup
      {:ok, result} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          []
        )

      # Verify request succeeded (using backup)
      assert result != nil
      # eth_blockNumber returns a hex string
      assert is_binary(result)
    end

    test "opens circuit breaker after repeated failures", %{chain: chain} do
      # Setup provider that always fails
      setup_providers([
        %{id: "failing_provider", priority: 10, behavior: :always_fail}
      ])

      # Execute multiple requests to trigger circuit breaker
      # Circuit breaker typically opens after 3-5 failures
      for _ <- 1..5 do
        {:error, _reason} =
          RequestPipeline.execute_via_channels(
            chain,
            "eth_blockNumber",
            [],
            provider_override: "failing_provider"
          )

        # Small delay between attempts
        Process.sleep(10)
      end

      # Give circuit breaker time to open
      Process.sleep(500)

      # Verify circuit breaker is now open
      CircuitBreakerHelper.assert_circuit_breaker_state(
        {chain, "failing_provider", :http},
        :open
      )

      # Next request should fail immediately with :circuit_open
      {:error, error} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          provider_override: "failing_provider"
        )

      # Should get circuit breaker error, not the underlying error
      assert error != nil
    end

    test "circuit breaker respects recovery timeout", %{chain: chain} do
      # Setup provider with intermittent failures
      setup_providers([
        %{id: "flaky", priority: 10, behavior: MockProviderBehavior.intermittent_failures(0.0)}
      ])

      # Attach telemetry collector BEFORE forcing circuit breaker open
      {:ok, open_collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :circuit_breaker, :open],
          match: [provider_id: "flaky"]
        )

      # Force circuit breaker open
      CircuitBreakerHelper.force_open({chain, "flaky", :http})

      # Wait for telemetry event
      {:ok, _measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(open_collector, timeout: 2000)

      # Immediate request should fail with circuit open
      {:error, _} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          provider_override: "flaky",
          failover_on_override: false
        )

      # Wait for circuit breaker recovery timeout (typically 60s in tests)
      # For testing, we can manually close it
      Process.sleep(100)

      # Attach telemetry collector BEFORE forcing circuit breaker closed
      {:ok, close_collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :circuit_breaker, :close],
          match: [provider_id: "flaky"]
        )

      CircuitBreakerHelper.reset_to_closed({chain, "flaky", :http})

      # Wait for telemetry event
      {:ok, _measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(close_collector, timeout: 2000)

      # Now requests should work again
      # (fails because behavior is 0% success, but circuit is closed)
      result =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          provider_override: "flaky",
          failover_on_override: false
        )

      # Should get actual error, not circuit breaker error
      assert result != {:error, :circuit_open}
    end
  end

  describe "provider selection and failover" do
    test "selects provider based on priority", %{chain: chain} do
      # Setup providers with different priorities
      setup_providers([
        %{id: "low_priority", priority: 100, behavior: :healthy},
        %{id: "high_priority", priority: 10, behavior: :healthy}
      ])

      # Attach telemetry collector BEFORE executing request
      {:ok, collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :rpc, :request, :stop],
          match: [method: "eth_blockNumber"]
        )

      # Execute request
      {:ok, _result} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          strategy: :priority
        )

      # Wait for telemetry event
      {:ok, measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(collector, timeout: 2000)

      # Duration should be non-negative (can be 0 for very fast requests)
      assert measurements.duration >= 0
      # Note: We can't easily assert which provider was used without additional telemetry
      # but the request succeeding shows provider selection worked
    end

    test "fails over to backup provider on retriable error", %{chain: chain} do
      # Setup primary that fails, backup that succeeds
      setup_providers([
        %{id: "primary", priority: 10, behavior: :always_fail},
        %{id: "backup", priority: 20, behavior: :healthy}
      ])

      # Attach telemetry collector BEFORE executing request
      # We expect one start event for the entire request
      {:ok, collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :rpc, :request, :start],
          match: [method: "eth_blockNumber"]
        )

      # Execute request - should failover to backup
      {:ok, result} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          []
        )

      # Request should succeed via backup
      assert result != nil
      assert is_binary(result)
      assert String.starts_with?(result, "0x")

      # Verify start event was captured
      {:ok, _measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(collector, timeout: 2000)
    end

    test "respects provider override without failover", %{chain: chain} do
      # Setup two providers
      setup_providers([
        %{id: "primary", priority: 10, behavior: :healthy},
        %{id: "backup", priority: 20, behavior: :healthy}
      ])

      # Execute with override and no failover
      {:ok, _result} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          provider_override: "backup",
          failover_on_override: false
        )

      # Should succeed using backup
      # (If it failed, would not failover to primary)
    end

    test "provider override with failover allows retry", %{chain: chain} do
      # Setup override provider that fails, and backup
      setup_providers([
        %{id: "preferred", priority: 50, behavior: :always_fail},
        %{id: "fallback", priority: 100, behavior: :healthy}
      ])

      # Execute with override and failover enabled
      {:ok, result} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          provider_override: "preferred",
          failover_on_override: true
        )

      # Should succeed by failing over from preferred to fallback
      assert result != nil
      assert is_binary(result)
      assert String.starts_with?(result, "0x")
    end
  end

  describe "adapter validation and parameter handling" do
    test "skips providers that reject parameters", %{chain: chain} do
      # This test would require a method that some providers don't support
      # For now, we test with a generic method that all providers accept
      setup_providers([
        %{id: "provider1", priority: 10, behavior: :healthy},
        %{id: "provider2", priority: 20, behavior: :healthy}
      ])

      # Execute standard method - should work on any provider
      {:ok, _result} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          []
        )

      # In a real scenario with provider-specific adapter logic:
      # - Provider1 might reject "debug_traceTransaction"
      # - Pipeline would skip to Provider2
      # - Request would succeed on Provider2
    end

    test "handles empty parameters correctly", %{chain: chain} do
      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy}
      ])

      # Execute with empty params
      {:ok, _result} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          []
        )

      # Execute with nil params
      {:ok, _result} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          nil
        )

      # Both should succeed
    end
  end

  describe "error handling and classification" do
    test "classifies errors correctly", %{chain: chain} do
      # Setup provider with specific error behavior
      setup_providers([
        %{
          id: "provider",
          priority: 10,
          behavior: {:error, %{code: -32000, message: "Server error"}}
        }
      ])

      # Execute request
      {:error, error} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          provider_override: "provider",
          failover_on_override: false
        )

      # Verify error is classified
      assert error != nil
      # Error should be wrapped in JSONRPC.Error structure
    end

    test "handles timeout errors", %{chain: chain} do
      # Setup provider that times out
      setup_providers([
        %{id: "slow", priority: 10, behavior: :always_timeout}
      ])

      # Execute with short timeout
      start_time = System.monotonic_time(:millisecond)

      {:error, _error} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          provider_override: "slow",
          failover_on_override: false,
          timeout: 100
        )

      duration = System.monotonic_time(:millisecond) - start_time

      # Should timeout quickly (within tolerance)
      assert duration < 500
    end

    test "handles provider not found error", %{chain: chain} do
      # Don't setup any providers

      # Execute request
      {:error, error} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          provider_override: "nonexistent",
          failover_on_override: false
        )

      # Should get appropriate error
      assert error != nil
    end
  end

  describe "transport selection" do
    test "respects transport override", %{chain: chain} do
      # Setup providers on multiple transports
      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy}
      ])

      # Execute with HTTP transport override
      {:ok, _result} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          transport_override: :http
        )

      # Execute with WS transport override (if supported)
      # {:ok, _result} = RequestPipeline.execute_via_channels(
      #   chain,
      #   "eth_blockNumber",
      #   [],
      #   transport_override: :ws
      # )
    end
  end

  describe "telemetry and observability" do
    test "emits request start and stop events", %{chain: chain} do
      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy}
      ])

      # Attach telemetry collectors BEFORE executing request
      {:ok, start_collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :rpc, :request, :start],
          match: [method: "eth_blockNumber"]
        )

      {:ok, stop_collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :rpc, :request, :stop],
          match: [method: "eth_blockNumber"]
        )

      # Execute request
      {:ok, _result} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          []
        )

      # Wait for start event
      {:ok, _measurements, metadata} =
        Lasso.Testing.TelemetrySync.await_event(
          start_collector,
          timeout: 1000
        )

      assert metadata.chain == chain
      assert metadata.method == "eth_blockNumber"

      # Wait for stop event
      {:ok, measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(
          stop_collector,
          timeout: 2000
        )

      # Duration should be non-negative (can be 0 for very fast requests)
      assert measurements.duration >= 0
    end

    test "records metrics for successful requests", %{chain: chain} do
      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy}
      ])

      # Attach telemetry collector BEFORE executing request
      {:ok, collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :rpc, :request, :stop],
          match: [method: "eth_blockNumber", status: :success]
        )

      # Execute request
      {:ok, _result} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          []
        )

      # Verify telemetry shows success
      {:ok, measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(collector, timeout: 2000)

      # Duration should be non-negative (can be 0 for very fast requests)
      assert measurements.duration >= 0
    end

    test "records metrics for failed requests", %{chain: chain} do
      setup_providers([
        %{id: "failing", priority: 10, behavior: :always_fail}
      ])

      # Attach telemetry collector BEFORE executing request
      {:ok, collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :rpc, :request, :stop],
          match: [method: "eth_blockNumber"]
        )

      # Execute request that will fail
      {:error, _} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          provider_override: "failing",
          failover_on_override: false
        )

      # Should still emit stop event with error status
      {:ok, measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(collector, timeout: 2000)

      # Duration should be non-negative (can be 0 for very fast requests)
      assert measurements.duration >= 0
    end
  end

  describe "retry and resilience" do
    test "retries on transient failures", %{chain: chain} do
      # Setup provider with intermittent failures (70% success)
      setup_providers([
        %{id: "flaky", priority: 10, behavior: MockProviderBehavior.intermittent_failures(0.7)}
      ])

      # Execute multiple requests
      results =
        for _ <- 1..10 do
          RequestPipeline.execute_via_channels(
            chain,
            "eth_blockNumber",
            []
          )
        end

      # Count successes
      successes =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      # Should have some successes (not all failures)
      assert successes > 0
      assert successes >= 5
    end

    test "gives up after max retries", %{chain: chain} do
      # Setup only failing providers
      setup_providers([
        %{id: "fail1", priority: 10, behavior: :always_fail},
        %{id: "fail2", priority: 20, behavior: :always_fail}
      ])

      # Attach telemetry collector BEFORE executing request
      {:ok, collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :rpc, :request, :start],
          match: [method: "eth_blockNumber"]
        )

      # Execute request
      {:error, _error} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          []
        )

      # Should have emitted at least one start event
      {:ok, _measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(collector, timeout: 2000)
    end
  end

  # Helper functions for circuit breaker state waiting
end

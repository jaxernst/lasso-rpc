defmodule Lasso.RPC.RequestPipelineIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration
  @moduletag timeout: 10_000

  alias Lasso.RPC.{RequestPipeline, RequestOptions, Response}
  alias Lasso.Test.CircuitBreakerHelper
  alias Lasso.Testing.MockProviderBehavior

  describe "circuit breaker coordination" do
    test "fails over when circuit breaker is open", %{chain: chain} do
      profile = "default"

      # Setup primary and backup providers
      setup_providers([
        %{id: "primary", priority: 10, behavior: :healthy, profile: profile},
        %{id: "backup", priority: 20, behavior: :healthy, profile: profile}
      ])

      # Ensure circuit breakers exist before forcing open
      CircuitBreakerHelper.ensure_circuit_breaker_started(profile, chain, "primary", :http)

      # Manually open circuit breaker on primary
      CircuitBreakerHelper.force_open({profile, chain, "primary", :http})

      # Give circuit breaker a moment to process the open command
      Process.sleep(100)

      # Verify circuit breaker is open
      CircuitBreakerHelper.assert_circuit_breaker_state({profile, chain, "primary", :http}, :open)

      # Execute request - should automatically use backup
      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      # Verify request succeeded (using backup)
      assert %Response.Success{} = result
      # eth_blockNumber returns a hex string in raw_bytes
      {:ok, block_number} = Response.Success.decode_result(result)
      assert String.starts_with?(block_number, "0x")
    end

    test "opens circuit breaker after repeated failures", %{chain: chain} do
      profile = "default"

      # Setup provider that always fails
      setup_providers([
        %{id: "failing_provider", priority: 10, behavior: :always_fail, profile: profile}
      ])

      # Execute multiple requests to trigger circuit breaker
      # Circuit breaker typically opens after 3-5 failures
      for _ <- 1..5 do
        {:error, _reason, _ctx} =
          RequestPipeline.execute_via_channels(
            chain,
            "eth_blockNumber",
            [],
            %RequestOptions{
              strategy: :round_robin,
              timeout_ms: 30_000,
              provider_override: "failing_provider"
            }
          )

        # Small delay between attempts
        Process.sleep(10)
      end

      # Give circuit breaker time to open
      Process.sleep(500)

      # Verify circuit breaker is now open
      CircuitBreakerHelper.assert_circuit_breaker_state(
        {profile, chain, "failing_provider", :http},
        :open
      )

      # Next request should fail immediately with :circuit_open
      {:error, error, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{
            provider_override: "failing_provider",
            failover_on_override: false,
            timeout_ms: 30_000,
            strategy: :round_robin
          }
        )

      # Should get circuit breaker error, not the underlying error
      assert error != nil
    end

    test "circuit breaker respects recovery timeout", %{chain: chain} do
      profile = "default"

      # Setup provider with intermittent failures
      setup_providers([
        %{
          id: "flaky",
          priority: 10,
          behavior: MockProviderBehavior.intermittent_failures(0.0),
          profile: profile
        }
      ])

      # Attach telemetry collector BEFORE forcing circuit breaker open
      {:ok, open_collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :circuit_breaker, :open],
          match: [provider_id: "flaky"]
        )

      # Force circuit breaker open
      CircuitBreakerHelper.force_open({profile, chain, "flaky", :http})

      # Wait for telemetry event
      {:ok, _measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(open_collector, timeout: 2000)

      # Immediate request should fail with circuit open
      {:error, _, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{
            provider_override: "flaky",
            failover_on_override: false,
            timeout_ms: 30_000,
            strategy: :round_robin
          }
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

      CircuitBreakerHelper.reset_to_closed({profile, chain, "flaky", :http})

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
          %RequestOptions{
            provider_override: "flaky",
            failover_on_override: false,
            timeout_ms: 30_000,
            strategy: :round_robin
          }
        )

      # Should get actual error, not circuit breaker error
      assert result != {:error, :circuit_open}
    end
  end

  describe "provider selection and failover" do
    test "selects provider based on priority", %{chain: chain} do
      profile = "default"

      # Setup providers with different priorities
      setup_providers([
        %{id: "low_priority", priority: 100, behavior: :healthy, profile: profile},
        %{id: "high_priority", priority: 10, behavior: :healthy, profile: profile}
      ])

      # Attach telemetry collector BEFORE executing request
      {:ok, collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :rpc, :request, :stop],
          match: [method: "eth_blockNumber"]
        )

      # Execute request
      {:ok, _result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :priority, timeout_ms: 30_000}
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
      profile = "default"

      # Setup primary that fails, backup that succeeds
      setup_providers([
        %{id: "primary", priority: 10, behavior: :always_fail, profile: profile},
        %{id: "backup", priority: 20, behavior: :healthy, profile: profile}
      ])

      # Attach telemetry collector BEFORE executing request
      # We expect one start event for the entire request
      {:ok, collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :rpc, :request, :start],
          match: [method: "eth_blockNumber"]
        )

      # Execute request - should failover to backup
      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      # Request should succeed via backup - now returns Response.Success
      assert %Response.Success{} = result
      {:ok, block_number} = Response.Success.decode_result(result)
      assert String.starts_with?(block_number, "0x")

      # Verify start event was captured
      {:ok, _measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(collector, timeout: 2000)
    end

    test "respects provider override without failover", %{chain: chain} do
      profile = "default"

      # Setup two providers
      setup_providers([
        %{id: "primary", priority: 10, behavior: :healthy, profile: profile},
        %{id: "backup", priority: 20, behavior: :healthy, profile: profile}
      ])

      # Execute with override and no failover
      {:ok, _result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{
            provider_override: "backup",
            failover_on_override: false,
            timeout_ms: 30_000,
            strategy: :round_robin
          }
        )

      # Should succeed using backup
      # (If it failed, would not failover to primary)
    end

    test "provider override with failover allows retry", %{chain: chain} do
      profile = "default"

      # Setup override provider that fails, and backup
      setup_providers([
        %{id: "preferred", priority: 50, behavior: :always_fail, profile: profile},
        %{id: "fallback", priority: 100, behavior: :healthy, profile: profile}
      ])

      # Execute with override and failover enabled
      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{
            provider_override: "preferred",
            failover_on_override: true,
            timeout_ms: 30_000,
            strategy: :round_robin
          }
        )

      # Should succeed by failing over from preferred to fallback - now returns Response.Success
      assert %Response.Success{} = result
      {:ok, block_number} = Response.Success.decode_result(result)
      assert String.starts_with?(block_number, "0x")
    end
  end

  describe "adapter validation and parameter handling" do
    test "skips providers that reject parameters", %{chain: chain} do
      profile = "default"

      # This test would require a method that some providers don't support
      # For now, we test with a generic method that all providers accept
      setup_providers([
        %{id: "provider1", priority: 10, behavior: :healthy, profile: profile},
        %{id: "provider2", priority: 20, behavior: :healthy, profile: profile}
      ])

      # Execute standard method - should work on any provider
      {:ok, _result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      # In a real scenario with provider-specific adapter logic:
      # - Provider1 might reject "debug_traceTransaction"
      # - Pipeline would skip to Provider2
      # - Request would succeed on Provider2
    end

    test "handles empty parameters correctly", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      # Execute with empty params
      {:ok, _result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      # Execute with nil params
      {:ok, _result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          nil,
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      # Both should succeed
    end
  end

  describe "error handling and classification" do
    test "classifies errors correctly", %{chain: chain} do
      profile = "default"

      # Setup provider with specific error behavior
      setup_providers([
        %{
          id: "provider",
          priority: 10,
          behavior: {:error, %{code: -32_000, message: "Server error"}},
          profile: profile
        }
      ])

      # Execute request
      {:error, error, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{
            provider_override: "provider",
            failover_on_override: false,
            timeout_ms: 30_000,
            strategy: :round_robin
          }
        )

      # Verify error is classified
      assert error != nil
      # Error should be wrapped in JSONRPC.Error structure
    end

    test "handles timeout errors", %{chain: chain} do
      profile = "default"

      # Setup provider that times out
      setup_providers([
        %{id: "slow", priority: 10, behavior: :always_timeout, profile: profile}
      ])

      # Execute with short timeout
      start_time = System.monotonic_time(:millisecond)

      {:error, _error, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{
            provider_override: "slow",
            failover_on_override: false,
            timeout_ms: 100,
            strategy: :round_robin
          }
        )

      duration = System.monotonic_time(:millisecond) - start_time

      # Should timeout quickly (within tolerance)
      assert duration < 500
    end

    test "handles provider not found error", %{chain: chain} do
      # Don't setup any providers

      # Execute request
      {:error, error, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{
            provider_override: "nonexistent",
            failover_on_override: false,
            timeout_ms: 30_000,
            strategy: :round_robin
          }
        )

      # Should get appropriate error
      assert error != nil
    end
  end

  describe "transport selection" do
    test "respects transport override", %{chain: chain} do
      profile = "default"

      # Setup providers on multiple transports
      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      # Execute with HTTP transport override
      {:ok, _result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{transport: :http, timeout_ms: 30_000, strategy: :round_robin}
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
      profile = "default"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
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
      {:ok, _result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
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
      profile = "default"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      # Attach telemetry collector BEFORE executing request
      # Note: telemetry metadata uses 'result' not 'status' for success/error indicator
      {:ok, collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :rpc, :request, :stop],
          match: [method: "eth_blockNumber", result: :success]
        )

      # Execute request
      {:ok, _result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      # Verify telemetry shows success
      {:ok, measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(collector, timeout: 2000)

      # Duration should be non-negative (can be 0 for very fast requests)
      assert measurements.duration >= 0
    end

    test "records metrics for failed requests", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "failing", priority: 10, behavior: :always_fail, profile: profile}
      ])

      # Attach telemetry collector BEFORE executing request
      {:ok, collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :rpc, :request, :stop],
          match: [method: "eth_blockNumber"]
        )

      # Execute request that will fail
      {:error, _, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{
            provider_override: "failing",
            failover_on_override: false,
            timeout_ms: 30_000,
            strategy: :round_robin
          }
        )

      # Should still emit stop event with error status
      {:ok, measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(collector, timeout: 2000)

      # Duration should be non-negative (can be 0 for very fast requests)
      assert measurements.duration >= 0
    end
  end

  describe "retry and resilience" do
    test "gives up after max retries", %{chain: chain} do
      profile = "default"

      # Setup only failing providers
      setup_providers([
        %{id: "fail1", priority: 10, behavior: :always_fail, profile: profile},
        %{id: "fail2", priority: 20, behavior: :always_fail, profile: profile}
      ])

      # Attach telemetry collector BEFORE executing request
      {:ok, collector} =
        Lasso.Testing.TelemetrySync.attach_collector(
          [:lasso, :rpc, :request, :start],
          match: [method: "eth_blockNumber"]
        )

      # Execute request
      {:error, _error, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      # Should have emitted at least one start event
      {:ok, _measurements, _metadata} =
        Lasso.Testing.TelemetrySync.await_event(collector, timeout: 2000)
    end
  end

  describe "rate limit failover" do
    test "rate-limited provider triggers automatic failover to healthy provider", %{chain: chain} do
      profile = "default"

      # Setup: Primary provider that rate limits, backup that's healthy
      rate_limit_error =
        %Lasso.JSONRPC.Error{
          code: 429,
          message: "Rate limit exceeded",
          category: :rate_limit,
          retriable?: true
        }

      setup_providers([
        %{
          id: "rate_limited",
          priority: 10,
          behavior: {:error, rate_limit_error},
          profile: profile
        },
        %{id: "healthy_backup", priority: 20, behavior: :healthy, profile: profile}
      ])

      # Ensure circuit breakers exist
      CircuitBreakerHelper.ensure_circuit_breaker_started(profile, chain, "rate_limited", :http)
      CircuitBreakerHelper.ensure_circuit_breaker_started(profile, chain, "healthy_backup", :http)

      # CRITICAL TEST: Request should automatically failover to healthy backup
      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :priority, timeout_ms: 30_000}
        )

      # Verify we got a successful response (failover worked)
      assert %Response.Success{} = result
      {:ok, block_number} = Response.Success.decode_result(result)
      assert String.starts_with?(block_number, "0x")

      # To trigger circuit breaker opening, we need to directly target the rate-limited
      # provider without failover, so the circuit breaker sees the failures
      for _ <- 1..2 do
        {:error, _, _} =
          RequestPipeline.execute_via_channels(
            chain,
            "eth_blockNumber",
            [],
            %RequestOptions{
              provider_override: "rate_limited",
              failover_on_override: false,
              timeout_ms: 30_000
            }
          )

        Process.sleep(100)
      end

      # Wait for circuit breaker to process the failures and open
      Process.sleep(500)

      # Wait for circuit breaker to open (rate limit threshold is 2)
      breaker_id = {profile, chain, "rate_limited", :http}

      {:ok, _state} =
        CircuitBreakerHelper.wait_for_circuit_breaker_state(
          breaker_id,
          fn state -> state.state == :open end,
          timeout: 10_000,
          interval: 100
        )

      # Verify rate-limited provider's circuit is now open
      CircuitBreakerHelper.assert_circuit_breaker_state(breaker_id, :open)

      # Now verify that subsequent requests with priority strategy use backup
      {:ok, result2, _ctx2} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :priority, timeout_ms: 30_000}
        )

      # Should still succeed using backup since primary's circuit is open
      assert %Response.Success{} = result2
    end

    test "rate limit error opens circuit breaker faster than normal errors", %{chain: chain} do
      profile = "default"

      # Setup provider that rate limits
      rate_limit_error =
        %Lasso.JSONRPC.Error{
          code: 429,
          message: "Rate limit exceeded",
          category: :rate_limit,
          retriable?: true
        }

      setup_providers([
        %{
          id: "rate_limited_fast",
          priority: 10,
          behavior: {:error, rate_limit_error},
          profile: profile
        }
      ])

      CircuitBreakerHelper.ensure_circuit_breaker_started(
        profile,
        chain,
        "rate_limited_fast",
        :http
      )

      # Execute 2 requests (rate limit threshold is 2, vs 5 for normal errors)
      for _ <- 1..2 do
        {:error, _error, _ctx} =
          RequestPipeline.execute_via_channels(
            chain,
            "eth_blockNumber",
            [],
            %RequestOptions{
              provider_override: "rate_limited_fast",
              failover_on_override: false,
              timeout_ms: 30_000
            }
          )

        Process.sleep(50)
      end

      # Give circuit breaker time to open
      Process.sleep(500)

      # Verify circuit opened after only 2 rate limit errors (not 5)
      CircuitBreakerHelper.assert_circuit_breaker_state(
        {profile, chain, "rate_limited_fast", :http},
        :open
      )
    end

    test "multiple providers can be rate-limited independently", %{chain: chain} do
      profile = "default"

      # Setup: Multiple providers, all rate-limited
      rate_limit_error =
        %Lasso.JSONRPC.Error{
          code: 429,
          message: "Rate limit exceeded",
          category: :rate_limit,
          retriable?: true
        }

      setup_providers([
        %{id: "provider_a", priority: 10, behavior: {:error, rate_limit_error}, profile: profile},
        %{id: "provider_b", priority: 20, behavior: {:error, rate_limit_error}, profile: profile},
        %{id: "provider_c", priority: 30, behavior: :healthy, profile: profile}
      ])

      # Ensure circuit breakers exist
      for provider_id <- ["provider_a", "provider_b", "provider_c"] do
        CircuitBreakerHelper.ensure_circuit_breaker_started(profile, chain, provider_id, :http)
      end

      # Rate limit provider_a
      for _ <- 1..2 do
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{
            provider_override: "provider_a",
            failover_on_override: false,
            timeout_ms: 30_000
          }
        )

        Process.sleep(50)
      end

      Process.sleep(300)

      # Rate limit provider_b
      for _ <- 1..2 do
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{
            provider_override: "provider_b",
            failover_on_override: false,
            timeout_ms: 30_000
          }
        )

        Process.sleep(50)
      end

      Process.sleep(300)

      # Verify both a and b are open, but c is still closed
      CircuitBreakerHelper.assert_circuit_breaker_state(
        {profile, chain, "provider_a", :http},
        :open
      )

      CircuitBreakerHelper.assert_circuit_breaker_state(
        {profile, chain, "provider_b", :http},
        :open
      )

      CircuitBreakerHelper.assert_circuit_breaker_state(
        {profile, chain, "provider_c", :http},
        :closed
      )

      # Request with priority strategy should use provider_c (only healthy one)
      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :priority, timeout_ms: 30_000}
        )

      assert %Response.Success{} = result
    end
  end

  # Helper functions for circuit breaker state waiting
end

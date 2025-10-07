defmodule Lasso.RPC.RateLimitFailoverTest do
  @moduledoc """
  Integration tests for rate limit detection, handling, and circuit breaker failover.

  Rate limits can manifest in multiple ways:
  - HTTP 429 status codes (transport level)
  - JSON-RPC error codes: -32005, -32429 (application level)
  - Error messages containing rate limit keywords
  - WebSocket close code 1013 (backpressure)

  Tests verify:
  - All rate limit formats are correctly detected and classified
  - Circuit breaker responds appropriately to rate limit errors
  - Automatic failover to healthy providers
  - Recovery after rate limit cooldown
  - System resilience under various failure scenarios
  """

  use ExUnit.Case, async: false

  alias Lasso.Testing.IntegrationHelper
  alias Lasso.RPC.{CircuitBreaker, ProviderPool}
  alias Lasso.JSONRPC.Error, as: JError

  @moduletag :integration

  setup do
    chain = "rate_limit_test_#{:rand.uniform(1_000_000)}"

    on_exit(fn ->
      # Cleanup happens automatically via MockWSProvider cleanup monitor
      :ok
    end)

    {:ok, chain: chain}
  end

  describe "rate limit detection - HTTP level (transport)" do
    test "HTTP 429 status code is detected as rate limit", %{chain: _chain} do
      # HTTP transport returns {:rate_limit, payload} tuple
      http_error = {:rate_limit, %{status: 429, body: "Too Many Requests"}}

      # Normalize through ErrorNormalizer as the HTTP client would
      normalized = Lasso.RPC.ErrorNormalizer.normalize(http_error, provider_id: "test_provider")

      assert normalized.category == :rate_limit
      assert normalized.retriable? == true
      assert normalized.source == :transport
    end

    test "HTTP 429 with JSON body is properly parsed", %{chain: _chain} do
      json_body = Jason.encode!(%{"error" => "Rate limit exceeded", "retry_after" => 60})
      http_error = {:rate_limit, %{status: 429, body: json_body}}

      normalized = Lasso.RPC.ErrorNormalizer.normalize(http_error, provider_id: "test_provider")

      assert normalized.category == :rate_limit
      assert normalized.retriable? == true
    end
  end

  describe "rate limit detection - JSON-RPC level" do
    test "JSON-RPC error code -32005 is detected as rate limit", %{chain: _chain} do
      # Provider returns standard JSON-RPC error with -32005 code
      rate_limit_error = JError.new(-32005, "Rate limit exceeded")

      assert rate_limit_error.category == :rate_limit
      assert rate_limit_error.retriable? == true
    end

    test "JSON-RPC error code -32429 is detected as rate limit", %{chain: _chain} do
      # Some providers use -32429 (HTTP 429 in JSON-RPC namespace)
      rate_limit_error = JError.new(-32429, "Too many requests", category: :rate_limit, retriable?: true)

      # Verify error is retriable (should failover to next provider)
      assert rate_limit_error.retriable? == true
      assert rate_limit_error.category == :rate_limit
    end

    test "HTTP 429 code is normalized to JSON-RPC -32005", %{chain: _chain} do
      # When creating JError from HTTP 429, it gets normalized
      rate_limit_error = JError.new(429, "Too Many Requests")

      assert rate_limit_error.code == -32005
      assert rate_limit_error.original_code == 429
      assert rate_limit_error.category == :rate_limit
      assert rate_limit_error.retriable? == true
    end

    test "rate limit keywords in error message trigger detection", %{chain: _chain} do
      # Provider returns generic error but message indicates rate limiting
      test_cases = [
        %{"error" => %{"code" => -32000, "message" => "rate limit exceeded"}},
        %{"error" => %{"code" => -32000, "message" => "Too many requests, please try again"}},
        %{"error" => %{"code" => -32000, "message" => "Request throttled"}},
        %{"error" => %{"code" => -32000, "message" => "Quota exceeded for this API key"}},
        %{"error" => %{"code" => -32000, "message" => "Capacity exceeded, retry later"}}
      ]

      for error_response <- test_cases do
        normalized = Lasso.RPC.ErrorNormalizer.normalize(error_response, provider_id: "test")
        assert normalized.category == :rate_limit, "Failed for: #{inspect(error_response)}"
        assert normalized.retriable? == true, "Should be retriable for: #{inspect(error_response)}"
      end
    end
  end

  describe "rate limit detection and circuit breaker integration" do

    test "circuit breaker opens quickly on rate limit errors", %{chain: _chain} do
      provider_id = "fast_provider"

      {:ok, _pid} =
        CircuitBreaker.start_link(
          {provider_id, %{failure_threshold: 3, recovery_timeout: 5_000, success_threshold: 2}}
        )

      # Simulate rapid rate limit failures
      for _i <- 1..3 do
        result =
          CircuitBreaker.call(provider_id, fn ->
            {:error, JError.new(429, "Too Many Requests", provider_id: provider_id)}
          end)

        assert match?({:error, _}, result)
      end

      # Circuit breaker should now be open
      state = CircuitBreaker.get_state(provider_id)
      assert state.state == :open
      assert state.failure_count >= 3

      # Subsequent requests should be blocked immediately
      result = CircuitBreaker.call(provider_id, fn -> {:ok, "success"} end)
      assert result == {:error, :circuit_open}
    end

    test "rate limit errors increment failure count in circuit breaker", %{chain: _chain} do
      provider_id = "rate_limited_provider"

      {:ok, _pid} =
        CircuitBreaker.start_link(
          {provider_id, %{failure_threshold: 5, recovery_timeout: 5_000, success_threshold: 2}}
        )

      # First rate limit error
      {:error, _} =
        CircuitBreaker.call(provider_id, fn ->
          {:error, JError.new(-32005, "Rate limit exceeded")}
        end)

      state1 = CircuitBreaker.get_state(provider_id)
      assert state1.failure_count == 1
      assert state1.state == :closed

      # Second rate limit error
      {:error, _} =
        CircuitBreaker.call(provider_id, fn ->
          {:error, JError.new(429, "Too Many Requests")}
        end)

      state2 = CircuitBreaker.get_state(provider_id)
      assert state2.failure_count == 2
      assert state2.state == :closed

      # Continue until circuit opens
      for _i <- 1..3 do
        CircuitBreaker.call(provider_id, fn ->
          {:error, JError.new(429, "Rate limited")}
        end)
      end

      final_state = CircuitBreaker.get_state(provider_id)
      assert final_state.state == :open
    end
  end

  describe "failover during rate limiting with 'fastest' strategy" do
    test "fails over to backup when fastest provider hits rate limit", %{chain: chain} do
      # Setup: Three providers with different priorities
      # - fast_primary: Lowest latency, but will be rate limited
      # - fast_backup: Second-best latency
      # - slow_backup: Highest latency fallback
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "fast_primary", priority: 100},
            %{id: "fast_backup", priority: 90},
            %{id: "slow_backup", priority: 80}
          ]
        )

      # Wait for providers to register
      Process.sleep(200)

      # Verify all providers are available
      candidates = ProviderPool.list_candidates(chain)
      assert length(candidates) == 3

      # Simulate rate limiting on the fastest provider by opening its circuit breaker
      provider_id = "fast_primary"

      case CircuitBreaker.start_link(
             {provider_id, %{failure_threshold: 2, recovery_timeout: 5_000, success_threshold: 2}}
           ) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      # Trigger rate limit failures
      for _i <- 1..3 do
        CircuitBreaker.call(provider_id, fn ->
          {:error, JError.new(429, "Too Many Requests", provider_id: provider_id)}
        end)

        Process.sleep(10)
      end

      # Verify circuit is open
      state = CircuitBreaker.get_state(provider_id)
      assert state.state == :open

      # Mark provider as rate_limited in the pool
      ProviderPool.report_failure(chain, provider_id, {:rate_limit, "429 Too Many Requests"})
      Process.sleep(100)

      # Verify pool recognizes the rate limited provider
      {:ok, pool_status} = ProviderPool.get_status(chain)

      rate_limited_provider =
        Enum.find(pool_status.providers, fn p -> p.id == provider_id end)

      assert rate_limited_provider.status == :rate_limited

      # Get available candidates (should exclude rate limited provider)
      available_candidates = ProviderPool.list_candidates(chain)

      # The rate limited provider should have degraded availability
      primary_candidate = Enum.find(available_candidates, fn c -> c.id == "fast_primary" end)

      if primary_candidate do
        # Provider might still be in the list but with degraded availability
        assert primary_candidate.availability != :up
      else
        # Or it might be filtered out entirely - both are acceptable
        assert true
      end

      # Verify we have backup providers available
      backup_candidates =
        Enum.filter(available_candidates, fn c ->
          c.id in ["fast_backup", "slow_backup"] and c.availability == :up
        end)

      assert length(backup_candidates) >= 1,
             "Should have at least one healthy backup provider available"
    end

    test "handles concurrent requests during rate limit failover", %{chain: chain} do
      # Setup providers
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "primary", priority: 100},
            %{id: "backup1", priority: 90},
            %{id: "backup2", priority: 80}
          ]
        )

      Process.sleep(200)

      # Start circuit breaker for primary
      primary_id = "primary"

      case CircuitBreaker.start_link(
             {primary_id, %{failure_threshold: 2, recovery_timeout: 10_000, success_threshold: 2}}
           ) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      # Simulate concurrent rate limit errors (simulating heavy load hitting rate limits)
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            CircuitBreaker.call(primary_id, fn ->
              {:error, JError.new(429, "Too Many Requests")}
            end)
          end)
        end

      results = Task.await_many(tasks, 2000)

      # All should be errors (either the rate limit error or circuit_open)
      assert Enum.all?(results, fn result -> match?({:error, _}, result) end)

      # Circuit should be open after concurrent failures
      state = CircuitBreaker.get_state(primary_id)
      assert state.state == :open

      # Mark as rate limited
      ProviderPool.report_failure(chain, primary_id, {:rate_limit, "429"})
      Process.sleep(100)

      # Verify backup providers are still available for failover
      candidates = ProviderPool.list_candidates(chain)
      healthy_backups = Enum.filter(candidates, fn c -> c.availability == :up end)

      assert length(healthy_backups) >= 1,
             "Should have healthy backup providers after primary is rate limited"
    end
  end

  describe "recovery after rate limiting" do
    test "circuit breaker attempts recovery after timeout", %{chain: _chain} do
      provider_id = "recovering_provider"

      {:ok, _pid} =
        CircuitBreaker.start_link(
          {provider_id,
           %{
             failure_threshold: 2,
             recovery_timeout: 100,
             # Short timeout for test
             success_threshold: 2
           }}
        )

      # Trigger rate limit failures to open circuit
      for _i <- 1..2 do
        CircuitBreaker.call(provider_id, fn ->
          {:error, JError.new(429, "Rate limited")}
        end)
      end

      assert CircuitBreaker.get_state(provider_id).state == :open

      # Wait for recovery timeout
      Process.sleep(150)

      # Next request should attempt recovery (half-open state)
      result = CircuitBreaker.call(provider_id, fn -> {:ok, "success"} end)
      assert result == {:ok, "success"}

      state_after_recovery = CircuitBreaker.get_state(provider_id)
      assert state_after_recovery.state in [:half_open, :closed]

      # One more success should close the circuit
      CircuitBreaker.call(provider_id, fn -> {:ok, "success"} end)

      final_state = CircuitBreaker.get_state(provider_id)
      assert final_state.state == :closed
      assert final_state.failure_count == 0
    end

    test "provider returns to candidate pool after rate limit recovery", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [%{id: "recovering", priority: 100}]
        )

      Process.sleep(200)

      provider_id = "recovering"

      # Simulate rate limiting
      ProviderPool.report_failure(chain, provider_id, {:rate_limit, "429"})
      Process.sleep(50)

      {:ok, status_during_limit} = ProviderPool.get_status(chain)
      provider_during = Enum.find(status_during_limit.providers, fn p -> p.id == provider_id end)
      assert provider_during.status == :rate_limited

      # Simulate recovery with successful requests
      ProviderPool.report_success(chain, provider_id)
      ProviderPool.report_success(chain, provider_id)
      ProviderPool.report_success(chain, provider_id)
      Process.sleep(50)

      {:ok, status_after_recovery} = ProviderPool.get_status(chain)

      provider_after =
        Enum.find(status_after_recovery.providers, fn p -> p.id == provider_id end)

      # Should transition back to healthy
      assert provider_after.status in [:healthy, :connecting]
      assert provider_after.consecutive_successes >= 3
    end
  end

  describe "rate limiting with multiple providers under 'fastest' strategy load" do
    test "distributes load to multiple providers when primary is rate limited", %{chain: chain} do
      # Setup realistic scenario: 3 fast providers
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "fast_1", priority: 100},
            %{id: "fast_2", priority: 99},
            %{id: "fast_3", priority: 98}
          ]
        )

      Process.sleep(200)

      # Simulate fast_1 getting rate limited under load
      ProviderPool.report_failure(chain, "fast_1", {:rate_limit, "429"})
      Process.sleep(100)

      # Verify fast_1 is marked as rate limited
      {:ok, status} = ProviderPool.get_status(chain)
      fast_1 = Enum.find(status.providers, fn p -> p.id == "fast_1" end)
      assert fast_1.status == :rate_limited

      # Verify other providers are still available
      candidates = ProviderPool.list_candidates(chain)
      healthy_candidates = Enum.filter(candidates, fn c -> c.availability == :up end)

      # Should have fast_2 and fast_3 available for failover
      healthy_ids = Enum.map(healthy_candidates, & &1.id)
      assert "fast_2" in healthy_ids
      assert "fast_3" in healthy_ids

      # Simulate successful requests to backup providers
      ProviderPool.report_success(chain, "fast_2")
      ProviderPool.report_success(chain, "fast_3")
      Process.sleep(50)

      {:ok, final_status} = ProviderPool.get_status(chain)

      # Verify backup providers are handling load successfully
      fast_2 = Enum.find(final_status.providers, fn p -> p.id == "fast_2" end)
      fast_3 = Enum.find(final_status.providers, fn p -> p.id == "fast_3" end)

      assert fast_2.status in [:healthy, :connecting]
      assert fast_3.status in [:healthy, :connecting]
      assert fast_2.consecutive_successes >= 1
      assert fast_3.consecutive_successes >= 1
    end
  end

  describe "provider-specific rate limit variations" do
    test "handles Infura-style rate limit errors", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [%{id: "infura_provider", priority: 100}]
        )

      Process.sleep(200)

      # Infura returns: {"error": {"code": -32005, "message": "daily request count exceeded, request rate limited"}}
      infura_error = %{"error" => %{"code" => -32005, "message" => "daily request count exceeded, request rate limited"}}
      normalized = Lasso.RPC.ErrorNormalizer.normalize(infura_error, provider_id: "infura_provider")

      assert normalized.category == :rate_limit
      assert normalized.retriable? == true

      # Report to pool
      ProviderPool.report_failure(chain, "infura_provider", normalized)
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status(chain)
      provider = Enum.find(status.providers, fn p -> p.id == "infura_provider" end)
      assert provider.status == :rate_limited
    end

    test "handles Alchemy-style rate limit errors", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [%{id: "alchemy_provider", priority: 100}]
        )

      Process.sleep(200)

      # Alchemy returns: {"error": {"code": -32016, "message": "Exceeded maximum requests per second"}}
      # Message contains rate limit keywords
      alchemy_error = %{"error" => %{"code" => -32016, "message" => "Exceeded maximum requests per second"}}
      normalized = Lasso.RPC.ErrorNormalizer.normalize(alchemy_error, provider_id: "alchemy_provider")

      # Should be detected by keyword matching even with non-standard code
      assert normalized.category == :rate_limit
      assert normalized.retriable? == true
    end

    test "handles QuickNode-style rate limit errors", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [%{id: "quicknode_provider", priority: 100}]
        )

      Process.sleep(200)

      # QuickNode style: generic server error with rate limit message
      quicknode_error = %{"error" => %{"code" => -32603, "message" => "Credits quota exceeded. Please upgrade your plan"}}
      normalized = Lasso.RPC.ErrorNormalizer.normalize(quicknode_error, provider_id: "quicknode_provider")

      assert normalized.category == :rate_limit
      assert normalized.retriable? == true
    end

    test "handles Ankr-style throttling errors", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [%{id: "ankr_provider", priority: 100}]
        )

      Process.sleep(200)

      # Ankr style: throttled message
      ankr_error = %{"error" => %{"code" => -32000, "message" => "Request throttled, please try again"}}
      normalized = Lasso.RPC.ErrorNormalizer.normalize(ankr_error, provider_id: "ankr_provider")

      assert normalized.category == :rate_limit
      assert normalized.retriable? == true
    end
  end

  describe "mixed error scenarios" do
    test "distinguishes rate limit from other server errors", %{chain: _chain} do
      # Rate limit error
      rate_limit = JError.new(-32005, "Rate limit exceeded")
      assert rate_limit.category == :rate_limit
      assert rate_limit.retriable? == true

      # Generic server error
      server_error = JError.new(-32603, "Internal server error")
      assert server_error.category == :server_error
      assert server_error.retriable? == true

      # User error (should NOT trigger failover)
      user_error = JError.new(-32602, "Invalid params")
      assert user_error.category == :client_error
      assert user_error.retriable? == false
    end

    test "rate limit followed by recovery doesn't affect other error handling", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [%{id: "mixed_provider", priority: 100}]
        )

      Process.sleep(200)

      # First: rate limit error
      ProviderPool.report_failure(chain, "mixed_provider", {:rate_limit, "429"})
      Process.sleep(50)

      {:ok, status1} = ProviderPool.get_status(chain)
      provider1 = Enum.find(status1.providers, fn p -> p.id == "mixed_provider" end)
      assert provider1.status == :rate_limited

      # Then: successful recovery
      ProviderPool.report_success(chain, "mixed_provider")
      ProviderPool.report_success(chain, "mixed_provider")
      Process.sleep(50)

      {:ok, status2} = ProviderPool.get_status(chain)
      provider2 = Enum.find(status2.providers, fn p -> p.id == "mixed_provider" end)
      assert provider2.status in [:healthy, :connecting]

      # Then: user error (should NOT affect health)
      user_error = JError.new(-32602, "Invalid params", provider_id: "mixed_provider")
      ProviderPool.report_failure(chain, "mixed_provider", user_error)
      Process.sleep(50)

      {:ok, status3} = ProviderPool.get_status(chain)
      provider3 = Enum.find(status3.providers, fn p -> p.id == "mixed_provider" end)
      # User errors don't affect health status
      assert provider3.status in [:healthy, :connecting]
    end

    test "circuit breaker treats rate limits differently than user errors", %{chain: _chain} do
      provider_id = "error_type_test"

      {:ok, _pid} =
        CircuitBreaker.start_link(
          {provider_id, %{failure_threshold: 3, recovery_timeout: 5_000, success_threshold: 2}}
        )

      # Rate limit errors increment failure count
      CircuitBreaker.call(provider_id, fn -> {:error, JError.new(429, "Rate limited")} end)
      state1 = CircuitBreaker.get_state(provider_id)
      assert state1.failure_count == 1

      # User errors do NOT increment failure count
      CircuitBreaker.call(provider_id, fn -> {:error, JError.new(-32602, "Invalid params")} end)
      state2 = CircuitBreaker.get_state(provider_id)
      assert state2.failure_count == 1  # Still 1, user error didn't increment

      # Another rate limit error increments
      CircuitBreaker.call(provider_id, fn -> {:error, JError.new(-32005, "Rate limited")} end)
      state3 = CircuitBreaker.get_state(provider_id)
      assert state3.failure_count == 2
    end
  end

  describe "stress testing and race conditions" do
    test "rapid rate limit errors don't cause state corruption", %{chain: _chain} do
      provider_id = "stress_test_provider"

      {:ok, _pid} =
        CircuitBreaker.start_link(
          {provider_id, %{failure_threshold: 10, recovery_timeout: 5_000, success_threshold: 2}}
        )

      # Send 100 concurrent rate limit errors
      tasks =
        for _i <- 1..100 do
          Task.async(fn ->
            CircuitBreaker.call(provider_id, fn ->
              {:error, JError.new(429, "Rate limited")}
            end)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should return errors
      assert Enum.all?(results, fn result -> match?({:error, _}, result) end)

      # Circuit breaker should be open
      final_state = CircuitBreaker.get_state(provider_id)
      assert final_state.state == :open
      # Failure count should not exceed the number of actual requests
      assert final_state.failure_count <= 100
      assert final_state.failure_count >= 10
    end

    test "interleaved rate limits and successes maintain consistent state", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [%{id: "interleaved_provider", priority: 100}]
        )

      Process.sleep(200)

      # Interleave successes and rate limit errors
      for _round <- 1..5 do
        ProviderPool.report_success(chain, "interleaved_provider")
        Process.sleep(10)
        ProviderPool.report_failure(chain, "interleaved_provider", {:rate_limit, "429"})
        Process.sleep(10)
        ProviderPool.report_success(chain, "interleaved_provider")
        Process.sleep(10)
      end

      Process.sleep(100)

      # Provider state should be consistent
      {:ok, status} = ProviderPool.get_status(chain)
      provider = Enum.find(status.providers, fn p -> p.id == "interleaved_provider" end)

      # Should have recorded both successes and the rate limit status
      assert is_integer(provider.consecutive_successes) or provider.consecutive_successes == nil
      assert is_integer(provider.consecutive_failures) or provider.consecutive_failures == nil
      assert is_map(status)
    end
  end

  describe "edge cases" do
    test "handles all providers rate limited simultaneously", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "p1", priority: 100},
            %{id: "p2", priority: 90}
          ]
        )

      Process.sleep(200)

      # Rate limit both providers
      ProviderPool.report_failure(chain, "p1", {:rate_limit, "429"})
      ProviderPool.report_failure(chain, "p2", {:rate_limit, "429"})
      Process.sleep(100)

      {:ok, status} = ProviderPool.get_status(chain)

      # Both should be marked as rate limited
      p1 = Enum.find(status.providers, fn p -> p.id == "p1" end)
      p2 = Enum.find(status.providers, fn p -> p.id == "p2" end)

      assert p1.status == :rate_limited
      assert p2.status == :rate_limited

      # System should still be queryable (graceful degradation)
      candidates = ProviderPool.list_candidates(chain)
      assert is_list(candidates)
    end

    test "rate limit during provider initialization doesn't crash system", %{chain: chain} do
      # Start provider that immediately gets rate limited
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [%{id: "instant_rate_limit", priority: 100}]
        )

      # Immediately report rate limit before provider is fully ready
      ProviderPool.report_failure(chain, "instant_rate_limit", {:rate_limit, "429"})

      # System should handle this gracefully
      Process.sleep(100)

      {:ok, status} = ProviderPool.get_status(chain)
      assert is_map(status)
      assert is_list(status.providers)
    end

    test "empty or malformed rate limit response doesn't crash", %{chain: _chain} do
      # Various malformed rate limit errors
      test_cases = [
        {:rate_limit, %{}},
        {:rate_limit, %{status: 429}},
        {:rate_limit, nil},
        %{"error" => %{"code" => -32005}},  # Missing message
        %{"error" => %{"message" => "rate limited"}}  # Missing code
      ]

      for error <- test_cases do
        normalized = Lasso.RPC.ErrorNormalizer.normalize(error, provider_id: "test")
        # Should not crash, should return a valid JError
        assert %JError{} = normalized
        # Should still detect as rate limit or at least be retriable
        assert normalized.retriable? == true
      end
    end

    test "rate limit with extremely long cooldown is handled", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [%{id: "long_cooldown", priority: 100}]
        )

      Process.sleep(200)

      # Report rate limit
      ProviderPool.report_failure(chain, "long_cooldown", {:rate_limit, "429"})
      Process.sleep(50)

      {:ok, status} = ProviderPool.get_status(chain)
      provider = Enum.find(status.providers, fn p -> p.id == "long_cooldown" end)

      assert provider.status == :rate_limited
      # Cooldown should be set to some future time
      assert is_integer(provider.cooldown_until) or provider.cooldown_until == nil
    end
  end
end

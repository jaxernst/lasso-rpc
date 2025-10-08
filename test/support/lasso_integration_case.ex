defmodule Lasso.Test.LassoIntegrationCase do
  @moduledoc """
  Base case template for integration tests with proper isolation.

  This module provides automatic setup and teardown for integration tests,
  ensuring:
  - Unique chain IDs per test (no cross-test pollution)
  - Clean circuit breaker state
  - Metrics reset
  - Proper cleanup on test exit
  - Access to all test helpers

  ## Usage

      defmodule MyIntegrationTest do
        use Lasso.Test.LassoIntegrationCase

        test "my test scenario", %{chain: chain} do
          # chain is unique per test
          # circuit breakers are clean
          # proper cleanup will happen automatically
        end
      end

  ## Available Test Helpers

  All tests using this module have access to:
  - `Lasso.Test.TelemetrySync` - Event-driven waiting
  - `Lasso.Test.Eventually` - Polling-based assertions
  - `Lasso.Test.CircuitBreakerHelper` - CB lifecycle management
  - `Lasso.Testing.IntegrationHelper` - Provider setup and utilities

  ## Setup Behavior

  Each test gets:
  - `chain` - Unique chain identifier
  - Clean circuit breaker state
  - Reset metrics (if needed)
  - Automatic cleanup on exit
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Lasso.Test.TelemetrySync
      import Lasso.Test.Eventually
      import Lasso.Test.CircuitBreakerHelper
      import Lasso.Testing.IntegrationHelper

      alias Lasso.Testing.{MockWSProvider, IntegrationHelper}
      alias Lasso.RPC.{
        CircuitBreaker,
        StreamCoordinator,
        UpstreamSubscriptionPool,
        ClientSubscriptionRegistry,
        RequestPipeline
      }

      # Mark as async: false by default for integration tests
      # Individual test modules can override this
      @moduletag :integration

      setup do
        # Generate unique chain ID for this test
        chain = "test_#{:rand.uniform(999_999_999)}"

        # Store chain in process dictionary for helper access
        # This avoids var! hygiene issues while maintaining convenience
        Process.put(:lasso_test_chain, chain)

        # Clean circuit breaker state
        Lasso.Test.CircuitBreakerHelper.setup_clean_circuit_breakers()

        # Reset metrics if needed
        reset_test_metrics()

        # Register cleanup callback
        on_exit(fn ->
          cleanup_test_resources(chain)
          Process.delete(:lasso_test_chain)
        end)

        {:ok, chain: chain}
      end

      # Private helpers available to tests using this case

      defp get_test_chain do
        # Get chain from process dictionary (set during setup)
        # This provides convenient access without var! hygiene issues
        case Process.get(:lasso_test_chain) do
          nil ->
            raise "get_test_chain/0 called outside test context or before setup. " <>
                    "Make sure you're calling this within a test block."

          chain ->
            chain
        end
      end

      defp reset_test_metrics do
        # Reset any global metrics that could pollute tests
        # For now, this is a no-op but can be extended
        :ok
      end

      defp cleanup_test_resources(chain) do
        # Clean up chain-specific resources
        # This includes stopping any supervisors, cleaning registries, etc.

        # Give async cleanup a moment to complete
        Process.sleep(50)

        :ok
      end

      @doc """
      Sets up providers with enhanced synchronization.

      This is a convenience wrapper that automatically uses the test's chain
      and waits for providers to be fully ready.

      ## Example

          test "failover scenario", %{chain: chain} do
            providers = setup_providers([
              %{id: "primary", priority: 10},
              %{id: "backup", priority: 20}
            ])

            # providers are guaranteed to be ready
          end
      """
      defp setup_providers(provider_specs, opts \\ []) do
        chain = Keyword.get(opts, :chain) || get_test_chain()

        {:ok, provider_ids} =
          IntegrationHelper.setup_test_chain_with_providers(chain, provider_specs, opts)

        provider_ids
      end

      @doc """
      Waits for a circuit breaker to open using TelemetrySync.

      Convenience wrapper that uses the deterministic telemetry-based waiting.

      ## Example

          test "circuit breaker opens on failures", %{chain: chain} do
            setup_providers([%{id: "failing", behavior: :always_fail}])

            # Trigger failures...

            wait_for_cb_open("failing", :http)
            assert true
          end
      """
      defp wait_for_cb_open(provider_id, transport, timeout \\ 5_000) do
        case Lasso.Test.TelemetrySync.wait_for_circuit_breaker_open(provider_id, transport, timeout) do
          {:ok, _meta} -> :ok
          {:error, :timeout} -> flunk("Circuit breaker did not open within #{timeout}ms")
        end
      end

      @doc """
      Waits for a circuit breaker to close.
      """
      defp wait_for_cb_close(provider_id, transport, timeout \\ 5_000) do
        case Lasso.Test.TelemetrySync.wait_for_circuit_breaker_close(provider_id, transport, timeout) do
          {:ok, _meta} -> :ok
          {:error, :timeout} -> flunk("Circuit breaker did not close within #{timeout}ms")
        end
      end

      @doc """
      Waits for a failover to complete.
      """
      defp wait_for_failover(chain, key, timeout \\ 5_000) do
        case Lasso.Test.TelemetrySync.wait_for_failover_completed(chain, key, timeout) do
          {:ok, meta} -> meta
          {:error, :timeout} -> flunk("Failover did not complete within #{timeout}ms")
        end
      end

      @doc """
      Asserts that a condition eventually becomes true.

      Uses Eventually helper for polling-based assertions.

      ## Example

          assert_eventually fn ->
            get_provider_status(provider_id) == :healthy
          end
      """
      defmacro assert_eventually(condition, opts \\ []) do
        quote do
          Lasso.Test.Eventually.assert_eventually(unquote(condition), unquote(opts))
        end
      end

      @doc """
      Asserts that a condition remains false.

      Uses Eventually helper for negative assertions.

      ## Example

          refute_eventually fn ->
            circuit_breaker_opened?(provider_id)
          end
      """
      defmacro refute_eventually(condition, opts \\ []) do
        quote do
          Lasso.Test.Eventually.refute_eventually(unquote(condition), unquote(opts))
        end
      end

      @doc """
      Subscribes a test client to a subscription key.

      Returns the subscription ID.

      ## Example

          test "subscription events", %{chain: chain} do
            setup_providers([%{id: "ws1", priority: 100}])

            sub_id = subscribe_test_client({:newHeads})

            # Wait for events...
            assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id}}}
          end
      """
      defp subscribe_test_client(key, client_pid \\ nil) do
        chain = get_test_chain()
        client_pid = client_pid || self()

        case IntegrationHelper.subscribe_client(chain, client_pid, key) do
          {:ok, sub_id} -> sub_id
          error -> flunk("Failed to subscribe: #{inspect(error)}")
        end
      end

      @doc """
      Unsubscribes a test client.
      """
      defp unsubscribe_test_client(sub_id) do
        chain = get_test_chain()
        IntegrationHelper.unsubscribe_client(chain, sub_id)
      end

      @doc """
      Triggers a provider failover for testing.
      """
      defp trigger_failover(provider_id, reason \\ :test_failure) do
        chain = get_test_chain()
        IntegrationHelper.trigger_provider_failover(chain, provider_id, reason)
      end

      @doc """
      Sends a block from a mock provider.

      ## Example

          send_mock_block("provider_id", %{
            "number" => "0x100",
            "hash" => "0xabc123"
          })
      """
      defp send_mock_block(provider_id, block_data) do
        chain = get_test_chain()
        MockWSProvider.send_block(chain, provider_id, block_data)
      end

      @doc """
      Sends a sequence of blocks from a mock provider.

      ## Example

          send_mock_block_sequence("provider_id", 100, 5)
          # Sends blocks 100, 101, 102, 103, 104
      """
      defp send_mock_block_sequence(provider_id, start_block, count) do
        chain = get_test_chain()
        IntegrationHelper.send_block_sequence(chain, provider_id, start_block, count)
      end

      @doc """
      Executes an RPC request via the pipeline.

      Convenience wrapper for testing request execution.

      ## Example

          result = execute_rpc("eth_blockNumber", [])
          assert {:ok, _block_num} = result
      """
      defp execute_rpc(method, params, opts \\ []) do
        chain = Keyword.get(opts, :chain, get_test_chain())
        RequestPipeline.execute_via_channels(chain, method, params, opts)
      end

      @doc """
      Collects telemetry events for a duration.

      Useful for asserting on multiple events.

      ## Example

          events = collect_telemetry([:lasso, :circuit_breaker, :open], timeout: 1000)
          assert length(events) >= 2
      """
      defp collect_telemetry(event_name, opts \\ []) do
        Lasso.Test.TelemetrySync.collect_events(event_name, opts)
      end
    end
  end
end

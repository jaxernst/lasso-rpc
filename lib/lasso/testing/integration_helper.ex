defmodule Lasso.Testing.IntegrationHelper do
  @moduledoc """
  Helper utilities for integration testing with mocked providers.

  Simplifies test setup by providing high-level helpers for:
  - Setting up test chains with mock providers
  - Establishing coordinators with subscriptions
  - Triggering failover scenarios
  - Waiting for coordinator state changes
  """

  alias Lasso.Testing.MockWSProvider
  alias Lasso.RPC.{StreamCoordinator, UpstreamSubscriptionPool}

  @doc """
  Sets up a test chain with mock WebSocket and HTTP providers.

  Returns `{:ok, ws: ws_results, http: http_results}` where each result
  is the provider_id returned by the mock.

  ## Options
  - `:wait_ms` - Time to wait for registration to complete (default: 200)

  ## Example

      {:ok, _providers} = setup_test_chain_with_providers(
        "test_chain",
        [%{id: "ws1", priority: 100}, %{id: "ws2", priority: 90}],
        []
      )
  """
  def setup_test_chain_with_providers(chain, ws_providers, http_providers \\ [], opts \\ []) do
    wait_ms = Keyword.get(opts, :wait_ms, 200)

    # Start all WS mocks
    ws_results =
      Enum.map(ws_providers, fn spec ->
        case MockWSProvider.start_mock(chain, spec) do
          {:ok, provider_id} -> {:ok, provider_id}
          error -> error
        end
      end)

    # Start all HTTP mocks (if we implement MockHTTPProvider later)
    http_results =
      Enum.map(http_providers, fn _spec ->
        # Placeholder for future HTTP mock support
        {:ok, nil}
      end)

    # Wait for registration
    Process.sleep(wait_ms)

    {:ok, ws: ws_results, http: http_results}
  end

  @doc """
  Sets up a StreamCoordinator with an established upstream subscription.

  This helper:
  1. Starts the coordinator
  2. Waits for it to be ready
  3. Returns coordinator PID

  The upstream subscription is established automatically via Pool when the
  first client subscribes.

  ## Options
  - `:wait_ms` - Time to wait for subscription to settle (default: 100)
  - Other options are passed to StreamCoordinator.start_link

  ## Example

      {:ok, coord_pid} = setup_coordinator_with_subscription(
        "test_chain",
        {:newHeads},
        continuity_policy: :zero_gap
      )
  """
  def setup_coordinator_with_subscription(chain, key, opts \\ []) do
    wait_ms = Keyword.get(opts, :wait_ms, 100)
    coordinator_opts = Keyword.drop(opts, [:wait_ms])

    # Start coordinator - it will auto-subscribe via Pool
    {:ok, coord_pid} = StreamCoordinator.start_link({chain, key, coordinator_opts})

    # Wait for subscription to settle
    Process.sleep(wait_ms)

    {:ok, coord_pid}
  end

  @doc """
  Triggers a provider failover by simulating an unhealthy event.

  Broadcasts a provider unhealthy event that will trigger the failover flow.
  """
  def trigger_provider_failover(chain, failed_provider_id, reason \\ :simulated_failure) do
    event = %Lasso.Events.Provider.Unhealthy{
      chain: chain,
      provider_id: failed_provider_id,
      reason: reason,
      ts: System.monotonic_time(:millisecond)
    }

    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "provider_pool:events:#{chain}",
      event
    )

    :ok
  end

  @doc """
  Waits for a coordinator to reach a specific state.

  Polls the coordinator state up to `max_attempts` times with `interval_ms`
  between attempts, calling the `condition_fn` to check if the desired state
  is reached.

  Returns `{:ok, state}` when condition is met, or `{:error, :timeout}` if
  max attempts are exceeded.

  ## Example

      {:ok, state} = wait_for_coordinator_state(coord_pid, fn state ->
        state.mode == :degraded
      end)
  """
  def wait_for_coordinator_state(coord_pid, condition_fn, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 50)
    interval_ms = Keyword.get(opts, :interval_ms, 20)

    wait_for_coordinator_state_recursive(coord_pid, condition_fn, max_attempts, interval_ms, 0)
  end

  defp wait_for_coordinator_state_recursive(
         _coord_pid,
         _condition_fn,
         max_attempts,
         _interval_ms,
         attempts
       )
       when attempts >= max_attempts do
    {:error, :timeout}
  end

  defp wait_for_coordinator_state_recursive(
         coord_pid,
         condition_fn,
         max_attempts,
         interval_ms,
         attempts
       ) do
    state = :sys.get_state(coord_pid)

    if condition_fn.(state) do
      {:ok, state}
    else
      Process.sleep(interval_ms)
      wait_for_coordinator_state_recursive(coord_pid, condition_fn, max_attempts, interval_ms, attempts + 1)
    end
  end

  @doc """
  Subscribes a client to a key via the Pool and returns the subscription ID.

  This is a convenience wrapper around UpstreamSubscriptionPool.subscribe_client.
  """
  def subscribe_client(chain, client_pid \\ nil, key) do
    client_pid = client_pid || self()
    UpstreamSubscriptionPool.subscribe_client(chain, client_pid, key)
  end

  @doc """
  Unsubscribes a client subscription.

  This is a convenience wrapper around UpstreamSubscriptionPool.unsubscribe_client.
  """
  def unsubscribe_client(chain, subscription_id) do
    UpstreamSubscriptionPool.unsubscribe_client(chain, subscription_id)
  end

  @doc """
  Sends a block sequence from a mock provider.

  Useful for testing ordered delivery and buffer management.
  """
  def send_block_sequence(chain, provider_id, start_block, count) do
    Enum.each(start_block..(start_block + count - 1), fn block_num ->
      MockWSProvider.send_block(chain, provider_id, %{
        "number" => "0x" <> Integer.to_string(block_num, 16),
        "hash" => "0x" <> Integer.to_string(block_num * 1000, 16),
        "timestamp" => "0x" <> Integer.to_string(:os.system_time(:second), 16)
      })

      # Small delay to ensure ordering
      Process.sleep(10)
    end)
  end

  @doc """
  Simulates a provider disconnect by stopping the mock provider.

  This is useful for testing circuit breaker and failover scenarios.
  """
  def simulate_disconnect(chain, provider_id) do
    MockWSProvider.stop_mock(chain, provider_id)
  end
end

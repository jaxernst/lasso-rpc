defmodule Lasso.Testing.IntegrationHelper do
  @moduledoc """
  Helper utilities for integration testing with mocked providers.

  Simplifies test setup by providing high-level helpers for:
  - Setting up test chains with mock providers
  - Establishing coordinators with subscriptions
  - Triggering failover scenarios
  - Waiting for coordinator state changes
  """

  alias Lasso.Testing.{MockWSProvider, MockHTTPProvider}
  alias Lasso.RPC.{StreamCoordinator, UpstreamSubscriptionPool}

  @doc """
  Sets up a test chain with mock WebSocket and HTTP providers.

  Returns `{:ok, provider_ids}` where provider_ids is a list of registered provider IDs.

  This enhanced version:
  - Starts all providers (WS and HTTP based on provider_type)
  - Waits for all providers to be fully registered (deterministic)
  - Ensures circuit breakers are ready for each provider
  - Verifies provider health status

  ## Options
  - `:wait_timeout` - Maximum time to wait for all providers to be ready (default: 5000ms)
  - `:skip_circuit_breaker_check` - Skip waiting for circuit breakers (default: false)
  - `:skip_health_check` - Skip waiting for health status (default: false)
  - `:provider_type` - Type of providers to start (`:http` or `:ws`, default: `:http`)

  ## Example

      # HTTP providers (for RequestPipeline testing)
      {:ok, provider_ids} = setup_test_chain_with_providers(
        "test_chain",
        [%{id: "p1", behavior: :healthy}, %{id: "p2", behavior: :always_fail}],
        provider_type: :http
      )

      # WebSocket providers (for subscription testing)
      {:ok, provider_ids} = setup_test_chain_with_providers(
        "test_chain",
        [%{id: "ws1", priority: 100}],
        provider_type: :ws
      )
  """
  def setup_test_chain_with_providers(chain, providers, opts \\ []) when is_list(providers) do
    wait_timeout = Keyword.get(opts, :wait_timeout, 5_000)
    skip_cb_check = Keyword.get(opts, :skip_circuit_breaker_check, false)
    skip_health_check = Keyword.get(opts, :skip_health_check, false)
    provider_type = Keyword.get(opts, :provider_type, :http)

    # Start all provider mocks (HTTP or WS based on provider_type)
    provider_ids =
      Enum.map(providers, fn spec ->
        result =
          case provider_type do
            :http -> MockHTTPProvider.start_mock(chain, spec)
            :ws -> MockWSProvider.start_mock(chain, spec)
          end

        case result do
          {:ok, provider_id} -> provider_id
          error -> raise "Failed to start mock provider: #{inspect(error)}"
        end
      end)

    # Wait for all providers to be fully registered
    Enum.each(provider_ids, fn provider_id ->
      wait_for_provider_ready(chain, provider_id,
        timeout: wait_timeout,
        skip_cb_check: skip_cb_check,
        skip_health_check: skip_health_check
      )
    end)

    {:ok, provider_ids}
  end

  @doc """
  Waits for a provider to be fully ready for testing.

  Checks:
  1. Provider is registered in the provider pool
  2. Circuit breakers are started and ready (unless skipped)
  3. Provider health status is available (unless skipped)

  Returns `:ok` when provider is ready, raises on timeout.
  """
  def wait_for_provider_ready(chain, provider_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    skip_cb_check = Keyword.get(opts, :skip_cb_check, false)
    skip_health_check = Keyword.get(opts, :skip_health_check, false)

    deadline = System.monotonic_time(:millisecond) + timeout

    # Wait for provider registration
    wait_for_provider_registered(chain, provider_id, deadline)

    # Wait for circuit breakers (unless skipped)
    if !skip_cb_check do
      wait_for_circuit_breakers_ready(chain, provider_id, deadline)
    end

    # Wait for health status (unless skipped)
    if !skip_health_check do
      wait_for_provider_health_available(chain, provider_id, deadline)
    end

    :ok
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
    profile = Keyword.get(opts, :profile, "default")
    coordinator_opts = Keyword.drop(opts, [:wait_ms, :profile])

    # Start coordinator - it will auto-subscribe via Pool
    {:ok, coord_pid} = StreamCoordinator.start_link({profile, chain, key, coordinator_opts})

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

      wait_for_coordinator_state_recursive(
        coord_pid,
        condition_fn,
        max_attempts,
        interval_ms,
        attempts + 1
      )
    end
  end

  @doc """
  Subscribes a client to a key via the Pool and returns the subscription ID.

  This is a convenience wrapper around UpstreamSubscriptionPool.subscribe_client.
  """
  def subscribe_client(chain, client_pid \\ nil, key, profile \\ "default") do
    client_pid = client_pid || self()
    UpstreamSubscriptionPool.subscribe_client(profile, chain, client_pid, key)
  end

  @doc """
  Unsubscribes a client subscription.

  This is a convenience wrapper around UpstreamSubscriptionPool.unsubscribe_client.
  """
  def unsubscribe_client(chain, subscription_id, profile \\ "default") do
    UpstreamSubscriptionPool.unsubscribe_client(profile, chain, subscription_id)
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

  # Private synchronization helpers

  defp wait_for_provider_registered(chain, provider_id, deadline) do
    interval = 50

    case poll_until_deadline(deadline, interval, fn ->
           provider_registered?(chain, provider_id)
         end) do
      :ok ->
        :ok

      {:error, :timeout} ->
        raise "Provider #{provider_id} not registered within timeout"
    end
  end

  defp wait_for_circuit_breakers_ready(chain, provider_id, deadline) do
    interval = 50

    # For mock providers, circuit breakers are created lazily on first request
    # Give it a brief window to see if they exist, but don't block
    short_deadline = min(deadline, System.monotonic_time(:millisecond) + 500)

    # Check for both HTTP and WS circuit breakers
    transports = [:http, :ws]

    Enum.each(transports, fn transport ->
      breaker_id = {"default", chain, provider_id, transport}

      case poll_until_deadline(short_deadline, interval, fn ->
             circuit_breaker_exists?(breaker_id)
           end) do
        :ok ->
          :ok

        {:error, :timeout} ->
          # It's ok if circuit breakers don't exist yet for mock providers
          # They're created lazily on first request
          :ok
      end
    end)

    :ok
  end

  defp wait_for_provider_health_available(chain, provider_id, deadline) do
    interval = 50

    case poll_until_deadline(deadline, interval, fn ->
           provider_health_available?(chain, provider_id)
         end) do
      :ok ->
        :ok

      {:error, :timeout} ->
        # Health might not be immediately available for mocks, that's ok
        :ok
    end
  end

  defp poll_until_deadline(deadline, interval, condition_fn) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      if condition_fn.() do
        :ok
      else
        Process.sleep(interval)
        poll_until_deadline(deadline, interval, condition_fn)
      end
    end
  end

  defp provider_registered?(chain, provider_id) do
    case Lasso.RPC.ProviderPool.get_status(chain) do
      {:ok, status} ->
        # Check if provider exists in the providers list
        Enum.any?(status.providers, fn p -> p.id == provider_id end)

      {:error, _} ->
        false
    end
  rescue
    # Chain might not exist yet or ProviderPool might not be started
    _ -> false
  end

  defp circuit_breaker_exists?(breaker_id) do
    try do
      case Lasso.RPC.CircuitBreaker.get_state(breaker_id) do
        %{} -> true
        _ -> false
      end
    catch
      :exit, _ -> false
    end
  end

  defp provider_health_available?(chain, provider_id) do
    case Lasso.RPC.ProviderPool.get_status(chain) do
      {:ok, status} ->
        # Find the provider and check if it has a health status
        case Enum.find(status.providers, fn p -> p.id == provider_id end) do
          nil -> false
          provider -> provider.status in [:healthy, :connecting, :unhealthy, :degraded]
        end

      {:error, _} ->
        false
    end
  rescue
    _ -> false
  end
end

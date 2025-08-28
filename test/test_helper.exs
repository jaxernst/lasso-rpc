ExUnit.start()

# Start the full application to ensure all registries and services are available
Application.ensure_all_started(:livechain)

Mox.defmock(Livechain.RPC.HttpClientMock, for: Livechain.RPC.HttpClient)

# Use the mock adapter for HTTP client in tests
Application.put_env(:livechain, :http_client, Livechain.RPC.HttpClientMock)

# Ensure config store is initialized with test configuration
# This helps with provider selection in tests
config_path = Path.join(__DIR__, "../config/chains.yml")

if File.exists?(config_path) do
  Livechain.Config.ConfigStore.reload()
end

# Load support modules
Code.require_file("test/support/mock_http_client.ex")

# Ensure test isolation by resetting benchmark store between tests
ExUnit.configure(
  exclude: [:skip],
  capture_log: true,
  timeout: 60_000,
  max_cases: 1
)

# Global test setup to ensure clean state
ExUnit.after_suite(fn _ ->
  # Clean up any remaining processes and state
  TestHelper.global_cleanup()
end)

# Helper to ensure clean test state
defmodule TestHelper do
  @moduledoc """
  Helper functions for test setup and cleanup.
  """

  def ensure_clean_state() do
    # Clean benchmark store if it's running
    try do
      case GenServer.whereis(Livechain.Benchmarking.BenchmarkStore) do
        nil ->
          :ok

        _pid ->
          # Clear metrics for common test chains
          Enum.each(
            ["ethereum", "polygon", "testnet", "test_chain", "integration_test_chain"],
            fn chain ->
              Livechain.Benchmarking.BenchmarkStore.clear_chain_metrics(chain)
            end
          )
      end
    rescue
      _ -> :ok
    end

    # Clean subscription manager state if it's running
    try do
      case GenServer.whereis(Livechain.RPC.SubscriptionManager) do
        nil ->
          :ok

        _pid ->
          # Get all current subscriptions and unsubscribe them
          subscriptions = Livechain.RPC.SubscriptionManager.get_subscriptions()

          Enum.each(subscriptions, fn {sub_id, _sub} ->
            Livechain.RPC.SubscriptionManager.unsubscribe(sub_id)
          end)
      end
    rescue
      _ -> :ok
    end
  end

  def global_cleanup() do
    # Stop any running GenServers that might have been started during tests
    try do
      # Stop test-specific processes
      case GenServer.whereis(Livechain.RPC.SubscriptionManagerTest.MockChainManager) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal, 1000)
      end
    rescue
      _ -> :ok
    end

    # Clean up ETS tables
    try do
      [:subscriptions, :event_cache]
      |> Enum.each(fn table ->
        case :ets.whereis(table) do
          :undefined -> :ok
          _ -> :ets.delete_all_objects(table)
        end
      end)
    rescue
      _ -> :ok
    end
  end

  def ensure_test_environment_ready() do
    # First ensure the main application is started
    case Application.ensure_all_started(:livechain) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Failed to start livechain application: #{inspect(reason)}"
    end

    # Wait for critical services with specific checks
    # Phoenix.PubSub is started with name: Livechain.PubSub
    wait_for_service_with_check(
      fn -> 
        # Simple test: try to get child spec
        :supervisor.which_children(Livechain.PubSub)
      end,
      "PubSub (Livechain.PubSub)"
    )
    
    # Registry is started with name: Livechain.Registry
    wait_for_service_with_check(
      fn -> Registry.select(Livechain.Registry, []) end,
      "Registry (Livechain.Registry)"
    )
    
    wait_for_service(Livechain.RPC.ProcessRegistry, "ProcessRegistry")
    
    # Give a moment for any post-startup initialization
    Process.sleep(100)
    :ok
  end

  defp wait_for_service_with_check(check_func, description) do
    wait_for_service_with_check_backoff(check_func, description, 1, 10_000, 50)
  end

  defp wait_for_service_with_check_backoff(check_func, description, attempt, max_wait_ms, base_sleep_ms) do
    if attempt * base_sleep_ms > max_wait_ms do
      raise "#{description} service not available after #{max_wait_ms}ms timeout"
    end

    try do
      check_func.()
      :ok
    rescue
      _ ->
        sleep_time = min(base_sleep_ms * attempt, 1000)
        Process.sleep(sleep_time)
        wait_for_service_with_check_backoff(check_func, description, attempt + 1, max_wait_ms, base_sleep_ms)
    end
  end

  defp wait_for_service(service_name, description) do
    case GenServer.whereis(service_name) do
      nil ->
        # Wait up to 10 seconds for the service to start with exponential backoff
        # This handles heavy test load scenarios better
        wait_with_backoff(service_name, description, 1, 10_000, 50)

      _pid ->
        :ok
    end
  end


  defp wait_with_backoff(service_name, description, attempt, max_wait_ms, base_sleep_ms) do
    if attempt * base_sleep_ms > max_wait_ms do
      raise "#{description} service not available after #{max_wait_ms}ms timeout"
    end

    case GenServer.whereis(service_name) do
      nil ->
        # Exponential backoff: 50ms, 100ms, 200ms, 400ms, etc.
        sleep_time = min(base_sleep_ms * attempt, 1000)
        Process.sleep(sleep_time)
        wait_with_backoff(service_name, description, attempt + 1, max_wait_ms, base_sleep_ms)

      _pid ->
        :ok
    end
  end

  def create_test_provider_config(id, priority \\ 1, type \\ "test") do
    %{
      id: id,
      name: "Test Provider #{id}",
      priority: priority,
      type: type,
      url: "https://#{id}.example.com",
      ws_url: "wss://#{id}.example.com/ws",
      api_key_required: false
    }
  end

  def create_test_chain_config(
        chain_name,
        provider_ids \\ ["provider1", "provider2", "provider3"]
      ) do
    providers =
      provider_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {id, priority} ->
        create_test_provider_config(id, priority)
      end)

    %{
      chain_id: 1,
      name: "Test Chain #{chain_name}",
      block_time: 1000,
      providers: providers
    }
  end

  def setup_test_chain(chain_name, provider_ids \\ ["provider1", "provider2", "provider3"]) do
    # Create a test config and manually insert it into the ETS table

    Enum.each(provider_ids, fn provider_id ->
      # Add some benchmark data so the provider appears in selection
      Livechain.Benchmarking.BenchmarkStore.record_event_race_win(
        chain_name,
        provider_id,
        :newHeads,
        System.monotonic_time(:millisecond)
      )
    end)

    :ok
  end
end

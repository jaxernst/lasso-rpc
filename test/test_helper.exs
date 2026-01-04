ExUnit.start()

# Start the full application to ensure all registries and services are available
Application.ensure_all_started(:lasso)

# Validate test environment isolation
defmodule TestStartupValidator do
  require Logger

  def validate_test_environment! do
    # Verify only test profiles loaded
    profiles = Lasso.Config.ConfigStore.list_profiles()

    unless profiles == ["default"] do
      raise """
      Test environment loaded unexpected profiles: #{inspect(profiles)}
      Expected only: ["default"]
      Check config/test_profiles/default.yml exists and config/test.exs uses backend_config
      """
    end

    # Verify no chains pre-configured
    chains = Lasso.Config.ConfigStore.list_chains()

    unless Enum.empty?(chains) do
      raise """
      Test environment has pre-configured chains: #{inspect(chains)}
      Integration tests should register chains dynamically.
      Check config/test_profiles/default.yml has empty chains: {}
      """
    end

    Logger.info("✓ Test environment validated: no real providers loaded")
  end
end

TestStartupValidator.validate_test_environment!()

Mox.defmock(Lasso.RPC.HttpClientMock, for: Lasso.RPC.HttpClient)

# Note: HTTP client mock is available but NOT set by default
# Integration tests use real Finch client (configured in config/test.exs)
# Unit tests can opt-in to mocking via:
#   setup do
#     Application.put_env(:lasso, :http_client, Lasso.RPC.HttpClientMock)
#     on_exit(fn -> Application.put_env(:lasso, :http_client, Lasso.RPC.HttpClient.Finch) end)
#   end

# Use mock WS client in tests for deterministic WSConnection behavior
Application.put_env(:lasso, :ws_client_module, TestSupport.MockWSClient)

# Load support modules
Code.require_file("test/support/mock_http_client.ex")
Code.require_file("test/support/mock_ws_client.ex")
Code.require_file("test/support/failing_ws_client.ex")
Code.require_file("test/support/failure_injector.ex")

# Load new test infrastructure
Code.require_file("test/support/telemetry_sync.ex")
Code.require_file("test/support/eventually.ex")
Code.require_file("test/support/circuit_breaker_helper.ex")
Code.require_file("test/support/lasso_integration_case.ex")

# Configure behavior-based HTTP client for integration tests
# This routes HTTP RPC requests to MockHTTPProvider instances with rich behaviors
Application.put_env(:lasso, :http_client, Lasso.Testing.BehaviorHttpClient)

# Ensure test isolation by resetting benchmark store between tests
# By default, exclude slow-running tests (integration, real providers)
ExUnit.configure(
  exclude: [:skip, :integration, :real_providers, :slow],
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
      case GenServer.whereis(Lasso.Benchmarking.BenchmarkStore) do
        nil ->
          :ok

        _pid ->
          # Clear metrics for common test chains (using default profile)
          Enum.each(
            ["ethereum", "polygon", "testnet", "test_chain", "integration_test_chain"],
            fn chain ->
              Lasso.Benchmarking.BenchmarkStore.clear_chain_metrics("default", chain)
            end
          )
      end
    rescue
      _ -> :ok
    end

    # Clean subscription pools if they're running
    try do
      # Clean up any active upstream subscription pools
      Registry.select(Lasso.Registry, [{{:pool, :"$1"}, :_, :_}])
      |> Enum.each(fn {_key, pool_pid} ->
        if Process.alive?(pool_pid) do
          # Pool cleanup is handled by supervisor termination
          :ok
        end
      end)
    rescue
      _ -> :ok
    end
  end

  def global_cleanup() do
    # Stop any running GenServers that might have been started during tests
    try do
      # Stop test-specific processes
      # Clean up any test-specific mock processes that may have been started
      :ok
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
    case Application.ensure_all_started(:lasso) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "Failed to start lasso application: #{inspect(reason)}"
    end

    # Wait for critical services with specific checks
    # Phoenix.PubSub is started with name: Lasso.PubSub
    wait_for_service_with_check(
      fn ->
        # Simple test: try to get child spec
        :supervisor.which_children(Lasso.PubSub)
      end,
      "PubSub (Lasso.PubSub)"
    )

    # Registry is started with name: Lasso.Registry
    wait_for_service_with_check(
      fn -> Registry.select(Lasso.Registry, []) end,
      "Registry (Lasso.Registry)"
    )

    wait_for_service(Lasso.RPC.ProcessRegistry, "ProcessRegistry")

    # Give a moment for any post-startup initialization
    Process.sleep(100)
    :ok
  end

  defp wait_for_service_with_check(check_func, description) do
    wait_for_service_with_check_backoff(check_func, description, 1, 10_000, 50)
  end

  defp wait_for_service_with_check_backoff(
         check_func,
         description,
         attempt,
         max_wait_ms,
         base_sleep_ms
       ) do
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

        wait_for_service_with_check_backoff(
          check_func,
          description,
          attempt + 1,
          max_wait_ms,
          base_sleep_ms
        )
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

  def eventually(func, timeout_ms \\ 1000) do
    eventually_with_delay(func, timeout_ms, 10)
  end

  defp eventually_with_delay(func, timeout_ms, delay_ms) do
    start_time = System.monotonic_time(:millisecond)

    case func.() do
      true ->
        true

      false ->
        if System.monotonic_time(:millisecond) - start_time >= timeout_ms do
          false
        else
          Process.sleep(delay_ms)
          eventually_with_delay(func, timeout_ms, delay_ms)
        end
    end
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
      Lasso.Benchmarking.BenchmarkStore.record_rpc_call(
        "default",
        chain_name,
        provider_id,
        "eth_blockNumber",
        100,
        :success
      )
    end)

    :ok
  end
end

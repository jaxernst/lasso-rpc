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

# Helper to ensure clean test state
defmodule TestHelper do
  @moduledoc """
  Helper functions for test setup and cleanup.
  """

  def ensure_clean_state() do
    # Clean benchmark store
    try do
      # Clear metrics for common test chains
      Enum.each(["ethereum", "polygon", "testnet", "test_chain"], fn chain ->
        Livechain.Benchmarking.BenchmarkStore.clear_chain_metrics(chain)
      end)
    rescue
      _ -> :ok
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
      api_key_required: false,
      rate_limit: 1000,
      latency_target: 100 + priority * 10,
      reliability: 0.99 - priority * 0.01
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

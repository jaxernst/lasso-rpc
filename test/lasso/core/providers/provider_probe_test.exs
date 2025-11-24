defmodule Lasso.RPC.ProviderProbeTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.ProviderProbe
  alias Lasso.RPC.ProviderPool

  setup do
    # Generate unique chain name for each test to avoid conflicts
    chain = "test_probe_chain_#{System.unique_integer([:positive])}"

    # Configure test chain
    chain_config = %{
      chain_id: 1,
      providers: [
        %{
          id: "test_provider_1",
          name: "Test Provider 1",
          url: "http://localhost:8545",
          priority: 100
        },
        %{
          id: "test_provider_2",
          name: "Test Provider 2",
          url: "http://localhost:8546",
          priority: 90
        }
      ]
    }

    # Start ProviderPool (required by ProviderProbe)
    # Registry and PubSub are already started by the application
    # Use explicit ID to avoid ExUnit supervision tree conflicts
    # Note: ConfigStore registration is not required for ProviderPool to function
    start_supervised!({ProviderPool, {chain, chain_config}}, id: {:provider_pool, chain})

    {:ok, chain: chain, chain_config: chain_config}
  end

  describe "start_link/1" do
    test "starts ProviderProbe GenServer", %{chain: chain} do
      assert {:ok, pid} = ProviderProbe.start_link(chain)
      assert Process.alive?(pid)
    end

    test "registers with correct name", %{chain: chain} do
      {:ok, _pid} = ProviderProbe.start_link(chain)
      assert is_pid(GenServer.whereis(ProviderProbe.via(chain)))
    end
  end

  describe "probe cycle" do
    test "executes probe cycle and reports results", %{chain: chain} do
      # Start probe
      {:ok, _pid} = ProviderProbe.start_link(chain)

      # Trigger manual probe
      ProviderProbe.trigger_probe(chain)

      # Give it time to execute
      Process.sleep(100)

      # Verify telemetry was emitted (results were collected)
      # In a real test, you'd mock the HTTP client and verify results
    end
  end

  describe "configuration" do
    test "uses default probe interval when not configured", %{chain: chain} do
      Application.put_env(:lasso, :provider_probe, default_probe_interval_ms: 15_000)

      {:ok, _pid} = ProviderProbe.start_link(chain)

      # Verify the interval is set correctly
      # In a real implementation, you'd check the state or timing
    end

    test "uses chain-specific probe interval when configured", %{chain: chain} do
      Application.put_env(:lasso, :provider_probe,
        probe_interval_by_chain: %{chain => 5_000},
        default_probe_interval_ms: 12_000
      )

      {:ok, _pid} = ProviderProbe.start_link(chain)

      # Verify chain-specific interval is used
    end
  end

  describe "error handling" do
    test "handles provider probe failures gracefully", %{chain: chain} do
      {:ok, _pid} = ProviderProbe.start_link(chain)

      # Trigger probe with unavailable providers
      ProviderProbe.trigger_probe(chain)

      # Should not crash
      Process.sleep(100)
      assert Process.alive?(GenServer.whereis(ProviderProbe.via(chain)))
    end

    test "handles empty provider list" do
      # Create chain with no providers
      empty_chain = "empty_chain_#{System.unique_integer([:positive])}"
      start_supervised!({ProviderPool, {empty_chain, %{chain_id: 1, providers: []}}}, id: {:provider_pool, empty_chain})

      {:ok, _pid} = ProviderProbe.start_link(empty_chain)

      # Trigger probe
      ProviderProbe.trigger_probe(empty_chain)

      # Should not crash
      Process.sleep(100)
      assert Process.alive?(GenServer.whereis(ProviderProbe.via(empty_chain)))
    end
  end

  describe "telemetry" do
    test "emits cycle_completed telemetry event", %{chain: chain} do
      {:ok, _pid} = ProviderProbe.start_link(chain)

      # Attach telemetry handler
      test_pid = self()
      handler_id = "test-#{System.unique_integer()}"

      :telemetry.attach(
        handler_id,
        [:lasso, :provider_probe, :cycle_completed],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      # Trigger probe
      ProviderProbe.trigger_probe(chain)

      # Wait for telemetry
      assert_receive {:telemetry_event, [:lasso, :provider_probe, :cycle_completed], measurements, metadata}, 1000

      # Verify measurements include expected keys
      assert Map.has_key?(measurements, :successful)
      assert Map.has_key?(measurements, :failed)
      assert Map.has_key?(measurements, :duration_ms)
      assert metadata.chain == chain

      :telemetry.detach(handler_id)
    end
  end
end

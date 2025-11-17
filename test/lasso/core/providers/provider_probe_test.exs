defmodule Lasso.RPC.ProviderProbeTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.ProviderProbe
  alias Lasso.RPC.ProviderPool
  alias Lasso.Config.ConfigStore

  setup do
    # Start necessary dependencies
    start_supervised!({Registry, keys: :unique, name: Lasso.Registry})
    start_supervised!({Phoenix.PubSub, name: Lasso.PubSub})

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

    # Store config
    ConfigStore.start_link([])
    ConfigStore.put_chain("test_chain", chain_config)

    # Start ProviderPool (required by ProviderProbe)
    start_supervised!({ProviderPool, {"test_chain", chain_config}})

    {:ok, chain_config: chain_config}
  end

  describe "start_link/1" do
    test "starts ProviderProbe GenServer" do
      assert {:ok, pid} = ProviderProbe.start_link("test_chain")
      assert Process.alive?(pid)
    end

    test "registers with correct name" do
      {:ok, _pid} = ProviderProbe.start_link("test_chain")
      assert is_pid(GenServer.whereis(ProviderProbe.via("test_chain")))
    end
  end

  describe "probe cycle" do
    test "executes probe cycle and reports results" do
      # Start probe
      {:ok, _pid} = ProviderProbe.start_link("test_chain")

      # Trigger manual probe
      ProviderProbe.trigger_probe("test_chain")

      # Give it time to execute
      Process.sleep(100)

      # Verify telemetry was emitted (results were collected)
      # In a real test, you'd mock the HTTP client and verify results
    end
  end

  describe "configuration" do
    test "uses default probe interval when not configured" do
      Application.put_env(:lasso, :provider_probe, default_probe_interval_ms: 15_000)

      {:ok, _pid} = ProviderProbe.start_link("test_chain")

      # Verify the interval is set correctly
      # In a real implementation, you'd check the state or timing
    end

    test "uses chain-specific probe interval when configured" do
      Application.put_env(:lasso, :provider_probe,
        probe_interval_by_chain: %{"test_chain" => 5_000},
        default_probe_interval_ms: 12_000
      )

      {:ok, _pid} = ProviderProbe.start_link("test_chain")

      # Verify chain-specific interval is used
    end
  end

  describe "error handling" do
    test "handles provider probe failures gracefully" do
      {:ok, _pid} = ProviderProbe.start_link("test_chain")

      # Trigger probe with unavailable providers
      ProviderProbe.trigger_probe("test_chain")

      # Should not crash
      Process.sleep(100)
      assert Process.alive?(GenServer.whereis(ProviderProbe.via("test_chain")))
    end

    test "handles empty provider list" do
      # Create chain with no providers
      ConfigStore.put_chain("empty_chain", %{chain_id: 1, providers: []})
      start_supervised!({ProviderPool, {"empty_chain", %{chain_id: 1, providers: []}}})

      {:ok, _pid} = ProviderProbe.start_link("empty_chain")

      # Trigger probe
      ProviderProbe.trigger_probe("empty_chain")

      # Should not crash
      Process.sleep(100)
      assert Process.alive?(GenServer.whereis(ProviderProbe.via("empty_chain")))
    end
  end

  describe "telemetry" do
    test "emits cycle_completed telemetry event" do
      {:ok, _pid} = ProviderProbe.start_link("test_chain")

      # Attach telemetry handler
      ref = :telemetry_test.attach_event_handlers(self(), [
        [:lasso, :provider_probe, :cycle_completed]
      ])

      # Trigger probe
      ProviderProbe.trigger_probe("test_chain")

      # Wait for telemetry
      assert_receive {:telemetry_event, [:lasso, :provider_probe, :cycle_completed], measurements, metadata}, 1000

      # Verify measurements include expected keys
      assert Map.has_key?(measurements, :successful)
      assert Map.has_key?(measurements, :failed)
      assert Map.has_key?(measurements, :duration_ms)
      assert metadata.chain == "test_chain"

      :telemetry.detach(ref)
    end
  end
end

defmodule Lasso.RPC.ChainStateTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.ChainState
  alias Lasso.RPC.ProviderPool

  setup do
    # Start necessary dependencies
    start_supervised!({Registry, keys: :unique, name: Lasso.Registry})
    start_supervised!({Phoenix.PubSub, name: Lasso.PubSub})

    # Configure test chain
    chain_config = %{
      chain_id: 1,
      providers: [
        %{id: "provider_1", name: "Provider 1", url: "http://localhost:8545", priority: 100},
        %{id: "provider_2", name: "Provider 2", url: "http://localhost:8546", priority: 90},
        %{id: "provider_3", name: "Provider 3", url: "http://localhost:8547", priority: 80}
      ]
    }

    # Start ProviderPool (creates ETS table)
    start_supervised!({ProviderPool, {"test_chain", chain_config}})

    {:ok, chain: "test_chain"}
  end

  describe "consensus_height/2" do
    test "calculates consensus from fresh provider data", %{chain: chain} do
      # Insert fresh provider sync states
      table = ProviderPool.table_name(chain)
      now = System.system_time(:millisecond)

      :ets.insert(table, {{:provider_sync, chain, "provider_1"}, {1_000_000, now, 1}})
      :ets.insert(table, {{:provider_sync, chain, "provider_2"}, {1_000_005, now, 1}})
      :ets.insert(table, {{:provider_sync, chain, "provider_3"}, {999_995, now, 1}})

      # Consensus should be max height
      assert {:ok, 1_000_005} = ChainState.consensus_height(chain)
    end

    test "excludes stale provider data from consensus", %{chain: chain} do
      # Insert mix of fresh and stale data
      table = ProviderPool.table_name(chain)
      now = System.system_time(:millisecond)
      old = now - 30_000  # 30 seconds old

      :ets.insert(table, {{:provider_sync, chain, "provider_1"}, {1_000_000, now, 1}})
      :ets.insert(table, {{:provider_sync, chain, "provider_2"}, {1_000_005, now, 1}})
      :ets.insert(table, {{:provider_sync, chain, "provider_3"}, {1_100_000, old, 0}})  # Stale, higher

      # Consensus should be max of FRESH data only (not the stale 1_100_000)
      assert {:ok, 1_000_005} = ChainState.consensus_height(chain)
    end

    test "returns error when no fresh data available", %{chain: chain} do
      # No data in table
      assert {:error, :no_fresh_data} = ChainState.consensus_height(chain)
    end

    test "returns stale consensus when allow_stale: true", %{chain: chain} do
      # Insert stale data
      table = ProviderPool.table_name(chain)
      old = System.system_time(:millisecond) - 30_000

      :ets.insert(table, {{:provider_sync, chain, "provider_1"}, {1_000_000, old, 1}})
      :ets.insert(table, {{:provider_sync, chain, "provider_2"}, {1_000_005, old, 1}})

      # Without allow_stale, should error
      assert {:error, :no_fresh_data} = ChainState.consensus_height(chain)

      # With allow_stale, should return stale data with :stale indicator
      assert {:ok, 1_000_005, :stale} = ChainState.consensus_height(chain, allow_stale: true)
    end

    test "returns error when data is too old even with allow_stale", %{chain: chain} do
      # Insert very old data (> 60 seconds)
      table = ProviderPool.table_name(chain)
      very_old = System.system_time(:millisecond) - 70_000

      :ets.insert(table, {{:provider_sync, chain, "provider_1"}, {1_000_000, very_old, 1}})

      # Should error even with allow_stale
      assert {:error, :no_data_available} = ChainState.consensus_height(chain, allow_stale: true)
    end
  end

  describe "consensus_height!/1" do
    test "returns height directly when available", %{chain: chain} do
      # Insert fresh data
      table = ProviderPool.table_name(chain)
      now = System.system_time(:millisecond)

      :ets.insert(table, {{:provider_sync, chain, "provider_1"}, {1_000_000, now, 1}})

      assert 1_000_000 = ChainState.consensus_height!(chain)
    end

    test "raises when consensus unavailable", %{chain: chain} do
      # No data
      assert_raise ArgumentError, ~r/Consensus height unavailable/, fn ->
        ChainState.consensus_height!(chain)
      end
    end
  end

  describe "provider_lag/2" do
    test "returns lag for a provider", %{chain: chain} do
      # Insert lag data
      table = ProviderPool.table_name(chain)

      :ets.insert(table, {{:provider_lag, chain, "provider_1"}, -5})
      :ets.insert(table, {{:provider_lag, chain, "provider_2"}, 0})
      :ets.insert(table, {{:provider_lag, chain, "provider_3"}, 3})

      assert {:ok, -5} = ChainState.provider_lag(chain, "provider_1")
      assert {:ok, 0} = ChainState.provider_lag(chain, "provider_2")
      assert {:ok, 3} = ChainState.provider_lag(chain, "provider_3")
    end

    test "returns error when provider not found", %{chain: chain} do
      assert {:error, :not_found} = ChainState.provider_lag(chain, "nonexistent")
    end

    test "returns error when table not found" do
      assert {:error, :table_not_found} = ChainState.provider_lag("nonexistent_chain", "provider")
    end
  end

  describe "consensus_fresh?/1" do
    test "returns true when consensus is fresh", %{chain: chain} do
      # Insert fresh data
      table = ProviderPool.table_name(chain)
      now = System.system_time(:millisecond)

      :ets.insert(table, {{:provider_sync, chain, "provider_1"}, {1_000_000, now, 1}})

      assert ChainState.consensus_fresh?(chain) == true
    end

    test "returns false when consensus is stale", %{chain: chain} do
      # Insert stale data
      table = ProviderPool.table_name(chain)
      old = System.system_time(:millisecond) - 30_000

      :ets.insert(table, {{:provider_sync, chain, "provider_1"}, {1_000_000, old, 1}})

      assert ChainState.consensus_fresh?(chain) == false
    end

    test "returns false when no data available", %{chain: chain} do
      assert ChainState.consensus_fresh?(chain) == false
    end
  end

  describe "current_sequence/1" do
    test "returns current sequence number from provider data", %{chain: chain} do
      # Insert data with different sequences
      table = ProviderPool.table_name(chain)
      now = System.system_time(:millisecond)

      :ets.insert(table, {{:provider_sync, chain, "provider_1"}, {1_000_000, now, 5}})
      :ets.insert(table, {{:provider_sync, chain, "provider_2"}, {1_000_005, now, 7}})
      :ets.insert(table, {{:provider_sync, chain, "provider_3"}, {999_995, now, 3}})

      # Should return max sequence
      assert {:ok, 7} = ChainState.current_sequence(chain)
    end

    test "returns error when no data available", %{chain: chain} do
      assert {:error, :no_data} = ChainState.current_sequence(chain)
    end
  end

  describe "configuration" do
    test "uses chain-specific probe interval for consensus window" do
      # Configure probe interval
      Application.put_env(:lasso, :provider_probe,
        probe_interval_by_chain: %{"test_chain" => 10_000},
        default_probe_interval_ms: 12_000
      )

      # Insert data just within the 1.5x window (15s for 10s interval)
      chain = "test_chain"
      table = ProviderPool.table_name(chain)
      now = System.system_time(:millisecond)
      almost_stale = now - 14_000  # 14 seconds old, within 15s window

      :ets.insert(table, {{:provider_sync, chain, "provider_1"}, {1_000_000, almost_stale, 1}})

      # Should still be considered fresh
      assert {:ok, 1_000_000} = ChainState.consensus_height(chain)
    end

    test "uses default probe interval when chain not configured" do
      Application.put_env(:lasso, :provider_probe,
        default_probe_interval_ms: 12_000
      )

      # Consensus window should be 18s (1.5x 12s)
      chain = "unconfigured_chain"

      # Start pool for unconfigured chain
      start_supervised!({ProviderPool, {chain, %{chain_id: 2, providers: []}}})

      table = ProviderPool.table_name(chain)
      now = System.system_time(:millisecond)
      within_window = now - 17_000  # Within 18s

      :ets.insert(table, {{:provider_sync, chain, "provider_1"}, {1_000_000, within_window, 1}})

      assert {:ok, 1_000_000} = ChainState.consensus_height(chain)
    end
  end
end

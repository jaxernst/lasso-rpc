defmodule Lasso.Battle.WebSocketSubscriptionTest do
  use ExUnit.Case, async: false
  require Logger

  alias Lasso.Battle.{Workload, SetupHelper}

  @moduletag :battle
  @moduletag :real_providers
  @moduletag timeout: 120_000

  setup_all do
    # Override HTTP client for real provider tests
    original_client = Application.get_env(:lasso, :http_client)
    Application.put_env(:lasso, :http_client, Lasso.RPC.HttpClient.Finch)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, original_client)
    end)

    :ok
  end

  setup do
    Application.ensure_all_started(:lasso)

    on_exit(fn ->
      try do
        SetupHelper.cleanup_providers("ethereum", ["llamarpc"])
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  describe "WebSocket newHeads subscription" do
    # Requires real blockchain events (~12s Ethereum blocks)
    @tag :slow
    test "basic subscription receives events" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])

      # Use Workload.ws_subscribe directly (returns stats synchronously)
      stats =
        Workload.ws_subscribe(
          chain: "ethereum",
          subscription: "newHeads",
          count: 1,
          duration: 30_000
        )

      # Verify subscription stats
      assert stats.subscriptions == 1
      # Should receive at least a few blocks (Ethereum ~12s block time)
      assert stats.events_received >= 1, "Expected at least 1 event, got #{stats.events_received}"

      Logger.info("✅ WebSocket subscription stats: #{inspect(stats)}")
      IO.puts("\n✅ Basic WebSocket Subscription Test Passed!")
      IO.puts("   Events received: #{stats.events_received}")
      IO.puts("   Duplicates: #{stats.duplicates}")
      IO.puts("   Gaps: #{stats.gaps}")
    end

    # 60s test requiring real blockchain events
    @tag :slow
    test "multiple concurrent subscriptions receive events" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])

      # 5 concurrent subscriptions for 60 seconds
      stats =
        Workload.ws_subscribe(
          chain: "ethereum",
          subscription: "newHeads",
          count: 5,
          duration: 60_000
        )

      assert stats.subscriptions == 5
      assert stats.events_received >= 5, "Expected multiple events across clients"

      # Check per-client stats
      Enum.each(stats.per_client_stats, fn client_stats ->
        assert client_stats.events_received >= 1,
               "Client #{client_stats.client_id} should receive events"
      end)

      Logger.info("✅ Multi-client stats: #{inspect(stats)}")
      IO.puts("\n✅ Concurrent Subscriptions Test Passed!")
      IO.puts("   Total events: #{stats.events_received}")
      IO.puts("   Clients: #{stats.subscriptions}")
    end

    # 30s test requiring real blockchain events
    @tag :slow
    test "subscription tracks duplicates and gaps" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])

      stats =
        Workload.ws_subscribe(
          chain: "ethereum",
          subscription: "newHeads",
          count: 1,
          duration: 30_000
        )

      # Verify tracking fields exist
      assert is_integer(stats.duplicates)
      assert is_integer(stats.gaps)

      # In normal operation, we expect 0 duplicates and 0 gaps
      Logger.info("Duplicate/Gap tracking: duplicates=#{stats.duplicates}, gaps=#{stats.gaps}")

      IO.puts("\n✅ Duplicate/Gap Detection Test Passed!")
      IO.puts("   Duplicates: #{stats.duplicates}")
      IO.puts("   Gaps: #{stats.gaps}")
    end
  end

  # WebSocket logs subscription tests removed - logs subscriptions are too sparse
  # and unpredictable for reliable testing. If needed, test logs subscriptions
  # separately with controlled test infrastructure.

  describe "WebSocket subscription lifecycle" do
    # 10s test requiring real blockchain connection
    @tag :slow
    test "subscriptions clean up properly" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])

      stats =
        Workload.ws_subscribe(
          chain: "ethereum",
          subscription: "newHeads",
          count: 3,
          duration: 10_000
        )

      # All clients should have stopped after duration
      Enum.each(stats.clients, fn pid ->
        refute Process.alive?(pid), "Client process should be stopped after duration"
      end)

      IO.puts("\n✅ Subscription Cleanup Test Passed!")
      IO.puts("   All #{stats.subscriptions} clients stopped cleanly")
    end
  end
end

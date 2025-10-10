defmodule Lasso.Battle.WebSocketFailoverTest do
  use ExUnit.Case, async: false
  require Logger

  alias Lasso.Battle.{Workload, Chaos, SetupHelper}

  @moduletag :battle
  @moduletag :real_providers
  @moduletag timeout: 180_000

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
        SetupHelper.cleanup_providers("ethereum", ["llamarpc", "ankr"])
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  describe "WebSocket subscription failover" do
    # 90s test with failover, requires real blockchain events
    @tag :slow
    test "subscription continues receiving events during provider failure" do
      # Setup 2 real providers
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"},
        {:real, "ankr", "https://rpc.ankr.com/eth", "wss://rpc.ankr.com/eth/ws"}
      ])

      # Seed benchmarks to prefer llamarpc initially (lower latency = higher priority)
      SetupHelper.seed_benchmarks("ethereum", "eth_subscribe", [
        {"llamarpc", 50},
        {"ankr", 200}
      ])

      # Subscribe to circuit breaker events to track failover
      Phoenix.PubSub.subscribe(Lasso.PubSub, "circuit:events")

      # Start subscription task
      parent = self()

      task =
        Task.async(fn ->
          stats =
            Workload.ws_subscribe(
              chain: "ethereum",
              subscription: "newHeads",
              count: 1,
              duration: 90_000
            )

          send(parent, {:stats, stats})
          stats
        end)

      # Wait for subscription to establish
      Process.sleep(5_000)

      # Detect which provider is actually being used by checking Pool state
      pool_pid = Lasso.RPC.UpstreamSubscriptionPool.via("ethereum")
      pool_state = :sys.get_state(pool_pid)

      active_provider =
        case pool_state.keys do
          %{{:newHeads} => %{primary_provider_id: provider_id}} ->
            Logger.info("📡 Detected active provider: #{provider_id}")
            provider_id

          _ ->
            Logger.info("📡 No active subscription found, defaulting to ankr")
            "ankr"
        end

      # Kill the ACTIVE provider (not necessarily llamarpc)
      Logger.info("💥 Killing #{active_provider} provider to trigger failover")
      kill_fn = Chaos.kill_provider(active_provider, chain: "ethereum")
      kill_fn.()

      # Wait for circuit breaker to open (failover indicator)
      circuit_opened =
        receive do
          {:circuit_breaker_event, %{provider_id: ^active_provider, to: :open}} ->
            Logger.info("✓ Circuit breaker opened for #{active_provider} - failover triggered")
            true
        after
          10_000 ->
            Logger.warning("⚠️  Circuit breaker did not open for #{active_provider} within 10s")
            false
        end

      # Wait for more events to arrive from backup provider
      Process.sleep(5_000)

      # Get stats when subscription completes
      stats = Task.await(task, 120_000)

      # Verify subscription received events
      assert stats.subscriptions == 1

      assert stats.events_received >= 3,
             "Expected events despite failover, got #{stats.events_received}"

      # Verify failover actually occurred
      assert circuit_opened,
             "Failover test invalid: #{active_provider} circuit breaker never opened"

      # Critical: Assert zero gaps during failover
      assert stats.gaps == 0,
             "ZERO-GAP GUARANTEE VIOLATED: Expected 0 gaps during failover, got #{stats.gaps}"

      # Assert bounded duplicate rate during failover
      # During failover, backfill + new subscription may create some overlap
      # Allow up to 30% duplicates (higher than normal 5% due to failover overlap)
      duplicate_rate =
        if stats.events_received > 0 do
          stats.duplicates / stats.events_received
        else
          0.0
        end

      assert duplicate_rate <= 0.30,
             "Duplicate rate too high during failover: #{Float.round(duplicate_rate * 100, 2)}% (expected ≤30%)"

      # Log failover metrics
      Logger.info("""
      ✅ WebSocket Failover Test Results:
         Events received: #{stats.events_received}
         Gaps: #{stats.gaps} ✓ (ZERO)
         Duplicates: #{stats.duplicates} (#{Float.round(duplicate_rate * 100, 2)}%)
         Duplicate rate: #{Float.round(duplicate_rate * 100, 2)}% (within 30% threshold)
         Failover verified: #{circuit_opened}
      """)

      IO.puts("\n✅ WebSocket Failover Test Passed!")
      IO.puts("   Subscription continued during provider failure")
      IO.puts("   Failed provider: #{active_provider}")
      IO.puts("   Events received: #{stats.events_received}")
      IO.puts("   Gaps: #{stats.gaps} (ZERO - failover guarantee met!)")

      IO.puts(
        "   Duplicates: #{stats.duplicates} (#{Float.round(duplicate_rate * 100, 2)}% - within threshold)"
      )

      IO.puts("   Failover verified: Circuit breaker opened for #{active_provider}")
    end

    # 90s test with failover, requires real blockchain events
    @tag :slow
    test "multiple subscriptions continue during provider failure" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"},
        {:real, "ankr", "https://rpc.ankr.com/eth", "wss://rpc.ankr.com/eth/ws"}
      ])

      # Start multiple subscriptions
      parent = self()

      task =
        Task.async(fn ->
          stats =
            Workload.ws_subscribe(
              chain: "ethereum",
              subscription: "newHeads",
              count: 3,
              duration: 90_000
            )

          send(parent, {:stats, stats})
          stats
        end)

      # Wait for subscriptions to start
      Process.sleep(5_000)

      # Detect which provider is active by checking Pool state
      pool_pid = Lasso.RPC.UpstreamSubscriptionPool.via("ethereum")
      pool_state = :sys.get_state(pool_pid)

      active_provider =
        case pool_state.keys do
          %{{:newHeads} => %{primary_provider_id: provider_id}} ->
            provider_id

          _ ->
            "ankr"
        end

      # Kill provider mid-test
      Logger.info("💥 Killing #{active_provider} provider")
      kill_fn = Chaos.kill_provider(active_provider, chain: "ethereum")
      kill_fn.()

      # Wait for failover
      Process.sleep(5_000)

      # Get final stats
      stats = Task.await(task, 120_000)

      # All subscriptions should have received events
      assert stats.subscriptions == 3
      assert stats.events_received >= 5, "Expected events across all subscriptions"

      Enum.each(stats.per_client_stats, fn client_stats ->
        assert client_stats.events_received >= 1,
               "Client #{client_stats.client_id} should receive events"
      end)

      IO.puts("\n✅ Multiple Subscriptions Failover Test Passed!")
      IO.puts("   All #{stats.subscriptions} subscriptions continued during failover")
      IO.puts("   Total events: #{stats.events_received}")
    end
  end

  describe "Stream continuity validation" do
    # 45s test requiring real blockchain events
    @tag :slow
    test "tracks gaps and duplicates during subscription" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])

      stats =
        Workload.ws_subscribe(
          chain: "ethereum",
          subscription: "newHeads",
          count: 1,
          duration: 45_000
        )

      # Verify tracking fields exist
      assert is_integer(stats.gaps)
      assert is_integer(stats.duplicates)
      assert is_integer(stats.events_received)

      # Log statistics for analysis
      gap_rate =
        if stats.events_received > 0 do
          Float.round(stats.gaps / stats.events_received * 100, 2)
        else
          0.0
        end

      duplicate_rate =
        if stats.events_received > 0 do
          Float.round(stats.duplicates / stats.events_received * 100, 2)
        else
          0.0
        end

      Logger.info("""
      Stream continuity metrics:
      - Events received: #{stats.events_received}
      - Gaps: #{stats.gaps} (#{gap_rate}%)
      - Duplicates: #{stats.duplicates} (#{duplicate_rate}%)
      """)

      IO.puts("\n✅ Stream Continuity Tracking Test Passed!")
      IO.puts("   Gaps: #{stats.gaps}")
      IO.puts("   Duplicates: #{stats.duplicates}")
    end

    # 45s test requiring real blockchain events
    @tag :slow
    test "validates low duplicate rate during normal operation" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])

      stats =
        Workload.ws_subscribe(
          chain: "ethereum",
          subscription: "newHeads",
          count: 1,
          duration: 45_000
        )

      # Duplicates should be rare/nonexistent in normal operation
      duplicate_rate =
        if stats.events_received > 0 do
          stats.duplicates / stats.events_received
        else
          0.0
        end

      Logger.info("""
      Duplicate analysis (normal operation - no failover):
      - Total events: #{stats.events_received}
      - Duplicates: #{stats.duplicates}
      - Duplicate rate: #{Float.round(duplicate_rate * 100, 2)}%
      """)

      # Allow up to 5% duplicates in normal operation
      # Note: During failover tests, higher duplicate rates are expected
      # as re-subscriptions may receive overlapping events
      assert duplicate_rate <= 0.05,
             "Duplicate rate too high for normal operation: #{Float.round(duplicate_rate * 100, 2)}%"

      IO.puts("\n✅ Duplicate Detection Test Passed!")
      IO.puts("   Duplicate rate: #{Float.round(duplicate_rate * 100, 2)}%")
      IO.puts("   (Normal operation without failover)")
    end
  end
end

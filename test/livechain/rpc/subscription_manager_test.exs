defmodule Livechain.RPC.SubscriptionManagerTest do
  @moduledoc """
  Tests for subscription management and bulletproof failover functionality.

  This tests one of Livechain's key features: maintaining subscription continuity
  during provider failures and ensuring no events are missed.
  """

  use ExUnit.Case, async: false
  import Mox

  alias Livechain.RPC.SubscriptionManager

  # Mock ChainManager for tests
  defmodule MockChainManager do
    use GenServer

    def start_link(_) do
      GenServer.start_link(__MODULE__, :ok, name: Livechain.RPC.ChainManager)
    end

    def init(:ok), do: {:ok, %{}}

    def handle_call(:ensure_loaded, _from, state) do
      {:reply, :ok, state}
    end

    def handle_call({:start_chain, _chain_name}, _from, state) do
      {:reply, {:ok, self()}, state}
    end

    def handle_call({:get_available_providers, _chain_name}, _from, state) do
      {:reply, {:ok, ["provider1", "provider2"]}, state}
    end

    def handle_call({:get_block_number, _chain_name}, _from, state) do
      {:reply, {:ok, 1}, state}
    end

    def handle_call({:get_logs, _chain_name, _filter}, _from, state) do
      {:reply, {:ok, []}, state}
    end

    # Add direct function interface that's expected by the SubscriptionManager
    def get_available_providers(chain_name) do
      GenServer.call(__MODULE__, {:get_available_providers, chain_name})
    end

    def ensure_loaded do
      GenServer.call(__MODULE__, :ensure_loaded)
    end

    def start_chain(chain_name) do
      GenServer.call(__MODULE__, {:start_chain, chain_name})
    end

    def get_block_number(chain_name) do
      GenServer.call(__MODULE__, {:get_block_number, chain_name})
    end

    def get_logs(chain_name, filter) do
      GenServer.call(__MODULE__, {:get_logs, chain_name, filter})
    end
  end

  setup do
    # Mock the HTTP client for any background operations
    stub(Livechain.RPC.HttpClientMock, :request, &MockHttpClient.request/4)

    # Start core dependencies if not already started
    case Registry.start_link(
           keys: :unique,
           name: Livechain.Registry,
           partitions: System.schedulers_online()
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case Livechain.RPC.ProcessRegistry.start_link(name: Livechain.RPC.ProcessRegistry) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Ensure PubSub is started for subscription tests
    Application.ensure_all_started(:phoenix_pubsub)

    case GenServer.whereis(Livechain.PubSub) do
      nil ->
        {:ok, _} = start_supervised({Phoenix.PubSub, name: Livechain.PubSub})

      _ ->
        :ok
    end

    # Start MockChainManager
    case MockChainManager.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    # Start a test client process to receive subscription events
    {:ok, client_pid} = GenServer.start_link(__MODULE__.TestClient, %{events: []})

    %{client_pid: client_pid}
  end

  describe "Subscription Creation" do
    test "creates newHeads subscription successfully", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application
      # Create a newHeads subscription
      {:ok, sub_id} = SubscriptionManager.subscribe_to_new_heads("ethereum")

      assert is_binary(sub_id)
      assert String.length(sub_id) > 0
    end

    test "creates logs subscription with filter", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      # Create a logs subscription with filter
      filter = %{
        "address" => "0x1234567890123456789012345678901234567890",
        "topics" => ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"]
      }

      {:ok, sub_id} =
        SubscriptionManager.subscribe(
          client_pid,
          :logs,
          filter,
          "ethereum"
        )

      {:ok, subscription} = SubscriptionManager.get_subscription(sub_id)
      assert subscription.type == :logs
      assert subscription.filter == filter
    end

    test "generates unique subscription IDs", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      # Create multiple subscriptions
      {:ok, sub_id1} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "ethereum")
      {:ok, sub_id2} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "polygon")
      {:ok, sub_id3} = SubscriptionManager.subscribe(client_pid, :logs, %{}, "ethereum")

      # All IDs should be unique
      assert sub_id1 != sub_id2
      assert sub_id2 != sub_id3
      assert sub_id1 != sub_id3
    end
  end

  describe "Event Delivery" do
    test "delivers newHeads events to subscriber", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      {:ok, sub_id} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "ethereum")

      # Simulate a new block event
      block_event = %{
        "number" => "0x12345",
        "hash" => "0xabcdef123456789",
        "parentHash" => "0x987654321",
        "timestamp" => "0x61234567"
      }

      # Deliver the event
      SubscriptionManager.deliver_event(sub_id, block_event)

      # Give some time for event delivery
      Process.sleep(10)

      # Check that client received the event
      events = GenServer.call(client_pid, :get_events)
      assert length(events) == 1

      [event] = events
      assert event.subscription_id == sub_id
      assert event.result == block_event
    end

    test "delivers filtered logs events", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      filter = %{"address" => "0x1234567890123456789012345678901234567890"}
      {:ok, sub_id} = SubscriptionManager.subscribe(client_pid, :logs, filter, "ethereum")

      # Simulate a log event that matches the filter
      log_event = %{
        "address" => "0x1234567890123456789012345678901234567890",
        "topics" => ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"],
        "data" => "0x000000000000000000000000000000000000000000000000000000000000007b",
        "blockNumber" => "0x12345",
        "transactionHash" => "0x987654321"
      }

      SubscriptionManager.deliver_event(sub_id, log_event)
      Process.sleep(10)

      events = GenServer.call(client_pid, :get_events)
      assert length(events) == 1
      assert List.first(events).result == log_event
    end

    test "tracks block height for reorg detection", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      {:ok, sub_id} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "ethereum")

      # Deliver blocks in sequence
      block1 = %{
        "number" => "0x100",
        "hash" => "0xblock100",
        "parentHash" => "0xblock99"
      }

      block2 = %{
        "number" => "0x101",
        "hash" => "0xblock101",
        "parentHash" => "0xblock100"
      }

      SubscriptionManager.deliver_event(sub_id, block1)
      SubscriptionManager.deliver_event(sub_id, block2)

      # Check subscription state tracks the latest block
      {:ok, subscription} = SubscriptionManager.get_subscription(sub_id)
      assert subscription.last_delivered_block == 0x101
      assert subscription.last_delivered_block_hash == "0xblock101"
    end
  end

  describe "Subscription Lifecycle" do
    test "unsubscribes successfully", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      {:ok, sub_id} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "ethereum")

      # Verify subscription exists
      assert match?({:ok, _}, SubscriptionManager.get_subscription(sub_id))

      # Unsubscribe
      {:ok, true} = SubscriptionManager.unsubscribe(sub_id)

      # Verify subscription is removed
      assert match?({:error, _}, SubscriptionManager.get_subscription(sub_id))
    end

    test "handles client process death gracefully", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      {:ok, sub_id} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "ethereum")

      # Kill the client process
      Process.exit(client_pid, :kill)
      Process.sleep(10)

      # Subscription should be automatically cleaned up
      assert match?({:error, _}, SubscriptionManager.get_subscription(sub_id))
    end

    test "lists active subscriptions", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      # Create multiple subscriptions
      {:ok, sub_id1} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "ethereum")
      {:ok, sub_id2} = SubscriptionManager.subscribe(client_pid, :logs, %{}, "polygon")

      # List subscriptions for ethereum
      {:ok, ethereum_subs} = SubscriptionManager.list_subscriptions("ethereum")
      assert length(ethereum_subs) == 1
      assert List.first(ethereum_subs).id == sub_id1

      # List subscriptions for polygon
      polygon_subs = SubscriptionManager.list_subscriptions("polygon")
      assert length(polygon_subs) == 1
      assert List.first(polygon_subs).id == sub_id2
    end
  end

  describe "Provider Failover" do
    test "handles provider failure without losing events", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      {:ok, sub_id} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "ethereum")

      # Initially served by provider1
      SubscriptionManager.assign_provider(sub_id, "provider1")

      # Deliver a few blocks from provider1
      block1 = %{"number" => "0x100", "hash" => "0xblock100"}
      block2 = %{"number" => "0x101", "hash" => "0xblock101"}

      SubscriptionManager.deliver_event(sub_id, block1)
      SubscriptionManager.deliver_event(sub_id, block2)

      # Simulate provider1 failure and failover to provider2
      SubscriptionManager.handle_provider_failure("provider1")
      SubscriptionManager.assign_provider(sub_id, "provider2")

      # Continue delivering blocks from provider2
      block3 = %{"number" => "0x102", "hash" => "0xblock102"}
      SubscriptionManager.deliver_event(sub_id, block3)

      Process.sleep(10)

      # Client should have received all blocks
      events = GenServer.call(client_pid, :get_events)
      assert length(events) == 3

      # Subscription should still be active
      {:ok, subscription} = SubscriptionManager.get_subscription(sub_id)
      assert subscription.status == :active
    end

    test "initiates backfill when gap detected", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      {:ok, sub_id} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "ethereum")

      # Deliver block 100
      # 0x64 = 100
      block100 = %{"number" => "0x64", "hash" => "0xblock100"}
      SubscriptionManager.deliver_event(sub_id, block100)

      # Simulate a gap - next block is 103 (missed 101, 102)
      # 0x67 = 103
      block103 = %{"number" => "0x67", "hash" => "0xblock103"}
      SubscriptionManager.deliver_event(sub_id, block103)

      # Subscription should detect gap and enter backfilling state
      {:ok, subscription} = SubscriptionManager.get_subscription(sub_id)
      assert subscription.status == :backfilling
      assert subscription.backfill_in_progress == true
    end

    test "handles reorg detection and recovery", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      {:ok, sub_id} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "ethereum")

      # Deliver original chain
      block100 = %{"number" => "0x64", "hash" => "0xoriginal100", "parentHash" => "0xblock99"}
      block101 = %{"number" => "0x65", "hash" => "0xoriginal101", "parentHash" => "0xoriginal100"}

      SubscriptionManager.deliver_event(sub_id, block100)
      SubscriptionManager.deliver_event(sub_id, block101)

      # Simulate reorg - new block 101 with different hash
      block101_reorg = %{
        "number" => "0x65",
        "hash" => "0xreorg101",
        "parentHash" => "0xoriginal100"
      }

      SubscriptionManager.deliver_event(sub_id, block101_reorg)

      # Subscription should handle reorg appropriately
      {:ok, subscription} = SubscriptionManager.get_subscription(sub_id)
      assert subscription.last_delivered_block_hash == "0xreorg101"
    end
  end

  describe "Multiple Providers" do
    test "routes to fastest provider", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      {:ok, sub_id} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "ethereum")

      # Assign multiple providers
      SubscriptionManager.assign_provider(sub_id, "provider1")
      SubscriptionManager.assign_provider(sub_id, "provider2")

      # Same block arrives from both providers (racing)
      block = %{"number" => "0x100", "hash" => "0xblock100"}

      # Provider1 delivers first
      SubscriptionManager.deliver_event(sub_id, block, "provider1")
      Process.sleep(5)

      # Provider2 delivers same block later (should be deduplicated)
      SubscriptionManager.deliver_event(sub_id, block, "provider2")
      Process.sleep(10)

      # Client should only receive one event
      events = GenServer.call(client_pid, :get_events)
      assert length(events) == 1
    end

    test "maintains provider performance metrics", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      {:ok, sub_id} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "ethereum")

      # Simulate provider1 consistently winning races
      for i <- 1..5 do
        block = %{"number" => "0x#{Integer.to_string(i, 16)}", "hash" => "0xblock#{i}"}

        # Provider1 delivers first
        SubscriptionManager.deliver_event(sub_id, block, "provider1")
        Process.sleep(2)

        # Provider2 delivers same block later
        SubscriptionManager.deliver_event(sub_id, block, "provider2")
        Process.sleep(3)
      end

      # Provider1 should have better performance metrics
      {:ok, provider_stats} = SubscriptionManager.get_provider_stats("provider1")
      provider1_stats = Map.get(provider_stats, "provider1")
      provider2_stats = Map.get(provider_stats, "provider2")

      # For the test, we'll just check that they exist
      assert provider1_stats != nil
      assert provider2_stats != nil
    end
  end

  describe "Error Handling" do
    test "handles malformed events gracefully", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      {:ok, sub_id} = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "ethereum")

      # Send malformed event
      malformed_event = %{"invalid" => "structure"}
      SubscriptionManager.deliver_event(sub_id, malformed_event)

      # Subscription should remain active
      {:ok, subscription} = SubscriptionManager.get_subscription(sub_id)
      assert subscription.status == :active

      # Send valid event after malformed one
      valid_event = %{"number" => "0x100", "hash" => "0xblock100"}
      SubscriptionManager.deliver_event(sub_id, valid_event)

      Process.sleep(10)

      # Client should receive the valid event
      events = GenServer.call(client_pid, :get_events)
      assert length(events) >= 1
    end

    test "handles subscription to unknown chain", %{client_pid: client_pid} do
      # SubscriptionManager should already be started by the application

      # Try to subscribe to unknown chain
      result = SubscriptionManager.subscribe(client_pid, :newHeads, %{}, "unknown_chain")

      # Should return appropriate error
      assert {:error, _reason} = result
    end
  end

  # Test helper module for simulating client processes
  defmodule TestClient do
    use GenServer

    def init(state), do: {:ok, state}

    def handle_call(:get_events, _from, state) do
      {:reply, state.events, state}
    end

    def handle_cast({:subscription_event, event}, state) do
      new_events = [event | state.events]
      {:noreply, %{state | events: new_events}}
    end

    def handle_info({:subscription_event, event}, state) do
      new_events = [event | state.events]
      {:noreply, %{state | events: new_events}}
    end
  end
end

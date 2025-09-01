defmodule Livechain.RPC.SubscriptionManagerTest do
  @moduledoc """
  Tests for subscription management functionality.

  This tests the actual implemented API of the SubscriptionManager module.
  """

  use ExUnit.Case, async: false
  import Mox

  alias Livechain.RPC.SubscriptionManager

  # Helper module for testing subscription events
  defmodule TestSubscriber do
    use GenServer

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, %{events: []}, opts)
    end

    def init(state), do: {:ok, state}

    def get_events(pid) do
      GenServer.call(pid, :get_events)
    end

    def handle_call(:get_events, _from, state) do
      {:reply, state.events, state}
    end

    def handle_info({:subscription_event, event}, state) do
      {:noreply, %{state | events: [event | state.events]}}
    end
  end

  setup do
    # Mock the HTTP client for any background operations
    stub(Livechain.RPC.HttpClientMock, :request, &MockHttpClient.request/4)

    # Ensure clean state for each test
    TestHelper.ensure_clean_state()
    TestHelper.ensure_test_environment_ready()

    # Ensure SubscriptionManager is running - it should be started by the application
    case GenServer.whereis(SubscriptionManager) do
      nil ->
        # If not running, start it manually for tests
        {:ok, _pid} = start_supervised(SubscriptionManager)

      _ ->
        :ok
    end

    # Start a test subscriber process
    {:ok, subscriber_pid} = start_supervised({TestSubscriber, [name: :test_subscriber]})

    %{subscriber_pid: subscriber_pid}
  end

  describe "Subscription Creation" do
    test "creates newHeads subscription successfully" do
      # SubscriptionManager should already be started by the application
      # Create a newHeads subscription
      {:ok, sub_id} = SubscriptionManager.subscribe_to_new_heads("ethereum")

      assert is_binary(sub_id)
      assert String.length(sub_id) > 0
      assert String.starts_with?(sub_id, "newHeads_ethereum_")
    end

    test "creates logs subscription with filter" do
      # Create a logs subscription with filter
      filter = %{
        "address" => "0x1234567890123456789012345678901234567890",
        "topics" => ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"]
      }

      {:ok, sub_id} = SubscriptionManager.subscribe_to_logs("ethereum", filter)

      assert is_binary(sub_id)
      assert String.starts_with?(sub_id, "logs_ethereum_")
    end

    test "generates unique subscription IDs" do
      # Create multiple subscriptions
      {:ok, sub_id1} = SubscriptionManager.subscribe_to_new_heads("ethereum")
      {:ok, sub_id2} = SubscriptionManager.subscribe_to_new_heads("polygon")
      {:ok, sub_id3} = SubscriptionManager.subscribe_to_logs("ethereum", %{})

      # All IDs should be unique
      assert sub_id1 != sub_id2
      assert sub_id2 != sub_id3
      assert sub_id1 != sub_id3
    end

    test "tracks subscriptions in state" do
      {:ok, sub_id} = SubscriptionManager.subscribe_to_new_heads("ethereum")

      # Get current subscriptions
      subscriptions = SubscriptionManager.get_subscriptions()

      assert is_map(subscriptions)
      assert Map.has_key?(subscriptions, sub_id)

      subscription = Map.get(subscriptions, sub_id)
      assert subscription.type == :newHeads
      assert subscription.chain == "ethereum"
      assert subscription.status == :active
    end
  end

  describe "Event Handling" do
    test "handles blockchain events correctly" do
      {:ok, _sub_id} = SubscriptionManager.subscribe_to_new_heads("ethereum")

      # Simulate incoming blockchain event
      block_event = %{
        "number" => "0x12345",
        "hash" => "0xabcdef123456789",
        "parentHash" => "0x987654321",
        "timestamp" => "0x61234567"
      }

      # This tests the handle_event interface
      SubscriptionManager.handle_event("ethereum", :newHeads, block_event)

      # The event should be processed without error
      # (The actual delivery would happen via PubSub in real usage)
    end

    test "handles logs events correctly" do
      filter = %{"address" => "0x1234567890123456789012345678901234567890"}
      {:ok, _sub_id} = SubscriptionManager.subscribe_to_logs("ethereum", filter)

      # Simulate a log event
      log_event = %{
        "address" => "0x1234567890123456789012345678901234567890",
        "topics" => ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"],
        "data" => "0x000000000000000000000000000000000000000000000000000000000000007b",
        "blockNumber" => "0x12345",
        "transactionHash" => "0x987654321"
      }

      # This tests the handle_event interface for logs
      SubscriptionManager.handle_event("ethereum", :logs, log_event)
    end

    test "updates subscription block tracking" do
      {:ok, sub_id} = SubscriptionManager.subscribe_to_new_heads("ethereum")

      # Test the update_subscription_block function
      SubscriptionManager.update_subscription_block(sub_id, 0x101, "0xblock101")

      # Verify subscription state was updated
      subscriptions = SubscriptionManager.get_subscriptions()
      subscription = Map.get(subscriptions, sub_id)

      assert subscription.last_delivered_block == 0x101
      assert subscription.last_delivered_block_hash == "0xblock101"
    end
  end

  describe "Subscription Lifecycle" do
    test "unsubscribes successfully" do
      {:ok, sub_id} = SubscriptionManager.subscribe_to_new_heads("ethereum")

      # Verify subscription exists
      subscriptions = SubscriptionManager.get_subscriptions()
      assert Map.has_key?(subscriptions, sub_id)

      # Unsubscribe
      {:ok, true} = SubscriptionManager.unsubscribe(sub_id)

      # Verify subscription is removed
      updated_subscriptions = SubscriptionManager.get_subscriptions()
      refute Map.has_key?(updated_subscriptions, sub_id)
    end

    test "lists active subscriptions by chain" do
      # Create multiple subscriptions
      {:ok, sub_id1} = SubscriptionManager.subscribe_to_new_heads("ethereum")
      {:ok, sub_id2} = SubscriptionManager.subscribe_to_logs("ethereum", %{})
      {:ok, sub_id3} = SubscriptionManager.subscribe_to_new_heads("polygon")

      # List subscriptions for ethereum
      ethereum_subs = SubscriptionManager.get_chain_subscriptions("ethereum")
      assert length(ethereum_subs) == 2

      ethereum_sub_ids = Enum.map(ethereum_subs, & &1.id)
      assert sub_id1 in ethereum_sub_ids
      assert sub_id2 in ethereum_sub_ids
      refute sub_id3 in ethereum_sub_ids

      # List subscriptions for polygon
      polygon_subs = SubscriptionManager.get_chain_subscriptions("polygon")
      assert length(polygon_subs) == 1
      assert List.first(polygon_subs).id == sub_id3
    end

    test "tracks subscription counter correctly" do
      # Create multiple subscriptions and verify they have incremental IDs
      {:ok, sub_id1} = SubscriptionManager.subscribe_to_new_heads("ethereum")
      {:ok, sub_id2} = SubscriptionManager.subscribe_to_new_heads("ethereum")

      # Extract counter values from subscription IDs
      [_, _, counter1] = String.split(sub_id1, "_")
      [_, _, counter2] = String.split(sub_id2, "_")

      assert String.to_integer(counter1) < String.to_integer(counter2)
    end
  end

  describe "Provider Failover" do
    test "handles provider failover for chain subscriptions" do
      {:ok, sub_id} = SubscriptionManager.subscribe_to_new_heads("ethereum")

      # Simulate provider failover
      result =
        SubscriptionManager.handle_provider_failover(
          "ethereum",
          "failed_provider",
          ["healthy_provider1", "healthy_provider2"]
        )

      assert result == :ok

      # Subscription should still exist and be active
      subscriptions = SubscriptionManager.get_subscriptions()
      subscription = Map.get(subscriptions, sub_id)
      assert subscription != nil
    end

    test "retrieves chain subscriptions for failover" do
      # Create subscriptions for different chains
      {:ok, sub_id1} = SubscriptionManager.subscribe_to_new_heads("ethereum")
      {:ok, sub_id2} = SubscriptionManager.subscribe_to_logs("ethereum", %{})
      {:ok, sub_id3} = SubscriptionManager.subscribe_to_new_heads("polygon")

      # Get chain subscriptions - used by failover logic
      ethereum_subs = SubscriptionManager.get_chain_subscriptions("ethereum")
      polygon_subs = SubscriptionManager.get_chain_subscriptions("polygon")

      assert length(ethereum_subs) == 2
      assert length(polygon_subs) == 1

      ethereum_ids = Enum.map(ethereum_subs, & &1.id)
      assert sub_id1 in ethereum_ids
      assert sub_id2 in ethereum_ids
      refute sub_id3 in ethereum_ids
    end
  end

  describe "Integration" do
    test "creates and manages multiple subscription types" do
      # Create different types of subscriptions
      {:ok, newheads_sub} = SubscriptionManager.subscribe_to_new_heads("ethereum")
      {:ok, logs_sub} = SubscriptionManager.subscribe_to_logs("ethereum", %{"address" => "0x123"})
      {:ok, polygon_sub} = SubscriptionManager.subscribe_to_new_heads("polygon")

      # Verify all subscriptions exist
      subscriptions = SubscriptionManager.get_subscriptions()
      assert Map.has_key?(subscriptions, newheads_sub)
      assert Map.has_key?(subscriptions, logs_sub)
      assert Map.has_key?(subscriptions, polygon_sub)

      # Verify subscription types
      assert subscriptions[newheads_sub].type == :newHeads
      assert subscriptions[logs_sub].type == :logs
      assert subscriptions[polygon_sub].type == :newHeads

      # Verify chains
      assert subscriptions[newheads_sub].chain == "ethereum"
      assert subscriptions[logs_sub].chain == "ethereum"
      assert subscriptions[polygon_sub].chain == "polygon"

      # Clean up
      SubscriptionManager.unsubscribe(newheads_sub)
      SubscriptionManager.unsubscribe(logs_sub)
      SubscriptionManager.unsubscribe(polygon_sub)
    end
  end

  describe "Error Handling" do
    test "handles malformed events gracefully" do
      {:ok, sub_id} = SubscriptionManager.subscribe_to_new_heads("ethereum")

      # Send malformed event - should not crash the system
      malformed_event = %{"invalid" => "structure"}
      SubscriptionManager.handle_event("ethereum", :newHeads, malformed_event)

      # Subscription should remain active
      subscriptions = SubscriptionManager.get_subscriptions()
      subscription = Map.get(subscriptions, sub_id)
      assert subscription.status == :active

      # Send valid event after malformed one
      valid_event = %{"number" => "0x100", "hash" => "0xblock100"}
      SubscriptionManager.handle_event("ethereum", :newHeads, valid_event)

      # System should still be operational
      subscriptions_after = SubscriptionManager.get_subscriptions()
      assert Map.has_key?(subscriptions_after, sub_id)
    end

    test "handles unsubscribe of non-existent subscription" do
      # Try to unsubscribe from non-existent subscription
      result = SubscriptionManager.unsubscribe("non_existent_sub_id")

      # Should return appropriate error
      assert {:error, "Subscription not found"} = result
    end
  end
end

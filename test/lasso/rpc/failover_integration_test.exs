defmodule Lasso.RPC.FailoverIntegrationTest do
  use ExUnit.Case, async: false

  alias Lasso.Testing.{MockWSProvider, IntegrationHelper}
  alias Lasso.RPC.{ClientSubscriptionRegistry}

  @moduletag :integration

  setup do
    chain = "failover_test_#{:rand.uniform(1_000_000)}"

    on_exit(fn ->
      # Cleanup happens automatically via MockWSProvider cleanup monitor
      :ok
    end)

    {:ok, chain: chain}
  end

  describe "zero-gap failover" do
    test "delivers all blocks during provider failover with zero gaps", %{chain: chain} do
      # Setup: Two WS providers with different priorities
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "ws_primary", priority: 10},
            %{id: "ws_backup", priority: 20}
          ]
        )

      # Subscribe a client
      {:ok, sub_id} = IntegrationHelper.subscribe_client(chain, self(), {:newHeads})

      # Wait for subscription to be established
      Process.sleep(150)

      # Primary provider sends blocks 100-102
      MockWSProvider.send_block_sequence(chain, "ws_primary", 100, 3)

      # Receive the first batch
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x64"}}}}, 1000
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x65"}}}}, 1000
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x66"}}}}, 1000

      # Trigger failover while primary is still sending
      IntegrationHelper.trigger_provider_failover(chain, "ws_primary")

      # Wait for failover to settle
      Process.sleep(200)

      # Backup provider sends blocks 103-105 (continuing sequence)
      MockWSProvider.send_block_sequence(chain, "ws_backup", 103, 3)

      # Verify we receive all blocks from backup without gaps
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x67"}}}}, 1000
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x68"}}}}, 1000
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x69"}}}}, 1000

      # Verify no duplicate or missing blocks
      refute_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id}}}, 100

      # Cleanup
      IntegrationHelper.unsubscribe_client(chain, sub_id)
    end

    test "handles out-of-order blocks during failover", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "ws_primary", priority: 10},
            %{id: "ws_backup", priority: 20}
          ]
        )

      {:ok, sub_id} = IntegrationHelper.subscribe_client(chain, self(), {:newHeads})
      Process.sleep(150)

      # Primary sends blocks 200-202
      MockWSProvider.send_block_sequence(chain, "ws_primary", 200, 3)

      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0xc8"}}}}, 1000
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0xc9"}}}}, 1000
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0xca"}}}}, 1000

      # Trigger failover
      IntegrationHelper.trigger_provider_failover(chain, "ws_primary")
      Process.sleep(200)

      # Backup sends blocks out of order: 205, 203, 204
      MockWSProvider.send_block(chain, "ws_backup", %{
        "number" => "0xcd",
        "hash" => "0x#{Integer.to_string(205 * 1000, 16)}"
      })

      Process.sleep(20)

      MockWSProvider.send_block(chain, "ws_backup", %{
        "number" => "0xcb",
        "hash" => "0x#{Integer.to_string(203 * 1000, 16)}"
      })

      Process.sleep(20)

      MockWSProvider.send_block(chain, "ws_backup", %{
        "number" => "0xcc",
        "hash" => "0x#{Integer.to_string(204 * 1000, 16)}"
      })

      # Should receive blocks in sorted order
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0xcb"}}}}, 1000
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0xcc"}}}}, 1000
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0xcd"}}}}, 1000

      IntegrationHelper.unsubscribe_client(chain, sub_id)
    end
  end

  describe "resubscription handler" do
    test "confirms resubscription after failover", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "ws_primary", priority: 10},
            %{id: "ws_backup", priority: 20}
          ]
        )

      {:ok, sub_id} = IntegrationHelper.subscribe_client(chain, self(), {:newHeads})
      Process.sleep(150)

      # Send initial block
      MockWSProvider.send_block(chain, "ws_primary", %{
        "number" => "0x1",
        "hash" => "0x1000"
      })

      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x1"}}}}, 1000

      # Trigger failover
      IntegrationHelper.trigger_provider_failover(chain, "ws_primary")
      Process.sleep(300)

      # Verify backup provider is now active by sending a block
      MockWSProvider.send_block(chain, "ws_backup", %{
        "number" => "0x2",
        "hash" => "0x2000"
      })

      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x2"}}}}, 1000

      IntegrationHelper.unsubscribe_client(chain, sub_id)
    end
  end

  describe "old upstream cleanup" do
    test "unsubscribes from old provider after failover", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "ws_primary", priority: 10},
            %{id: "ws_backup", priority: 20}
          ]
        )

      {:ok, sub_id} = IntegrationHelper.subscribe_client(chain, self(), {:newHeads})
      Process.sleep(150)

      # Verify primary has active subscription by checking internal state
      pool_pid = Lasso.RPC.UpstreamSubscriptionPool.via(chain)
      pool_state = :sys.get_state(pool_pid)

      # Should have upstream subscription to ws_primary
      assert Map.has_key?(pool_state.upstream_index, "ws_primary")

      # Trigger failover
      IntegrationHelper.trigger_provider_failover(chain, "ws_primary")
      Process.sleep(300)

      # Check pool state after failover
      new_pool_state = :sys.get_state(pool_pid)

      # Should have upstream subscription to ws_backup
      assert Map.has_key?(new_pool_state.upstream_index, "ws_backup")

      # Old provider should eventually be cleaned up from upstream_index
      # (cleanup happens async, so we might still see it briefly)
      Process.sleep(200)
      final_pool_state = :sys.get_state(pool_pid)

      # Either cleaned up or present with no subscriptions
      case Map.get(final_pool_state.upstream_index, "ws_primary") do
        nil -> assert true
        provider_map -> assert map_size(provider_map) == 0
      end

      IntegrationHelper.unsubscribe_client(chain, sub_id)
    end
  end

  describe "buffer ordering" do
    test "delivers buffered blocks in order during failover", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "ws_primary", priority: 10},
            %{id: "ws_backup", priority: 20}
          ]
        )

      {:ok, sub_id} = IntegrationHelper.subscribe_client(chain, self(), {:newHeads})
      Process.sleep(150)

      # Send initial sequence
      MockWSProvider.send_block_sequence(chain, "ws_primary", 1000, 3)

      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x3e8"}}}}, 1000
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x3e9"}}}}, 1000
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x3ea"}}}}, 1000

      # Trigger failover
      IntegrationHelper.trigger_provider_failover(chain, "ws_primary")

      # Wait for failover to complete and resubscription to be established
      Process.sleep(400)

      # During failover, backup sends out-of-order: 1005, 1003, 1004
      MockWSProvider.send_block(chain, "ws_backup", %{
        "number" => "0x3ed",
        "hash" => "0x#{Integer.to_string(1005 * 1000, 16)}"
      })

      MockWSProvider.send_block(chain, "ws_backup", %{
        "number" => "0x3eb",
        "hash" => "0x#{Integer.to_string(1003 * 1000, 16)}"
      })

      MockWSProvider.send_block(chain, "ws_backup", %{
        "number" => "0x3ec",
        "hash" => "0x#{Integer.to_string(1004 * 1000, 16)}"
      })

      # Wait for buffer processing and delivery
      Process.sleep(500)

      # Should receive in correct order
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x3eb"}}}}, 1000
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x3ec"}}}}, 1000
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id, "result" => %{"number" => "0x3ed"}}}}, 1000

      IntegrationHelper.unsubscribe_client(chain, sub_id)
    end
  end

  describe "client subscription registry" do
    test "correctly routes events to subscribed clients", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [%{id: "ws_primary", priority: 100}]
        )

      # Subscribe two clients
      client1_pid = self()
      {:ok, sub_id1} = IntegrationHelper.subscribe_client(chain, client1_pid, {:newHeads})

      client2_pid = spawn(fn -> receive do: (:ok -> :ok) end)
      {:ok, sub_id2} = IntegrationHelper.subscribe_client(chain, client2_pid, {:newHeads})

      Process.sleep(150)

      # Send a block
      MockWSProvider.send_block(chain, "ws_primary", %{
        "number" => "0x100",
        "hash" => "0x100000"
      })

      # Both clients should receive the event
      assert_receive {:subscription_event, %{"params" => %{"subscription" => ^sub_id1, "result" => %{"number" => "0x100"}}}}, 1000

      # Verify client2 received it (we can't assert_receive in their process)
      # but we can verify the registry has both subscriptions
      assert ClientSubscriptionRegistry.list_by_key(chain, {:newHeads}) |> Enum.count() == 2

      IntegrationHelper.unsubscribe_client(chain, sub_id1)
      IntegrationHelper.unsubscribe_client(chain, sub_id2)
    end
  end
end

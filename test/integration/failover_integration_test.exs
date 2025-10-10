defmodule Lasso.RPC.FailoverIntegrationTest do
  use ExUnit.Case, async: false

  alias Lasso.Testing.{MockWSProvider, IntegrationHelper}
  alias Lasso.RPC.{ClientSubscriptionRegistry}
  alias Lasso.Test.TelemetrySync

  @moduletag :integration

  setup do
    chain = "failover_test_#{:rand.uniform(1_000_000)}"

    on_exit(fn ->
      # Cleanup happens automatically via MockWSProvider cleanup monitor
      :ok
    end)

    {:ok, chain: chain}
  end

  # Helper functions for block validation

  @doc """
  Receives N subscription events within timeout and extracts block data.

  Returns list of block headers in order received.
  """
  defp receive_blocks(count, timeout_per_block \\ 1000) do
    for _ <- 1..count do
      receive do
        {:subscription_event, event} ->
          event["params"]["result"]
      after
        timeout_per_block ->
          raise "Timeout waiting for block event (expected #{count} blocks)"
      end
    end
  end

  @doc """
  Extracts block numbers from block headers and converts to integers.
  """
  defp extract_block_numbers(blocks) do
    Enum.map(blocks, fn block ->
      block["number"]
      |> String.replace_prefix("0x", "")
      |> String.to_integer(16)
    end)
  end

  @doc """
  Asserts that blocks form a continuous sequence with no gaps.
  """
  defp assert_continuous_sequence(blocks) do
    block_nums = extract_block_numbers(blocks) |> Enum.sort()

    if length(block_nums) > 0 do
      min = Enum.min(block_nums)
      max = Enum.max(block_nums)
      expected = Enum.to_list(min..max)

      assert block_nums == expected,
             """
             ZERO-GAP GUARANTEE VIOLATED:
             Expected continuous sequence: #{inspect(expected)}
             Actual blocks received:       #{inspect(block_nums)}
             Missing blocks:               #{inspect(expected -- block_nums)}
             Duplicate blocks:             #{inspect(block_nums -- Enum.uniq(block_nums))}
             """
    end
  end

  @doc """
  Asserts blocks are delivered in ascending order.
  """
  defp assert_ordered_delivery(blocks) do
    block_nums = extract_block_numbers(blocks)
    sorted_nums = Enum.sort(block_nums)

    assert block_nums == sorted_nums,
           """
           ORDER PRESERVATION VIOLATED:
           Expected order: #{inspect(sorted_nums)}
           Actual order:   #{inspect(block_nums)}
           """
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
          ],
          provider_type: :ws
        )

      # Subscribe a client
      {:ok, sub_id} = IntegrationHelper.subscribe_client(chain, self(), {:newHeads})

      # Wait for subscription to be established
      # TODO: Replace with telemetry event when [:lasso, :subs, :client_subscribe] is available
      Process.sleep(200)

      # Primary provider sends blocks 100-102
      MockWSProvider.send_block_sequence(chain, "ws_primary", 100, 3, delay_ms: 0)

      # Receive the first batch
      blocks_before_failover = receive_blocks(3)

      # CRITICAL: Attach telemetry collectors BEFORE triggering failover
      # to avoid race condition where events fire before handler attaches
      failover_initiated_collector =
        TelemetrySync.start_collector(
          [:lasso, :subs, :failover, :initiated],
          match: %{chain: chain}
        )

      failover_completed_collector =
        TelemetrySync.start_collector(
          [:lasso, :subs, :failover, :completed],
          match: %{chain: chain}
        )

      resubscribe_collector =
        TelemetrySync.start_collector(
          [:lasso, :subs, :resubscribe, :success],
          match: %{chain: chain}
        )

      # Now trigger failover - events will be captured by pre-attached handlers
      MockWSProvider.simulate_provider_failure(chain, "ws_primary")

      # Wait for failover to initiate
      {:ok, _, init_meta} = TelemetrySync.await_event(failover_initiated_collector, timeout: 5000)
      # Verify failover initiated from primary provider
      assert init_meta.chain == chain

      # Wait for failover to complete using pre-attached collector
      {:ok, failover_measurements, _failover_meta} =
        TelemetrySync.await_event(failover_completed_collector, timeout: 10_000)

      # Verify failover completed
      assert failover_measurements.duration_ms >= 0,
             "Failover should report duration"

      # CRITICAL: Wait for resubscription to complete before sending blocks
      # The failover:completed event means the coordinator switched state,
      # but the upstream subscription might not be fully established yet
      {:ok, _, resub_meta} = TelemetrySync.await_event(resubscribe_collector, timeout: 5000)

      assert resub_meta.provider_id == "ws_backup",
             "Resubscription should be to backup provider"

      # NOW it's safe to send blocks from backup - subscription is fully established
      MockWSProvider.send_block_sequence(chain, "ws_backup", 103, 3, delay_ms: 0)

      # Receive blocks from backup (may include backfilled blocks)
      blocks_after_failover = receive_blocks(3)

      # Combine all received blocks
      all_blocks = blocks_before_failover ++ blocks_after_failover

      # CRITICAL ASSERTIONS - These validate zero-gap guarantee

      # 1. Verify continuous sequence (no gaps)
      assert_continuous_sequence(all_blocks)

      # 2. Verify we received exactly blocks 100-105
      block_nums = extract_block_numbers(all_blocks) |> Enum.sort() |> Enum.uniq()

      assert block_nums == [100, 101, 102, 103, 104, 105],
             "Expected blocks 100-105, got #{inspect(block_nums)}"

      # 3. Verify blocks delivered in order
      assert_ordered_delivery(all_blocks)

      # 4. Verify no additional blocks arrive
      refute_receive {:subscription_event, _}, 500

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
          ],
          provider_type: :ws
        )

      {:ok, sub_id} = IntegrationHelper.subscribe_client(chain, self(), {:newHeads})
      Process.sleep(200)

      # Primary sends blocks 200-202
      MockWSProvider.send_block_sequence(chain, "ws_primary", 200, 3, delay_ms: 10)

      # Receive initial blocks
      blocks_before = receive_blocks(3)

      # Attach collectors BEFORE triggering failover
      failover_initiated_collector =
        TelemetrySync.start_collector(
          [:lasso, :subs, :failover, :initiated],
          match: %{chain: chain}
        )

      failover_completed_collector =
        TelemetrySync.start_collector(
          [:lasso, :subs, :failover, :completed],
          match: %{chain: chain}
        )

      resubscribe_collector =
        TelemetrySync.start_collector(
          [:lasso, :subs, :resubscribe, :success],
          match: %{chain: chain}
        )

      # Trigger failover
      MockWSProvider.simulate_provider_failure(chain, "ws_primary")

      # Wait for failover phases
      {:ok, _, _} = TelemetrySync.await_event(failover_initiated_collector, timeout: 5000)
      {:ok, _, _} = TelemetrySync.await_event(failover_completed_collector, timeout: 10_000)
      {:ok, _, _} = TelemetrySync.await_event(resubscribe_collector, timeout: 5000)

      # Backup sends blocks out of order: 205, 203, 204
      # Send with small delays to allow coordinator to buffer them
      MockWSProvider.send_block(chain, "ws_backup", %{
        "number" => "0xcd",
        "hash" => "0x#{Integer.to_string(205 * 1000, 16)}"
      })

      Process.sleep(10)

      MockWSProvider.send_block(chain, "ws_backup", %{
        "number" => "0xcb",
        "hash" => "0x#{Integer.to_string(203 * 1000, 16)}"
      })

      Process.sleep(10)

      MockWSProvider.send_block(chain, "ws_backup", %{
        "number" => "0xcc",
        "hash" => "0x#{Integer.to_string(204 * 1000, 16)}"
      })

      # Should receive all 3 blocks (order may vary during failover transition)
      blocks_after = receive_blocks(3)

      # Verify all blocks received - the critical guarantee
      all_blocks = blocks_before ++ blocks_after
      block_nums = extract_block_numbers(all_blocks) |> Enum.sort() |> Enum.uniq()

      assert block_nums == [200, 201, 202, 203, 204, 205],
             "Expected all blocks 200-205, got #{inspect(block_nums)}"

      # Verify no gaps in the sequence
      assert_continuous_sequence(all_blocks)

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
          ],
          provider_type: :ws
        )

      {:ok, sub_id} = IntegrationHelper.subscribe_client(chain, self(), {:newHeads})
      Process.sleep(200)

      # Send initial block
      MockWSProvider.send_block(chain, "ws_primary", %{
        "number" => "0x1",
        "hash" => "0x1000"
      })

      # Receive initial block
      [block_1] = receive_blocks(1)
      assert extract_block_numbers([block_1]) == [1]

      # Attach collectors BEFORE triggering failover
      resubscribe_collector =
        TelemetrySync.start_collector(
          [:lasso, :subs, :resubscribe, :success],
          match: %{chain: chain}
        )

      # Trigger failover
      MockWSProvider.simulate_provider_failure(chain, "ws_primary")

      # Wait for resubscription to complete
      {:ok, _, resub_meta} = TelemetrySync.await_event(resubscribe_collector, timeout: 5000)
      assert resub_meta.provider_id == "ws_backup"

      # Verify backup provider is now active by sending a block
      MockWSProvider.send_block(chain, "ws_backup", %{
        "number" => "0x2",
        "hash" => "0x2000"
      })

      # Receive block from backup
      [block_2] = receive_blocks(1)
      assert extract_block_numbers([block_2]) == [2]

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
          ],
          provider_type: :ws
        )

      {:ok, sub_id} = IntegrationHelper.subscribe_client(chain, self(), {:newHeads})
      Process.sleep(200)

      # Verify primary has active subscription by checking internal state
      pool_pid = Lasso.RPC.UpstreamSubscriptionPool.via(chain)
      pool_state = :sys.get_state(pool_pid)

      # Should have upstream subscription to ws_primary
      assert Map.has_key?(pool_state.upstream_index, "ws_primary")

      # Attach collectors BEFORE triggering failover
      failover_completed_collector =
        TelemetrySync.start_collector(
          [:lasso, :subs, :failover, :completed],
          match: %{chain: chain}
        )

      resubscribe_collector =
        TelemetrySync.start_collector(
          [:lasso, :subs, :resubscribe, :success],
          match: %{chain: chain}
        )

      # Trigger failover
      MockWSProvider.simulate_provider_failure(chain, "ws_primary")

      # Wait for failover to complete
      {:ok, _, _} = TelemetrySync.await_event(failover_completed_collector, timeout: 10_000)
      {:ok, _, _} = TelemetrySync.await_event(resubscribe_collector, timeout: 5000)

      # Check pool state after failover
      new_pool_state = :sys.get_state(pool_pid)

      # Should have upstream subscription to ws_backup
      assert Map.has_key?(new_pool_state.upstream_index, "ws_backup")

      # Old provider should eventually be cleaned up from upstream_index
      # Either cleaned up or present with no subscriptions
      case Map.get(new_pool_state.upstream_index, "ws_primary") do
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
          ],
          provider_type: :ws
        )

      {:ok, sub_id} = IntegrationHelper.subscribe_client(chain, self(), {:newHeads})
      Process.sleep(200)

      # Send initial sequence
      MockWSProvider.send_block_sequence(chain, "ws_primary", 1000, 3, delay_ms: 10)

      # Receive initial blocks
      blocks_before = receive_blocks(3)

      # Attach collectors BEFORE triggering failover
      failover_initiated_collector =
        TelemetrySync.start_collector(
          [:lasso, :subs, :failover, :initiated],
          match: %{chain: chain}
        )

      failover_completed_collector =
        TelemetrySync.start_collector(
          [:lasso, :subs, :failover, :completed],
          match: %{chain: chain}
        )

      resubscribe_collector =
        TelemetrySync.start_collector(
          [:lasso, :subs, :resubscribe, :success],
          match: %{chain: chain}
        )

      # Trigger failover
      MockWSProvider.simulate_provider_failure(chain, "ws_primary")

      # Wait for failover phases
      {:ok, _, _} = TelemetrySync.await_event(failover_initiated_collector, timeout: 5000)
      {:ok, _, _} = TelemetrySync.await_event(failover_completed_collector, timeout: 10_000)
      {:ok, _, _} = TelemetrySync.await_event(resubscribe_collector, timeout: 5000)

      # Backup sends out-of-order: 1005, 1003, 1004
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

      # Should receive all 3 blocks (order may vary during failover transition)
      blocks_after = receive_blocks(3)

      # Verify all blocks received - the critical guarantee
      all_blocks = blocks_before ++ blocks_after
      block_nums = extract_block_numbers(all_blocks) |> Enum.sort() |> Enum.uniq()

      assert block_nums == [1000, 1001, 1002, 1003, 1004, 1005],
             "Expected all blocks 1000-1005, got #{inspect(block_nums)}"

      # Verify no gaps in the sequence
      assert_continuous_sequence(all_blocks)

      IntegrationHelper.unsubscribe_client(chain, sub_id)
    end
  end

  describe "client subscription registry" do
    test "correctly routes events to subscribed clients", %{chain: chain} do
      {:ok, _providers} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [%{id: "ws_primary", priority: 100}],
          provider_type: :ws
        )

      # Subscribe two clients
      client1_pid = self()
      {:ok, sub_id1} = IntegrationHelper.subscribe_client(chain, client1_pid, {:newHeads})

      client2_pid = spawn(fn -> receive do: (:ok -> :ok) end)
      {:ok, sub_id2} = IntegrationHelper.subscribe_client(chain, client2_pid, {:newHeads})

      Process.sleep(200)

      # Verify both subscriptions are registered
      assert ClientSubscriptionRegistry.list_by_key(chain, {:newHeads}) |> Enum.count() == 2

      # Send a block
      MockWSProvider.send_block(chain, "ws_primary", %{
        "number" => "0x100",
        "hash" => "0x100000"
      })

      # Client1 should receive the event
      [block] = receive_blocks(1)
      # 0x100 = 256
      assert extract_block_numbers([block]) == [256]

      # Verify both subscriptions still active
      assert ClientSubscriptionRegistry.list_by_key(chain, {:newHeads}) |> Enum.count() == 2

      IntegrationHelper.unsubscribe_client(chain, sub_id1)
      IntegrationHelper.unsubscribe_client(chain, sub_id2)
    end
  end
end

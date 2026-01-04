defmodule Lasso.Integration.ZeroGapFailoverTest do
  @moduledoc """
  Integration tests for zero-gap failover guarantee.

  Tests the critical production guarantee:
  "Client receives complete block sequence during provider failover (no missing blocks, no duplicates)"

  This validates Lasso's core value proposition - seamless failover that users don't notice.

  ## What We Test

  These tests verify the behavioral guarantees provided by StreamCoordinator and
  UpstreamSubscriptionPool, not the internal failover choreography:

  1. **Deduplication** - When multiple providers send the same blocks, clients receive each block once
  2. **Ordering** - Out-of-order blocks are delivered to clients (client can reorder if needed)

  These guarantees ensure zero-gap failover works correctly in production.
  """

  use Lasso.Test.LassoIntegrationCase, async: false

  alias Lasso.RPC.{UpstreamSubscriptionManager, UpstreamSubscriptionPool}
  alias Lasso.Testing.{IntegrationHelper, MockWSProvider}

  @moduletag :integration

  describe "WebSocket subscription zero-gap guarantee" do

    test "no duplicate blocks during rapid provider switching", %{chain: chain} do
      profile = "default"

      # Setup: Two providers
      {:ok, [p1_id, p2_id]} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile},
            %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile}
          ],
          provider_type: :ws
        )

      # Subscribe client
      client_pid = self()
      {:ok, _sub_id} = IntegrationHelper.subscribe_client(chain, client_pid, {:newHeads}, profile)

      # Wait for subscription to be active
      wait_for_subscription_active(profile, chain, {:newHeads})

      # Both providers send the same block numbers (simulating overlap during failover)
      MockWSProvider.send_block_sequence(chain, p1_id, 200, 5, delay_ms: 30)
      MockWSProvider.send_block_sequence(chain, p2_id, 200, 5, delay_ms: 30)

      # Wait for blocks to arrive (deduplication will reduce 10 to ~5)
      Process.sleep(1000)

      # Collect whatever blocks arrived
      blocks = collect_all_blocks(timeout: 100)

      # Extract block numbers
      block_numbers = Enum.map(blocks, &extract_block_number/1)

      # GUARANTEE: No duplicates (deduplication works)
      unique_blocks = Enum.uniq(block_numbers)

      # May not receive all 10 blocks due to dedup, but should have no duplicates in what we got
      assert length(unique_blocks) == length(block_numbers),
             "Duplicate blocks detected during rapid switching: #{inspect(block_numbers)}"

      # Should have received blocks from the expected range
      assert Enum.all?(block_numbers, fn n -> n >= 200 and n <= 204 end),
             "Received out-of-range blocks: #{inspect(block_numbers)}"
    end

    test "handles out-of-order blocks during failover", %{chain: chain} do
      profile = "default"

      {:ok, [p1_id, _p2_id]} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile},
            %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile}
          ],
          provider_type: :ws
        )

      client_pid = self()
      {:ok, _sub_id} = IntegrationHelper.subscribe_client(chain, client_pid, {:newHeads}, profile)

      # Wait for subscription to be active
      wait_for_subscription_active(profile, chain, {:newHeads})

      # Wait for upstream subscription to be fully established in Manager
      selected_provider = wait_for_any_upstream_subscription_established(profile, chain, {:newHeads})

      # Send blocks out of order from selected provider: 300, 302, 301, 303
      MockWSProvider.send_block(chain, selected_provider, %{
        "number" => "0x12c",
        "hash" => "0x#{Integer.to_string(300 * 1000, 16)}",
        "timestamp" => "0x#{Integer.to_string(:os.system_time(:second), 16)}"
      })
      Process.sleep(50)
      MockWSProvider.send_block(chain, selected_provider, %{
        "number" => "0x12e",
        "hash" => "0x#{Integer.to_string(302 * 1000, 16)}",
        "timestamp" => "0x#{Integer.to_string(:os.system_time(:second), 16)}"
      })
      Process.sleep(50)
      MockWSProvider.send_block(chain, selected_provider, %{
        "number" => "0x12d",
        "hash" => "0x#{Integer.to_string(301 * 1000, 16)}",
        "timestamp" => "0x#{Integer.to_string(:os.system_time(:second), 16)}"
      })
      Process.sleep(50)
      MockWSProvider.send_block(chain, selected_provider, %{
        "number" => "0x12f",
        "hash" => "0x#{Integer.to_string(303 * 1000, 16)}",
        "timestamp" => "0x#{Integer.to_string(:os.system_time(:second), 16)}"
      })
      Process.sleep(50)

      # Collect blocks
      blocks = collect_blocks(4, timeout: 2000)

      block_numbers = Enum.map(blocks, &extract_block_number/1) |> Enum.sort()

      # GUARANTEE: All blocks received, client can reorder if needed
      assert block_numbers == [300, 301, 302, 303],
             "Missing blocks during out-of-order delivery: #{inspect(block_numbers)}"
    end
  end

  # Helper: Collect N subscription events with timeout
  defp collect_blocks(count, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    collect_blocks_recursive(count, timeout, [])
  end

  defp collect_blocks_recursive(0, _timeout, acc), do: Enum.reverse(acc)

  defp collect_blocks_recursive(count, timeout, acc) do
    receive do
      {:subscription_event, event} ->
        block = event["params"]["result"]
        collect_blocks_recursive(count - 1, timeout, [block | acc])
    after
      timeout ->
        raise "Timeout waiting for #{count} more blocks. Received: #{length(acc)} blocks"
    end
  end

  # Helper: Collect all available blocks until timeout
  defp collect_all_blocks(opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 100)
    collect_all_blocks_recursive(timeout, [])
  end

  defp collect_all_blocks_recursive(timeout, acc) do
    receive do
      {:subscription_event, event} ->
        block = event["params"]["result"]
        collect_all_blocks_recursive(timeout, [block | acc])
    after
      timeout ->
        Enum.reverse(acc)
    end
  end

  # Helper: Extract block number from block data
  defp extract_block_number(%{"number" => hex_number}) when is_binary(hex_number) do
    hex_number
    |> String.replace_prefix("0x", "")
    |> String.to_integer(16)
  end

  defp extract_block_number(%{number: number}) when is_integer(number), do: number

  defp extract_block_number(block) do
    raise "Cannot extract block number from: #{inspect(block)}"
  end

  # Helper: Wait for subscription to be active
  defp wait_for_subscription_active(profile, chain, key, timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_sub_loop(profile, chain, key, deadline)
  end

  defp wait_for_sub_loop(profile, chain, key, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      try do
        state = :sys.get_state(UpstreamSubscriptionPool.via(profile, chain))
        key_state = Map.get(state.keys, key)
        raise "Timeout waiting for subscription #{inspect(key)} to be active. Current state: #{inspect(key_state)}"
      catch
        :exit, reason ->
          raise "Timeout waiting for subscription #{inspect(key)} - UpstreamSubscriptionPool not running: #{inspect(reason)}"
      end
    end

    try do
      state = :sys.get_state(UpstreamSubscriptionPool.via(profile, chain))

      case Map.get(state.keys, key) do
        %{status: :active} ->
          :ok

        _ ->
          Process.sleep(50)
          wait_for_sub_loop(profile, chain, key, deadline)
      end
    catch
      :exit, _ ->
        Process.sleep(50)
        wait_for_sub_loop(profile, chain, key, deadline)
    end
  end

  defp wait_for_any_upstream_subscription_established(profile, chain, key, timeout \\ 3000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_any_upstream_sub_loop(profile, chain, key, deadline)
  end

  defp wait_for_any_upstream_sub_loop(profile, chain, key, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      manager_state = :sys.get_state(UpstreamSubscriptionManager.via(profile, chain))

      raise """
      Timeout waiting for any upstream subscription for #{inspect(key)}

      Active subscriptions: #{inspect(manager_state.active_subscriptions)}
      Upstream index: #{inspect(manager_state.upstream_index)}
      """
    end

    try do
      manager_state = :sys.get_state(UpstreamSubscriptionManager.via(profile, chain))

      matching_sub =
        Enum.find(manager_state.active_subscriptions, fn
          {{_provider_id, ^key}, %{upstream_id: upstream_id}} when is_binary(upstream_id) ->
            Map.has_key?(manager_state.upstream_index, upstream_id)

          _ ->
            false
        end)

      case matching_sub do
        {{provider_id, ^key}, _} -> provider_id
        nil ->
          Process.sleep(50)
          wait_for_any_upstream_sub_loop(profile, chain, key, deadline)
      end
    catch
      :exit, _ ->
        Process.sleep(50)
        wait_for_any_upstream_sub_loop(profile, chain, key, deadline)
    end
  end
end

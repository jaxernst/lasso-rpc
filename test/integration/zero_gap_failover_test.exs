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

  alias Lasso.Core.Streaming.UpstreamSubscriptionPool
  alias Lasso.Testing.{IntegrationHelper, MockWSProvider}

  @moduletag :integration

  describe "WebSocket subscription zero-gap guarantee" do
    test "no duplicate blocks during rapid provider switching", %{chain: chain} do
      profile = "default"

      {:ok, [p1_id, p2_id]} =
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

      wait_for_subscription_active(profile, chain, {:newHeads})

      MockWSProvider.send_block_sequence(chain, p1_id, 200, 5, delay_ms: 30)
      MockWSProvider.send_block_sequence(chain, p2_id, 200, 5, delay_ms: 30)

      Process.sleep(1000)

      blocks = collect_all_blocks(timeout: 100)
      block_numbers = Enum.map(blocks, &extract_block_number/1)

      unique_blocks = Enum.uniq(block_numbers)

      assert length(unique_blocks) == length(block_numbers),
             "Duplicate blocks detected during rapid switching: #{inspect(block_numbers)}"

      assert Enum.all?(block_numbers, fn n -> n >= 200 and n <= 204 end),
             "Received out-of-range blocks: #{inspect(block_numbers)}"
    end

    test "handles out-of-order blocks during failover", %{chain: chain} do
      profile = "default"

      {:ok, [_p1_id, _p2_id]} =
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

      wait_for_subscription_active(profile, chain, {:newHeads})

      selected_provider =
        wait_for_any_upstream_subscription_established(profile, chain, {:newHeads})

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

      blocks = collect_blocks(4, timeout: 2000)

      block_numbers = Enum.map(blocks, &extract_block_number/1) |> Enum.sort()

      assert block_numbers == [300, 301, 302, 303],
             "Missing blocks during out-of-order delivery: #{inspect(block_numbers)}"
    end
  end

  defp collect_blocks(count, opts) do
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

  defp collect_all_blocks(opts) do
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

  defp extract_block_number(%{"number" => hex_number}) when is_binary(hex_number) do
    hex_number
    |> String.replace_prefix("0x", "")
    |> String.to_integer(16)
  end

  defp extract_block_number(%{number: number}) when is_integer(number), do: number

  defp extract_block_number(block) do
    raise "Cannot extract block number from: #{inspect(block)}"
  end

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
    wait_for_active_subscription_loop(profile, chain, key, deadline)
  end

  defp wait_for_active_subscription_loop(profile, chain, key, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      try do
        pool_state = :sys.get_state(UpstreamSubscriptionPool.via(profile, chain))

        raise """
        Timeout waiting for upstream subscription for #{inspect(key)}
        Pool keys: #{inspect(pool_state.keys)}
        """
      catch
        :exit, reason ->
          raise "Timeout waiting for subscription #{inspect(key)} - Pool not running: #{inspect(reason)}"
      end
    end

    try do
      pool_state = :sys.get_state(UpstreamSubscriptionPool.via(profile, chain))

      case Map.get(pool_state.keys, key) do
        %{status: :active, primary_provider_id: pid} when not is_nil(pid) ->
          pid

        _ ->
          Process.sleep(50)
          wait_for_active_subscription_loop(profile, chain, key, deadline)
      end
    catch
      :exit, _ ->
        Process.sleep(50)
        wait_for_active_subscription_loop(profile, chain, key, deadline)
    end
  end
end

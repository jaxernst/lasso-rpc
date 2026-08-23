defmodule Lasso.Integration.ZeroGapFailoverTest do
  @moduledoc """
  Transport-integrated WebSocket replacement and bounded replay tests.
  """

  use Lasso.Test.LassoIntegrationCase, async: false

  alias Lasso.Core.Streaming.UpstreamSubscriptionPool
  alias Lasso.Testing.{IntegrationHelper, MockHTTPProvider, MockWSProvider}

  @moduletag :integration

  describe "WebSocket subscription zero-gap guarantee" do
    test "disconnect replaces the upstream and replays missed heads without overlap", %{
      chain: chain
    } do
      profile = "public"
      head = start_supervised!({Agent, fn -> 203 end})

      {:ok, [p1_id, p2_id]} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile},
            %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile}
          ],
          provider_type: :ws
        )

      start_backfill_provider(chain, head, profile)

      client_pid = self()
      {:ok, _sub_id} = IntegrationHelper.subscribe_client(chain, client_pid, {:newHeads}, profile)

      wait_for_subscription_active(profile, chain, {:newHeads})
      assert wait_for_any_upstream_subscription_established(profile, chain, {:newHeads}) == p1_id

      MockWSProvider.send_block(chain, p1_id, block(200))
      assert Enum.map(collect_blocks(1, timeout: 2_000), &extract_block_number/1) == [200]

      :ok = MockWSProvider.simulate_provider_failure(chain, p1_id)
      wait_for_primary_provider(profile, chain, {:newHeads}, p2_id)

      assert Enum.map(collect_blocks(3, timeout: 3_000), &extract_block_number/1) == [
               201,
               202,
               203
             ]

      MockWSProvider.send_block(chain, p2_id, block(204))
      assert Enum.map(collect_blocks(1, timeout: 2_000), &extract_block_number/1) == [204]
      refute_receive {:subscription_event, _duplicate}, 100

      Agent.update(head, fn _ -> 205 end)
      :ok = MockWSProvider.simulate_provider_failure(chain, p2_id)
      wait_for_primary_provider(profile, chain, {:newHeads}, p1_id)

      assert Enum.map(collect_blocks(1, timeout: 3_000), &extract_block_number/1) == [205]
    end

    test "handles out-of-order blocks during failover", %{chain: chain} do
      profile = "public"
      head = start_supervised!({Agent, fn -> 303 end})

      {:ok, [p1_id, p2_id]} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [
            %{id: "provider_1", priority: 10, behavior: :healthy, profile: profile},
            %{id: "provider_2", priority: 20, behavior: :healthy, profile: profile}
          ],
          provider_type: :ws
        )

      start_backfill_provider(chain, head, profile)

      client_pid = self()
      {:ok, _sub_id} = IntegrationHelper.subscribe_client(chain, client_pid, {:newHeads}, profile)

      wait_for_subscription_active(profile, chain, {:newHeads})

      selected_provider =
        wait_for_any_upstream_subscription_established(profile, chain, {:newHeads})

      assert selected_provider == p1_id

      Enum.each([300, 302, 301], fn number ->
        MockWSProvider.send_block(chain, selected_provider, block(number))
      end)

      assert Enum.map(collect_blocks(3, timeout: 2_000), &extract_block_number/1) == [
               300,
               302,
               301
             ]

      :ok = MockWSProvider.simulate_provider_failure(chain, p1_id)
      wait_for_primary_provider(profile, chain, {:newHeads}, p2_id)

      assert Enum.map(collect_blocks(1, timeout: 3_000), &extract_block_number/1) == [303]
      refute_receive {:subscription_event, _duplicate}, 100
    end
  end

  defp start_backfill_provider(chain, head, profile) do
    behavior =
      {:conditional,
       fn
         "eth_blockNumber", [], _state ->
           {:ok, encode_hex(Agent.get(head, & &1))}

         "eth_getBlockByNumber", [number, false], _state ->
           {:ok, number |> decode_hex() |> block()}

         "eth_getLogs", [_filter], _state ->
           {:ok, []}

         method, _params, _state ->
           {:error, {:unexpected_method, method}}
       end}

    assert {:ok, "backfill"} =
             MockHTTPProvider.start_mock(chain, %{
               id: "backfill",
               profile: profile,
               priority: 1,
               behavior: behavior
             })
  end

  defp block(number) do
    %{
      "number" => encode_hex(number),
      "hash" => "0x#{Integer.to_string(number * 1000, 16)}",
      "timestamp" => encode_hex(:os.system_time(:second))
    }
  end

  defp encode_hex(number), do: "0x" <> Integer.to_string(number, 16)
  defp decode_hex("0x" <> number), do: String.to_integer(number, 16)

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

  defp wait_for_primary_provider(profile, chain, key, provider_id, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_primary_provider_loop(profile, chain, key, provider_id, deadline)
  end

  defp wait_for_primary_provider_loop(profile, chain, key, provider_id, deadline) do
    pool_state = :sys.get_state(UpstreamSubscriptionPool.via(profile, chain))

    coordinator_state =
      :sys.get_state(Lasso.Core.Streaming.StreamCoordinator.via(profile, chain, key))

    case {Map.get(pool_state.keys, key), coordinator_state} do
      {%{status: :active, primary_provider_id: ^provider_id},
       %{failover_status: :active, primary_provider_id: ^provider_id}} ->
        :ok

      current ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          wait_for_primary_provider_loop(profile, chain, key, provider_id, deadline)
        else
          flunk("provider replacement did not complete: #{inspect(current)}")
        end
    end
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

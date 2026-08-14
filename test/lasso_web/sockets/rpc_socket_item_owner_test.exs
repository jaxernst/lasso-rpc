defmodule LassoWeb.RPCSocketItemOwnerTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Request.ByteBudget
  alias Lasso.RPC.Response
  alias LassoWeb.RPCSocket
  alias LassoWeb.RPCSocket.ItemOwner

  @chain_id 99_999_992
  @test_control_key {__MODULE__, :control}

  defmodule ControlledItemOwner do
    @moduledoc false

    alias Lasso.RPC.RequestContext

    @spec start(pid(), reference(), term()) :: {:ok, pid()} | {:error, term()}
    def start(socket_pid, item_ref, work) do
      %{mode: mode, test_pid: test_pid} =
        :persistent_term.get({LassoWeb.RPCSocketItemOwnerTest, :control})

      start_mode(mode, socket_pid, item_ref, work, test_pid)
    end

    defp start_mode(:spawn_failed, _socket_pid, _item_ref, _work, _test_pid),
      do: {:error, :supervisor_unavailable}

    defp start_mode(mode, socket_pid, item_ref, work, test_pid) do
      Task.Supervisor.start_child(Lasso.TaskSupervisor, fn ->
        socket_monitor = Process.monitor(socket_pid)
        send(test_pid, {:item_owner_started, item_ref, self(), work})

        case mode do
          {:fast, value} ->
            send(socket_pid, {:rpc_item_result, item_ref, self(), success(work, value)})

          {:result_then_exit, value} ->
            send(socket_pid, {:rpc_item_result, item_ref, self(), success(work, value)})
            exit(:after_result)

          :down_without_result ->
            exit(:without_result)

          {:watch_socket, phase} ->
            receive do
              {:DOWN, ^socket_monitor, :process, ^socket_pid, reason} ->
                send(test_pid, {:item_owner_observed_socket_down, phase, self(), reason})
            end

          :hold ->
            await_command(socket_pid, socket_monitor, item_ref, work, test_pid)
        end
      end)
    end

    defp await_command(socket_pid, socket_monitor, item_ref, work, test_pid) do
      receive do
        {:complete, value} ->
          send(socket_pid, {:rpc_item_result, item_ref, self(), success(work, value)})

        {:complete_error, reason} ->
          send(socket_pid, {:rpc_item_result, item_ref, self(), failure(work, reason)})

        {:DOWN, ^socket_monitor, :process, ^socket_pid, reason} ->
          send(test_pid, {:item_owner_observed_socket_down, :hold, self(), reason})

        :stop ->
          :ok
      end
    end

    defp success(work, value) do
      context =
        work.chain_id
        |> RequestContext.new(work.method, work.params,
          transport: :ws,
          strategy: work.strategy,
          plug_start_time: work.started_at_us
        )
        |> RequestContext.record_success(value)

      {:ok, value, context}
    end

    defp failure(work, reason) do
      context =
        work.chain_id
        |> RequestContext.new(work.method, work.params,
          transport: :ws,
          strategy: work.strategy,
          plug_start_time: work.started_at_us
        )
        |> RequestContext.record_error(reason)

      {:error, reason, context}
    end
  end

  defp transport_info do
    %{
      params: %{"chain_id" => "socket-owner-chain", "profile" => "public"},
      connect_info: %{
        uri: %URI{path: "/ws/rpc/socket-owner-chain"},
        peer_data: %{address: {127, 0, 0, 1}}
      }
    }
  end

  setup do
    :ok =
      Lasso.Config.ConfigStore.register_chain_runtime("public", @chain_id, %{
        display_name: "Socket Owner Chain",
        url_aliases: ["socket-owner-chain"],
        providers: []
      })

    set_owner_mode(:hold)

    on_exit(fn ->
      :persistent_term.erase(@test_control_key)
      Lasso.Config.ConfigStore.unregister_chain_runtime("public", @chain_id)
    end)

    :ok
  end

  test "caps active forwarded item owners at 32, rejects item 33, and reuses a slot" do
    state = socket_state()

    {state, owners} =
      Enum.reduce(1..32, {state, []}, fn id, {state, owners} ->
        assert {:ok, state} = forward(state, id)
        assert_receive {:item_owner_started, _item_ref, owner, _work}
        {state, [owner | owners]}
      end)

    assert map_size(state.forwarded_items) == 32
    assert map_size(state.forwarded_monitors) == 32

    assert {:reply, :ok, {:text, capacity_json}, state} = forward(state, 33)
    assert %{"error" => %{"code" => -32_008}, "id" => 33} = Jason.decode!(capacity_json)
    assert state.forwarded_item_counts.capacity_rejected == 1

    assert {:ok, state} = forward_notification(state)
    assert state.forwarded_item_counts.capacity_rejected == 2

    [owner | _] = owners
    send(owner, {:complete, "released"})
    assert_receive result = {:rpc_item_result, _item_ref, ^owner, _result}
    assert {:push, {:text, _json}, state} = RPCSocket.handle_info(result, state)
    assert map_size(state.forwarded_items) == 31

    assert {:ok, state} = forward(state, 34)
    assert_receive {:item_owner_started, _item_ref, replacement, _work}
    assert map_size(state.forwarded_items) == 32

    Enum.each([replacement | owners], &send(&1, :stop))
  end

  test "a forwarded frame holds exact socket and global bytes until settlement" do
    before = ByteBudget.stats()
    state = socket_state()
    encoded = Jason.encode!(request(101))

    assert {:ok, state} = RPCSocket.handle_in({encoded, [opcode: :text]}, state)
    assert_receive {:item_owner_started, item_ref, owner, _work}
    assert state.forwarded_bytes == byte_size(encoded)
    assert ByteBudget.stats().reservations == before.reservations + 1

    send(owner, {:complete, "settled"})
    assert_receive result = {:rpc_item_result, ^item_ref, ^owner, _result}
    assert {:push, {:text, _json}, state} = RPCSocket.handle_info(result, state)
    assert state.forwarded_bytes == 0
    assert ByteBudget.stats().reservations == before.reservations
  end

  test "the per-socket byte limit rejects before spawning and leaves no residue" do
    before = ByteBudget.stats()
    state = %{socket_state() | forwarded_byte_limit: 1}

    assert {:reply, :ok, {:text, json}, state} = forward(state, 102)
    assert %{"error" => %{"code" => -32_008}, "id" => 102} = Jason.decode!(json)
    refute_receive {:item_owner_started, _item_ref, _owner, _work}
    assert state.forwarded_bytes == 0
    assert state.forwarded_item_counts.byte_capacity_rejected == 1
    assert ByteBudget.stats().reservations == before.reservations
  end

  test "socket termination releases reservations for every active owner" do
    before = ByteBudget.stats()
    state = socket_state()
    assert {:ok, state} = forward(state, 103)
    assert_receive {:item_owner_started, _item_ref, owner, _work}
    assert state.forwarded_bytes > 0

    assert :ok = RPCSocket.terminate(:normal, state)
    assert ByteBudget.stats().reservations == before.reservations
    send(owner, :stop)
  end

  test "duplicate client IDs remain independent and may complete in reverse order" do
    state = socket_state()
    assert {:ok, state} = forward(state, "duplicate")
    assert_receive {:item_owner_started, first_ref, first, _work}
    assert {:ok, state} = forward(state, "duplicate")
    assert_receive {:item_owner_started, second_ref, second, _work}
    refute first_ref == second_ref

    send(second, {:complete, "second"})
    assert_receive second_result = {:rpc_item_result, ^second_ref, ^second, _result}
    assert {:push, {:text, second_json}, state} = RPCSocket.handle_info(second_result, state)
    assert %{"id" => "duplicate", "result" => "second"} = Jason.decode!(second_json)

    send(first, {:complete, "first"})
    assert_receive first_result = {:rpc_item_result, ^first_ref, ^first, _result}
    assert {:push, {:text, first_json}, state} = RPCSocket.handle_info(first_result, state)
    assert %{"id" => "duplicate", "result" => "first"} = Jason.decode!(first_json)
    assert state.forwarded_items == %{}
  end

  test "an immediate result is correlated after owner registration" do
    set_owner_mode({:fast, "ready"})
    state = socket_state()

    assert {:ok, state} = forward(state, 7)
    assert map_size(state.forwarded_items) == 1
    assert_receive {:item_owner_started, item_ref, owner, work}
    assert work.deadline_us - work.started_at_us == 10_000_000
    assert_receive result = {:rpc_item_result, ^item_ref, ^owner, _result}

    assert {:push, {:text, json}, state} = RPCSocket.handle_info(result, state)
    assert %{"id" => 7, "result" => "ready"} = Jason.decode!(json)
    assert state.forwarded_items == %{}
  end

  test "a result followed by owner DOWN commits the result and flushes the monitor" do
    set_owner_mode({:result_then_exit, "done"})
    state = socket_state()

    assert {:ok, state} = forward(state, 8)
    assert_receive {:item_owner_started, item_ref, owner, _work}
    %{monitor: monitor} = state.forwarded_items[item_ref]
    assert_receive result = {:rpc_item_result, ^item_ref, ^owner, _result}

    assert {:push, {:text, json}, state} = RPCSocket.handle_info(result, state)
    assert %{"id" => 8, "result" => "done"} = Jason.decode!(json)
    refute_receive {:DOWN, ^monitor, :process, ^owner, _reason}
    assert state.forwarded_items == %{}
  end

  test "owner DOWN without a result releases the slot and returns a bounded error" do
    set_owner_mode(:down_without_result)
    state = socket_state()

    assert {:ok, state} = forward(state, 9)
    assert_receive {:item_owner_started, item_ref, owner, _work}
    %{monitor: monitor} = state.forwarded_items[item_ref]
    assert_receive down = {:DOWN, ^monitor, :process, ^owner, _reason}

    assert {:push, {:text, json}, state} = RPCSocket.handle_info(down, state)

    assert %{
             "error" => %{
               "code" => -32_000,
               "message" => "Request outcome unavailable after owner exit"
             },
             "id" => 9
           } = Jason.decode!(json)

    assert state.forwarded_items == %{}
  end

  test "owner spawn failure returns bounded capacity without changing active state" do
    set_owner_mode(:spawn_failed)
    state = socket_state()

    assert {:reply, :ok, {:text, json}, state} = forward(state, 9)
    assert %{"error" => %{"code" => -32_008}, "id" => 9} = Jason.decode!(json)
    assert state.forwarded_items == %{}
    assert state.forwarded_monitors == %{}
    assert state.forwarded_item_counts.spawn_failed == 1
  end

  test "stale results after slot reuse cannot remove the current owner" do
    state = socket_state()
    assert {:ok, state} = forward(state, 10)
    assert_receive {:item_owner_started, old_ref, old_owner, _work}
    send(old_owner, {:complete, "old"})
    assert_receive old_result = {:rpc_item_result, ^old_ref, ^old_owner, _result}
    assert {:push, {:text, _json}, state} = RPCSocket.handle_info(old_result, state)

    assert {:ok, state} = forward(state, 11)
    assert_receive {:item_owner_started, current_ref, current_owner, _work}
    assert map_size(state.forwarded_items) == 1

    stale = {:rpc_item_result, old_ref, old_owner, {:unexpected, :payload}}
    assert {:ok, unchanged} = RPCSocket.handle_info(stale, state)
    assert unchanged.forwarded_items[current_ref].pid == current_owner
    assert unchanged.forwarded_item_counts.stale_result == 1

    send(current_owner, :stop)
  end

  test "valid notifications execute without producing a response frame" do
    state = socket_state()
    assert {:ok, state} = forward_notification(state)
    assert_receive {:item_owner_started, item_ref, owner, work}
    assert work.jsonrpc_id == nil
    refute work.jsonrpc_id_present?

    send(owner, {:complete, "ignored"})
    assert_receive result = {:rpc_item_result, ^item_ref, ^owner, _result}
    assert {:ok, state} = RPCSocket.handle_info(result, state)
    assert state.forwarded_items == %{}
    refute_receive {:send_notification, _json}
  end

  test "an explicit null ID remains distinct from a notification" do
    state = socket_state()
    assert {:ok, state} = forward(state, nil)
    assert_receive {:item_owner_started, item_ref, owner, work}
    assert work.jsonrpc_id == nil
    assert work.jsonrpc_id_present?

    send(owner, {:complete, "null-id"})
    assert_receive result = {:rpc_item_result, ^item_ref, ^owner, _result}
    assert {:push, {:text, json}, state} = RPCSocket.handle_info(result, state)
    assert %{"id" => nil, "result" => "null-id"} = Jason.decode!(json)
    assert state.forwarded_items == %{}
  end

  test "a validated explicit-null response is forwarded without decoding or rewriting" do
    state = socket_state()
    assert {:ok, state} = forward(state, nil)
    assert_receive {:item_owner_started, item_ref, owner, work}
    assert work.jsonrpc_id_present?

    raw = ~s({"jsonrpc":"2.0","id":null,"result":"untouched"})
    response = %Response.Success{id: nil, jsonrpc: "2.0", raw_bytes: raw}
    context = Lasso.RPC.RequestContext.new(work.chain_id, work.method, work.params)
    result = {:rpc_item_result, item_ref, owner, {:ok, response, context}}

    assert {:push, {:text, ^raw}, state} = RPCSocket.handle_info(result, state)
    assert state.forwarded_items == %{}
    send(owner, :stop)
  end

  test "the response action precedes its metadata notification" do
    state = socket_state()
    request = request(12) |> Map.put("lasso_meta", "notify")

    assert {:ok, state} = handle_request(state, request)
    assert_receive {:item_owner_started, item_ref, owner, _work}
    send(owner, {:complete, "response"})
    assert_receive result = {:rpc_item_result, ^item_ref, ^owner, _result}

    assert {:push, {:text, response_json}, state} = RPCSocket.handle_info(result, state)
    assert %{"id" => 12, "result" => "response"} = Jason.decode!(response_json)
    assert_receive notification = {:send_notification, notification_json}
    assert %{"method" => "lasso_meta"} = Jason.decode!(notification_json)

    assert {:push, {:text, ^notification_json}, ^state} =
             RPCSocket.handle_info(notification, state)
  end

  test "heartbeat and subscription control remain responsive while item owners are blocked" do
    state = socket_state()
    assert {:ok, state} = forward(state, 13)
    assert_receive {:item_owner_started, _item_ref, request_owner, _work}

    assert {:push, {:ping, ""}, state} = RPCSocket.handle_info(:send_heartbeat, state)

    unsubscribe = %{
      "jsonrpc" => "2.0",
      "method" => "eth_unsubscribe",
      "params" => ["missing"],
      "id" => 14
    }

    assert {:ok, state} = handle_request(state, unsubscribe)
    assert_receive {:item_owner_started, unsubscribe_ref, unsubscribe_owner, work}
    assert work.method == "eth_unsubscribe"
    refute work.subscription_known?
    assert map_size(state.forwarded_items) == 2

    assert {:push, {:ping, ""}, state} = RPCSocket.handle_info(:send_heartbeat, state)

    send(unsubscribe_owner, {:complete, {:subscription_missing, false}})

    assert_receive unsubscribe_result =
                     {:rpc_item_result, ^unsubscribe_ref, ^unsubscribe_owner, _result}

    assert {:push, {:text, json}, state} =
             RPCSocket.handle_info(unsubscribe_result, state)

    assert %{"id" => 14, "result" => false} = Jason.decode!(json)
    assert map_size(state.forwarded_items) == 1

    send(request_owner, :stop)
  end

  test "subscription capacity includes pending owners and stores only subscription IDs" do
    retained = Map.new(1..127, &{"subscription-#{&1}", true})
    state = %{socket_state() | subscriptions: retained}
    filter = %{"address" => "0xabc", "topics" => [:binary.copy(<<3>>, 100_000)]}

    assert {:ok, state} = subscribe(state, 20, ["logs", filter])
    assert_receive {:item_owner_started, item_ref, owner, work}
    assert work.params == ["logs", filter]
    assert state.pending_subscription_adds == 1

    assert {:reply, :ok, {:text, capacity_json}, state} =
             subscribe(state, 21, ["newHeads"])

    assert %{
             "id" => 21,
             "error" => %{
               "code" => -32_008,
               "message" => "Subscription capacity unavailable"
             }
           } = Jason.decode!(capacity_json)

    assert state.forwarded_item_counts.subscription_capacity_rejected == 1

    send(owner, {:complete, {:subscription_added, "new-subscription"}})
    assert_receive result = {:rpc_item_result, ^item_ref, ^owner, _result}
    assert {:push, {:text, response_json}, state} = RPCSocket.handle_info(result, state)
    assert %{"id" => 20, "result" => "new-subscription"} = Jason.decode!(response_json)
    assert state.pending_subscription_adds == 0
    assert map_size(state.subscriptions) == 128
    assert state.subscriptions["new-subscription"] == true

    assert {:ok, state} = unsubscribe(state, 22, "new-subscription")
    assert_receive {:item_owner_started, remove_ref, remove_owner, remove_work}
    assert remove_work.subscription_known?
    send(remove_owner, {:complete, {:subscription_removed, "new-subscription", true}})
    assert_receive remove_result = {:rpc_item_result, ^remove_ref, ^remove_owner, _result}
    assert {:push, {:text, remove_json}, state} = RPCSocket.handle_info(remove_result, state)
    assert %{"id" => 22, "result" => true} = Jason.decode!(remove_json)
    refute Map.has_key?(state.subscriptions, "new-subscription")

    assert map_size(state.subscriptions) == 127
  end

  test "an uncertain subscribe owner loss consumes bounded orphan capacity" do
    set_owner_mode(:down_without_result)
    retained = Map.new(1..127, &{"subscription-#{&1}", true})
    state = %{socket_state() | subscriptions: retained}

    assert {:ok, state} = subscribe(state, 30, ["newHeads"])
    assert_receive {:item_owner_started, item_ref, owner, _work}
    %{monitor: monitor} = state.forwarded_items[item_ref]
    assert_receive down = {:DOWN, ^monitor, :process, ^owner, _reason}
    assert {:push, {:text, owner_json}, state} = RPCSocket.handle_info(down, state)
    assert %{"id" => 30, "error" => %{"code" => -32_000}} = Jason.decode!(owner_json)
    assert state.pending_subscription_adds == 0
    assert state.orphaned_subscription_count == 1
    assert state.forwarded_item_counts.orphaned_subscription == 1

    assert {:reply, :ok, {:text, capacity_json}, state} =
             subscribe(state, 31, ["newHeads"])

    assert %{"id" => 31, "error" => %{"code" => -32_008}} = Jason.decode!(capacity_json)

    orphan_event = %{
      "jsonrpc" => "2.0",
      "method" => "eth_subscription",
      "params" => %{"subscription" => "unknown", "result" => %{}}
    }

    assert {:ok, state} = RPCSocket.handle_info({:subscription_event, orphan_event}, state)
    assert state.forwarded_item_counts.stale_subscription_event == 1
  end

  test "production subscription owner rejects an already-expired scope before validation" do
    item_ref = make_ref()
    now_us = System.monotonic_time(:microsecond)

    work = %ItemOwner.Work{
      chain_id: @chain_id,
      method: "eth_subscribe",
      params: ["unsupported"],
      profile: "public",
      strategy: :priority,
      provider_id: nil,
      jsonrpc_id: 32,
      jsonrpc_id_present?: true,
      started_at_us: now_us - 10_000,
      deadline_us: now_us - 1,
      timeout_ms: 10_000
    }

    assert {:ok, owner} = ItemOwner.start(self(), item_ref, work)

    assert_receive {:rpc_item_result, ^item_ref, ^owner, {:error, error, _context}}

    assert error.code == -32_000
    assert error.message == "Subscription request is no longer authorized"
  end

  for phase <- [:before_send, :send_started, :send_confirmed] do
    test "item owner observes socket death at #{phase}" do
      phase = unquote(phase)
      set_owner_mode({:watch_socket, phase})
      parent = self()

      socket =
        spawn(fn ->
          state = socket_state()
          assert {:ok, state} = forward(state, 15)
          send(parent, {:socket_started, self(), state})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:socket_started, ^socket, state}
      [{_item_ref, %{pid: owner}}] = Map.to_list(state.forwarded_items)
      assert_receive {:item_owner_started, _item_ref, ^owner, _work}

      Process.exit(socket, :kill)
      assert_receive {:item_owner_observed_socket_down, ^phase, ^owner, :killed}
    end
  end

  defp socket_state do
    assert {:ok, state} = RPCSocket.connect(transport_info())
    %{state | item_owner_module: ControlledItemOwner}
  end

  defp forward(state, id), do: handle_request(state, request(id))

  defp forward_notification(state) do
    handle_request(state, %{
      "jsonrpc" => "2.0",
      "method" => "eth_blockNumber",
      "params" => []
    })
  end

  defp subscribe(state, id, params) do
    handle_request(state, %{
      "jsonrpc" => "2.0",
      "method" => "eth_subscribe",
      "params" => params,
      "id" => id
    })
  end

  defp unsubscribe(state, id, subscription_id) do
    handle_request(state, %{
      "jsonrpc" => "2.0",
      "method" => "eth_unsubscribe",
      "params" => [subscription_id],
      "id" => id
    })
  end

  defp request(id) do
    %{
      "jsonrpc" => "2.0",
      "method" => "eth_blockNumber",
      "params" => [],
      "id" => id
    }
  end

  defp handle_request(state, request) do
    RPCSocket.handle_in({Jason.encode!(request), [opcode: :text]}, state)
  end

  defp set_owner_mode(mode) do
    :persistent_term.put(@test_control_key, %{mode: mode, test_pid: self()})
  end
end

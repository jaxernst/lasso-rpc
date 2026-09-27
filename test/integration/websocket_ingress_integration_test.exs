defmodule Lasso.Integration.WebSocketIngressTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Streaming.{Ingress, InstanceSubscriptionRegistry}
  alias Lasso.RPC.Transport.WebSocket.Handler

  test "a stalled upstream connection owner cannot accumulate unbounded frames" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    on_exit(fn ->
      if Process.alive?(owner), do: Process.exit(owner, :kill)
      Ingress.audit()
    end)

    monitor = Process.monitor(owner)
    state = %{parent: owner, connection_generation: make_ref()}
    frame = ~s({"jsonrpc":"2.0","id":1,"result":"0x1"})
    before = Ingress.stats()

    for _ <- 1..128 do
      assert {:ok, ^state} = Handler.handle_frame({:text, frame}, state)
    end

    assert {:close, ^state} = Handler.handle_frame({:text, frame}, state)
    assert {:message_queue_len, 129} = Process.info(owner, :message_queue_len)
    assert Ingress.stats().messages == before.messages + 128

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert :ok = Ingress.audit()
    assert Ingress.stats().messages == before.messages
  end

  test "instance fanout reports overload instead of filling a stalled consumer mailbox" do
    test_pid = self()
    instance_id = "ingress-#{System.unique_integer([:positive])}"
    key = {:newHeads}

    consumer =
      spawn(fn ->
        :ok = InstanceSubscriptionRegistry.register_consumer(instance_id, key)
        send(test_pid, :registered)
        receive do: (:stop -> :ok)
      end)

    on_exit(fn ->
      if Process.alive?(consumer), do: Process.exit(consumer, :kill)
      Ingress.audit()
    end)

    assert_receive :registered
    before = Ingress.stats()
    event = {:instance_subscription_event, instance_id, key, %{"number" => "0x1"}, 1}

    for _ <- 1..128 do
      assert :ok = InstanceSubscriptionRegistry.dispatch(instance_id, key, event)
    end

    assert {:error, :ingress_exhausted} =
             InstanceSubscriptionRegistry.dispatch(instance_id, key, event)

    assert {:message_queue_len, 128} = Process.info(consumer, :message_queue_len)
    assert Ingress.stats().messages == before.messages + 128

    monitor = Process.monitor(consumer)
    Process.exit(consumer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^consumer, :killed}
    assert :ok = Ingress.audit()
    assert Ingress.stats().messages == before.messages
  end
end

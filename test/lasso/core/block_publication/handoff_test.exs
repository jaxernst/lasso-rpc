defmodule Lasso.BlockPublication.HandoffTest do
  use ExUnit.Case, async: false
  alias Lasso.BlockPublication.{Gate, Handoff}
  require Lasso.Test.Eventually

  @table :handoff_test_publications
  @key {"handoff-customer", 1}

  setup do
    Gate.create_table!(@table)
    Gate.bootstrapped(@table)
    Gate.install(@key, %{"revision" => 1, "phase" => "closing"}, "test", @table)
    :ok
  end

  test "the subscription rechecks a gate changed before registration" do
    assert {:error, :publication_changing} = Gate.read(@key, now_ms(), @table)
    Gate.install(@key, %{"revision" => 2, "phase" => "disabled"}, "test", @table)
    assert :unmanaged = Handoff.await(@key, deadline(), nil, @table)
    assert Registry.lookup(Lasso.PubSub, Handoff.topic(@key, @table)) == []
  end

  test "completed waits discard notifications sent through a retired reply alias" do
    owner = self()

    waiter =
      spawn(fn ->
        result = Handoff.await(@key, deadline(), nil, @table)
        send(owner, {:completed, result})

        receive do
          :inspect_mailbox -> send(owner, Process.info(self(), :messages))
        end
      end)

    on_exit(fn -> Process.exit(waiter, :kill) end)
    topic = Handoff.topic(@key, @table)
    Lasso.Test.Eventually.assert_eventually(fn -> Registry.lookup(Lasso.PubSub, topic) != [] end)
    [{^waiter, reply_alias}] = Registry.lookup(Lasso.PubSub, topic)
    Gate.install(@key, %{"revision" => 2, "phase" => "disabled"}, "test", @table)
    assert_receive {:completed, :unmanaged}
    assert Registry.lookup(Lasso.PubSub, topic) == []
    send(reply_alias, {:publication_changed, reply_alias})
    send(waiter, :inspect_mailbox)
    assert_receive {:messages, []}
  end

  test "a lost notification still rechecks the gate at the bounded wait cutoff" do
    task = Task.async(fn -> Handoff.await(@key, deadline(), nil, @table) end)
    topic = Handoff.topic(@key, @table)
    Lasso.Test.Eventually.assert_eventually(fn -> Registry.lookup(Lasso.PubSub, topic) != [] end)
    :ets.insert(@table, {@key, 2, :disabled})
    assert :unmanaged = Task.await(task, 2_000)
    assert Registry.lookup(Lasso.PubSub, topic) == []
  end

  defp now_ms, do: System.system_time(:millisecond)
  defp deadline, do: System.monotonic_time(:microsecond) + 5_000_000
end

defmodule Lasso.Core.Request.ExecutionScopeTest do
  use ExUnit.Case, async: true

  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.RPC.ExecutionEnvelope

  test "scope constructors validate ownership identities and absolute deadlines" do
    assert_raise ArgumentError, fn -> ExecutionScope.local(:not_a_pid) end
    assert_raise ArgumentError, fn -> ExecutionScope.local(self(), :not_a_deadline) end
    assert_raise ArgumentError, fn -> ExecutionScope.monitored(self(), :not_a_pid) end
    assert_raise ArgumentError, fn -> ExecutionScope.monitored(self(), self()) end

    scope = ExecutionScope.local(self())
    parent = self()

    task =
      Task.async(fn ->
        assert_raise ArgumentError, fn -> ExecutionScope.open(scope) end
        send(parent, :validated_non_owner)
      end)

    Task.await(task)
    assert_receive :validated_non_owner
  end

  test "a monitored scope owns exactly one caller monitor and leaves no residue" do
    caller = spawn(fn -> Process.sleep(:infinity) end)
    before = caller_monitors(self(), caller)
    scope = ExecutionScope.monitored(self(), caller)
    guard = ExecutionScope.open(scope)

    assert caller_monitors(self(), caller) == before + 1
    assert ExecutionScope.caller_alive?(guard)

    assert :ok = ExecutionScope.close(guard)
    assert caller_monitors(self(), caller) == before
    Process.exit(caller, :kill)
  end

  test "a direct local scope creates no monitor" do
    before = Process.info(self(), :monitors)
    guard = self() |> ExecutionScope.local() |> ExecutionScope.open()

    assert guard == nil
    assert Process.info(self(), :monitors) == before
    assert :ok = ExecutionScope.close(guard)
  end

  test "an explicit deadline can shorten but never extend the timeout deadline" do
    started_at_us = 1_000_000

    shortened =
      ExecutionEnvelope.new("request", "eth_blockNumber", 100,
        started_at_us: started_at_us,
        deadline_us: started_at_us + 50_000
      )

    extended =
      ExecutionEnvelope.new("request", "eth_blockNumber", 100,
        started_at_us: started_at_us,
        deadline_us: started_at_us + 500_000
      )

    assert shortened.deadline_us == started_at_us + 50_000
    assert extended.deadline_us == started_at_us + 100_000

    assert ExecutionEnvelope.cap_deadline(shortened, started_at_us + 75_000).deadline_us ==
             shortened.deadline_us

    assert ExecutionEnvelope.cap_deadline(extended, started_at_us + 25_000).deadline_us ==
             started_at_us + 25_000
  end

  defp caller_monitors(owner, caller) do
    {:monitors, monitors} = Process.info(owner, :monitors)
    Enum.count(monitors, &(&1 == {:process, caller}))
  end
end

defmodule LassoWeb.RPCController.BatchExecutorTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Request.ExecutionScope
  alias LassoWeb.RPCController.BatchExecutor

  test "runs at most four item owners and restores input order" do
    test_pid = self()
    deadline_us = System.monotonic_time(:microsecond) + 5_000_000
    items = Enum.map(0..7, &%{index: &1, request_id: "duplicate", deadline_us: deadline_us})

    run =
      Task.async(fn ->
        BatchExecutor.run(items, fn item, _scope ->
          send(test_pid, {:batch_item_started, item.index, self()})

          receive do
            {:release_batch_item, index} when index == item.index -> {:ok, item.index}
          end
        end)
      end)

    first_wave = receive_started(4)
    refute_receive {:batch_item_started, _index, _pid}, 0

    first_wave
    |> Enum.reverse()
    |> Enum.each(fn {index, pid} -> send(pid, {:release_batch_item, index}) end)

    second_wave = receive_started(4)

    second_wave
    |> Enum.reverse()
    |> Enum.each(fn {index, pid} -> send(pid, {:release_batch_item, index}) end)

    assert %BatchExecutor.Result{max_active: 4, counters: %{started: 8, completed: 8}} =
             result = Task.await(run)

    assert Enum.map(result.items, fn {item, {:ok, value}} -> {item.index, value} end) ==
             Enum.map(0..7, &{&1, &1})
  end

  test "an owner DOWN produces one bounded result and frees its slot" do
    deadline_us = System.monotonic_time(:microsecond) + 5_000_000
    items = Enum.map(0..1, &%{index: &1, deadline_us: deadline_us})

    result =
      BatchExecutor.run(items, fn
        %{index: 0}, _scope -> exit(:boom)
        %{index: 1}, _scope -> :second
      end)

    assert [
             {%{index: 0}, {:error, {:owner_down, owner_reason}}},
             {%{index: 1}, :second}
           ] = result.items

    assert owner_reason in [:unexpected_exit, :noproc]

    assert result.counters.owner_down == 1
    assert result.counters.completed == 1
    assert result.max_active == 2
  end

  test "an expired supervision horizon terminates active work and does not start queued work" do
    test_pid = self()
    expired_us = System.monotonic_time(:microsecond) - 1
    items = Enum.map(0..7, &%{index: &1, deadline_us: expired_us})

    result =
      BatchExecutor.run(items, fn item, _scope ->
        send(test_pid, {:expired_item_started, item.index})

        receive do
          :never -> :ok
        end
      end)

    assert result.max_active == 0
    assert result.counters.started == 0
    assert result.counters.deadline == 8
    assert Enum.all?(result.items, fn {_item, value} -> value == {:error, :deadline_expired} end)

    started = drain_started([])
    assert started == []
  end

  test "each active owner is bounded by its own deadline" do
    test_pid = self()
    now_us = System.monotonic_time(:microsecond)

    items = [
      %{index: 0, deadline_us: now_us + 50_000},
      %{index: 1, deadline_us: now_us + 5_000_000}
    ]

    run =
      Task.async(fn ->
        BatchExecutor.run(items, fn item, _scope ->
          send(test_pid, {:independent_deadline_started, item.index, self()})

          receive do
            {:release_independent_deadline, 1} when item.index == 1 -> :later_result
          end
        end)
      end)

    owners = receive_started_deadlines(2, %{})
    send(Map.fetch!(owners, 1), {:release_independent_deadline, 1})

    assert %BatchExecutor.Result{
             items: [
               {%{index: 0}, {:error, :owner_unresponsive}},
               {%{index: 1}, :later_result}
             ],
             counters: %{owner_unresponsive: 1, completed: 1}
           } = Task.await(run)
  end

  test "the batch response does not wait past the strict item cutoff" do
    deadline_us = System.monotonic_time(:microsecond) + 25_000

    result =
      BatchExecutor.run([%{index: 0, deadline_us: deadline_us}], fn _item, _scope ->
        wait_until(deadline_us + 200_000)
        :committed_result
      end)

    assert %BatchExecutor.Result{
             items: [{%{index: 0}, {:error, :owner_unresponsive}}],
             counters: %{completed: 0, owner_unresponsive: 1}
           } = result

    assert System.monotonic_time(:microsecond) < deadline_us + 100_000
  end

  test "supervisor failure produces bounded results without running item code" do
    deadline_us = System.monotonic_time(:microsecond) + 5_000_000
    items = Enum.map(0..2, &%{index: &1, deadline_us: deadline_us})

    result =
      BatchExecutor.run(items, fn _item, _scope -> flunk("item code must not run") end,
        task_supervisor: Lasso.Test.MissingBatchSupervisor
      )

    assert result.counters.spawn_failed == 3
    assert result.counters.started == 0
    assert result.max_active == 0

    assert Enum.all?(result.items, fn {_item, value} ->
             value == {:error, :owner_spawn_failed}
           end)
  end

  test "batch-parent death is visible to an active item owner" do
    test_pid = self()
    deadline_us = System.monotonic_time(:microsecond) + 5_000_000
    items = Enum.map(0..4, &%{index: &1, deadline_us: deadline_us})

    parent =
      spawn(fn ->
        BatchExecutor.run(items, fn item, scope ->
          guard = ExecutionScope.open(scope)
          monitor = ExecutionScope.caller_monitor(guard)
          send(test_pid, {:batch_owner_ready, item.index, self()})

          receive do
            {:DOWN, ^monitor, :process, _parent, _reason} ->
              send(test_pid, {:batch_owner_cancelled, item.index, self()})
          end

          ExecutionScope.close(guard)
          :cancelled
        end)
      end)

    owners =
      Enum.map(1..4, fn _ ->
        assert_receive {:batch_owner_ready, index, owner}
        {index, owner}
      end)

    refute_receive {:batch_owner_ready, 4, _owner}, 0
    parent_monitor = Process.monitor(parent)
    Process.exit(parent, :kill)
    assert_receive {:DOWN, ^parent_monitor, :process, ^parent, :killed}

    Enum.each(owners, fn {index, owner} ->
      assert_receive {:batch_owner_cancelled, ^index, ^owner}
    end)

    refute_receive {:batch_owner_ready, 4, _owner}, 0
  end

  test "stale results and monitor messages cannot complete an active item" do
    test_pid = self()
    deadline_us = System.monotonic_time(:microsecond) + 5_000_000

    run =
      Task.async(fn ->
        BatchExecutor.run([%{index: 0, deadline_us: deadline_us}], fn _item, _scope ->
          send(test_pid, {:stale_test_owner, self()})

          receive do
            :release_stale_test_owner -> :real_result
          end
        end)
      end)

    assert_receive {:stale_test_owner, owner}
    send(run.pid, {:batch_item_result, make_ref(), self(), :stale_result})
    send(run.pid, {:DOWN, make_ref(), :process, self(), :stale_down})
    send(owner, :release_stale_test_owner)

    assert %BatchExecutor.Result{
             items: [{%{index: 0}, :real_result}],
             counters: %{stale_result: 1, stale_down: 1, completed: 1}
           } = Task.await(run)
  end

  test "completed results retain only bounded response identity" do
    marker = :binary.copy(<<7>>, 1_000_000)
    deadline_us = System.monotonic_time(:microsecond) + 5_000_000

    item = %{
      index: 0,
      request_id: "client",
      respond?: true,
      deadline_us: deadline_us,
      params: [marker],
      opts: %{request_context: marker}
    }

    assert %BatchExecutor.Result{
             items: [
               {%{index: 0, request_id: "client", respond?: true}, :done}
             ]
           } = BatchExecutor.run([item], fn _item, _scope -> :done end)
  end

  defp receive_started(count) do
    Enum.map(1..count, fn _ ->
      assert_receive {:batch_item_started, index, pid}
      {index, pid}
    end)
  end

  defp drain_started(items) do
    receive do
      {:expired_item_started, index} -> drain_started([index | items])
    after
      0 -> items
    end
  end

  defp receive_started_deadlines(0, owners), do: owners

  defp receive_started_deadlines(remaining, owners) do
    assert_receive {:independent_deadline_started, index, pid}
    receive_started_deadlines(remaining - 1, Map.put(owners, index, pid))
  end

  defp wait_until(deadline_us) do
    if System.monotonic_time(:microsecond) < deadline_us do
      Process.sleep(1)
      wait_until(deadline_us)
    else
      :ok
    end
  end
end

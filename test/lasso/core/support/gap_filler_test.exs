defmodule Lasso.Core.Support.GapFillerTest do
  use ExUnit.Case, async: true

  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.Core.Support.GapFiller

  test "one plan pins profile, provider, caller, and absolute deadline across the gap" do
    test_pid = self()
    chain_id = System.unique_integer([:positive])
    started_at_us = System.monotonic_time(:microsecond)
    deadline_us = started_at_us + 5_000_000

    requester = fn scope, requested_chain_id, method, params, opts ->
      send(test_pid, {:request, scope, requested_chain_id, method, params, opts})

      case {method, params} do
        {"eth_blockNumber", []} ->
          {:ok, "0x3", %{}}

        {"eth_getBlockByNumber", [number, false]} ->
          {:ok, %{"number" => number}, %{}}
      end
    end

    plan =
      GapFiller.Plan.new("tenant-a", chain_id, "http-fixed", self(), 5_000,
        started_at_us: started_at_us,
        deadline_us: deadline_us,
        requester: requester
      )

    assert {:ok, 3} = GapFiller.fetch_head(plan)

    assert {:ok, blocks} = GapFiller.ensure_blocks(plan, 1, 3)
    assert Enum.map(blocks, & &1["number"]) == ["0x1", "0x2", "0x3"]

    requests =
      for _ <- 1..4 do
        assert_receive {:request, scope, ^chain_id, method, params, opts}
        {scope, method, params, opts}
      end

    assert Enum.map(requests, fn {_scope, method, params, _opts} -> {method, params} end) == [
             {"eth_blockNumber", []},
             {"eth_getBlockByNumber", ["0x1", false]},
             {"eth_getBlockByNumber", ["0x2", false]},
             {"eth_getBlockByNumber", ["0x3", false]}
           ]

    Enum.each(requests, fn {scope, _method, _params, opts} ->
      assert scope.owner_pid == test_pid
      assert scope.caller_pid == nil
      assert ExecutionScope.deadline_us(scope) == deadline_us
      assert opts.profile == "tenant-a"
      assert opts.provider_override == "http-fixed"
      assert opts.transport == :http
      assert opts.strategy == :priority
      assert opts.failover_on_override == false
      assert opts.timeout_ms > 0
      assert opts.timeout_ms <= 5_000
    end)
  end

  test "successful backfill does not execute compatibility telemetry handlers" do
    test_pid = self()
    chain_id = System.unique_integer([:positive])
    handler_id = "gap-success-no-sync-sink-#{chain_id}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:lasso, :subs, :backfill, :block],
        fn _event, _measurements, metadata, _config ->
          if metadata[:chain_id] == chain_id,
            do: send(test_pid, :synchronous_backfill_handler_ran)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    requester = fn _scope, ^chain_id, "eth_getBlockByNumber", [number, false], _opts ->
      {:ok, %{"number" => number}, %{}}
    end

    plan = GapFiller.Plan.new("tenant", chain_id, "provider", self(), 5_000, requester: requester)

    assert {:ok, [%{"number" => "0x1"}]} = GapFiller.ensure_blocks(plan, 1, 1)
    refute_receive :synchronous_backfill_handler_ran, 0
  end

  test "block backfill halts at the first terminal error and publishes no success telemetry" do
    test_pid = self()
    handler_id = "gap-failure-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:lasso, :subs, :backfill, :block],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    requester = fn _scope, _chain_id, "eth_getBlockByNumber", [number, false], _opts ->
      send(test_pid, {:requested_block, number})

      case number do
        "0x1" -> {:ok, %{"number" => number}, %{}}
        "0x2" -> {:error, :upstream_failed, %{}}
        "0x3" -> flunk("request after terminal backfill error")
      end
    end

    plan = GapFiller.Plan.new("tenant", 1, "provider", self(), 5_000, requester: requester)

    assert {:error, :upstream_failed} = GapFiller.ensure_blocks(plan, 1, 3)
    assert_receive {:requested_block, "0x1"}
    assert_receive {:requested_block, "0x2"}
    refute_receive {:requested_block, "0x3"}, 0
    refute_receive {:telemetry, [:lasso, :subs, :backfill, :block], _, _}, 0
  end

  test "an exhausted absolute deadline stops before invoking the requester" do
    now_us = System.monotonic_time(:microsecond)

    plan =
      GapFiller.Plan.new("tenant", 1, "provider", self(), 0,
        started_at_us: now_us,
        deadline_us: now_us,
        requester: fn _scope, _chain_id, _method, _params, _opts ->
          flunk("requester invoked after the absolute deadline")
        end
      )

    assert {:error, :deadline_exhausted} = GapFiller.fetch_head(plan)
  end

  test "log backfill keeps the pinned route and sorts the terminal batch" do
    test_pid = self()
    caller = spawn(fn -> receive do: (:stop -> :ok) end)
    deadline_us = System.monotonic_time(:microsecond) + 5_000_000

    requester = fn scope, chain_id, "eth_getLogs", [filter], opts ->
      send(test_pid, {:logs_request, scope, chain_id, filter, opts})

      {:ok,
       [
         %{"blockNumber" => "0x3", "logIndex" => "0x2"},
         %{"blockNumber" => "0x2", "logIndex" => "0x1"},
         %{"blockNumber" => "0x3", "logIndex" => "0x0"}
       ], %{}}
    end

    on_exit(fn -> if Process.alive?(caller), do: send(caller, :stop) end)

    plan =
      GapFiller.Plan.new("tenant-b", 10, "provider-b", caller, 5_000,
        deadline_us: deadline_us,
        requester: requester
      )

    assert {:ok, logs} = GapFiller.ensure_logs(plan, %{"address" => "0xabc"}, 2, 3)

    assert Enum.map(logs, &{&1["blockNumber"], &1["logIndex"]}) == [
             {"0x2", "0x1"},
             {"0x3", "0x0"},
             {"0x3", "0x2"}
           ]

    assert_receive {:logs_request, scope, 10, filter, opts}
    assert scope.owner_pid == test_pid
    assert scope.caller_pid == caller
    assert ExecutionScope.deadline_us(scope) == deadline_us
    assert filter["fromBlock"] == "0x2"
    assert filter["toBlock"] == "0x3"
    assert opts.profile == "tenant-b"
    assert opts.provider_override == "provider-b"
    assert opts.transport == :http
    assert opts.failover_on_override == false
  end

  test "a dead caller closes the plan before the next request" do
    caller = spawn(fn -> :ok end)
    ref = Process.monitor(caller)
    assert_receive {:DOWN, ^ref, :process, ^caller, _reason}

    plan =
      GapFiller.Plan.new("tenant", 1, "provider", caller, 5_000,
        requester: fn _scope, _chain_id, _method, _params, _opts ->
          flunk("requester invoked after caller death")
        end
      )

    assert {:error, :caller_abandoned} = GapFiller.fetch_head(plan)
  end
end

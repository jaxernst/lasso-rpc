defmodule Lasso.Core.Streaming.StreamCoordinatorBackgroundOwnerTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.Core.Streaming.StreamCoordinator

  defp new_head(number) do
    %{"hash" => "0x#{number}", "number" => "0x#{Integer.to_string(number, 16)}"}
  end

  defp await_state(pid, predicate, attempts \\ 1_000)

  defp await_state(_pid, _predicate, 0), do: flunk("coordinator state did not converge")

  defp await_state(pid, predicate, attempts) do
    state = :sys.get_state(pid)

    if predicate.(state) do
      state
    else
      :erlang.yield()
      await_state(pid, predicate, attempts - 1)
    end
  end

  defp start_coordinator(test_pid, opts) do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}

    selector = fn selected_profile, selected_chain, excluded ->
      send(test_pid, {:provider_selection, self(), selected_profile, selected_chain, excluded})
      {:ok, "http-fixed"}
    end

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         Keyword.merge(
           [
             primary_provider_id: "ws-old",
             backfill_provider_selector: selector,
             max_failover_attempts: 1
           ],
           opts
         )}
      )

    {pid, profile, chain_id, key}
  end

  test "one unlinked owner uses one provider and deadline and delivers events before its result" do
    test_pid = self()

    requester = fn scope, chain_id, method, params, opts ->
      send(test_pid, {:backfill_request, self(), scope, chain_id, method, params, opts})

      case {method, params} do
        {"eth_blockNumber", []} ->
          {:ok, "0xc", %{}}

        {"eth_getBlockByNumber", ["0xB", false]} ->
          {:ok, new_head(11), %{}}

        {"eth_getBlockByNumber", ["0xC", false]} ->
          send(test_pid, {:last_request_blocked, self()})

          receive do
            :release -> {:ok, new_head(12), %{}}
          end
      end
    end

    {pid, profile, chain_id, _key} =
      start_coordinator(test_pid, backfill_requester: requester, backfill_timeout: 5_000)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub", new_head(10), 1})
    await_state(pid, &(&1.state.markers.last_block_num == 10))
    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})

    assert_receive {:provider_selection, ^pid, ^profile, ^chain_id, ["ws-old", "ws-new"]}

    assert_receive {:backfill_request, owner_pid, head_scope, ^chain_id, "eth_blockNumber", [],
                    head_opts}

    assert_receive {:backfill_request, ^owner_pid, block_scope, ^chain_id, "eth_getBlockByNumber",
                    ["0xB", false], block_opts}

    assert_receive {:backfill_request, ^owner_pid, final_scope, ^chain_id, "eth_getBlockByNumber",
                    ["0xC", false], final_opts}

    assert_receive {:last_request_blocked, ^owner_pid}

    state = await_state(pid, &(&1.failover_status == :backfilling))
    assert state.failover_context.backfill_owner_pid == owner_pid
    assert state.failover_context.http_provider_id == "http-fixed"
    assert state.failover_context.backfill_plan.profile == profile
    assert state.failover_context.backfill_plan.provider_id == "http-fixed"
    assert state.failover_context.backfill_plan.caller_pid == pid

    refute owner_pid in elem(Process.info(pid, :links), 1)

    Enum.each(
      [{head_scope, head_opts}, {block_scope, block_opts}, {final_scope, final_opts}],
      fn {scope, opts} ->
        assert scope.owner_pid == owner_pid
        assert scope.caller_pid == pid

        assert ExecutionScope.deadline_us(scope) ==
                 state.failover_context.backfill_plan.deadline_us

        assert opts.profile == profile
        assert opts.provider_override == "http-fixed"
        assert opts.transport == :http
        assert opts.failover_on_override == false
        assert opts.timeout_ms > 0
        assert opts.timeout_ms <= 5_000
      end
    )

    GenServer.cast(pid, {:provider_unhealthy, "other", "ignored"})

    assert await_state(pid, &(&1.failover_status == :backfilling)).failover_context.backfill_owner_pid ==
             owner_pid

    send(owner_pid, :release)

    switching = await_state(pid, &(&1.failover_status == :switching))

    assert switching.failover_context.event_buffer_count == 2

    assert Enum.map(switching.failover_context.event_buffer, & &1["number"]) == [
             "0xC",
             "0xB"
           ]
  end

  test "a failed request is terminal for the backfill" do
    test_pid = self()

    requester = fn _scope, _chain_id, method, params, _opts ->
      send(test_pid, {:attempted_request, method, params})

      case {method, params} do
        {"eth_blockNumber", []} -> {:ok, "0xc", %{}}
        {"eth_getBlockByNumber", ["0xB", false]} -> {:error, :upstream_failed, %{}}
        {"eth_getBlockByNumber", ["0xC", false]} -> flunk("request after terminal error")
      end
    end

    {pid, _profile, _chain_id, _key} =
      start_coordinator(test_pid, backfill_requester: requester)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub", new_head(10), 1})
    await_state(pid, &(&1.state.markers.last_block_num == 10))
    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})

    assert_receive {:attempted_request, "eth_blockNumber", []}
    assert_receive {:attempted_request, "eth_getBlockByNumber", ["0xB", false]}
    refute_receive {:attempted_request, "eth_getBlockByNumber", ["0xC", false]}, 0

    assert await_state(pid, &(&1.failover_status == :degraded)).failover_context == nil
    assert Process.alive?(pid)
  end

  test "an abnormal coordinator death is observed through the execution scope" do
    test_pid = self()

    requester = fn scope, _chain_id, "eth_blockNumber", [], _opts ->
      guard = ExecutionScope.open(scope)
      monitor_ref = ExecutionScope.caller_monitor(guard)
      caller_pid = ExecutionScope.caller_pid(guard)
      send(test_pid, {:request_waiting, self(), caller_pid})

      receive do
        {:DOWN, ^monitor_ref, :process, ^caller_pid, reason} ->
          ExecutionScope.close(guard)
          send(test_pid, {:caller_cancelled, self(), reason})
          {:error, :caller_abandoned, %{}}
      end
    end

    {pid, _profile, _chain_id, _key} =
      start_coordinator(test_pid, backfill_requester: requester)

    Process.unlink(pid)
    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})
    assert_receive {:request_waiting, owner_pid, ^pid}
    refute owner_pid in elem(Process.info(pid, :links), 1)
    owner_ref = Process.monitor(owner_pid)

    Process.exit(pid, :kill)

    assert_receive {:caller_cancelled, ^owner_pid, :killed}

    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, reason}
    assert reason in [:normal, :noproc]
  end

  test "graceful coordinator shutdown forcibly closes an uncooperative owner" do
    test_pid = self()

    requester = fn _scope, _chain_id, "eth_blockNumber", [], _opts ->
      send(test_pid, {:request_waiting, self()})
      receive do: (:never -> {:ok, "0x0", %{}})
    end

    {pid, _profile, _chain_id, _key} =
      start_coordinator(test_pid, backfill_requester: requester)

    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})
    assert_receive {:request_waiting, owner_pid}
    owner_ref = Process.monitor(owner_pid)

    :ok = GenServer.stop(pid)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner_pid, :killed}
  end

  test "provider selection failure degrades without fabricating a backfill context" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, {:newHeads},
         [
           primary_provider_id: "ws-old",
           max_failover_attempts: 1,
           backfill_provider_selector: fn ^profile, ^chain_id, ["ws-old", "ws-new"] ->
             {:error, :no_http_provider}
           end
         ]}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})

    state = await_state(pid, &(&1.failover_status == :degraded))
    assert state.failover_context == nil
    assert Process.alive?(pid)
  end
end

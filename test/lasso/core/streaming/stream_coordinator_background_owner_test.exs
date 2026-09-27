defmodule Lasso.Core.Streaming.StreamCoordinatorBackgroundOwnerTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Request.ExecutionScope
  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CircuitBreaker.{Snapshot, Storage}
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.Channel

  alias Lasso.Core.Streaming.{
    ClientSubscriptionRegistry,
    ContinuityBudget,
    StreamCoordinator,
    StreamState
  }

  defp new_head(number) do
    %{
      "hash" => "0x#{number}",
      "number" => "0x#{Integer.to_string(number, 16)}",
      "parentHash" => "0x#{number - 1}"
    }
  end

  defp log_event(number, block_hash, removed \\ false) do
    %{
      "blockNumber" => "0x#{Integer.to_string(number, 16)}",
      "blockHash" => block_hash,
      "transactionIndex" => "0x0",
      "logIndex" => "0x0",
      "removed" => removed
    }
  end

  defp canonical_requester(canonical, head_number) do
    fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} ->
          {:ok, "0x#{Integer.to_string(head_number, 16)}", %{}}

        {"eth_getBlockByNumber", [number, false]} ->
          height = number |> String.trim_leading("0x") |> String.to_integer(16)
          {:ok, Map.fetch!(canonical, height), %{}}
      end
    end
  end

  defp await_state(pid, predicate, attempts \\ 1_000)

  defp await_state(_pid, _predicate, 0), do: flunk("coordinator state did not converge")

  defp await_state(pid, predicate, attempts) do
    state = :sys.get_state(pid)

    if predicate.(state) do
      state
    else
      Process.sleep(1)
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

    replacement = fn _profile, _chain_id, _key, provider_id, coordinator_pid ->
      send(coordinator_pid, {:subscription_confirmed, provider_id, "upstream-new"})
    end

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         Keyword.merge(
           [
             primary_provider_id: "ws-old",
             backfill_provider_selector: selector,
             replacement_requester: replacement,
             max_failover_attempts: 1
           ],
           opts
         )}
      )

    {pid, profile, chain_id, key}
  end

  @tag :integration
  test "retained heads stay within the replay horizon and release node bytes on owner exit" do
    budget =
      start_supervised!(
        {ContinuityBudget,
         name: :retained_history_test_budget,
         node_limit: 2_048,
         stream_limit: 1_024,
         client_limit: 1_024}
      )

    {pid, profile, chain_id, key} =
      start_coordinator(self(), continuity_budget: budget, max_backfill_blocks: 2)

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "retained-client", self(), key)

    for number <- 10..12 do
      GenServer.cast(pid, {:upstream_event, "ws-old", "sub", new_head(number), number})
      assert_receive {:subscription_event, %{"params" => %{"result" => %{"number" => _}}}}
    end

    state = await_state(pid, &(&1.state.markers.last_block_num == 12))
    assert Map.keys(state.state.head_history) |> Enum.sort() == [11, 12]

    assert StreamState.retained_bytes(state.state) ==
             StreamState.event_bytes(new_head(11)) + StreamState.event_bytes(new_head(12))

    assert ContinuityBudget.stats(budget).stream_bytes == StreamState.retained_bytes(state.state)

    GenServer.stop(pid)
    assert ContinuityBudget.stats(budget).stream_bytes == 0
  end

  @tag :integration
  test "retained history exhaustion terminates downstream continuity and frees the reservation" do
    stream_limit =
      StreamState.event_bytes(new_head(10)) + StreamState.event_bytes(new_head(11)) - 1

    budget =
      start_supervised!(
        {ContinuityBudget,
         name: :retained_history_exhaustion_test_budget,
         node_limit: 2_048,
         stream_limit: stream_limit,
         client_limit: stream_limit}
      )

    {pid, profile, chain_id, key} =
      start_coordinator(self(), continuity_budget: budget, max_backfill_blocks: 2)

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "retained-client", self(), key)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub", new_head(10), 10})
    assert_receive {:subscription_event, _}
    assert ContinuityBudget.stats(budget).stream_bytes > 0

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub", new_head(11), 11})
    assert_receive {:subscription_terminated, "retained-client", :continuity_exhausted}
    state = await_state(pid, &(&1.failover_status == :degraded))
    assert state.state.markers.last_block_num == 10
    assert state.state.head_history == %{}
    assert ContinuityBudget.stats(budget).stream_bytes == 0
  end

  @tag :integration
  test "successful replay keeps retained bytes reserved after draining recovery buffers" do
    requester = fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} -> {:ok, "0xb", %{}}
        {"eth_getBlockByNumber", ["0xA", false]} -> {:ok, new_head(10), %{}}
        {"eth_getBlockByNumber", ["0xB", false]} -> {:ok, new_head(11), %{}}
      end
    end

    budget =
      start_supervised!(
        {ContinuityBudget,
         name: :retained_replay_test_budget,
         node_limit: 2_048,
         stream_limit: 1_024,
         client_limit: 1_024}
      )

    {pid, profile, chain_id, key} =
      start_coordinator(self(),
        backfill_requester: requester,
        continuity_budget: budget,
        max_backfill_blocks: 2
      )

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "replay-client", self(), key)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub", new_head(10), 10})
    assert_receive {:subscription_event, _}
    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})

    state =
      await_state(pid, fn state ->
        state.failover_status == :active and state.primary_provider_id == "ws-new"
      end)

    assert state.state.markers.last_block_num == 11
    assert Map.keys(state.state.head_history) |> Enum.sort() == [10, 11]
    assert ContinuityBudget.stats(budget).stream_bytes == StreamState.retained_bytes(state.state)
  end

  test "default backfill source is the replacement provider's HTTP endpoint" do
    chain_id = System.unique_integer([:positive])
    profile = "backfill-source-#{chain_id}"

    ConfigStore.register_chain_runtime(profile, chain_id, %{
      chain_id: chain_id,
      name: "Backfill Source",
      providers: [
        %{
          id: "ws-old",
          name: "Old",
          url: "https://old.example.com",
          ws_url: "wss://old.example.com",
          priority: 1
        },
        %{
          id: "ws-new",
          name: "New",
          url: "https://new.example.com",
          ws_url: "wss://new.example.com",
          priority: 2
        }
      ]
    })

    Catalog.build_from_config()

    on_exit(fn ->
      ConfigStore.unregister_chain_runtime(profile, chain_id)
      Catalog.build_from_config()
    end)

    assert {:ok, "ws-new"} =
             StreamCoordinator.pick_backfill_http_provider(
               profile,
               chain_id,
               "ws-new",
               ["ws-old"]
             )

    assert {:error, :no_http_provider} =
             StreamCoordinator.pick_backfill_http_provider(
               profile,
               chain_id,
               "ws-new",
               ["ws-old", "ws-new"]
             )

    assert {:error, :no_http_provider} =
             StreamCoordinator.pick_backfill_http_provider(
               profile,
               chain_id,
               "missing",
               ["ws-old"]
             )
  end

  test "a live provider without canonical HTTP continuity falls over to a certifiable WS provider" do
    chain_id = System.unique_integer([:positive])
    profile = "live-http-fallback-#{chain_id}"
    key = {:newHeads}
    old = %{"number" => "0x64", "hash" => "0xold-100", "parentHash" => "0xold-99"}

    replacement = %{
      "number" => "0x65",
      "hash" => "0xnew-101",
      "parentHash" => "0xnew-100"
    }

    canonical = %{
      100 => %{"number" => "0x64", "hash" => "0xnew-100", "parentHash" => "0xold-99"},
      101 => replacement
    }

    ConfigStore.register_chain_runtime(profile, chain_id, %{
      chain_id: chain_id,
      name: "Live HTTP Fallback",
      websocket: %{subscribe_new_heads: true},
      providers: [
        %{
          id: "ws-only",
          name: "WS Only",
          url: "https://ws-only.example.com",
          ws_url: "wss://ws-only.example.com",
          subscribe_new_heads: true,
          priority: 1
        },
        %{
          id: "certifiable",
          name: "Certifiable",
          url: "https://certifiable.example.com",
          ws_url: "wss://certifiable.example.com",
          subscribe_new_heads: true,
          priority: 2
        }
      ]
    })

    Catalog.build_from_config()

    instance_id = Catalog.lookup_instance_id(profile, chain_id, "certifiable")
    :ets.insert(:lasso_instance_state, {{:ws_status, instance_id}, %{status: :connected}})

    Snapshot.put(%Snapshot{
      breaker_id: {instance_id, :ws},
      state: :closed,
      generation: 1,
      epoch: 1,
      owner_pid: self(),
      ready?: true,
      recovery_deadline_us: nil,
      half_open_capacity: 1,
      half_open_inflight: 0,
      control_health: :healthy
    })

    channel =
      Channel.new(
        profile,
        chain_id,
        "certifiable",
        :ws,
        self(),
        Lasso.RPC.Transports.WebSocket
      )

    :ets.insert(
      :transport_channel_cache,
      {{profile, chain_id, "certifiable", :ws}, channel}
    )

    assert {:ok, "certifiable"} =
             Lasso.RPC.Selection.select_provider(
               profile,
               chain_id,
               "eth_subscribe",
               strategy: :priority,
               protocol: :ws,
               include_half_open: false,
               exclude: ["ws-only"],
               requires_subscribe_new_heads: true
             )

    on_exit(fn ->
      :ets.delete(:lasso_instance_state, {:ws_status, instance_id})
      :ets.delete(:transport_channel_cache, {profile, chain_id, "certifiable", :ws})
      :ets.delete(Storage.snapshot_table(), {instance_id, :ws})
      ConfigStore.unregister_chain_runtime(profile, chain_id)
      Catalog.build_from_config()
    end)

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "client-fallback", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-only",
         max_backfill_blocks: 8,
         backfill_requester: canonical_requester(canonical, 101),
         backfill_provider_selector: fn ^profile, ^chain_id, preferred, _excluded ->
           if preferred == "ws-only",
             do: {:error, :no_http_provider},
             else: {:ok, preferred}
         end,
         replacement_requester: fn _profile, _chain_id, _key, provider_id, coordinator_pid ->
           send(coordinator_pid, {:subscription_confirmed, provider_id, "upstream-new"})
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-only", "sub-live", old, 1})
    assert_receive {:subscription_event, _}
    GenServer.cast(pid, {:upstream_event, "ws-only", "sub-live", replacement, 2})

    for height <- 100..101 do
      expected = canonical[height]
      assert_receive {:subscription_event, %{"params" => %{"result" => ^expected}}}
    end

    assert await_state(pid, &(&1.failover_status == :active)).primary_provider_id == "certifiable"
    refute_receive {:subscription_event, _}, 50
  end

  test "one unlinked owner uses one provider and deadline and delivers events before its result" do
    test_pid = self()

    requester = fn scope, chain_id, method, params, opts ->
      send(test_pid, {:backfill_request, self(), scope, chain_id, method, params, opts})

      case {method, params} do
        {"eth_blockNumber", []} ->
          {:ok, "0xc", %{}}

        {"eth_getBlockByNumber", ["0xA", false]} ->
          {:ok, new_head(10), %{}}

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

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub", new_head(10), 1})
    await_state(pid, &(&1.state.markers.last_block_num == 10))
    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})

    assert_receive {:provider_selection, ^pid, ^profile, ^chain_id, ["ws-old", "ws-new"]}

    assert_receive {:backfill_request, owner_pid, head_scope, ^chain_id, "eth_blockNumber", [],
                    head_opts}

    assert_receive {:backfill_request, ^owner_pid, replay_scope, ^chain_id,
                    "eth_getBlockByNumber", ["0xA", false], replay_opts}

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
      [
        {head_scope, head_opts},
        {replay_scope, replay_opts},
        {block_scope, block_opts},
        {final_scope, final_opts}
      ],
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

    active = await_state(pid, &(&1.failover_status == :active))

    assert active.state.markers.last_block_num == 12
  end

  test "replacement is live before backfill and overlapping heads are delivered once in order" do
    test_pid = self()
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}

    requester = fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} ->
          send(test_pid, {:head_requested, self()})

          receive do
            :respond_head -> {:ok, "0x66", %{}}
          end

        {"eth_getBlockByNumber", [number, false]} ->
          block_number = String.to_integer(String.trim_leading(number, "0x"), 16)

          block =
            case block_number do
              100 -> %{new_head(100) | "hash" => "0xcanonical-100"}
              101 -> %{new_head(101) | "parentHash" => "0xcanonical-100"}
              _ -> new_head(block_number)
            end

          {:ok, block, %{}}
      end
    end

    replacement = fn _profile, _chain_id, _key, provider_id, coordinator_pid ->
      send(test_pid, {:replacement_requested, provider_id})
      send(coordinator_pid, {:subscription_confirmed, provider_id, "upstream-new"})
    end

    selector = fn _profile, _chain_id, _excluded -> {:ok, "http-fixed"} end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "client-sub", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-old",
         backfill_requester: requester,
         backfill_provider_selector: selector,
         replacement_requester: replacement}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub-old", new_head(100), 1})
    assert_receive {:subscription_event, %{"params" => %{"result" => %{"number" => "0x64"}}}}

    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})

    assert_receive {:replacement_requested, "ws-new"}
    assert_receive {:head_requested, owner_pid}

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub-old", new_head(103), 2})
    GenServer.cast(pid, {:upstream_event, "ws-new", "sub-new", new_head(102), 2})
    send(owner_pid, :respond_head)

    assert await_state(pid, &(&1.failover_status == :active)).primary_provider_id == "ws-new"

    assert_receive {:subscription_event,
                    %{
                      "params" => %{
                        "result" => %{"number" => "0x64", "hash" => "0xcanonical-100"}
                      }
                    }}

    assert_receive {:subscription_event, %{"params" => %{"result" => %{"number" => "0x65"}}}}
    assert_receive {:subscription_event, %{"params" => %{"result" => %{"number" => "0x66"}}}}

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub-old", new_head(104), 3})
    refute_receive {:subscription_event, _duplicate}, 50
  end

  test "log failover replays the last block, preserves removals, and suppresses overlap" do
    test_pid = self()
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    filter = %{"address" => "0xabc"}
    key = {:logs, filter}

    canonical_100 = log_event(100, "0xcanonical-100")
    log_101 = log_event(101, "0xcanonical-101")

    requester = fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} ->
          send(test_pid, {:log_head_requested, self()})

          receive do
            :respond_log_head -> {:ok, "0x65", %{}}
          end

        {"eth_getLogs", [request_filter]} ->
          send(test_pid, {:log_backfill_filter, request_filter})
          {:ok, [canonical_100, log_101], %{}}

        {"eth_getBlockByNumber", ["0x64", false]} ->
          {:ok, %{"number" => "0x64", "hash" => "0xcanonical-100"}, %{}}
      end
    end

    replacement = fn _profile, _chain_id, _key, provider_id, coordinator_pid ->
      send(coordinator_pid, {:subscription_confirmed, provider_id, "upstream-new"})
    end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "client-logs", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-old",
         backfill_requester: requester,
         backfill_provider_selector: fn _profile, _chain_id, _excluded ->
           {:ok, "http-fixed"}
         end,
         replacement_requester: replacement}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    original = log_event(100, "0xold-100")
    GenServer.cast(pid, {:upstream_event, "ws-old", "sub-old", original, 1})
    assert_receive {:subscription_event, %{"params" => %{"result" => ^original}}}

    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})
    assert_receive {:log_head_requested, owner_pid}

    removed = %{original | "removed" => true}
    GenServer.cast(pid, {:upstream_event, "ws-new", "sub-new", removed, 2})
    GenServer.cast(pid, {:upstream_event, "ws-new", "sub-new", log_101, 3})
    send(owner_pid, :respond_log_head)

    assert_receive {:log_backfill_filter, %{"fromBlock" => "0x64", "toBlock" => "0x65"}}

    assert await_state(pid, &(&1.failover_status == :active)).primary_provider_id == "ws-new"

    delivered =
      for _ <- 1..3 do
        assert_receive {:subscription_event, %{"params" => %{"result" => payload}}}
        payload
      end

    assert delivered == [removed, canonical_100, log_101]
    refute_receive {:subscription_event, _duplicate}, 50
  end

  test "a connected tip-only reorg repairs every missing replacement header" do
    test_pid = self()
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}

    shared = %{"number" => "0x62", "hash" => "0xshared-98", "parentHash" => "0xshared-97"}

    old_branch = %{
      98 => shared,
      99 => %{"number" => "0x63", "hash" => "0xold-99", "parentHash" => "0xshared-98"},
      100 => %{"number" => "0x64", "hash" => "0xold-100", "parentHash" => "0xold-99"}
    }

    canonical = %{
      98 => shared,
      99 => %{"number" => "0x63", "hash" => "0xnew-99", "parentHash" => "0xshared-98"},
      100 => %{"number" => "0x64", "hash" => "0xnew-100", "parentHash" => "0xnew-99"},
      101 => %{"number" => "0x65", "hash" => "0xnew-101", "parentHash" => "0xnew-100"}
    }

    requester = canonical_requester(canonical, 101)
    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})

    :ok =
      ClientSubscriptionRegistry.add_client(profile, chain_id, "client-live-reorg", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-live",
         max_backfill_blocks: 8,
         backfill_requester: requester,
         backfill_provider_selector: fn ^profile, ^chain_id, "ws-live", [] ->
           {:ok, "ws-live"}
         end,
         replacement_requester: fn _profile, _chain_id, _key, _provider, _coordinator ->
           send(test_pid, :unexpected_replacement)
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for height <- 98..100 do
      GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", old_branch[height], 1})
      assert_receive {:subscription_event, %{"params" => %{"result" => expected}}}
      assert expected == old_branch[height]
    end

    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", canonical[101], 2})

    for height <- 99..101 do
      expected = canonical[height]
      assert_receive {:subscription_event, %{"params" => %{"result" => ^expected}}}
    end

    state =
      await_state(
        pid,
        &(&1.failover_status == :active and &1.state.markers.last_block_num == 101)
      )

    assert state.primary_provider_id == "ws-live"
    refute_receive :unexpected_replacement
    refute_receive {:subscription_event, _}, 50
  end

  test "a connected equal-height replacement is reconciled before delivery" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}
    shared = %{"number" => "0x63", "hash" => "0xshared-99", "parentHash" => "0xshared-98"}
    old = %{"number" => "0x64", "hash" => "0xold-100", "parentHash" => "0xshared-99"}
    replacement = %{"number" => "0x64", "hash" => "0xnew-100", "parentHash" => "0xshared-99"}
    canonical = %{99 => shared, 100 => replacement}

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})

    :ok =
      ClientSubscriptionRegistry.add_client(profile, chain_id, "client-live-equal", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-live",
         max_backfill_blocks: 8,
         backfill_requester: canonical_requester(canonical, 100),
         backfill_provider_selector: fn _profile, _chain_id, _preferred, _excluded ->
           {:ok, "http-fixed"}
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for head <- [shared, old] do
      GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", head, 1})
      assert_receive {:subscription_event, _}
    end

    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", replacement, 2})
    assert_receive {:subscription_event, %{"params" => %{"result" => ^replacement}}}

    assert await_state(pid, &(&1.failover_status == :active)).primary_provider_id == "ws-live"
    refute_receive {:subscription_event, _}, 50
  end

  test "a connected reorg can regress to the start of an unfilled observation window" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}
    head = start_supervised!({Agent, fn -> 1 end})

    original = %{
      1 => %{"number" => "0x1", "hash" => "0xold-1", "parentHash" => "0xgenesis"},
      2 => %{"number" => "0x2", "hash" => "0xold-2", "parentHash" => "0xold-1"}
    }

    canonical = %{
      1 => %{"number" => "0x1", "hash" => "0xnew-1", "parentHash" => "0xgenesis"},
      2 => %{"number" => "0x2", "hash" => "0xnew-2", "parentHash" => "0xnew-1"}
    }

    requester = fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} ->
          {:ok, "0x#{Integer.to_string(Agent.get(head, & &1), 16)}", %{}}

        {"eth_getBlockByNumber", [number, false]} ->
          height = number |> String.trim_leading("0x") |> String.to_integer(16)
          {:ok, Map.fetch!(canonical, height), %{}}
      end
    end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})

    :ok =
      ClientSubscriptionRegistry.add_client(
        profile,
        chain_id,
        "client-live-regression",
        self(),
        key
      )

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-live",
         max_backfill_blocks: 8,
         backfill_requester: requester,
         backfill_provider_selector: fn _profile, _chain_id, _preferred, _excluded ->
           {:ok, "http-fixed"}
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for height <- 1..2 do
      GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", original[height], 1})
      expected = original[height]
      assert_receive {:subscription_event, %{"params" => %{"result" => ^expected}}}
    end

    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", canonical[1], 2})
    expected_one = canonical[1]
    assert_receive {:subscription_event, %{"params" => %{"result" => ^expected_one}}}

    Agent.update(head, fn _ -> 2 end)
    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", canonical[2], 3})
    expected_two = canonical[2]
    assert_receive {:subscription_event, %{"params" => %{"result" => ^expected_two}}}

    assert await_state(pid, &(&1.failover_status == :active)).state.markers.last_block_num == 2
    refute_receive {:subscription_event, _}, 50
  end

  test "a reorg concurrent with repair starts another bounded reconciliation" do
    test_pid = self()
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}
    shared = %{"number" => "0x62", "hash" => "0xshared-98", "parentHash" => "0xshared-97"}

    old_branch = %{
      98 => shared,
      99 => %{"number" => "0x63", "hash" => "0xold-99", "parentHash" => "0xshared-98"},
      100 => %{"number" => "0x64", "hash" => "0xold-100", "parentHash" => "0xold-99"}
    }

    canonical = %{
      98 => shared,
      99 => %{"number" => "0x63", "hash" => "0xnew-99", "parentHash" => "0xshared-98"},
      100 => %{"number" => "0x64", "hash" => "0xnew-100", "parentHash" => "0xnew-99"},
      101 => %{"number" => "0x65", "hash" => "0xnew-101", "parentHash" => "0xnew-100"},
      102 => %{"number" => "0x66", "hash" => "0xnew-102", "parentHash" => "0xnew-101"},
      103 => %{"number" => "0x67", "hash" => "0xnew-103", "parentHash" => "0xnew-102"},
      104 => %{"number" => "0x68", "hash" => "0xnew-104", "parentHash" => "0xnew-103"},
      105 => %{"number" => "0x69", "hash" => "0xnew-105", "parentHash" => "0xnew-104"}
    }

    head_reads = start_supervised!({Agent, fn -> 0 end})

    requester = fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} ->
          read = Agent.get_and_update(head_reads, &{&1 + 1, &1 + 1})
          {:ok, if(read == 1, do: "0x67", else: "0x69"), %{}}

        {"eth_getBlockByNumber", ["0x67", false]} ->
          if Agent.get(head_reads, & &1) == 1 do
            send(test_pid, {:first_repair_waiting, self()})

            receive do
              :release_first_repair -> :ok
            end
          end

          {:ok, canonical[103], %{}}

        {"eth_getBlockByNumber", [number, false]} ->
          height = number |> String.trim_leading("0x") |> String.to_integer(16)
          {:ok, Map.fetch!(canonical, height), %{}}
      end
    end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})

    :ok =
      ClientSubscriptionRegistry.add_client(profile, chain_id, "client-live-race", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-live",
         max_backfill_blocks: 8,
         backfill_requester: requester,
         backfill_provider_selector: fn _profile, _chain_id, _preferred, _excluded ->
           {:ok, "http-fixed"}
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for height <- 98..100 do
      GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", old_branch[height], 1})
      assert_receive {:subscription_event, _}
    end

    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", canonical[103], 2})
    assert_receive {:first_repair_waiting, first_owner}

    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", canonical[105], 3})
    send(first_owner, :release_first_repair)

    for height <- 99..105 do
      expected = canonical[height]
      assert_receive {:subscription_event, %{"params" => %{"result" => ^expected}}}
    end

    assert Agent.get(head_reads, & &1) == 2
    assert await_state(pid, &(&1.failover_status == :active)).state.markers.last_block_num == 105
    refute_receive {:subscription_event, _}, 50
  end

  test "a transient connected fork tip is suppressed when HTTP proves another branch" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}
    shared = %{"number" => "0x62", "hash" => "0xshared-98", "parentHash" => "0xshared-97"}

    old_branch = %{
      98 => shared,
      99 => %{"number" => "0x63", "hash" => "0xold-99", "parentHash" => "0xshared-98"},
      100 => %{"number" => "0x64", "hash" => "0xold-100", "parentHash" => "0xold-99"}
    }

    canonical = %{
      98 => shared,
      99 => %{"number" => "0x63", "hash" => "0xnew-99", "parentHash" => "0xshared-98"},
      100 => %{"number" => "0x64", "hash" => "0xnew-100", "parentHash" => "0xnew-99"},
      101 => %{"number" => "0x65", "hash" => "0xnew-101", "parentHash" => "0xnew-100"},
      102 => %{"number" => "0x66", "hash" => "0xnew-102", "parentHash" => "0xnew-101"},
      103 => %{"number" => "0x67", "hash" => "0xnew-103", "parentHash" => "0xnew-102"}
    }

    transient_tip = %{
      "number" => "0x67",
      "hash" => "0xfork-103",
      "parentHash" => "0xfork-102"
    }

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})

    :ok =
      ClientSubscriptionRegistry.add_client(profile, chain_id, "client-stale-tip", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-live",
         max_backfill_blocks: 8,
         backfill_requester: canonical_requester(canonical, 103),
         backfill_provider_selector: fn _profile, _chain_id, _preferred, _excluded ->
           {:ok, "http-fixed"}
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for height <- 98..100 do
      GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", old_branch[height], 1})
      assert_receive {:subscription_event, _}
    end

    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", transient_tip, 2})

    for height <- 99..103 do
      expected = canonical[height]
      assert_receive {:subscription_event, %{"params" => %{"result" => ^expected}}}
    end

    assert await_state(pid, &(&1.failover_status == :active)).state.markers.last_block_num == 103
    refute_receive {:subscription_event, %{"params" => %{"result" => ^transient_tip}}}, 50
  end

  test "connected reorg repair cannot reset its attempt budget" do
    test_pid = self()
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}
    shared = %{"number" => "0x63", "hash" => "0xshared-99", "parentHash" => "0xshared-98"}
    old = %{"number" => "0x64", "hash" => "0xold-100", "parentHash" => "0xshared-99"}

    canonical = %{
      99 => shared,
      100 => %{"number" => "0x64", "hash" => "0xnew-100", "parentHash" => "0xshared-99"},
      101 => %{"number" => "0x65", "hash" => "0xnew-101", "parentHash" => "0xnew-100"}
    }

    future = %{"number" => "0x67", "hash" => "0xnew-103", "parentHash" => "0xnew-102"}

    requester = fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} ->
          {:ok, "0x65", %{}}

        {"eth_getBlockByNumber", ["0x65", false]} ->
          send(test_pid, {:attempt_budget_repair_waiting, self()})

          receive do
            :release_attempt_budget_repair -> {:ok, canonical[101], %{}}
          end

        {"eth_getBlockByNumber", [number, false]} ->
          height = number |> String.trim_leading("0x") |> String.to_integer(16)
          {:ok, Map.fetch!(canonical, height), %{}}
      end
    end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})

    :ok =
      ClientSubscriptionRegistry.add_client(
        profile,
        chain_id,
        "client-attempt-budget",
        self(),
        key
      )

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-live",
         max_backfill_blocks: 8,
         max_failover_attempts: 1,
         backfill_requester: requester,
         backfill_provider_selector: fn _profile, _chain_id, _preferred, _excluded ->
           {:ok, "http-fixed"}
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for head <- [shared, old] do
      GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", head, 1})
      assert_receive {:subscription_event, _}
    end

    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", canonical[101], 2})
    assert_receive {:attempt_budget_repair_waiting, owner_pid}
    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", future, 3})
    send(owner_pid, :release_attempt_budget_repair)

    for height <- 100..101 do
      expected = canonical[height]
      assert_receive {:subscription_event, %{"params" => %{"result" => ^expected}}}
    end

    assert_receive {:subscription_terminated, "client-attempt-budget", :continuity_exhausted}
    assert await_state(pid, &(&1.failover_status == :degraded)).recovery_attempts == 0
    refute_receive {:subscription_event, %{"params" => %{"result" => ^future}}}, 50
  end

  test "a connected gap beyond the replay window terminates explicitly" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}
    old = %{"number" => "0x64", "hash" => "0xold-100", "parentHash" => "0xold-99"}
    distant = %{"number" => "0xc8", "hash" => "0xnew-200", "parentHash" => "0xnew-199"}

    requester = fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} -> {:ok, "0xc8", %{}}
        {"eth_getBlockByNumber", _} -> flunk("overflow must fail before partial replay")
      end
    end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "client-live-gap", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-live",
         max_backfill_blocks: 3,
         max_failover_attempts: 1,
         backfill_requester: requester,
         backfill_provider_selector: fn _profile, _chain_id, _preferred, _excluded ->
           {:ok, "http-fixed"}
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", old, 1})
    assert_receive {:subscription_event, _}
    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", distant, 2})

    assert_receive {:subscription_terminated, "client-live-gap", :continuity_exhausted}
    assert await_state(pid, &(&1.failover_status == :degraded)).state.retained_bytes == 0
  end

  test "a live repair source behind the observed tip cannot certify continuity" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}
    old = %{"number" => "0x64", "hash" => "0xold-100", "parentHash" => "0xold-99"}
    observed = %{"number" => "0x65", "hash" => "0xnew-101", "parentHash" => "0xnew-100"}

    requester = fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} -> {:ok, "0x64", %{}}
        {"eth_getBlockByNumber", _} -> flunk("a source behind the observed tip must not replay")
      end
    end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})

    :ok =
      ClientSubscriptionRegistry.add_client(profile, chain_id, "client-live-behind", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-live",
         max_failover_attempts: 1,
         backfill_requester: requester,
         backfill_provider_selector: fn _profile, _chain_id, _preferred, _excluded ->
           {:ok, "http-fixed"}
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", old, 1})
    assert_receive {:subscription_event, _}
    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", observed, 2})

    assert_receive {:subscription_terminated, "client-live-behind", :continuity_exhausted}
    assert await_state(pid, &(&1.failover_status == :degraded)).state.retained_bytes == 0
  end

  test "live reorg buffering obeys the exact continuity byte budget" do
    test_pid = self()
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}
    old = %{"number" => "0x64", "hash" => "0xold-100", "parentHash" => "0xold-99"}

    observed = %{
      "number" => "0x65",
      "hash" => "0xnew-101",
      "parentHash" => "0xnew-100",
      "extraData" => String.duplicate("a", 256)
    }

    stream_limit = StreamState.event_bytes(old) + StreamState.event_bytes(observed) - 1
    budget = :"live-reorg-budget-#{chain_id}"

    start_supervised!(
      {ContinuityBudget,
       name: budget,
       node_limit: stream_limit,
       stream_limit: stream_limit,
       client_limit: stream_limit}
    )

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})

    :ok =
      ClientSubscriptionRegistry.add_client(profile, chain_id, "client-live-budget", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-live",
         continuity_budget: budget,
         backfill_provider_selector: fn _profile, _chain_id, _preferred, _excluded ->
           send(test_pid, :unexpected_http_selection)
           {:ok, "http-fixed"}
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", old, 1})
    assert_receive {:subscription_event, _}
    GenServer.cast(pid, {:upstream_event, "ws-live", "sub-live", observed, 2})

    assert_receive {:subscription_terminated, "client-live-budget", :continuity_exhausted}
    assert await_state(pid, &(&1.failover_status == :degraded)).state.retained_bytes == 0
    refute_receive :unexpected_http_selection
    assert ContinuityBudget.stats(budget).used_bytes == 0
  end

  test "repeated disconnected reorg re-emits a branch that becomes canonical again" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}

    shared = %{"number" => "0x62", "hash" => "0xshared-98", "parentHash" => "0xshared-97"}

    branch_a = %{
      98 => shared,
      99 => %{"number" => "0x63", "hash" => "0xa-99", "parentHash" => "0xshared-98"},
      100 => %{"number" => "0x64", "hash" => "0xa-100", "parentHash" => "0xa-99"},
      101 => %{"number" => "0x65", "hash" => "0xa-101", "parentHash" => "0xa-100"}
    }

    branch_b = %{
      98 => shared,
      99 => %{"number" => "0x63", "hash" => "0xb-99", "parentHash" => "0xshared-98"},
      100 => %{"number" => "0x64", "hash" => "0xb-100", "parentHash" => "0xb-99"},
      101 => %{"number" => "0x65", "hash" => "0xb-101", "parentHash" => "0xb-100"}
    }

    branch = start_supervised!({Agent, fn -> branch_b end})

    requester = fn _scope, _chain_id, method, params, _opts ->
      canonical = Agent.get(branch, & &1)

      case {method, params} do
        {"eth_blockNumber", []} ->
          {:ok, "0x65", %{}}

        {"eth_getBlockByNumber", [number, false]} ->
          height = number |> String.trim_leading("0x") |> String.to_integer(16)
          {:ok, Map.fetch!(canonical, height), %{}}
      end
    end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "client-repeat", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-a",
         max_backfill_blocks: 8,
         backfill_requester: requester,
         backfill_provider_selector: fn _profile, _chain_id, _excluded ->
           {:ok, "http-fixed"}
         end,
         replacement_requester: fn _profile, _chain_id, _key, provider_id, coordinator_pid ->
           send(coordinator_pid, {:subscription_confirmed, provider_id, "upstream-new"})
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for height <- 98..101 do
      GenServer.cast(pid, {:upstream_event, "ws-a", "sub-a", branch_a[height], 1})
      assert_receive {:subscription_event, %{"params" => %{"result" => expected}}}
      assert expected == branch_a[height]
    end

    GenServer.cast(pid, {:provider_unhealthy, "ws-a", "ws-b"})
    assert await_state(pid, &(&1.failover_status == :active)).primary_provider_id == "ws-b"

    for height <- 99..101 do
      expected = branch_b[height]
      assert_receive {:subscription_event, %{"params" => %{"result" => ^expected}}}
    end

    Agent.update(branch, fn _ -> branch_a end)
    GenServer.cast(pid, {:provider_unhealthy, "ws-b", "ws-a"})
    assert await_state(pid, &(&1.failover_status == :active)).primary_provider_id == "ws-a"

    for height <- 99..101 do
      expected = branch_a[height]
      assert_receive {:subscription_event, %{"params" => %{"result" => ^expected}}}
    end

    refute_receive {:subscription_event, _}, 50
  end

  test "an internally inconsistent HTTP branch cannot certify reorg continuity" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}

    requester = fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} ->
          {:ok, "0x65", %{}}

        {"eth_getBlockByNumber", ["0x64", false]} ->
          {:ok, %{"number" => "0x64", "hash" => "0xnew-100", "parentHash" => "0x99"}, %{}}

        {"eth_getBlockByNumber", ["0x65", false]} ->
          {:ok, %{"number" => "0x65", "hash" => "0xnew-101", "parentHash" => "0xwrong"}, %{}}
      end
    end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})

    :ok =
      ClientSubscriptionRegistry.add_client(profile, chain_id, "client-bad-branch", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-old",
         max_backfill_blocks: 8,
         max_failover_attempts: 1,
         backfill_requester: requester,
         backfill_provider_selector: fn _profile, _chain_id, _excluded ->
           {:ok, "http-fixed"}
         end,
         replacement_requester: fn _profile, _chain_id, _key, provider_id, coordinator_pid ->
           send(coordinator_pid, {:subscription_confirmed, provider_id, "upstream-new"})
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub-old", new_head(100), 1})
    assert_receive {:subscription_event, _}
    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})

    assert_receive {:subscription_terminated, "client-bad-branch", :continuity_exhausted}
    assert await_state(pid, &(&1.failover_status == :degraded)).failover_context == nil
  end

  test "log reorg synthesizes orphan removals before the canonical branch" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    filter = %{"address" => "0xabc"}
    key = {:logs, filter}
    orphan = log_event(100, "0xold-100")
    canonical = log_event(100, "0xnew-100")

    requester = fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} ->
          {:ok, "0x64", %{}}

        {"eth_getBlockByNumber", ["0x64", false]} ->
          {:ok, %{"number" => "0x64", "hash" => "0xnew-100"}, %{}}

        {"eth_getLogs", [%{"fromBlock" => "0x64", "toBlock" => "0x64"}]} ->
          {:ok, [canonical], %{}}
      end
    end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})

    :ok =
      ClientSubscriptionRegistry.add_client(profile, chain_id, "client-log-reorg", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-old",
         max_backfill_blocks: 8,
         backfill_requester: requester,
         backfill_provider_selector: fn _profile, _chain_id, _excluded ->
           {:ok, "http-fixed"}
         end,
         replacement_requester: fn _profile, _chain_id, _key, provider_id, coordinator_pid ->
           send(coordinator_pid, {:subscription_confirmed, provider_id, "upstream-new"})
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub-old", orphan, 1})
    assert_receive {:subscription_event, %{"params" => %{"result" => ^orphan}}}

    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})
    assert await_state(pid, &(&1.failover_status == :active)).primary_provider_id == "ws-new"

    removed = %{orphan | "removed" => true}
    assert_receive {:subscription_event, %{"params" => %{"result" => ^removed}}}
    assert_receive {:subscription_event, %{"params" => %{"result" => ^canonical}}}
    refute_receive {:subscription_event, _}, 50
  end

  test "dense delivered log history fails closed when it cannot be retained" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    filter = %{"address" => "0xabc"}
    key = {:logs, filter}

    requester = fn _scope, _chain_id, method, params, _opts ->
      flunk("overflow is terminal before an HTTP request: #{method} #{inspect(params)}")
    end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})

    :ok =
      ClientSubscriptionRegistry.add_client(profile, chain_id, "client-dense-logs", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-old",
         history_max_items: 2,
         max_failover_attempts: 1,
         backfill_requester: requester,
         backfill_provider_selector: fn _profile, _chain_id, _excluded ->
           {:ok, "http-fixed"}
         end,
         replacement_requester: fn _profile, _chain_id, _key, provider_id, coordinator_pid ->
           send(coordinator_pid, {:subscription_confirmed, provider_id, "upstream-new"})
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for index <- 0..2 do
      log = Map.put(log_event(100, "0xold-100"), "logIndex", "0x#{index}")
      GenServer.cast(pid, {:upstream_event, "ws-old", "sub-old", log, index})
      assert_receive {:subscription_event, _}
    end

    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})

    assert_receive {:subscription_terminated, "client-dense-logs", :continuity_exhausted}
    assert await_state(pid, &(&1.failover_status == :degraded)).failover_context == nil
  end

  test "a disconnected reorg beyond retained ancestry terminates the stream" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}

    requester = fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} ->
          {:ok, "0x64", %{}}

        {"eth_getBlockByNumber", [number, false]} ->
          height = number |> String.trim_leading("0x") |> String.to_integer(16)

          {:ok,
           %{
             "number" => number,
             "hash" => "0xnew-#{height}",
             "parentHash" => "0xnew-#{height - 1}"
           }, %{}}
      end
    end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})

    :ok =
      ClientSubscriptionRegistry.add_client(profile, chain_id, "client-deep-reorg", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-old",
         max_backfill_blocks: 3,
         max_failover_attempts: 1,
         backfill_requester: requester,
         backfill_provider_selector: fn _profile, _chain_id, _excluded ->
           {:ok, "http-fixed"}
         end,
         replacement_requester: fn _profile, _chain_id, _key, provider_id, coordinator_pid ->
           send(coordinator_pid, {:subscription_confirmed, provider_id, "upstream-new"})
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    for height <- 98..100 do
      old = %{
        "number" => "0x#{Integer.to_string(height, 16)}",
        "hash" => "0xold-#{height}",
        "parentHash" => "0xold-#{height - 1}"
      }

      GenServer.cast(pid, {:upstream_event, "ws-old", "sub-old", old, 1})
      assert_receive {:subscription_event, _}
    end

    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})

    assert_receive {:subscription_terminated, "client-deep-reorg", :continuity_exhausted}
    assert await_state(pid, &(&1.failover_status == :degraded)).failover_context == nil
  end

  test "buffered removals across blocks precede every replacement addition" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:logs, %{}}
    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "client-order", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link({profile, chain_id, key, primary_provider_id: "old"})

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    removal_100 = log_event(100, "old-100", true)
    removal_101 = log_event(101, "old-101", true)
    replacement_100 = log_event(100, "new-100")
    replacement_101 = log_event(101, "new-101")
    owner_pid = self()
    owner_id = make_ref()
    owner_ref = Process.monitor(self())

    :sys.replace_state(pid, fn state ->
      %{
        state
        | failover_status: :backfilling,
          failover_context: %{
            old_provider_id: "old",
            new_provider_id: "new",
            backfill_owner_id: owner_id,
            backfill_owner_pid: owner_pid,
            backfill_owner_ref: owner_ref,
            backfill_task_ref: owner_ref,
            started_at: System.monotonic_time(:millisecond),
            attempt_count: 1,
            event_buffer: [replacement_101, removal_100, replacement_100, removal_101]
          }
      }
    end)

    send(pid, {:backfill_result, owner_id, owner_pid, :ok})

    delivered =
      for _ <- 1..4 do
        assert_receive {:subscription_event, %{"params" => %{"result" => payload}}}
        payload
      end

    assert delivered == [removal_100, removal_101, replacement_100, replacement_101]
    refute_receive {:subscription_event, _}, 50
  end

  test "a buffered orphan addition is undone before replacement logs" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:logs, %{}}
    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "client-order", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link({profile, chain_id, key, primary_provider_id: "old"})

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    orphan_100 = log_event(100, "old-100")
    removal_100 = log_event(100, "old-100", true)
    removal_101 = log_event(101, "old-101", true)
    replacement_100 = log_event(100, "new-100")
    replacement_101 = log_event(101, "new-101")
    owner_pid = self()
    owner_id = make_ref()
    owner_ref = Process.monitor(self())

    :sys.replace_state(pid, fn state ->
      %{
        state
        | failover_status: :backfilling,
          failover_context: %{
            old_provider_id: "old",
            new_provider_id: "new",
            backfill_owner_id: owner_id,
            backfill_owner_pid: owner_pid,
            backfill_owner_ref: owner_ref,
            backfill_task_ref: owner_ref,
            started_at: System.monotonic_time(:millisecond),
            attempt_count: 1,
            event_buffer: [replacement_101, removal_100, replacement_100, removal_101, orphan_100]
          }
      }
    end)

    send(pid, {:backfill_result, owner_id, owner_pid, :ok})

    delivered =
      for _ <- 1..5 do
        assert_receive {:subscription_event, %{"params" => %{"result" => payload}}}
        payload
      end

    assert delivered == [orphan_100, removal_100, removal_101, replacement_100, replacement_101]
    refute_receive {:subscription_event, _}, 50
  end

  test "a gap beyond the replay window terminates downstream subscriptions" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}

    requester = fn _scope, _chain_id, method, params, _opts ->
      case {method, params} do
        {"eth_blockNumber", []} -> {:ok, "0xc8", %{}}
        {"eth_getBlockByNumber", _params} -> flunk("strict overflow must not partially replay")
      end
    end

    replacement = fn _profile, _chain_id, _key, provider_id, coordinator_pid ->
      send(coordinator_pid, {:subscription_confirmed, provider_id, "upstream-new"})
    end

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "client-sub", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-old",
         max_backfill_blocks: 32,
         continuity_policy: :strict_abort,
         max_failover_attempts: 1,
         backfill_requester: requester,
         backfill_provider_selector: fn _profile, _chain_id, _excluded ->
           {:ok, "http-fixed"}
         end,
         replacement_requester: replacement}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub-old", new_head(100), 1})
    assert_receive {:subscription_event, _head_100}

    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})

    assert_receive {:subscription_terminated, "client-sub", :continuity_exhausted}
    assert await_state(pid, &(&1.failover_status == :degraded)).failover_context == nil
  end

  test "replacement deadline exhaustion terminates downstream subscriptions" do
    chain_id = System.unique_integer([:positive])
    profile = "profile-#{chain_id}"
    key = {:newHeads}

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "client-sub", self(), key)

    {:ok, pid} =
      StreamCoordinator.start_link(
        {profile, chain_id, key,
         primary_provider_id: "ws-old",
         recovery_timeout_ms: 20,
         backfill_provider_selector: fn _profile, _chain_id, _excluded ->
           {:ok, "http-fixed"}
         end,
         replacement_requester: fn _profile, _chain_id, _key, _provider, _coordinator ->
           :ok
         end}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})

    assert_receive {:subscription_terminated, "client-sub", :continuity_exhausted}, 200
    assert await_state(pid, &(&1.failover_status == :degraded)).recovery_deadline_us == nil
  end

  test "a failed request is terminal for the backfill" do
    test_pid = self()

    requester = fn _scope, _chain_id, method, params, _opts ->
      send(test_pid, {:attempted_request, method, params})

      case {method, params} do
        {"eth_blockNumber", []} -> {:ok, "0xc", %{}}
        {"eth_getBlockByNumber", ["0xA", false]} -> {:error, :upstream_failed, %{}}
        {"eth_getBlockByNumber", [_number, false]} -> flunk("request after terminal error")
      end
    end

    {pid, profile, chain_id, _key} =
      start_coordinator(test_pid, backfill_requester: requester)

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub", new_head(10), 1})
    await_state(pid, &(&1.state.markers.last_block_num == 10))
    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})

    assert_receive {:attempted_request, "eth_blockNumber", []}
    assert_receive {:attempted_request, "eth_getBlockByNumber", ["0xA", false]}
    refute_receive {:attempted_request, "eth_getBlockByNumber", ["0xB", false]}, 0

    assert await_state(pid, &(&1.failover_status == :degraded)).failover_context == nil
    assert Process.alive?(pid)
  end

  test "a byte-saturated recovery terminates continuity and releases its reservation" do
    test_pid = self()

    requester = fn _scope, _chain_id, "eth_blockNumber", [], _opts ->
      send(test_pid, :backfill_waiting)
      receive do: (:never -> {:ok, "0xa", %{}})
    end

    budget =
      start_supervised!(
        {ContinuityBudget,
         name: :stream_recovery_test_budget,
         node_limit: 1_024,
         stream_limit: 512,
         client_limit: 512}
      )

    {pid, profile, chain_id, key} =
      start_coordinator(test_pid,
        backfill_requester: requester,
        continuity_budget: budget
      )

    start_supervised!({ClientSubscriptionRegistry, {profile, chain_id}})
    :ok = ClientSubscriptionRegistry.add_client(profile, chain_id, "client-sub", self(), key)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    GenServer.cast(pid, {:upstream_event, "ws-old", "sub", new_head(10), 1})
    assert_receive {:subscription_event, _}
    GenServer.cast(pid, {:provider_unhealthy, "ws-old", "ws-new"})
    assert_receive :backfill_waiting

    assert :ok =
             StreamCoordinator.upstream_event(
               profile,
               chain_id,
               key,
               "ws-new",
               "sub-new",
               new_head(11),
               2
             )

    await_state(pid, &(&1.failover_context.event_buffer_count == 1))
    assert ContinuityBudget.stats(budget).stream_bytes > 0

    assert :ok =
             StreamCoordinator.upstream_event(
               profile,
               chain_id,
               key,
               "ws-new",
               "sub-new",
               Map.put(new_head(12), "extra", String.duplicate("x", 600)),
               3
             )

    assert_receive {:subscription_terminated, "client-sub", :continuity_exhausted}
    assert await_state(pid, &(&1.failover_status == :degraded)).state.markers.last_block_num == 10
    assert ContinuityBudget.stats(budget).stream_bytes == 0
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

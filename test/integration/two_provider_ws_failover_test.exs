defmodule Lasso.TwoProviderWsFailoverTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.Config.ConfigStore
  alias Lasso.Test.Harness.{Fleet, Rpc}

  test "newHeads stays consecutive when one of two HTTP and WS providers stops", context do
    assert_continuity(context)
  end

  @tag stalled_replacement: true
  test "independent HTTP backfill survives a replacement with unresponsive HTTP", context do
    assert_continuity(context)
  end

  @tag refused_replacement: true
  test "replacement ingress refusal during replay retries the returning route", context do
    assert_continuity(context)
  end

  @tag refused_replacement: true, third_replacement: true
  test "a third provider restores ordered heads within the original recovery budget", context do
    assert_continuity(context)
  end

  @tag stalled_replacement: true, transactions: true
  test "transaction policy prefers independent HTTP replay before replacement fallback",
       context do
    assert_continuity(context)
  end

  @tag rejected_logs: true, third_replacement: true
  test "rejected pending replacement logs never reach the winning stream", context do
    assert_continuity(context)
  end

  @tag connection_cooldown: true
  test "restore A then lose B inside A's connection cooldown preserves the subscription",
       context do
    assert_continuity(context)
  end

  @tag connection_cooldown: true, probation_poll: true
  test "subscription backfill retries a connection probation lease held by a head poll",
       context do
    assert_continuity(context)
  end

  defp assert_continuity(%{chain: chain} = context) do
    original_http = Application.get_env(:lasso, :http_client)
    original_ws = Application.get_env(:lasso, :ws_client_module)
    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)
    Application.put_env(:lasso, :ws_client_module, Lasso.RPC.Transport.WebSocket.Client)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, original_http)
      Application.put_env(:lasso, :ws_client_module, original_ws)
    end)

    a = Fleet.start!(self(), "own-a-#{chain}")
    b = Fleet.start!(self(), "own-b-#{chain}")

    fleets =
      if context[:stalled_replacement] || context[:third_replacement],
        do: [a, b, Fleet.start!(self(), "own-c-#{chain}")],
        else: [a, b]

    fleets =
      if context[:transactions],
        do: fleets ++ [Fleet.start!(self(), "relay-#{chain}")],
        else: fleets

    on_exit(fn ->
      # Fleet monitors the test owner and shuts its listener down on owner death.
      for fleet <- fleets do
        monitor = Process.monitor(fleet.pid)
        assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
      end
    end)

    for fleet <- fleets do
      Fleet.script(fleet, "eth_chainId", [], {:answer, hex(chain)})
      Fleet.script(fleet, "eth_blockNumber", [], {:answer, hex(102)})
      Fleet.script(fleet, "eth_getLogs", [], {:answer, [log(101), log(102)]})

      Fleet.script(
        fleet,
        "eth_getBlockByNumber",
        [],
        {:respond,
         fn request ->
           [number | _] = request["params"]

           height =
             if number == "latest",
               do: 102,
               else: String.to_integer(String.trim_leading(number, "0x"), 16)

           {:answer, header(height)}
         end}
      )
    end

    assert :ok =
             ConfigStore.register_chain_runtime("public", chain, %{
               block_time_ms: 1_000,
               websocket: %{subscribe_new_heads: true},
               providers: []
             })

    assert :ok = Lasso.Testing.ChainHelper.ensure_chain_exists(chain, profile: "public")

    for {fleet, priority} <- Enum.with_index(fleets, 1) do
      priority =
        if context[:connection_cooldown] && priority <= 2, do: 3 - priority, else: priority

      config = %{
        id: fleet.name,
        url: fleet.url,
        ws_url: if(priority <= 2 or context[:third_replacement], do: fleet.ws_url),
        priority: priority,
        subscribe_new_heads: true,
        background_observations: false
      }

      assert :ok = ConfigStore.register_provider_runtime("public", chain, config)
      assert :ok = Lasso.RPC.ChainSupervisor.ensure_provider("public", chain, config)

      if config.ws_url do
        instance = Lasso.Providers.Catalog.lookup_instance_id("public", chain, fleet.name)

        Lasso.Test.Eventually.assert_eventually(fn ->
          status = Lasso.Core.Streaming.InstanceSubscriptionManager.get_status(instance)
          match?(%{status: :connected}, status.connection_state)
        end)
      end
    end

    if context[:transactions] do
      {:ok, config} = ConfigStore.get_chain("public", chain)
      :ok = ConfigStore.unregister_chain_runtime("public", chain)

      :ok =
        ConfigStore.register_chain_runtime(
          "public",
          chain,
          Map.put(Map.from_struct(config), :transactions, %{
            providers: [List.last(fleets).name],
            fallback: "none"
          })
        )

      Lasso.Providers.Catalog.build_from_config()
    end

    if context[:stalled_replacement] do
      action = if context[:transactions], do: {:disconnect, 1011}, else: {:hold, :blocked}
      Fleet.script(b, "eth_blockNumber", [], action)
    end

    port = LassoWeb.Endpoint.config(:http)[:port]
    wire = Rpc.wire!("ws://127.0.0.1:#{port}/ws/rpc/profile/public/priority/#{chain}")

    on_exit(fn ->
      monitor = Process.monitor(wire.pid)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    end)

    params = if context[:rejected_logs], do: ["logs", %{}], else: ["newHeads"]
    Rpc.send!(wire, "eth_subscribe", params)
    source_fleet = if context[:connection_cooldown], do: b, else: a
    a_pid = source_fleet.pid

    assert_receive {:fleet, ^a_pid,
                    %{transport: :ws, request: %{"method" => "eth_subscribe"}} = source},
                   5_000

    assert %{"result" => subscription} = frame!(wire)
    key = if(context[:rejected_logs], do: {:logs, %{}}, else: {:newHeads})

    coordinator =
      GenServer.whereis(Lasso.Core.Streaming.StreamCoordinator.via("public", chain, key))

    assert is_pid(coordinator)

    on_exit(fn ->
      monitor = Process.monitor(coordinator)
      assert_receive {:DOWN, ^monitor, :process, ^coordinator, _}, 5_000
    end)

    assert is_binary(subscription)

    cond do
      context[:connection_cooldown] ->
        connection_cooldown(context, a, b, source, wire, subscription, coordinator)

      context[:rejected_logs] ->
        rejected_logs(chain, a, b, List.last(fleets), source, wire, subscription)

      true ->
        Fleet.notify(source, header(100))
        assert_head!(wire, subscription, 100)

        http = Enum.at(fleets, 2, b)

        if context[:third_replacement],
          do: Fleet.script(http, "eth_subscribe", [], {:hold, :third_subscription})

        if context[:refused_replacement],
          do: Fleet.script(http, "eth_blockNumber", [{:hold, :replay_head}], {:answer, hex(102)})

        Fleet.stop(a)

        b_pid = b.pid

        assert_receive {:fleet, ^b_pid,
                        %{transport: :ws, request: %{"method" => "eth_subscribe"}} = replacement},
                       5_000

        initial =
          if context[:refused_replacement],
            do: refuse_replacement_during_replay(chain, b, http, replacement)

        assert_head!(wire, subscription, 101)
        assert_head!(wire, subscription, 102)

        if context[:transactions] do
          refute Enum.any?(Fleet.drain(b), fn call ->
                   call.transport == :http and call.request["method"] == "eth_blockNumber"
                 end)

          assert Enum.any?(Fleet.drain(http), fn call ->
                   call.transport == :http and call.request["method"] == "eth_blockNumber"
                 end)
        end

        if context[:third_replacement] do
          third_pid = http.pid

          assert_receive {:fleet, ^third_pid,
                          %{transport: :ws, request: %{"method" => "eth_subscribe"}} = third},
                         5_000

          coordinator = Lasso.Core.Streaming.StreamCoordinator.via("public", chain, {:newHeads})
          next = :sys.get_state(coordinator)

          fields = [
            :recovery_deadline_us,
            :recovery_started_at_ms,
            :recovery_attempts,
            :max_backfill_blocks,
            :backfill_timeout
          ]

          assert Map.take(next, fields) == Map.take(initial, fields)
          assert Enum.any?(next.failover_history, &(&1.provider_id == a.name))
          # Hold the replacement result while its first live event overtakes it.
          pool = Lasso.Core.Streaming.UpstreamSubscriptionPool.via("public", chain)
          entry = :sys.get_state(pool).keys[{:newHeads}]
          owner = entry.resubscribe_pid
          true = :erlang.suspend_process(owner)

          try do
            :ok = Fleet.release(http, :third_subscription, {:answer, "third-sub"})
            Fleet.notify(%{third | action: {:answer, "third-sub"}}, header(103))
            Fleet.script(http, "eth_blockNumber", [], {:answer, hex(103)})

            Lasso.Test.Eventually.assert_eventually(fn ->
              state = :sys.get_state(coordinator)

              state.failover_status == :switching and
                state.failover_context.event_buffer_count == 1
            end)
          after
            true = :erlang.resume_process(owner)
          end

          assert_head!(wire, subscription, 103)
          Rpc.close!(wire)
        else
          if context[:refused_replacement] do
            assert_receive {:fleet, ^b_pid,
                            %{transport: :ws, request: %{"method" => "eth_subscribe"}}},
                           5_000

            Fleet.script(b, "eth_blockNumber", [], {:answer, hex(103)})
            assert_head!(wire, subscription, 103)
            Rpc.close!(wire)
          else
            Fleet.notify(replacement, header(103))
            assert_head!(wire, subscription, 103)
            Rpc.send!(wire, "eth_unsubscribe", [subscription], 2)
            assert %{"id" => 2, "result" => true} = frame!(wire)
            Rpc.close!(wire)
            refute_received {:rpc_disconnect, _, _}
            refute_received {:rpc_frame, _, {:close, _, _}}
          end
        end
    end
  end

  defp connection_cooldown(
         %{chain: chain} = context,
         a,
         b,
         source,
         wire,
         subscription,
         coordinator
       ) do
    alias Lasso.BlockSync.Strategies.HttpStrategy
    alias Lasso.Core.Support.CircuitBreaker
    alias Lasso.Test.Eventually

    Fleet.notify(source, header(100))
    assert_head!(wire, subscription, 100)
    Eventually.assert_eventually(fn -> :sys.get_state(coordinator).failover_status == :active end)
    :ok = Fleet.suspend_listener(a)
    port = LassoWeb.Endpoint.config(:http)[:port]

    credentials = %{
      rpc_url: "http://127.0.0.1:#{port}/rpc/profile/public/provider/#{a.name}/#{chain}"
    }

    instance = Lasso.Providers.Catalog.lookup_instance_id("public", chain, a.name)
    breaker = {instance, :http}

    Eventually.assert_eventually(fn ->
      Rpc.call(credentials, "web3_clientVersion")
      CircuitBreaker.get_state(breaker).state == :open
    end)

    :ok = Fleet.resume_listener(a)
    assert CircuitBreaker.get_state(breaker).state == :open
    assert CircuitBreaker.get_recovery_time_remaining(breaker) > 0

    poll =
      if context[:probation_poll] do
        Eventually.assert_eventually(fn ->
          CircuitBreaker.get_state(breaker).state == :half_open
        end)

        :ok = Fleet.script(a, "eth_blockNumber", [{:hold, :probation}], {:answer, hex(102)})

        {:ok, poll} = HttpStrategy.start(chain, instance, poll_interval_ms: 60_000)
        {:polling, poll} = HttpStrategy.poll(poll)
        a_pid = a.pid
        assert_receive {:fleet, ^a_pid, %{transport: :http, action: {:hold, :probation}}}, 2_000
        poll
      end

    started = System.monotonic_time(:millisecond)
    Fleet.stop(b)

    Eventually.assert_eventually(
      fn ->
        state = :sys.get_state(coordinator)

        state.failover_status == :backfilling and
          a.name in state.failover_context.backfill_context.admission_retries
      end,
      timeout: 2_000,
      interval: 1
    )

    waiting = :sys.get_state(coordinator)
    deadline = waiting.recovery_deadline_us
    assert deadline - System.monotonic_time(:microsecond) > 25_000_000

    if poll, do: :ok = Fleet.release(a, :probation, {:answer, hex(102)})
    assert_head!(wire, subscription, 101)
    assert_head!(wire, subscription, 102)

    Eventually.assert_eventually(fn ->
      state = :sys.get_state(coordinator)
      state.failover_status == :active and state.primary_provider_id == a.name
    end)

    assert System.monotonic_time(:microsecond) < deadline
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert CircuitBreaker.get_state(breaker).state == :closed
    if poll, do: HttpStrategy.stop(poll)
    Rpc.send!(wire, "eth_unsubscribe", [subscription], 2)
    assert %{"id" => 2, "result" => true} = frame!(wire)
    Rpc.close!(wire)
    refute_received {:rpc_disconnect, _, _}
    refute_received {:rpc_frame, _, {:close, _, _}}
  end

  defp rejected_logs(chain, a, b, c, source, wire, subscription) do
    Fleet.notify(source, log(100))
    assert_log!(wire, subscription, 100)
    Fleet.script(b, "eth_subscribe", [], {:hold, :pending_logs})
    Fleet.stop(a)
    b_pid = b.pid

    assert_receive {:fleet, ^b_pid, %{request: %{"method" => "eth_subscribe"}} = pending},
                   5_000

    pool = Lasso.Core.Streaming.UpstreamSubscriptionPool.via("public", chain)
    key = {:logs, %{}}
    owner = :sys.get_state(pool).keys[key].resubscribe_pid
    true = :erlang.suspend_process(owner)
    monitor = Process.monitor(owner)

    try do
      :ok = Fleet.release(b, :pending_logs, {:answer, "pending-logs"})
      rejected = Map.put(log(101), "blockHash", "0x" <> String.duplicate("f", 64))
      Fleet.notify(%{pending | action: {:answer, "pending-logs"}}, rejected)
      coordinator = Lasso.Core.Streaming.StreamCoordinator.via("public", chain, key)

      Lasso.Test.Eventually.assert_eventually(fn ->
        state = :sys.get_state(coordinator)
        state.failover_status == :switching and state.failover_context.event_buffer_count == 1
      end)

      # Reject the accepted subscription before its worker can commit the route.
      Fleet.stop(b)
      assert_receive {:DOWN, ^monitor, :process, ^owner, _}, 5_000
    after
      if Process.alive?(owner), do: :erlang.resume_process(owner)
    end

    c_pid = c.pid

    assert_receive {:fleet, ^c_pid, %{request: %{"method" => "eth_subscribe"}} = winner},
                   5_000

    assert_log!(wire, subscription, 101)
    assert_log!(wire, subscription, 102)
    Fleet.notify(winner, log(103))
    assert_log!(wire, subscription, 103)
    ref = wire.reference
    refute_receive {:rpc_frame, ^ref, _}, 100
    Rpc.close!(wire)
  end

  defp assert_log!(wire, subscription, height) do
    assert %{"params" => %{"subscription" => ^subscription, "result" => result}} = frame!(wire)
    assert result == log(height)
  end

  defp log(height) do
    %{
      "blockNumber" => hex(height),
      "blockHash" => header(height)["hash"],
      "transactionHash" => header(height + 1000)["hash"],
      "transactionIndex" => "0x0",
      "logIndex" => "0x0",
      "removed" => false,
      "address" => "0x" <> String.duplicate("1", 40),
      "topics" => [],
      "data" => "0x"
    }
  end

  defp refuse_replacement_during_replay(chain, fleet, http, replacement) do
    alias Lasso.Core.Streaming.{Ingress, InstanceSubscriptionManager}
    fleet_pid = fleet.pid

    http_pid = http.pid

    assert_receive {:fleet, ^http_pid,
                    %{
                      transport: :http,
                      request: %{"method" => "eth_blockNumber"},
                      action: {:hold, :replay_head}
                    }},
                   5_000

    initial =
      :sys.get_state(Lasso.Core.Streaming.StreamCoordinator.via("public", chain, {:newHeads}))

    instance = Lasso.Providers.Catalog.lookup_instance_id("public", chain, fleet.name)
    manager = GenServer.whereis(InstanceSubscriptionManager.via(instance))

    tokens =
      for _ <- 1..128 do
        {:ok, token} = Ingress.reserve(:lasso_stream_ingress, manager, 256)
        token
      end

    try do
      Fleet.notify(replacement, header(103))
      assert_receive {:fleet, ^fleet_pid, %{request: %{"method" => "eth_unsubscribe"}}}, 5_000
    after
      Enum.each(tokens, &Ingress.release/1)
    end

    :ok = Fleet.release(http, :replay_head, {:answer, hex(102)})
    initial
  end

  defp frame!(wire) do
    ref = wire.reference

    receive do
      {:rpc_frame, ^ref, {:text, raw}} -> Jason.decode!(raw)
      {:rpc_frame, ^ref, frame} -> flunk("unexpected frame: #{inspect(frame)}")
      {:rpc_disconnect, ^ref, reason} -> flunk("subscription disconnected: #{inspect(reason)}")
    after
      5_000 -> flunk("no subscription frame")
    end
  end

  defp assert_head!(wire, subscription, height) do
    assert %{
             "method" => "eth_subscription",
             "params" => %{"subscription" => ^subscription, "result" => result}
           } = frame!(wire)

    assert result["number"] == hex(height)
    assert result["hash"] == header(height)["hash"]
  end

  defp hex(height), do: "0x" <> Integer.to_string(height, 16)

  defp header(height) do
    %{
      "number" => hex(height),
      "hash" => "0x" <> String.pad_leading(Integer.to_string(height, 16), 64, "0"),
      "parentHash" => "0x" <> String.pad_leading(Integer.to_string(height - 1, 16), 64, "0"),
      "timestamp" => hex(1_700_000_000 + height)
    }
  end
end

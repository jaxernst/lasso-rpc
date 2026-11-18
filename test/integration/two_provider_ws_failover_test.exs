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
  test "replacement ingress refusal during replay closes with continuity failure", context do
    assert_continuity(context)
  end

  @tag refused_replacement: true, third_replacement: true
  test "a third provider restores ordered heads within the original recovery budget", context do
    assert_continuity(context)
  end

  @tag stalled_replacement: true, transactions: true
  test "transaction policy retries replay through an eligible HTTP read provider", context do
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

    Rpc.send!(wire, "eth_subscribe", ["newHeads"])
    a_pid = a.pid

    assert_receive {:fleet, ^a_pid,
                    %{transport: :ws, request: %{"method" => "eth_subscribe"}} = source},
                   5_000

    assert %{"result" => subscription} = frame!(wire)
    assert is_binary(subscription)

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

        Lasso.Test.Eventually.assert_eventually(fn ->
          state = :sys.get_state(coordinator)
          state.failover_status == :switching and state.failover_context.event_buffer_count == 1
        end)
      after
        true = :erlang.resume_process(owner)
      end

      assert_head!(wire, subscription, 103)
      Rpc.close!(wire)
    else
      if context[:refused_replacement] do
        ref = wire.reference
        assert_receive {:rpc_disconnect, ^ref, %{reason: {:remote, 1011, _reason}}}, 5_000
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

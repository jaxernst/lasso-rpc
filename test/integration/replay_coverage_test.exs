defmodule Lasso.ReplayCoverageTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.Config.ConfigStore
  alias Lasso.Test.Harness.{Fleet, Rpc}

  test "canonical replay covers discarded logs before later live logs", context do
    assert_continuity(context)
  end

  @tag exhausted: true
  @tag timeout: 45_000
  test "a winner behind the discarded log closes with 1011", context do
    assert_continuity(context)
  end

  @tag heads: true
  test "canonical replay restores the last discarded head without another live head", context do
    assert_continuity(context)
  end

  @tag heads: true, lagging_source: true
  test "live repair uses an already caught-up alternate HTTP source", context do
    assert_continuity(context)
  end

  @tag heads: true, moving_head: true
  test "a moving head retains verified progress during slow replay", context do
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

    fleets = [a, b, Fleet.start!(self(), "own-c-#{chain}")]

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
        "eth_getLogs",
        [],
        {:respond,
         fn request ->
           [filter] = request["params"]
           from = String.to_integer(String.trim_leading(filter["fromBlock"], "0x"), 16)
           to = String.to_integer(String.trim_leading(filter["toBlock"], "0x"), 16)

           {:answer,
            Enum.filter([log(101), log(102), log(103), log(104)], fn event ->
              n = String.to_integer(String.trim_leading(event["blockNumber"], "0x"), 16)
              n >= from and n <= to
            end)}
         end}
      )

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
        ws_url: fleet.ws_url,
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

    port = LassoWeb.Endpoint.config(:http)[:port]
    wire = Rpc.wire!("ws://127.0.0.1:#{port}/ws/rpc/profile/public/priority/#{chain}")

    on_exit(fn ->
      monitor = Process.monitor(wire.pid)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    end)

    params = if context[:heads], do: ["newHeads"], else: ["logs", %{}]
    Rpc.send!(wire, "eth_subscribe", params)
    a_pid = a.pid

    assert_receive {:fleet, ^a_pid,
                    %{transport: :ws, request: %{"method" => "eth_subscribe"}} = source},
                   5_000

    assert %{"result" => subscription} = frame!(wire)
    assert is_binary(subscription)

    replay_coverage(chain, a, b, List.last(fleets), source, wire, subscription, context)
  end

  defp replay_coverage(_chain, a, b, c, source, wire, subscription, %{moving_head: true}) do
    Fleet.notify(source, header(100))
    assert_head!(wire, subscription, 100)
    head = start_supervised!({Agent, fn -> 120 end})

    for fleet <- [a, b, c] do
      Fleet.script(
        fleet,
        "eth_blockNumber",
        [],
        {:respond,
         fn _ ->
           {:answer, hex(Agent.get(head, & &1))}
         end}
      )

      Fleet.script(
        fleet,
        "eth_getBlockByNumber",
        [],
        {:respond,
         fn request ->
           [number | _] = request["params"]
           Process.sleep(100)
           {:answer, header(String.to_integer(String.trim_leading(number, "0x"), 16))}
         end}
      )
    end

    start_supervised!(
      {Task,
       fn ->
         for height <- 121..150 do
           Process.sleep(1_000)
           Agent.update(head, fn _ -> height end)
           Fleet.notify(source, header(height))
         end
       end}
    )

    Fleet.notify(source, header(120))
    for height <- 101..123, do: assert_head!(wire, subscription, height)
    Rpc.close!(wire)
  end

  defp replay_coverage(_chain, _a, b, c, source, wire, subscription, %{
         lagging_source: true
       }) do
    Fleet.notify(source, header(100))
    assert_head!(wire, subscription, 100)
    Fleet.script(b, "eth_blockNumber", [], {:answer, hex(103)})
    Fleet.script(c, "eth_blockNumber", [], {:answer, hex(103)})
    Fleet.notify(source, header(103))
    for height <- 101..103, do: assert_head!(wire, subscription, height)

    Fleet.notify(source, header(104))
    assert_head!(wire, subscription, 104)
    Rpc.close!(wire)
  end

  defp replay_coverage(chain, a, b, c, source, wire, subscription, context) do
    event = if context[:heads], do: &header/1, else: &log/1
    assert_event = if context[:heads], do: &assert_head!/3, else: &assert_log!/3
    Fleet.notify(source, event.(100))
    assert_event.(wire, subscription, 100)
    Fleet.script(b, "eth_subscribe", [], {:hold, :pending_logs})
    Fleet.stop(a)
    b_pid = b.pid

    assert_receive {:fleet, ^b_pid, %{request: %{"method" => "eth_subscribe"}} = pending},
                   5_000

    pool = Lasso.Core.Streaming.UpstreamSubscriptionPool.via("public", chain)
    key = if context[:heads], do: {:newHeads}, else: {:logs, %{}}
    owner = :sys.get_state(pool).keys[key].resubscribe_pid
    true = :erlang.suspend_process(owner)
    monitor = Process.monitor(owner)

    try do
      :ok = Fleet.release(b, :pending_logs, {:answer, "pending-logs"})
      rejected = Map.put(event.(103), "unverified", true)
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

    assert_receive {:fleet, ^c_pid,
                    %{transport: :http, request: %{"method" => "eth_blockNumber"}}},
                   5_000

    if context[:exhausted] do
      ref = wire.reference
      assert_receive {:rpc_disconnect, ^ref, %{reason: {:remote, 1011, _}}}, 35_000
    else
      Fleet.script(c, "eth_blockNumber", [], {:answer, hex(103)})
      for height <- 101..102, do: assert_event.(wire, subscription, height)

      unless context[:heads] do
        Fleet.script(c, "eth_blockNumber", [], {:answer, hex(104)})
        Fleet.notify(winner, event.(104))
      end

      assert_event.(wire, subscription, 103)
      unless context[:heads], do: assert_event.(wire, subscription, 104)
      ref = wire.reference
      refute_receive {:rpc_frame, ^ref, _}, 100
      Rpc.close!(wire)
    end
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

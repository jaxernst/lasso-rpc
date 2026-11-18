defmodule Lasso.SubscriptionReconnectTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag feature: ["core-websocket-4"]

  alias Lasso.Config.ConfigStore
  alias Lasso.Test.Harness.{Fleet, Rpc}

  test "replacement reconnects before the original deadline", context do
    reconnect(context, :replacement)
  end

  test "returning original wins while the proposal remains disconnected", context do
    reconnect(context, :returning)
  end

  test "sole upstream reconnects without losing the client", context do
    reconnect(context, :sole)
  end

  @tag timeout: 45_000
  test "all routes down closes the client within the original budget", context do
    reconnect(context, :exhausted)
  end

  defp reconnect(%{chain: chain}, scenario) do
    original_http = Application.get_env(:lasso, :http_client)
    original_ws = Application.get_env(:lasso, :ws_client_module)
    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)
    Application.put_env(:lasso, :ws_client_module, Lasso.RPC.Transport.WebSocket.Client)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, original_http)
      Application.put_env(:lasso, :ws_client_module, original_ws)
    end)

    a = Fleet.start!(self(), "reconnect-a-#{chain}")

    fleets =
      if scenario == :sole, do: [a], else: [a, Fleet.start!(self(), "reconnect-b-#{chain}")]

    on_exit(fn ->
      for fleet <- fleets do
        monitor = Process.monitor(fleet.pid)
        assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
      end
    end)

    try do
      b = List.last(fleets)

      for fleet <- fleets do
        Fleet.script(fleet, "fixture_connected", [], {:answer, true})
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
          ws_url: fleet.ws_url,
          priority: priority,
          subscribe_new_heads: true,
          background_observations: false
        }

        assert :ok = ConfigStore.register_provider_runtime("public", chain, config)
        assert :ok = Lasso.RPC.ChainSupervisor.ensure_provider("public", chain, config)
      end

      wire =
        Rpc.wire!(
          "ws://127.0.0.1:#{LassoWeb.Endpoint.config(:http)[:port]}/ws/rpc/profile/public/priority/#{chain}"
        )

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
      Fleet.notify(source, header(100))
      assert_head!(wire, subscription, 100)

      for fleet <- fleets, do: Fleet.script(fleet, "fixture_upgrade", [], {:hold, :reconnect})
      # Break only the upstream socket; HTTP remains available for canonical replay.
      started = System.monotonic_time(:millisecond)

      if scenario != :sole do
        b_pid = b.pid
        assert_receive {:fleet, ^b_pid, %{request: %{"method" => "fixture_connected"}}}, 5_000
        Fleet.script(b, "eth_subscribe", [{:hold, :proposal}])
        send(source.connection, :fixture_disconnect)

        assert_receive {:fleet, ^b_pid,
                        %{request: %{"method" => "eth_subscribe"}, action: {:hold, :proposal}}},
                       5_000

        :ok = Fleet.release(b, :proposal, {:disconnect, 1011})

        assert_receive {:fleet, ^b_pid,
                        %{request: %{"method" => "fixture_upgrade"}, action: {:hold, :reconnect}}},
                       5_000
      else
        send(source.connection, :fixture_disconnect)
      end

      assert_receive {:fleet, ^a_pid,
                      %{request: %{"method" => "fixture_upgrade"}, action: {:hold, :reconnect}}},
                     5_000

      if scenario == :exhausted do
        ref = wire.reference
        assert_receive {:rpc_disconnect, ^ref, %{reason: {:remote, 1011, _}}}, 31_000
        elapsed = System.monotonic_time(:millisecond) - started
        assert elapsed >= 29_000
        assert elapsed < 31_500
      else
        target = if scenario == :replacement, do: b, else: a
        # A retry must keep the public socket alive while neither route is ready.
        ref = wire.reference
        refute_receive {:rpc_disconnect, ^ref, _}, 250
        reconnected_at = System.monotonic_time(:millisecond)
        assert :ok = Fleet.release(target, :reconnect, {:answer, true})
        target_pid = target.pid

        assert_receive {:fleet, ^target_pid,
                        %{transport: :ws, request: %{"method" => "eth_subscribe"}} = replacement},
                       5_000

        assert_head!(wire, subscription, 101)
        assert_head!(wire, subscription, 102)
        assert System.monotonic_time(:millisecond) - reconnected_at < 1_000
        Fleet.notify(replacement, header(103))
        assert_head!(wire, subscription, 103)

        assert Enum.any?(Enum.flat_map(fleets, &Fleet.drain/1), fn call ->
                 call.transport == :http and call.request["method"] == "eth_getBlockByNumber" and
                   call.request["params"] == [hex(101), false]
               end)

        if scenario == :returning do
          assert Enum.count(Fleet.drain(b), &(&1.request["method"] == "eth_subscribe")) == 1
        end

        Rpc.close!(wire)
      end
    after
      for fleet <- fleets do
        Fleet.script(fleet, "fixture_upgrade", [], {:answer, true})
        Fleet.release(fleet, :reconnect, {:answer, true})
        Fleet.release(fleet, :proposal, {:disconnect, 1011})
      end
    end
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

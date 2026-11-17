defmodule Lasso.TwoProviderWsFailoverTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.Config.ConfigStore
  alias Lasso.Test.Harness.{Fleet, Rpc}

  test "newHeads stays consecutive when one of two HTTP and WS providers stops", %{chain: chain} do
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

    on_exit(fn ->
      for fleet <- [a, b], Process.alive?(fleet.pid), do: Fleet.stop(fleet)
    end)

    for fleet <- [a, b] do
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

    for {fleet, priority} <- [{a, 1}, {b, 2}] do
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

    wire = Rpc.wire!("ws://127.0.0.1:4002/ws/rpc/profile/public/priority/#{chain}")
    on_exit(fn -> if Process.alive?(wire.pid), do: Rpc.close!(wire) end)
    Rpc.send!(wire, "eth_subscribe", ["newHeads"])
    a_pid = a.pid

    assert_receive {:fleet, ^a_pid,
                    %{transport: :ws, request: %{"method" => "eth_subscribe"}} = source},
                   5_000

    assert %{"result" => subscription} = frame!(wire)
    assert is_binary(subscription)

    Fleet.notify(source, header(100))
    assert_head!(wire, subscription, 100)
    Fleet.stop(a)

    b_pid = b.pid

    assert_receive {:fleet, ^b_pid,
                    %{transport: :ws, request: %{"method" => "eth_subscribe"}} = replacement},
                   5_000

    assert_head!(wire, subscription, 101)
    assert_head!(wire, subscription, 102)
    Fleet.notify(replacement, header(103))
    assert_head!(wire, subscription, 103)
    refute_received {:rpc_disconnect, _, _}
    refute_received {:rpc_frame, _, {:close, _, _}}
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

defmodule Lasso.RPC.HeadsStandbyFeedTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.BlockSync.{Registry, Worker}
  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Streaming.InstanceSubscriptionRegistry
  alias Lasso.Providers.Catalog

  @freshness_ms 2_000

  defmodule HTTPUpstream do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "eth_chainId" -> "0x" <> Integer.to_string(opts[:chain_id], 16)
          "eth_blockNumber" -> "0x64"
          _ -> "0x0"
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      )
    end
  end

  defmodule WSUpstream do
    def init(req, state), do: {:cowboy_websocket, req, state}

    def websocket_init(state) do
      send(state.test_pid, {:upstream_socket, state.provider, self()})
      {:ok, state}
    end

    def websocket_handle({:text, raw}, state) do
      request = Jason.decode!(raw)

      if request["method"] in ["eth_subscribe", "eth_unsubscribe"],
        do: send(state.test_pid, {:upstream, request["method"], state.provider})

      reply =
        case request["method"] do
          "eth_subscribe" when state.reject_subscribe? ->
            %{"error" => %{"code" => -32_601, "message" => "the method does not exist"}}

          "eth_subscribe" ->
            %{"result" => "subscription-#{state.provider}"}

          "eth_unsubscribe" ->
            %{"result" => true}

          "eth_chainId" ->
            %{"result" => "0x" <> Integer.to_string(state.chain_id, 16)}

          "eth_blockNumber" ->
            %{"result" => "0x64"}

          _ ->
            %{"result" => nil}
        end

      response = Jason.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => request["id"]}, reply))
      {:reply, {:text, response}, state}
    end

    def websocket_handle(_frame, state), do: {:ok, state}

    def websocket_info({:head, height}, state) do
      notification =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "eth_subscription",
          "params" => %{
            "subscription" => "subscription-#{state.provider}",
            "result" => %{
              "number" => "0x" <> Integer.to_string(height, 16),
              "hash" => "0x" <> Integer.to_string(height, 16),
              "timestamp" => "0x" <> Integer.to_string(System.system_time(:second), 16)
            }
          }
        })

      {:reply, {:text, notification}, state}
    end

    def websocket_info(_message, state), do: {:ok, state}
  end

  test "one live feed holds the only newHeads subscription and a working standby covers its outage",
       %{chain: chain} do
    profile = "public"
    original_ws_client = Application.get_env(:lasso, :ws_client_module)
    Application.put_env(:lasso, :ws_client_module, Lasso.RPC.Transport.WebSocket.Client)
    on_exit(fn -> Application.put_env(:lasso, :ws_client_module, original_ws_client) end)

    assert :ok =
             ConfigStore.register_chain_runtime(profile, chain, %{
               block_time_ms: 1_000,
               monitoring: %{evidence_freshness_ms: @freshness_ms},
               websocket: %{subscribe_new_heads: true, new_heads_timeout_ms: 5_000},
               providers: []
             })

    assert :ok = Lasso.Testing.ChainHelper.ensure_chain_exists(chain, profile: profile)

    roles = [live: "live", standby_a: "standby", standby_b: "standby", passive: "passive"]

    sockets =
      roles
      |> Enum.with_index(1)
      |> Map.new(fn {{name, heads}, priority} ->
        provider = "#{name}-#{chain}"
        {http_url, ws_url} = start_upstream(provider, chain, name == :standby_a)

        config = %{
          id: provider,
          url: http_url,
          ws_url: ws_url,
          priority: priority,
          heads: heads
        }

        assert :ok = ConfigStore.register_provider_runtime(profile, chain, config)
        assert :ok = Lasso.RPC.ChainSupervisor.ensure_provider(profile, chain, config)
        assert_receive {:upstream_socket, ^provider, socket}, 5_000
        {name, socket}
      end)

    live = "live-#{chain}"
    rejecting = "standby_a-#{chain}"
    standby = "standby_b-#{chain}"
    pump = start_head_pump(sockets.live)
    standby_pump = start_head_pump(sockets.standby_b)

    assert_receive {:upstream, "eth_subscribe", ^live}, 5_000
    assert subscribers_within(3 * @freshness_ms) -- [live] == []

    # standby_a has the better priority but rejects eth_subscribe, so the
    # election moves the feed to standby_b.
    send(pump, :pause)
    assert_receive {:upstream, "eth_subscribe", ^rejecting}, 4 * @freshness_ms
    assert_receive {:upstream, "eth_subscribe", ^standby}, 4 * @freshness_ms

    standby_id = Catalog.lookup_instance_id(profile, chain, standby)

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?(
        {:ok, %{head_at_ms: at}} when is_integer(at),
        {:ok, Registry.get_feed(chain, standby_id)}
      )
    end)

    assert subscribers_within(2 * @freshness_ms) -- [live, rejecting] == []
    assert InstanceSubscriptionRegistry.count_consumers(standby_id, {:newHeads}) == 1

    # The standby releases its feed once live heads are fresh again; the
    # upstream subscription itself closes after the subscription manager's
    # teardown grace period.
    send(pump, :resume)

    Lasso.Test.Eventually.assert_eventually(
      fn ->
        match?({:ok, %{ws_status: nil}}, Worker.get_status(chain, standby_id)) and
          InstanceSubscriptionRegistry.count_consumers(standby_id, {:newHeads}) == 0
      end,
      timeout: 6 * @freshness_ms
    )

    send(standby_pump, :pause)
    assert subscribers_within(2 * @freshness_ms) -- [live] == []
  end

  defp subscribers_within(window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    collect_subscribers(deadline, [])
  end

  defp collect_subscribers(deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:upstream, "eth_subscribe", provider} -> collect_subscribers(deadline, [provider | acc])
    after
      remaining -> Enum.uniq(acc)
    end
  end

  defp start_upstream(provider, chain, reject_subscribe?) do
    http_ref = {:heads_standby_http, provider}
    ws_ref = {:heads_standby_ws, provider}
    {:ok, _} = Plug.Cowboy.http(HTTPUpstream, [chain_id: chain], ref: http_ref, port: 0)

    state = %{
      test_pid: self(),
      provider: provider,
      chain_id: chain,
      reject_subscribe?: reject_subscribe?
    }

    dispatch = :cowboy_router.compile([{:_, [{"/", WSUpstream, state}]}])
    {:ok, _} = :cowboy.start_clear(ws_ref, [{:port, 0}], %{env: %{dispatch: dispatch}})

    on_exit(fn ->
      Plug.Cowboy.shutdown(http_ref)
      :cowboy.stop_listener(ws_ref)
    end)

    {"http://127.0.0.1:#{:ranch.get_port(http_ref)}",
     "ws://127.0.0.1:#{:ranch.get_port(ws_ref)}/"}
  end

  defp start_head_pump(socket) do
    pump = spawn_link(fn -> pump_heads(socket, 100, true) end)
    on_exit(fn -> Process.exit(pump, :kill) end)
    pump
  end

  defp pump_heads(socket, height, running?) do
    receive do
      :pause -> pump_heads(socket, height, false)
      :resume -> pump_heads(socket, height, true)
    after
      500 ->
        if running?, do: send(socket, {:head, height})
        pump_heads(socket, height + 1, running?)
    end
  end
end

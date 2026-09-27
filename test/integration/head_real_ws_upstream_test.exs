defmodule Lasso.RPC.HeadRealWsUpstreamTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.BlockSync.{Registry, Worker}
  alias Lasso.Config.ConfigStore
  alias Lasso.Events.HeadObserved
  alias Lasso.Providers.{Catalog, HeadEvidence}
  alias Lasso.RPC.Selection
  alias Lasso.RPC.Selection.CandidateCursor
  alias LassoWeb.Dashboard.StatusHelpers

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

      if request["method"] == "eth_subscribe",
        do: send(state.test_pid, {:upstream_subscribe, state.provider, self()})

      result =
        case request["method"] do
          "eth_subscribe" -> state.subscription_id
          "eth_unsubscribe" -> true
          "eth_chainId" -> "0x" <> Integer.to_string(state.chain_id, 16)
          "eth_blockNumber" -> "0x64"
          _ -> nil
        end

      response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      {:reply, {:text, response}, state}
    end

    def websocket_handle(_frame, state), do: {:ok, state}

    def websocket_info({:head, header}, state) do
      notification =
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "eth_subscription",
          "params" => %{"subscription" => state.subscription_id, "result" => header}
        })

      {:reply, {:text, notification}, state}
    end

    def websocket_info(_message, state), do: {:ok, state}
  end

  test "real local WebSocket upstream heads inform operator and request routing", %{chain: chain} do
    profile = "public"
    assert :ok = Phoenix.PubSub.subscribe(Lasso.PubSub, Lasso.Topics.block_sync(profile, chain))
    original_ws_client = Application.get_env(:lasso, :ws_client_module)

    Application.put_env(:lasso, :ws_client_module, Lasso.RPC.Transport.WebSocket.Client)
    on_exit(fn -> Application.put_env(:lasso, :ws_client_module, original_ws_client) end)

    assert :ok =
             ConfigStore.register_chain_runtime(profile, chain, %{
               block_time_ms: 1_000,
               selection: %{max_lag_blocks: 2},
               websocket: %{subscribe_new_heads: true, new_heads_timeout_ms: 5_000},
               providers: []
             })

    assert :ok = Lasso.Testing.ChainHelper.ensure_chain_exists(chain, profile: profile)

    suffix = Integer.to_string(chain)
    providers = ["minority-#{suffix}", "majority-a-#{suffix}", "majority-b-#{suffix}"]
    minority = hd(providers)

    Enum.each(Enum.with_index(providers, 1), fn {provider, priority} ->
      http_ref = {:head_http_upstream, provider, chain}
      ws_ref = {:head_ws_upstream, provider, chain}
      {:ok, _} = Plug.Cowboy.http(HTTPUpstream, [chain_id: chain], ref: http_ref, port: 0)

      dispatch =
        :cowboy_router.compile([
          {:_,
           [
             {"/", WSUpstream,
              %{
                test_pid: self(),
                provider: provider,
                chain_id: chain,
                subscription_id: "subscription-#{provider}"
              }}
           ]}
        ])

      {:ok, _} = :cowboy.start_clear(ws_ref, [{:port, 0}], %{env: %{dispatch: dispatch}})

      on_exit(fn ->
        Plug.Cowboy.shutdown(http_ref)
        :cowboy.stop_listener(ws_ref)
      end)

      config = %{
        id: provider,
        url: "http://127.0.0.1:#{:ranch.get_port(http_ref)}",
        ws_url: "ws://127.0.0.1:#{:ranch.get_port(ws_ref)}/",
        priority: priority
      }

      assert :ok = ConfigStore.register_provider_runtime(profile, chain, config)
      assert :ok = Lasso.RPC.ChainSupervisor.ensure_provider(profile, chain, config)
    end)

    connected =
      Map.new(providers, fn provider ->
        assert_receive {:upstream_socket, ^provider, socket}, 5_000
        {provider, socket}
      end)

    for provider <- providers do
      assert_receive {:upstream_subscribe, ^provider, _socket}, 5_000
    end

    ids = Map.new(providers, &{&1, Catalog.lookup_instance_id(profile, chain, &1)})

    Lasso.Test.Eventually.assert_eventually(fn ->
      Enum.all?(ids, fn {_provider, id} ->
        Lasso.Core.Streaming.InstanceSubscriptionRegistry.count_consumers(id, {:newHeads}) > 0
      end)
    end)

    handler_id = {:invalid_head, chain}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:lasso, :block_sync, :observation, :invalid],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:invalid_head, metadata.instance_id})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    minority_id = ids[minority]
    worker_before_invalid = GenServer.whereis(Worker.via(chain, minority_id))
    assert is_pid(worker_before_invalid)
    send(connected[minority], {:head, %{"number" => "0xzz", "hash" => "0xbad"}})
    assert_receive {:invalid_head, ^minority_id}, 5_000
    assert GenServer.whereis(Worker.via(chain, minority_id)) == worker_before_invalid
    assert Registry.get_observation(chain, minority_id, :ws) == {:error, :not_found}

    send_head(connected[hd(providers)], 100, "0xbbb")

    assert_receive %HeadObserved{
                     profile: ^profile,
                     provider_id: ^minority,
                     node_id: node_id,
                     observation: %{transport: :ws, height: 100, origin_member_id: node_id}
                   },
                   5_000

    assert node_id == Lasso.Cluster.Topology.self_node_id()
    send_head(connected[Enum.at(providers, 1)], 100, "0xaaa")

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?({:ok, %{qualification: :ambiguous}}, HeadEvidence.snapshot(profile, chain))
    end)

    send_head(connected[Enum.at(providers, 2)], 100, "0xaaa")

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?({:ok, %{qualification: :qualified}}, HeadEvidence.snapshot(profile, chain))
    end)

    assert {:ok, %{height: 100, block_hash: "0xbbb"}} =
             Registry.get_observation(chain, ids[hd(providers)], :ws)

    assert {:ok, %{provider_id: selected}, _} =
             profile
             |> Selection.select_channel_candidates(chain, "eth_blockNumber",
               strategy: :priority,
               transport: :ws
             )
             |> CandidateCursor.next()

    assert selected == Enum.at(providers, 1)

    send_head(connected[hd(providers)], 90, "0xbbb")

    Lasso.Test.Eventually.assert_eventually(fn ->
      StatusHelpers.check_block_lag(chain, ids[hd(providers)], profile) == :lagging
    end)

    Lasso.Test.Eventually.assert_eventually(
      fn ->
        match?(
          {:ok, %{mode: :http_only, ws_status: nil, http_reduced: false}},
          Worker.get_status(chain, ids[hd(providers)])
        )
      end,
      timeout: 9_000
    )

    assert StatusHelpers.check_block_lag(chain, ids[hd(providers)], profile) != :lagging

    assert_receive {:upstream_subscribe, ^minority, _socket}, 8_000

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?(
        {:ok, %{mode: :http_with_ws, ws_status: %{status: :connecting}}},
        Worker.get_status(chain, ids[minority])
      )
    end)

    send_head(connected[hd(providers)], 100, "0xaaa")

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?(
        {:ok, %{ws_status: %{status: :active}}},
        Worker.get_status(chain, ids[hd(providers)])
      ) and
        StatusHelpers.check_block_lag(chain, ids[hd(providers)], profile) == :synced
    end)

    assert {:ok, {_connection_pid, _generation}} =
             Lasso.RPC.Transport.WebSocket.Connection.transport_snapshot(ids[minority], 250)

    worker = GenServer.whereis(Worker.via(chain, ids[minority]))
    assert is_pid(worker)
    send(worker, {:ws_disconnected, ids[minority], :old_socket})

    assert {:ok, %{mode: :http_with_ws, ws_status: %{status: :active}}} =
             Worker.get_status(chain, ids[minority])
  end

  defp send_head(socket, height, hash) do
    send(socket, {
      :head,
      %{
        "number" => "0x" <> Integer.to_string(height, 16),
        "hash" => hash,
        "timestamp" => "0x" <> Integer.to_string(System.system_time(:second), 16)
      }
    })
  end
end

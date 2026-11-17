defmodule Lasso.URLCredentialsTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.Config.{ChainConfig, ConfigStore, ConfigValidator}
  alias Lasso.Test.Harness.Rpc
  import ExUnit.CaptureLog

  defmodule HTTP do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      send(
        opts[:owner],
        {:target, :http, conn.request_path, conn.query_string,
         get_req_header(conn, "authorization")}
      )

      if get_req_header(conn, "authorization") == [opts[:auth]] do
        {:ok, body, conn} = read_body(conn)
        request = Jason.decode!(body)
        result = if request["method"] == "eth_chainId", do: opts[:chain], else: "0x64"

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{jsonrpc: "2.0", id: request["id"], result: result}))
      else
        send_resp(conn, 401, "unauthorized")
      end
    end
  end

  defmodule WS do
    def init(req, state) do
      auth = :cowboy_req.header("authorization", req, nil)
      send(state.owner, {:target, :ws, :cowboy_req.path(req), :cowboy_req.qs(req), auth})

      if auth == state.auth do
        {:cowboy_websocket, req, state}
      else
        {:ok, :cowboy_req.reply(401, %{}, "unauthorized", req), state}
      end
    end

    def websocket_init(state), do: {:ok, state}

    def websocket_handle({:text, raw}, state) do
      request = Jason.decode!(raw)

      result =
        case request["method"] do
          "eth_subscribe" -> "credential-subscription"
          "eth_chainId" -> state.chain
          "eth_unsubscribe" -> true
          _ -> "0x64"
        end

      {:reply, {:text, Jason.encode!(%{jsonrpc: "2.0", id: request["id"], result: result})},
       state}
    end

    def websocket_handle(_, state), do: {:ok, state}
    def websocket_info(_, state), do: {:ok, state}
  end

  for {label, http_user, ws_user, http_plain, ws_plain} <- [
        {"percent-encoded distinct passwords", "al%69ce:h%40tp", "al%69ce:w%3Ass", "alice:h@tp",
         "alice:w:ss"},
        {"username only", "solo", "solo", "solo:", "solo:"},
        {"HTTP credential beside keyless WS", "alice:only-http", nil, "alice:only-http", nil}
      ] do
    @http_user http_user
    @ws_user ws_user
    @http_plain http_plain
    @ws_plain ws_plain
    test label, %{chain: chain} do
      original_http = Application.get_env(:lasso, :http_client)
      original_ws = Application.get_env(:lasso, :ws_client_module)
      Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)
      Application.put_env(:lasso, :ws_client_module, Lasso.RPC.Transport.WebSocket.Client)

      on_exit(fn ->
        Application.put_env(:lasso, :http_client, original_http)
        Application.put_env(:lasso, :ws_client_module, original_ws)
      end)

      http_auth = basic(@http_plain)
      ws_auth = basic(@ws_plain)
      http_ref = {:credentials_http, chain}
      ws_ref = {:credentials_ws, chain}
      chain_hex = "0x" <> String.downcase(Integer.to_string(chain, 16))

      {:ok, _} =
        Plug.Cowboy.http(HTTP, [owner: self(), auth: http_auth, chain: chain_hex],
          ref: http_ref,
          port: 0
        )

      dispatch =
        :cowboy_router.compile([
          {:_, [{"/rpc", WS, %{owner: self(), auth: ws_auth, chain: chain_hex}}]}
        ])

      {:ok, _} = :cowboy.start_clear(ws_ref, [{:port, 0}], %{env: %{dispatch: dispatch}})

      on_exit(fn ->
        Plug.Cowboy.shutdown(http_ref)
        :cowboy.stop_listener(ws_ref)
      end)

      url = endpoint("http", @http_user, :ranch.get_port(http_ref))
      ws_url = endpoint("ws", @ws_user, :ranch.get_port(ws_ref))

      logs =
        capture_log(fn ->
          :ok =
            ConfigStore.register_chain_runtime("public", chain, %{
              providers: [],
              websocket: %{subscribe_new_heads: true}
            })

          :ok = Lasso.Testing.ChainHelper.ensure_chain_exists(chain, profile: "public")

          config = %{
            id: "credentials-#{chain}",
            url: url,
            ws_url: ws_url,
            background_observations: false
          }

          :ok = ConfigStore.register_provider_runtime("public", chain, config)
          :ok = Lasso.RPC.ChainSupervisor.ensure_provider("public", chain, config)
          port = LassoWeb.Endpoint.config(:http)[:port]

          response =
            Rpc.call(
              %{rpc_url: "http://127.0.0.1:#{port}/rpc/profile/public/priority/#{chain}"},
              "eth_chainId"
            )

          assert response.body["result"] == chain_hex

          balance =
            Rpc.call(
              %{rpc_url: "http://127.0.0.1:#{port}/rpc/profile/public/priority/#{chain}"},
              "eth_getBalance",
              ["0x0000000000000000000000000000000000000001", "latest"]
            )

          assert balance.body["result"] == "0x64"
          wire = Rpc.wire!("ws://127.0.0.1:#{port}/ws/rpc/profile/public/priority/#{chain}")
          Rpc.send!(wire, "eth_subscribe", ["newHeads"])
          assert_receive {:rpc_frame, _, {:text, raw}}, 5_000
          assert Jason.decode!(raw)["result"]
          Rpc.close!(wire)
          assert_receive {:target, :http, "/rpc", "key=a%2Fb", [^http_auth]}, 5_000
          assert_receive {:target, :ws, "/rpc", "key=a%2Fb", ^ws_auth}, 5_000
          discovery_url = url <> "&discovery=1"

          results =
            Lasso.Discovery.probe(discovery_url, probes: [:methods], method_level: :critical)

          assert Enum.any?(
                   results.methods,
                   &(&1.method == "eth_chainId" and &1.status == :supported)
                 )

          assert_receive {:target, :http, "/rpc", "key=a%2Fb&discovery=1", [^http_auth]}, 5_000
          refute results.url =~ "@"
        end)

      diagnostic = inspect(%Lasso.RPC.Transport.WebSocket.Endpoint{ws_url: ws_url})

      for secret <-
            Enum.reject(
              [@http_user, @ws_user, @http_plain, @ws_plain, http_auth, ws_auth],
              &is_nil/1
            ) do
        refute logs =~ secret
        refute diagnostic =~ secret
      end
    end
  end

  test "malformed runtime URL fields return errors without crashing or logging credentials", %{
    chain: chain
  } do
    :ok = ConfigStore.register_chain_runtime("public", chain, %{providers: []})
    owner = Process.whereis(ConfigStore)

    logs =
      capture_log(fn ->
        for field <- [:url, :ws_url] do
          config =
            Map.put(
              %{
                id: "bad-url",
                name: "Bad URL",
                url: "http://127.0.0.1:1/rpc",
                auth_headers: %{"Authorization" => "Basic review-secret"}
              },
              field,
              123
            )

          assert {:error, :invalid_provider_headers} =
                   ConfigStore.register_provider_runtime("public", chain, config)

          assert Process.whereis(ConfigStore) == owner
          assert Process.alive?(owner)
        end
      end)

    refute logs =~ "Basic review-secret"
  end

  test "conflicting configured authorization fails validation before dialing" do
    for field <- [:url, :ws_url],
        headers <- [
          %{headers: %{"Authorization" => "Basic explicit"}},
          %{auth_headers: %{"authorization" => "Basic legacy"}}
        ] do
      provider =
        struct!(
          ChainConfig.Provider,
          Map.merge(
            Map.put(
              %{id: "conflict", name: "Conflict", url: "http://127.0.0.1:1/rpc"},
              field,
              "#{if field == :url, do: "http", else: "ws"}://user:secret@127.0.0.1:1/rpc"
            ),
            headers
          )
        )

      assert {:error, :invalid_provider_headers} =
               ConfigValidator.validate_providers([provider], false)

      assert ConfigValidator.format_error(:invalid_provider_headers) =~
               "authorization conflicts with URL userinfo"
    end
  end

  defp basic(nil), do: nil
  defp basic(value), do: "Basic " <> Base.encode64(value)
  defp endpoint(scheme, nil, port), do: "#{scheme}://127.0.0.1:#{port}/rpc?key=a%2Fb"

  defp endpoint(scheme, userinfo, port),
    do: "#{scheme}://#{userinfo}@127.0.0.1:#{port}/rpc?key=a%2Fb"
end

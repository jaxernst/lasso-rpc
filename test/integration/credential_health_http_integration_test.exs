defmodule Lasso.CredentialHealthHTTPIntegrationTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CredentialHealth
  alias Lasso.Providers
  alias Lasso.RPC.{RequestOptions, RequestPipeline}

  @moduletag :integration

  defmodule Upstream do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      case request["method"] do
        "eth_chainId" ->
          chain_hex = "0x" <> Integer.to_string(opts[:chain_id], 16)
          reply = %{"jsonrpc" => "2.0", "id" => request["id"], "result" => chain_hex}
          send_resp(conn, 200, Jason.encode!(reply))

        "eth_blockNumber" ->
          send_resp(conn, 401, "<html>key disabled</html>")

        _ ->
          send_resp(
            conn,
            200,
            Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => "0x1"})
          )
      end
    end
  end

  test "plain HTTP 401 on a dispatched request activates credential health" do
    chain_id = 700_000_000 + rem(System.unique_integer([:positive]), 100_000_000)
    provider_id = "plain-401-#{chain_id}"
    ref = {:credential_upstream, chain_id}
    prior_http_client = Application.get_env(:lasso, :http_client)

    {:ok, _pid} = Plug.Cowboy.http(Upstream, [chain_id: chain_id], ref: ref, port: 0)
    port = :ranch.get_port(ref)
    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, prior_http_client)
      Providers.remove_provider(chain_id, provider_id)
      Lasso.ProfileChainSupervisor.stop_profile_chain("public", chain_id)
      ConfigStore.unregister_chain_runtime("public", chain_id)
      Plug.Cowboy.shutdown(ref)
    end)

    :ok =
      ConfigStore.register_chain_runtime("public", chain_id, %{
        display_name: "Credential 401 integration",
        url_aliases: ["credential-401-#{chain_id}"],
        providers: []
      })

    assert {:ok, ^provider_id} =
             Providers.add_provider(
               chain_id,
               %{id: provider_id, name: "Credential 401", url: "http://127.0.0.1:#{port}"},
               validate: false
             )

    for _ <- 1..3 do
      assert {:error, %Lasso.JSONRPC.Error{http_status: 401}, _ctx} =
               RequestPipeline.execute_via_channels(
                 chain_id,
                 "eth_blockNumber",
                 [],
                 %RequestOptions{
                   profile: "public",
                   provider_override: provider_id,
                   failover_on_override: false,
                   timeout_ms: 5_000
                 }
               )
    end

    Lasso.Test.Eventually.assert_eventually(fn ->
      Enum.any?(CredentialHealth.active("public"), &(&1.provider_id == provider_id))
    end)
  end
end

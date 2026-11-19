defmodule Lasso.GatewayMethodRefusalTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Providers

  @moduletag :integration

  @refusal_body <<"<html><body>Not Acceptable ", 0xFF, 0xFE, "</body></html>">>

  defmodule Upstream do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      case {request["method"], opts[:name]} do
        {"eth_chainId", _name} ->
          reply(conn, request, "0x" <> Integer.to_string(opts[:chain], 16))

        {"eth_getBalance", "refusing"} ->
          send(opts[:observer], {:called, "refusing"})

          conn
          |> put_resp_content_type("text/html")
          |> send_resp(406, opts[:body])

        {"eth_getBalance", name} ->
          send(opts[:observer], {:called, name})
          reply(conn, request, "0x123")

        _other ->
          reply(conn, request, "0x100")
      end
    end

    defp reply(conn, request, result),
      do:
        send_resp(conn, 200, Jason.encode!(%{jsonrpc: "2.0", id: request["id"], result: result}))
  end

  setup do
    chain = 720_000_000 + rem(System.unique_integer([:positive]), 100_000_000)
    previous = Application.get_env(:lasso, :http_client)
    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, previous)
      Lasso.ProfileChainSupervisor.stop_profile_chain("public", chain)
      ConfigStore.unregister_chain_runtime("public", chain)
      Providers.Catalog.build_from_config()
    end)

    :ok =
      ConfigStore.register_chain_runtime("public", chain, %{
        display_name: "Gateway method refusal",
        providers: []
      })

    %{chain: chain}
  end

  test "an HTTP 406 refusal reaches the next provider and leaves the circuit closed", %{
    chain: chain
  } do
    add_upstreams(chain, [{"refusing", 1}, {"healthy", 2}])

    for _request <- 1..6 do
      assert %{"id" => 1, "result" => "0x123"} = rpc(chain)
      assert_receive {:called, "refusing"}
      assert_receive {:called, "healthy"}
    end

    instance_id = Providers.Catalog.lookup_instance_id("public", chain, "refusing")
    assert %{state: :closed, failure_count: 0} = CircuitBreaker.get_state({instance_id, :http})
  end

  test "the client error for a sole refusing provider carries no upstream body", %{
    chain: chain
  } do
    add_upstreams(chain, [{"refusing", 1}])

    assert %{"id" => 1, "error" => error} = rpc(chain)
    assert_received {:called, "refusing"}
    assert %{"code" => -32_006, "data" => %{"status" => 406}} = error
    refute Jason.encode!(error) =~ "Not Acceptable"
  end

  defp add_upstreams(chain, upstreams) do
    for {name, priority} <- upstreams do
      ref = {__MODULE__, chain, name}

      {:ok, _} =
        Plug.Cowboy.http(
          Upstream,
          [chain: chain, name: name, body: @refusal_body, observer: self()],
          ref: ref,
          port: 0
        )

      on_exit(fn -> Plug.Cowboy.shutdown(ref) end)

      assert {:ok, ^name} =
               Providers.add_provider(
                 chain,
                 %{
                   id: name,
                   name: name,
                   priority: priority,
                   url: "http://127.0.0.1:#{:ranch.get_port(ref)}"
                 },
                 validate: false
               )
    end
  end

  defp rpc(chain) do
    port = LassoWeb.Endpoint.config(:http)[:port]

    request = %{
      jsonrpc: "2.0",
      id: 1,
      method: "eth_getBalance",
      params: ["0x0000000000000000000000000000000000000001", "latest"]
    }

    {:ok, response} =
      Finch.build(
        :post,
        "http://127.0.0.1:#{port}/rpc/priority/#{chain}",
        [{"content-type", "application/json"}],
        Jason.encode!(request)
      )
      |> Finch.request(Lasso.Finch)

    assert response.status == 200
    Jason.decode!(response.body)
  end
end

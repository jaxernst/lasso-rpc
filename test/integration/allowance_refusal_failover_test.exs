defmodule Lasso.AllowanceRefusalFailoverTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Providers

  @moduletag :integration

  defmodule Upstream do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      case {request["method"], opts[:name]} do
        {"eth_chainId", _name} ->
          reply(conn, 200, request, %{result: "0x" <> Integer.to_string(opts[:chain], 16)})

        {"eth_getBalance", "spent"} ->
          send(opts[:observer], {:called, "spent"})

          conn
          |> put_resp_header("retry-after", "60")
          |> send_resp(402, opts[:body])

        {"eth_getBalance", name} ->
          send(opts[:observer], {:called, name})
          reply(conn, 200, request, %{result: "0x123"})

        _other ->
          reply(conn, 200, request, %{result: "0x100"})
      end
    end

    defp reply(conn, status, request, payload),
      do:
        send_resp(
          conn,
          status,
          Jason.encode!(Map.merge(payload, %{jsonrpc: "2.0", id: request["id"]}))
        )
  end

  for {label, body} <- [
        {"JSON error body",
         ~s({"code":402,"message":"Payment Required","details":"daily credit limit reached"})},
        {"plain text body", "Payment Required"}
      ] do
    test "HTTP 402 with a #{label} fails over without a breaker penalty" do
      chain = 710_000_000 + rem(System.unique_integer([:positive]), 100_000_000)
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
          display_name: "Allowance refusal",
          providers: []
        })

      for {name, priority} <- [{"spent", 1}, {"healthy", 2}] do
        ref = {__MODULE__, chain, name}

        {:ok, _} =
          Plug.Cowboy.http(
            Upstream,
            [chain: chain, name: name, body: unquote(body), observer: self()],
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

      assert %{"id" => 1, "result" => "0x123"} = rpc(chain)
      assert_receive {:called, "spent"}
      assert_receive {:called, "healthy"}

      instance_id = Providers.Catalog.lookup_instance_id("public", chain, "spent")
      assert %{state: :closed, failure_count: 0} = CircuitBreaker.get_state({instance_id, :http})

      cooldown = Providers.InstanceState.read_rate_limit(instance_id, :http)
      assert cooldown.remaining_ms > 55_000
      assert cooldown.remaining_ms <= 60_000

      assert %{"id" => 1, "result" => "0x123"} = rpc(chain)
      assert_receive {:called, "healthy"}
      refute_received {:called, "spent"}
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

defmodule Lasso.HTTPStatusPrecedenceTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers

  @moduletag :integration

  defmodule Upstream do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      method = request["method"]

      {status, payload} =
        case method do
          "eth_chainId" ->
            {200, %{result: "0x" <> Integer.to_string(opts[:chain], 16)}}

          method when method in ["eth_getBalance", "eth_sendRawTransaction"] ->
            send(opts[:observer], {:called, opts[:name]})

            if opts[:name] == "healthy",
              do: {200, %{result: "0x123"}},
              else:
                {opts[:status],
                 %{
                   error: %{
                     code: opts[:code],
                     message:
                       if(opts[:code] == -32_005,
                         do: "monthly quota exceeded",
                         else: "Invalid request"
                       ),
                     data: if(opts[:code] == -32_005, do: %{retry_after_ms: 3_600_000}, else: nil)
                   }
                 }}

          _ ->
            {200, %{result: "0x100"}}
        end

      reply = Map.merge(payload, %{jsonrpc: "2.0", id: request["id"]})
      send_resp(conn, status, Jason.encode!(reply))
    end
  end

  @read_params ["0x0000000000000000000000000000000000000001", "latest"]
  @cases for(
           status <- [429, 401, 403],
           code <- [-32_600, -32_700],
           do: {"eth_getBalance", @read_params, status, code, true}
         ) ++
           for(
             status <- [429, 401, 403],
             do: {"eth_sendRawTransaction", ["0x02"], status, -32_600, false}
           ) ++
           for(
             status <- [200, 400],
             do: {"eth_getBalance", @read_params, status, -32_600, false}
           )

  for {method, params, status, code, failover?} <-
        @cases ++ [{"eth_getBalance", @read_params, 429, -32_005, true}] do
    test "#{method} HTTP #{status} code #{code} failover=#{failover?}" do
      chain = 700_000_000 + System.unique_integer([:positive, :monotonic])
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
          display_name: "HTTP status precedence",
          providers: []
        })

      for {name, status, priority} <- [{"refused", unquote(status), 1}, {"healthy", 200, 2}] do
        ref = {__MODULE__, chain, name}

        {:ok, _} =
          Plug.Cowboy.http(
            Upstream,
            [chain: chain, name: name, status: status, code: unquote(code), observer: self()],
            ref: ref,
            port: 0
          )

        on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
        port = :ranch.get_port(ref)

        assert {:ok, ^name} =
                 Providers.add_provider(
                   chain,
                   %{id: name, name: name, priority: priority, url: "http://127.0.0.1:#{port}"},
                   validate: false
                 )
      end

      port = LassoWeb.Endpoint.config(:http)[:port]

      request = %{
        jsonrpc: "2.0",
        id: 1,
        method: unquote(method),
        params: unquote(params)
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
      body = Jason.decode!(response.body)
      assert_receive {:called, "refused"}

      if unquote(failover?) do
        assert %{"id" => 1, "result" => "0x123"} = body
        assert_receive {:called, "healthy"}
      else
        assert %{"id" => 1, "error" => error} = body
        if unquote(status) in [200, 400], do: assert(error["code"] == -32_600)
        refute_receive {:called, "healthy"}
      end

      if unquote(code) == -32_005 do
        instance_id = Providers.Catalog.lookup_instance_id("public", chain, "refused")
        evidence = Providers.InstanceState.read_rate_limit(instance_id, :http)
        assert evidence.remaining_ms > 3_500_000
      end

      refute_receive {:called, _provider}
    end
  end
end

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
                       opts[:message] ||
                         cond do
                           opts[:code] == -32_099 -> String.duplicate("é", 1000)
                           opts[:code] == -32_005 -> "monthly quota exceeded"
                           true -> "Invalid request"
                         end,
                     data:
                       opts[:data] ||
                         %{
                           retry_after_ms: 3_600_000,
                           discarded: String.duplicate("secret", 1000)
                         }
                   }
                 }}

          _ ->
            {200, %{result: "0x100"}}
        end

      reply = Map.merge(payload, %{jsonrpc: "2.0", id: request["id"]})
      conn = if opts[:code] == -32_098, do: put_resp_header(conn, "retry-after", "60"), else: conn

      conn =
        Enum.reduce(opts[:headers] || [], conn, fn {name, value}, conn ->
          put_resp_header(conn, name, value)
        end)

      body = Jason.encode!(reply)
      body = if opts[:escape], do: String.replace(body, "Try", "\\u0054ry"), else: body
      send_resp(conn, status, body)
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
             do: {"eth_sendRawTransaction", ["0x02"], status, -32_600, true}
           ) ++
           for(
             status <- [200, 400],
             do: {"eth_getBalance", @read_params, status, -32_600, false}
           )

  for {method, params, status, code, failover?} <-
        @cases ++
          [
            {"eth_getBalance", @read_params, 429, -32_005, true},
            {"eth_getBalance", @read_params, 429, -32_099, false},
            {"eth_getBalance", @read_params, 429, -32_098, true}
          ] do
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

      providers =
        if unquote(code) == -32_099,
          do: [{"refused", 429, 1}],
          else: [{"refused", unquote(status), 1}, {"healthy", 200, 2}]

      for {name, status, priority} <- providers do
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

        if unquote(code) == -32_099 do
          assert byte_size(error["message"]) <= 1000
          assert String.valid?(error["message"])
          refute Map.has_key?(error["data"] || %{}, "discarded")
        end

        refute_receive {:called, "healthy"}
      end

      if unquote(code) == -32_005 do
        instance_id = Providers.Catalog.lookup_instance_id("public", chain, "refused")
        evidence = Providers.InstanceState.read_rate_limit(instance_id, :http)
        assert evidence.remaining_ms > 590_000
        assert evidence.remaining_ms <= 600_000
      end

      if unquote(code) == -32_098 do
        instance_id = Providers.Catalog.lookup_instance_id("public", chain, "refused")
        evidence = Providers.InstanceState.read_rate_limit(instance_id, :http)
        assert evidence.remaining_ms > 55_000
        assert evidence.remaining_ms <= 60_000
      end

      refute_receive {:called, _provider}
    end
  end

  defp route(url, anvil) do
    chain = 31337

    :ok =
      ConfigStore.register_chain_runtime("public", chain, %{
        display_name: "review384",
        providers: []
      })

    on_exit(fn ->
      Lasso.ProfileChainSupervisor.stop_profile_chain("public", chain)
      ConfigStore.unregister_chain_runtime("public", chain)
      Providers.Catalog.build_from_config()
    end)

    for {name, priority, provider_url} <- [
          {"refused", 1, url},
          {"healthy", 2, "http://127.0.0.1:#{anvil.port_number}"}
        ] do
      assert {:ok, ^name} =
               Providers.add_provider(
                 chain,
                 %{id: name, name: name, priority: priority, url: provider_url},
                 validate: false
               )
    end

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

    assert %{"result" => _} = Jason.decode!(response.body)
    instance = Providers.Catalog.lookup_instance_id("public", chain, "refused")
    Providers.InstanceState.read_rate_limit(instance, :http)
  end

  for {label, message, data, header, lower, upper} <- [
        {"long body seconds", "Rate limited", %{retry_after: String.duplicate("9", 4_000_000)},
         nil, 595_000, 600_000},
        {"long message delay", "Try again in " <> String.duplicate("9", 4_000_000) <> " seconds",
         %{}, nil, 595_000, 600_000},
        {"past HTTP date", "Rate limited", %{retry_after_ms: 1_000},
         "Wed, 21 Oct 2015 07:28:00 GMT", 0, 1_000},
        {"zero header", "Rate limited", %{retry_after_ms: 1_000}, "0", 0, 1_000},
        {"huge message with header", "Try again in " <> String.duplicate("9", 307) <> " seconds",
         %{}, "60", 55_000, 60_000},
        {"huge message without header",
         "Try again in " <> String.duplicate("9", 307) <> " seconds", %{}, nil, 595_000, 600_000},
        {"malformed seconds suffix", "Rate limited", %{retry_after: "120ms"}, nil, 25_000,
         30_000},
        {"message seconds", "Rate limit. Try again in 120 seconds", %{}, nil, 115_000, 120_000},
        {"data seconds", "Rate limited", %{retry_after: 120}, nil, 115_000, 120_000},
        {"HTTP date", "Rate limited", %{retry_after_ms: 600_000}, :future, 115_000, 120_000}
      ] do
    test "retains #{label} cooldown through public route failover" do
      anvil = Lasso.Test.AnvilCase.start_anvil_node!()
      previous = Application.get_env(:lasso, :http_client)
      Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)
      on_exit(fn -> Application.put_env(:lasso, :http_client, previous) end)

      headers =
        if unquote(header) == :future do
          date =
            DateTime.utc_now()
            |> DateTime.add(120, :second)
            |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

          [{"retry-after", date}]
        else
          if is_binary(unquote(header)), do: [{"retry-after", unquote(header)}], else: []
        end

      ref = {__MODULE__, make_ref()}

      {:ok, _} =
        Plug.Cowboy.http(
          Upstream,
          [
            chain: 31337,
            name: "refused",
            status: 429,
            code: -32_005,
            escape: String.starts_with?(unquote(label), "huge message"),
            message: unquote(message),
            data: unquote(Macro.escape(data)),
            headers: headers,
            observer: self()
          ],
          ref: ref,
          port: 0
        )

      on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
      evidence = route("http://127.0.0.1:#{:ranch.get_port(ref)}", anvil)
      assert evidence.remaining_ms > unquote(lower)
      assert evidence.remaining_ms <= unquote(upper)
    end
  end
end

defmodule Lasso.RefusalVendorDiversityTest do
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
        if method == "eth_getBalance" do
          send(opts[:observer], {:called, opts[:name]})

          if opts[:name] == "first" or
               (opts[:name] == "sibling" and opts[:sibling_refuses]) do
            {opts[:status], %{error: %{code: opts[:code], message: opts[:message]}}}
          else
            {200, %{result: if(opts[:name] == "sibling", do: "0x22", else: "0x33")}}
          end
        else
          {200, %{result: "0x" <> Integer.to_string(opts[:chain], 16)}}
        end

      reply = Map.merge(payload, %{jsonrpc: "2.0", id: request["id"]})
      send_resp(conn, status, Jason.encode!(reply))
    end
  end

  @params ["0x0000000000000000000000000000000000000001", "0x1"]

  for {label, status, code, message, unknown?, independent?, expected} <- [
        {"missing method", 200, -32601, "Method not found", false, true, "other"},
        {"plan refusal", 200, -32000, "method not supported on free tier", false, true, "other"},
        {"only siblings eligible", 200, -32000, "missing trie node", false, false, "sibling"},
        {"unknown hosts", 200, -32000, "missing trie node", true, true, "sibling"},
        {"service failure", 503, -32000, "upstream temporarily unavailable", false, true,
         "sibling"},
        {"rate limit", 429, -32005, "rate limit exceeded", false, true, "sibling"}
      ] do
    test label do
      run_case(
        unquote(label),
        unquote(status),
        unquote(code),
        unquote(message),
        unquote(unknown?),
        unquote(independent?),
        unquote(expected)
      )
    end
  end

  @tag feature: ["core-routing-6"]
  test "archival refusal uses only two dispatches" do
    run_case("archive refusal", 200, -32000, "missing trie node", false, true, "other")
  end

  defp run_case(label, status, code, message, unknown?, independent?, expected) do
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
        display_name: "Refusal retry fixtures",
        providers: []
      })

    # Recognised domains are fixture identities, resolved only to owned listeners.
    hosts =
      if unknown?,
        do: ["first.fixture.invalid", "second.fixture.invalid", "other.fixture.invalid"],
        else: ["first.alchemy.com", "second.alchemy.com", "other.drpc.org"]

    :ok = :inet_db.add_host({127, 0, 0, 1}, Enum.map(hosts, &String.to_charlist/1))
    prior_lookup = :inet_db.res_option(:lookup)
    :ok = :inet_db.set_lookup([:file])

    for host <- hosts do
      assert {:ok, {127, 0, 0, 1}} == :inet.getaddr(String.to_charlist(host), :inet)
    end

    on_exit(fn -> :inet_db.set_lookup(prior_lookup) end)

    routes = Enum.zip(["first", "sibling", "other"], hosts)
    routes = if independent?, do: routes, else: Enum.take(routes, 2)

    for {{name, host}, priority} <- Enum.with_index(routes, 1) do
      ref = {__MODULE__, chain, name}

      {:ok, _} =
        Plug.Cowboy.http(
          Upstream,
          [
            chain: chain,
            name: name,
            status: status,
            code: code,
            message: message,
            sibling_refuses: label == "archive refusal",
            observer: self()
          ],
          ref: ref,
          port: 0
        )

      on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
      port = :ranch.get_port(ref)

      assert {:ok, ^name} =
               Providers.add_provider(
                 chain,
                 %{
                   id: name,
                   name: name,
                   priority: priority,
                   archival: true,
                   url: "http://#{host}:#{port}"
                 },
                 validate: false
               )
    end

    if label == "archive refusal" do
      alias Lasso.RPC.{RequestContext, RequestOptions, RequestPipeline}

      opts = %RequestOptions{
        profile: "public",
        strategy: :priority,
        transport: :http,
        timeout_ms: 2_000
      }

      ctx = RequestContext.new(chain, "eth_getBalance", @params, opts)
      envelope = Lasso.RPC.ExecutionEnvelope.new(ctx.request_id, "eth_getBalance", 2_000)
      ctx = %{ctx | execution_envelope: %{envelope | dispatch_limit: 2}}

      assert {:ok, _, completed} =
               RequestPipeline.execute_via_channels(
                 chain,
                 "eth_getBalance",
                 @params,
                 %{opts | request_context: ctx}
               )

      assert completed.execution_envelope.dispatch_count == 2
      assert completed.execution_envelope.dispatch_limit == 2
      assert_receive {:called, "first"}
      assert_receive {:called, "other"}
      refute_receive {:called, _}
    end

    port = LassoWeb.Endpoint.config(:http)[:port]
    request = %{jsonrpc: "2.0", id: 1, method: "eth_getBalance", params: @params}

    {:ok, response} =
      Finch.build(
        :post,
        "http://127.0.0.1:#{port}/rpc/priority/#{chain}",
        [{"content-type", "application/json"}],
        Jason.encode!(request)
      )
      |> Finch.request(Lasso.Finch)

    result = if expected == "other", do: "0x33", else: "0x22"
    assert %{"result" => ^result} = Jason.decode!(response.body)
    assert_receive {:called, "first"}
    assert_receive {:called, ^expected}
    refute_receive {:called, _}
  end
end

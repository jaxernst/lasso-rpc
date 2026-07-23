defmodule Lasso.Providers.AuthenticatedProbeTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers

  @moduletag :integration

  defmodule ProbeEndpoint do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      headers = Map.new(conn.req_headers)
      send(opts[:test_pid], {:probe_request, request["method"], headers})

      chain_hex = "0x" <> Integer.to_string(opts[:chain_id], 16)

      response =
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => chain_hex})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, response)
    end
  end

  test "health probes send the same provider authentication headers as routed requests" do
    chain_id = 700_000_000 + rem(System.unique_integer([:positive]), 100_000_000)
    provider_id = "authenticated-probe-#{chain_id}"
    ref = {:probe_endpoint, chain_id}

    {:ok, _pid} =
      Plug.Cowboy.http(ProbeEndpoint, [test_pid: self(), chain_id: chain_id],
        ref: ref,
        port: 0
      )

    port = :ranch.get_port(ref)

    on_exit(fn ->
      Providers.remove_provider(chain_id, provider_id)
      Lasso.ProfileChainSupervisor.stop_profile_chain("public", chain_id)
      ConfigStore.unregister_chain_runtime("public", chain_id)
      Plug.Cowboy.shutdown(ref)
    end)

    :ok =
      ConfigStore.register_chain_runtime("public", chain_id, %{
        display_name: "Authenticated Probe",
        url_aliases: ["authenticated-probe-#{chain_id}"],
        providers: []
      })

    assert {:ok, ^provider_id} =
             Providers.add_provider(
               chain_id,
               %{
                 id: provider_id,
                 name: "Authenticated Probe Provider",
                 url: "http://127.0.0.1:#{port}",
                 api_key: "probe-secret",
                 headers: %{"x-provider-network" => "local"}
               },
               validate: false
             )

    assert_receive {:probe_request, "eth_chainId", headers}, 3_000
    assert headers["authorization"] == "Bearer probe-secret"
    assert headers["x-provider-network"] == "local"
  end
end

defmodule Lasso.Providers.AuthenticatedProbeTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers
  alias Lasso.Providers.{Catalog, InstanceState}
  require Lasso.Test.Eventually

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

  defmodule RateLimitProbeEndpoint do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      send(opts[:test_pid], {:rate_limit_probe_started, self()})

      receive do
        :finish_rate_limit_probe -> :ok
      after
        3_000 -> :ok
      end

      conn
      |> put_resp_header("retry-after", "120")
      |> put_resp_content_type("application/json")
      |> send_resp(429, ~s({"error":"rate limited"}))
    end
  end

  test "a real rate-limited identity probe extends the routed provider cooldown" do
    chain_id = 700_000_000 + rem(System.unique_integer([:positive]), 100_000_000)
    provider_id = "rate-limited-probe-#{chain_id}"
    ref = {:rate_limited_probe_endpoint, chain_id}

    {:ok, _pid} = Plug.Cowboy.http(RateLimitProbeEndpoint, [test_pid: self()], ref: ref, port: 0)
    port = :ranch.get_port(ref)

    on_exit(fn ->
      Providers.remove_provider(chain_id, provider_id)
      Lasso.ProfileChainSupervisor.stop_profile_chain("public", chain_id)
      ConfigStore.unregister_chain_runtime("public", chain_id)
      Plug.Cowboy.shutdown(ref)
    end)

    :ok = ConfigStore.register_chain_runtime("public", chain_id, %{providers: []})

    assert {:ok, ^provider_id} =
             Providers.add_provider(
               chain_id,
               %{id: provider_id, name: "Rate-limited Probe", url: "http://127.0.0.1:#{port}"},
               validate: false
             )

    assert_receive {:rate_limit_probe_started, server}, 3_000
    instance_id = Catalog.lookup_instance_id("public", chain_id, provider_id)
    assert is_binary(instance_id)

    short_expiry = System.monotonic_time(:millisecond) + 10_000

    :ets.insert(
      :lasso_instance_state,
      {{:rate_limit, instance_id, :http}, %{expiry_ms: short_expiry, retry_after_ms: 10_000}}
    )

    send(server, :finish_rate_limit_probe)

    Lasso.Test.Eventually.assert_eventually(fn ->
      InstanceState.read_rate_limit(instance_id, :http).remaining_ms > 110_000
    end)
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

defmodule Lasso.BlockPublication.ProbeCapacityTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Lasso.BlockPublication.Probe
  alias Lasso.Config.ConfigStore
  alias Lasso.JSONRPC.Quantity
  alias Lasso.Providers

  defmodule Upstream do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "eth_chainId" -> Quantity.encode(opts[:chain_id])
          "eth_blockNumber" -> Quantity.encode(100)
          "eth_getBlockByNumber" -> opts[:header]
          _ -> "0x1"
        end

      send_resp(
        conn,
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})
      )
    end
  end

  test "a successful block probe releases its retained upstream response" do
    chain = 700_000_000 + rem(System.unique_integer([:positive]), 100_000_000)
    provider_id = "publication-probe-#{chain}"
    ref = {:publication_probe, chain}
    prior_http_client = Application.get_env(:lasso, :http_client)

    {:ok, _pid} =
      Plug.Cowboy.http(Upstream, [chain_id: chain, header: header(100)], ref: ref, port: 0)

    port = :ranch.get_port(ref)
    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, prior_http_client)
      Providers.remove_provider(chain, provider_id)
      Lasso.ProfileChainSupervisor.stop_profile_chain("public", chain)
      ConfigStore.unregister_chain_runtime("public", chain)
      Plug.Cowboy.shutdown(ref)
    end)

    :ok =
      ConfigStore.register_chain_runtime("public", chain, %{
        display_name: "Publication probe integration",
        providers: []
      })

    assert {:ok, ^provider_id} =
             Providers.add_provider(
               chain,
               %{id: provider_id, name: "Publication probe", url: "http://127.0.0.1:#{port}"},
               validate: false
             )

    observer = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:lasso, :upstream_admission, :released],
        fn _, _, metadata, test_pid -> send(test_pid, {:capacity_released, metadata}) end,
        observer
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{"height" => 100}, _route} = Probe.latest({"public", chain}, 60_000)
    assert_receive {:capacity_released, %{reason: :block_publication_consumed}}, 1_000
  end

  defp header(height) do
    hash = fn n -> "0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0") end

    %{
      "number" => Quantity.encode(height),
      "hash" => hash.(height),
      "parentHash" => hash.(height - 1),
      "timestamp" => Quantity.encode(System.system_time(:second)),
      "transactions" => []
    }
  end
end

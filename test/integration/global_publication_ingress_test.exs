defmodule Lasso.Integration.GlobalPublicationIngressTest do
  use ExUnit.Case, async: false
  use Lasso.Test.PublicationDBCase
  use Lasso.Test.AnvilCase, prune_history: false
  import Phoenix.ConnTest
  import Plug.Conn
  alias Lasso.BlockPublication.{Gate, Probe}
  alias Lasso.BlockPublication.Postgres, as: Journal
  alias Lasso.Config.ConfigStore

  @endpoint LassoWeb.Endpoint
  @address "0x000000000000000000000000000000000000dead"
  @sender "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"

  test "file-profile published block choices and query-wide hash reads through an actual reorg",
       %{anvil_port: port} do
    prior = Application.get_env(:lasso, :block_publication)
    Application.put_env(:lasso, :block_publication, members: [node_id()], journal: Journal)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:lasso, :block_publication, prior),
        else: Application.delete_env(:lasso, :block_publication)
    end)

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    slug = "public"
    provider_id = String.duplicate("節", 64)
    key = {slug, @anvil_chain_id}

    on_exit(fn ->
      Lasso.Providers.remove_provider(slug, @anvil_chain_id, provider_id)
      Lasso.ProfileChainSupervisor.stop_profile_chain(slug, @anvil_chain_id)
      ConfigStore.unregister_chain_runtime(slug, @anvil_chain_id)
      :ets.delete(:lasso_block_publications, key)
      :ets.delete(:lasso_accepted_heads, key)
    end)

    :ok =
      ConfigStore.register_chain_runtime(slug, @anvil_chain_id, %{
        display_name: "Anvil",
        head_policy: "global",
        block_time_ms: 1_000,
        providers: []
      })

    assert {:ok, ^provider_id} =
             Lasso.Providers.add_provider(
               @anvil_chain_id,
               %{
                 id: provider_id,
                 name: "Anvil",
                 url: "http://127.0.0.1:#{port}",
                 priority: 1,
                 archival: true
               },
               profile: slug,
               validate: false
             )

    fixture = run_client_fixture!("deploy", port)

    assert {:ok, _} = Journal.configure(key, "global", 1_000)

    assert %{"error" => %{"data" => %{"reason" => "publication_pending"}}} =
             rpc(slug, "eth_blockNumber", []) |> body()

    %{"result" => snapshot} = rpc_call!(port, "evm_snapshot")
    rpc_call!(port, "anvil_setBalance", [@address, "0x64"])
    rpc_call!(port, "evm_mine")
    first = publish!(key)
    conn = rpc(slug, "eth_getBlockByNumber", ["latest", false])
    assert %{"result" => %{"number" => n, "hash" => hash}} = body(conn)
    assert metadata(conn)["head_policy"]["source"] == "published_block"
    assert metadata(conn)["head_policy"]["scope"] == "profile_chain_fleet"
    selector = %{"blockHash" => hash, "requireCanonical" => true}

    report =
      run_client_fixture!("verify", port, [
        {"RPC_URL", "#{LassoWeb.Endpoint.url()}/rpc/profile/#{slug}/#{@anvil_chain_id}"},
        {"LASSO_PROFILE", slug},
        {"QUERY_FIXTURE", Jason.encode!(fixture)}
      ])

    assert report["context"]["hash"] == hash
    assert report["evidence"]["parent"]["complete"]
    assert report["evidence"]["worker"]["complete"]
    assert report["result"]["dependentRounds"] == 2

    assert %{"result" => _tx} =
             rpc_call!(port, "eth_sendTransaction", [
               %{"from" => @sender, "to" => @address, "value" => "0x64", "gas" => "0x5208"}
             ])

    for {method, params} <- [
          {"eth_getCode", [@address, selector]},
          {"eth_getStorageAt", [@address, "0x0", selector]},
          {"eth_call", [%{"to" => @address, "data" => "0x"}, selector]},
          {"eth_getBalance", [@address, selector]}
        ] do
      assert %{"result" => value} = rpc(slug, method, params) |> body()
      if method == "eth_getBalance", do: assert(value == "0x64")
    end

    assert %{"result" => ^n} = rpc(slug, "eth_blockNumber", []) |> body()

    assert %{"result" => %{"hash" => ^hash, "transactions" => []}} =
             rpc(slug, "eth_getBlockByNumber", ["latest", true]) |> body()

    assert %{"result" => true} = rpc_call!(port, "evm_revert", [snapshot])
    rpc_call!(port, "anvil_setBalance", [@address, "0x12c"])
    rpc_call!(port, "evm_mine")
    rpc_call!(port, "evm_mine")

    assert %{"error" => %{"code" => reorg_error_code}} =
             rpc(slug, "eth_getBalance", [@address, selector]) |> body()

    second = publish!(key)

    assert second["evidence"][node_id()]["provider_id"] ==
             Lasso.RPC.BoundedIdentifier.encode(provider_id)

    assert second["published"]["height"] > first["published"]["height"]
    next = rpc(slug, "eth_blockNumber", [])
    assert metadata(next)["head_policy"]["chain_change"]["kind"] == "anchor_hash_changed"
    assert metadata(next)["head_policy"]["chain_change"]["previous_hash"] == String.downcase(hash)

    assert {:ok, _} = Journal.configure(key, "off", 1_000)

    disabling = Journal.get(key)
    Gate.install(key, disabling, node_id())
    assert %{"error" => _} = rpc(slug, "eth_blockNumber", []) |> body()

    assert {:ok, disabled} =
             Journal.command(key, {:closed, disabling["epoch"], node_id(), Gate.boot()})

    Gate.install(key, disabled, node_id())
    assert :unmanaged = Gate.read(key)
    assert %{"error" => _} = rpc(slug, "eth_blockNumber", []) |> body()

    {:ok, profile} = ConfigStore.get_profile(slug)
    {:ok, config} = ConfigStore.get_chain(slug, @anvil_chain_id)

    assert :ok =
             ConfigStore.update_profile(
               Map.put(profile, :chains, %{
                 @anvil_chain_id => %{config | head_policy: "off"}
               })
             )

    assert %{"result" => _} = rpc(slug, "eth_blockNumber", []) |> body()

    if path = System.get_env("LASSO_QUERY_EVIDENCE_PATH") do
      report =
        Map.put(report, "reorg", %{
          previous_hash: hash,
          next_hash: second["published"]["hash"],
          next_number: body(next)["result"],
          old_selector_error_code: reorg_error_code,
          reported_change: metadata(next)["head_policy"]["chain_change"],
          cleanup: "publication_disabled_and_gate_unmanaged"
        })

      File.write!(path, Jason.encode!(report, pretty: true))
    end
  end

  defp publish!(key) do
    assert {:ok, _} = Journal.command(key, {:join, node_id(), Gate.boot(), nil})
    before = Journal.get(key)
    assert {:ok, block, _} = Probe.latest(key, before["max_age_ms"])
    assert {:ok, proposal} = Journal.command(key, {:propose, node_id(), Gate.boot(), block})
    assert {:ok, evidence} = Probe.prepare(key, block, before["published"], before["max_age_ms"])

    assert {:ok, closing} =
             Journal.command(key, {:ready, proposal["epoch"], node_id(), Gate.boot(), evidence})

    Gate.install(key, closing, node_id())

    assert {:ok, committed} =
             Journal.command(key, {:closed, closing["epoch"], node_id(), Gate.boot()})

    Gate.install(key, committed, node_id())
    committed
  end

  defp run_client_fixture!(mode, port, env \\ []) do
    script = Path.expand("../../examples/logical-read/fixture.mjs", __DIR__)

    {output, status} =
      System.cmd("node", [script, mode],
        env: [{"ANVIL_URL", "http://127.0.0.1:#{port}"} | env],
        stderr_to_stdout: true
      )

    assert status == 0,
           "Logical-read client fixture failed (run npm ci in examples/logical-read):\n#{output}"

    Jason.decode!(output)
  end

  defp node_id, do: Lasso.Cluster.Topology.self_node_id()
  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp metadata(conn) do
    [encoded] = get_resp_header(conn, "x-lasso-meta")
    encoded |> Base.url_decode64!(padding: false) |> Jason.decode!()
  end

  defp rpc(slug, method, params) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> dispatch(
      @endpoint,
      :post,
      "/rpc/profile/#{slug}/#{@anvil_chain_id}?include_meta=headers",
      %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
    )
  end
end

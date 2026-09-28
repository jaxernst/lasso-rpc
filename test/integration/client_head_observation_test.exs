defmodule Lasso.RPC.ClientHeadObservationTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.Response.Success

  test "a real client head response publishes attributed evidence without changing the response",
       %{
         chain: chain
       } do
    setup_providers([
      %{id: "client-head", priority: 1, behavior: :healthy, background_observations: false}
    ])

    [{mock_pid, _}] = Registry.lookup(Lasso.Registry, {:http_provider, "client-head"})

    :sys.replace_state(
      mock_pid,
      &%{&1 | behavior: {:conditional, fn _, _, _ -> {:ok, "0x64"} end}}
    )

    instance_id = Catalog.lookup_instance_id("public", chain, "client-head")
    started_at = System.system_time(:millisecond)

    assert {:ok, %Success{} = response, _ctx} =
             RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], %RequestOptions{
               timeout_ms: 5_000,
               profile: "public",
               strategy: :priority,
               transport: :http,
               provider_override: "client-head",
               request_origin: :client
             })

    assert {:ok, "0x64"} = Success.decode_result(response)

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?(
        {:ok, %{height: 100, transport: :http}},
        BlockSyncRegistry.get_observation(chain, instance_id, :http)
      )
    end)

    assert {:ok, observation} = BlockSyncRegistry.get_observation(chain, instance_id, :http)
    assert observation.observed_at_ms >= started_at
    assert observation.attributes.collection == :client
    assert observation.origin_member_id == Lasso.Cluster.Topology.self_node_id()
  end

  test "malformed and oversized client head responses do not publish evidence", %{chain: chain} do
    setup_providers([
      %{id: "client-head-bounds", priority: 1, behavior: :healthy, background_observations: false}
    ])

    [{mock_pid, _}] = Registry.lookup(Lasso.Registry, {:http_provider, "client-head-bounds"})
    instance_id = Catalog.lookup_instance_id("public", chain, "client-head-bounds")

    for result <- ["invalid", "0x" <> String.duplicate("f", 70_000)] do
      :sys.replace_state(
        mock_pid,
        &%{&1 | behavior: {:conditional, fn _, _, _ -> {:ok, result} end}}
      )

      assert {:ok, %Success{} = response, _ctx} =
               RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], %RequestOptions{
                 timeout_ms: 5_000,
                 profile: "public",
                 strategy: :priority,
                 transport: :http,
                 provider_override: "client-head-bounds",
                 request_origin: :client
               })

      assert {:ok, ^result} = Success.decode_result(response)
    end

    Process.sleep(300)
    assert {:error, :not_found} = BlockSyncRegistry.get_observation(chain, instance_id, :http)
  end

  test "latest block header preserves the client result and records hash and timestamp", %{
    chain: chain
  } do
    setup_providers([
      %{id: "client-header", priority: 1, behavior: :healthy, background_observations: false}
    ])

    header = %{
      "number" => "0x65",
      "hash" => "0x" <> String.duplicate("a", 64),
      "timestamp" => "0x66"
    }

    [{mock_pid, _}] = Registry.lookup(Lasso.Registry, {:http_provider, "client-header"})

    :sys.replace_state(
      mock_pid,
      &%{&1 | behavior: {:conditional, fn _, _, _ -> {:ok, header} end}}
    )

    instance_id = Catalog.lookup_instance_id("public", chain, "client-header")

    assert {:ok, %Success{} = response, _ctx} =
             RequestPipeline.execute_via_channels(
               chain,
               "eth_getBlockByNumber",
               ["latest", false],
               %RequestOptions{
                 timeout_ms: 5_000,
                 profile: "public",
                 strategy: :priority,
                 transport: :http,
                 provider_override: "client-header",
                 request_origin: :client
               }
             )

    assert {:ok, ^header} = Success.decode_result(response)

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?(
        {:ok, %{height: 101, block_hash: "0x" <> _, block_timestamp: 102}},
        BlockSyncRegistry.get_observation(chain, instance_id, :http)
      )
    end)
  end
end

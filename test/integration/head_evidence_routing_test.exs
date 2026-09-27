defmodule Lasso.RPC.HeadEvidenceRoutingTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.BlockSync.Registry
  alias Lasso.Config.ConfigStore
  alias Lasso.Observations.HeadSnapshot
  alias Lasso.Providers.{Catalog, HeadEvidence, LagCalculation}
  alias Lasso.RPC.Selection
  alias Lasso.RPC.Selection.CandidateCursor

  test "HTTP requests retain unknown upstreams, avoid proven lag, and fail open", %{chain: chain} do
    profile = "public"

    assert :ok =
             ConfigStore.register_chain_runtime(profile, chain, %{
               block_time_ms: 1_000,
               selection: %{max_lag_blocks: 2},
               providers: []
             })

    suffix = Integer.to_string(chain)
    behind = "behind-#{suffix}"
    peer_a = "peer-a-#{suffix}"
    peer_b = "peer-b-#{suffix}"

    setup_providers([
      %{id: behind, priority: 1, behavior: :healthy},
      %{id: peer_a, priority: 2, behavior: :healthy},
      %{id: peer_b, priority: 3, behavior: :healthy}
    ])

    ids =
      Map.new([behind, peer_a, peer_b], fn id ->
        {id, Catalog.lookup_instance_id(profile, chain, id)}
      end)

    request = fn ->
      RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [], %RequestOptions{
        profile: profile,
        strategy: :priority,
        transport: :http,
        timeout_ms: 2_000
      })
    end

    assert {:ok, _, initial} = request.()
    assert initial.executed_channel.provider_id == behind

    for id <- [peer_a, peer_b] do
      assert :ok = Registry.put_height(chain, ids[id], 100, :ws)
    end

    assert :ok = Registry.put_height(chain, ids[behind], 90, :ws)
    assert :ok = Registry.put_height(chain, ids[behind], 90, :http)
    assert {:ok, snapshot} = HeadEvidence.snapshot(profile, chain)
    assert snapshot.qualification == :qualified
    assert {:ok, reference} = HeadSnapshot.reference(snapshot)

    # A height without its poll-start reference is unknown, so it remains eligible.
    assert {:ok, _, unknown} = request.()
    assert unknown.executed_channel.provider_id == behind

    assert :ok = put_http_with_reference(chain, ids[behind], reference)
    assert {:ok, plan} = Catalog.get_routing_plan(Catalog.snapshot(), profile, chain)
    assert plan.max_lag_blocks == 2

    assert LagCalculation.assess_transport(chain, ids[behind], :http, snapshot, 2).status ==
             :lagging

    cursor =
      Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
        strategy: :priority,
        transport: :http
      )

    assert cursor.filters.head_snapshot.qualification == :qualified
    assert {:ok, %{provider_id: ^peer_a}, _} = CandidateCursor.next(cursor)

    assert {:ok, _, routed} = request.()
    assert routed.executed_channel.provider_id == peer_a

    # If every HTTP route is proven behind, availability wins over filtering.
    for id <- [peer_a, peer_b] do
      assert :ok = put_http_with_reference(chain, ids[id], reference)
      assert :ok = Registry.put_height(chain, ids[id], 100, :ws)
    end

    assert {:ok, all_lagging_snapshot} = HeadEvidence.snapshot(profile, chain)
    assert all_lagging_snapshot.qualification == :qualified
    assert all_lagging_snapshot.reference_height == 100

    for id <- [behind, peer_a, peer_b] do
      assert LagCalculation.assess_transport(chain, ids[id], :http, all_lagging_snapshot, 2).status ==
               :lagging
    end

    assert {:ok, _, fallback} = request.()
    assert fallback.executed_channel.provider_id == behind
  end

  defp put_http_with_reference(chain, instance_id, reference) do
    Registry.put_height(chain, instance_id, 90, :http, %{
      poll_references: [%{reference | captured_at_ms: System.system_time(:millisecond)}]
    })
  end
end

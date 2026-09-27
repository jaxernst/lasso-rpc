defmodule Lasso.RPC.HeadBranchRoutingTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.BlockSync.Registry
  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.Selection
  alias Lasso.RPC.Selection.CandidateCursor

  test "a minority WebSocket branch is not the first route", %{chain: chain} do
    profile = "public"

    assert :ok =
             ConfigStore.register_chain_runtime(profile, chain, %{
               block_time_ms: 1_000,
               selection: %{max_lag_blocks: 2},
               providers: []
             })

    suffix = Integer.to_string(chain)
    minority = "minority-#{suffix}"
    majority_a = "majority-a-#{suffix}"
    majority_b = "majority-b-#{suffix}"

    setup_providers(
      [
        %{id: minority, priority: 1},
        %{id: majority_a, priority: 2},
        %{id: majority_b, priority: 3}
      ],
      provider_type: :ws
    )

    for {provider, hash} <- [{minority, "0xbbb"}, {majority_a, "0xaaa"}] do
      instance_id = Catalog.lookup_instance_id(profile, chain, provider)
      assert :ok = Registry.put_height(chain, instance_id, 100, :ws, %{hash: hash})
    end

    ambiguous =
      Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
        strategy: :priority,
        transport: :ws
      )

    assert ambiguous.filters.head_snapshot.qualification == :ambiguous
    assert {:ok, %{provider_id: ^minority}, _} = CandidateCursor.next(ambiguous)

    instance_id = Catalog.lookup_instance_id(profile, chain, majority_b)
    assert :ok = Registry.put_height(chain, instance_id, 100, :ws, %{hash: "0xaaa"})

    cursor =
      Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
        strategy: :priority,
        transport: :ws
      )

    assert cursor.filters.head_snapshot.qualification == :qualified
    assert {:ok, %{provider_id: ^majority_a}, _} = CandidateCursor.next(cursor)

    # Hard exclusions must be applied before deciding the all-routes fallback.
    for strategy <- [:priority, :load_balanced] do
      restricted =
        Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
          strategy: strategy,
          transport: :ws,
          exclude: [majority_a, majority_b]
        )

      assert {:ok, %{provider_id: ^minority}, _} = CandidateCursor.next(restricted)
    end

    minority_id = Catalog.lookup_instance_id(profile, chain, minority)
    assert :ok = Registry.put_height(chain, minority_id, 90, :ws, %{hash: "0xbbb"})

    for strategy <- [:priority, :load_balanced] do
      restricted =
        Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
          strategy: strategy,
          transport: :ws,
          exclude: [majority_a, majority_b]
        )

      assert {:ok, %{provider_id: ^minority}, _} = CandidateCursor.next(restricted)
    end
  end
end

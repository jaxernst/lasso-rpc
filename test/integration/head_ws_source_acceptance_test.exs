defmodule Lasso.RPC.HeadWsSourceAcceptanceTest do
  use Lasso.Test.LassoIntegrationCase

  alias Lasso.BlockSync.{Registry, Worker}
  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{Catalog, HeadEvidence}
  alias Lasso.RPC.Selection
  alias Lasso.RPC.Selection.CandidateCursor
  alias LassoWeb.Dashboard.StatusHelpers

  test "newHeads source events drive branch and lag evidence for operators and routing", %{
    chain: chain
  } do
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

    ids =
      Map.new([minority, majority_a, majority_b], fn provider ->
        {provider, Catalog.lookup_instance_id(profile, chain, provider)}
      end)

    for {_provider, id} <- ids do
      start_supervised!(Supervisor.child_spec({Worker, {chain, id}}, id: {:head_worker, id}))
    end

    Lasso.Test.Eventually.assert_eventually(fn ->
      Enum.all?(ids, fn {_provider, id} ->
        match?({:ok, %{mode: :http_with_ws}}, Worker.get_status(chain, id))
      end)
    end)

    assert {:ok, %{qualification: :unavailable}} = HeadEvidence.snapshot(profile, chain)
    assert StatusHelpers.check_block_lag(chain, ids[minority], profile) == :unavailable

    for {provider, hash} <- [{minority, "0xbbb"}, {majority_a, "0xaaa"}] do
      send_head(chain, provider, 100, hash)
    end

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?({:ok, %{qualification: :ambiguous}}, HeadEvidence.snapshot(profile, chain))
    end)

    assert {:ok, %{provider_id: ^minority}, _} =
             profile
             |> Selection.select_channel_candidates(chain, "eth_blockNumber",
               strategy: :priority,
               transport: :ws
             )
             |> CandidateCursor.next()

    send_head(chain, majority_b, 100, "0xaaa")

    Lasso.Test.Eventually.assert_eventually(fn ->
      match?({:ok, %{qualification: :qualified}}, HeadEvidence.snapshot(profile, chain))
    end)

    for {provider, hash} <-
          [{minority, "0xbbb"}, {majority_a, "0xaaa"}, {majority_b, "0xaaa"}] do
      assert {:ok, %{height: 100, block_hash: ^hash}} =
               Registry.get_observation(chain, ids[provider], :ws)
    end

    cursor =
      Selection.select_channel_candidates(profile, chain, "eth_blockNumber",
        strategy: :priority,
        transport: :ws
      )

    assert {:ok, %{provider_id: ^majority_a}, _} = CandidateCursor.next(cursor)

    send_head(chain, minority, 90, "0xbbb")

    Lasso.Test.Eventually.assert_eventually(fn ->
      StatusHelpers.check_block_lag(chain, ids[minority], profile) == :lagging
    end)

    assert {:ok, %{provider_id: ^majority_a}, _} =
             profile
             |> Selection.select_channel_candidates(chain, "eth_blockNumber",
               strategy: :priority,
               transport: :ws
             )
             |> CandidateCursor.next()

    assert {:ok, %{ws_status: %{status: :active}}} = Worker.get_status(chain, ids[majority_a])
  end

  defp send_head(chain, provider, height, hash) do
    assert :ok =
             MockWSProvider.send_block(chain, provider, %{
               "number" => "0x" <> Integer.to_string(height, 16),
               "hash" => hash,
               "timestamp" => "0x" <> Integer.to_string(System.system_time(:second), 16)
             })
  end
end

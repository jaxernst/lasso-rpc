defmodule Lasso.Providers.HeadEvidenceTest do
  use ExUnit.Case, async: false

  alias Lasso.BlockSync.Registry
  alias Lasso.BlockSync.Strategies.HttpStrategy
  alias Lasso.Config.ConfigStore
  alias Lasso.Observations.{HeadComparison, HeadSnapshot}
  alias Lasso.Providers.{CandidateListing, Catalog, HeadEvidence, LagCalculation}
  alias Lasso.RPC.Selection.CandidateCursor
  alias LassoWeb.Dashboard.StatusHelpers

  test "conflicting WebSocket block hashes need a concrete majority" do
    chain_id = System.unique_integer([:positive])
    profile = "branch-evidence-#{chain_id}"

    on_exit(fn ->
      Registry.clear_chain(chain_id)
      ConfigStore.unregister_chain_runtime(profile, chain_id)
      Catalog.build_from_config()
    end)

    assert :ok =
             ConfigStore.register_chain_runtime(profile, chain_id, %{
               block_time_ms: 1_000,
               providers: Enum.map(["a", "b", "c", "d"], &provider/1)
             })

    Catalog.build_from_config()

    ids =
      Map.new(Catalog.get_profile_providers(profile, chain_id), &{&1.provider_id, &1.instance_id})

    assert :ok = Registry.put_height(chain_id, ids["a"], 100, :ws, %{hash: "0xaaa"})
    assert :ok = Registry.put_height(chain_id, ids["b"], 100, :ws, %{hash: "0xbbb"})
    assert {:ok, split} = HeadEvidence.snapshot(profile, chain_id)
    assert split.qualification == :ambiguous
    assert split.voter_count == 2
    assert StatusHelpers.check_block_lag(chain_id, ids["a"], profile) == :unavailable

    assert :ok = Registry.put_height(chain_id, ids["c"], 100, :ws, %{hash: "0xaaa"})
    assert {:ok, majority} = HeadEvidence.snapshot(profile, chain_id)
    assert majority.qualification == :qualified
    assert majority.support == 2
    assert Enum.sort(majority.supporting_instances) == Enum.sort([ids["a"], ids["c"]])
    assert majority.dissenting_instances == [ids["b"]]

    assert LagCalculation.assess_transport(chain_id, ids["b"], :ws, majority, 2).reason ==
             :branch_conflict

    assert StatusHelpers.check_block_lag(chain_id, ids["b"], profile) == :unavailable

    assert :ok = Registry.put_height(chain_id, ids["d"], 100, :ws)
    assert {:ok, unknown_hash} = HeadEvidence.snapshot(profile, chain_id)
    assert unknown_hash.qualification == :ambiguous

    assert :ok = Registry.put_height(chain_id, ids["d"], 100, :ws, %{hash: "0xAAA"})
    assert {:ok, recovered} = HeadEvidence.snapshot(profile, chain_id)
    assert recovered.qualification == :qualified
    assert recovered.support == 3
    assert recovered.dissenting_instances == [ids["b"]]
  end

  test "current probe facts compare only the requesting profile's active upstreams" do
    chain_id = System.unique_integer([:positive])
    profile_a = "head-a-#{chain_id}"
    profile_b = "head-b-#{chain_id}"

    on_exit(fn ->
      Registry.clear_chain(chain_id)
      ConfigStore.unregister_chain_runtime(profile_a, chain_id)
      ConfigStore.unregister_chain_runtime(profile_b, chain_id)
      Catalog.build_from_config()
    end)

    assert :ok =
             ConfigStore.register_chain_runtime(profile_a, chain_id, %{
               block_time_ms: 1_000,
               providers: [provider("a"), provider("b")]
             })

    assert :ok =
             ConfigStore.register_chain_runtime(profile_b, chain_id, %{
               block_time_ms: 1_000,
               providers: [provider("other")]
             })

    Catalog.build_from_config()

    ids_a =
      Map.new(
        Catalog.get_profile_providers(profile_a, chain_id),
        &{&1.provider_id, &1.instance_id}
      )

    [other] = Catalog.get_profile_providers(profile_b, chain_id)

    assert {:ok, empty} = HeadEvidence.snapshot(profile_a, chain_id)
    assert empty.qualification == :unavailable

    assert :ok = Registry.put_height(chain_id, ids_a["a"], 100, :http)
    assert :ok = Registry.put_height(chain_id, ids_a["a"], 100, :ws, %{hash: "0xabc"})
    assert :ok = Registry.put_height(chain_id, ids_a["b"], 100, :ws, %{hash: "0xabc"})
    assert :ok = Registry.put_height(chain_id, other.instance_id, 200, :http)

    assert Enum.map(Registry.get_observations(chain_id, ids_a["a"]), & &1.transport) ==
             [:http, :ws]

    for height <- 101..164 do
      assert :ok = Registry.put_height(chain_id, ids_a["a"], height, :http)
    end

    assert length(Registry.get_observations(chain_id, ids_a["a"])) == 2
    assert {:ok, ws_fact} = Registry.get_observation(chain_id, ids_a["a"], :ws)
    assert ws_fact.height == 100

    assert :ok = Registry.put_height(chain_id, ids_a["a"], 100, :http)

    assert {:ok, public} = HeadEvidence.snapshot(profile_a, chain_id)
    assert public.qualification == :qualified
    assert public.reference_height == 100
    assert public.voter_count == 2
    assert public.supporting_instances == Enum.sort(Map.values(ids_a))
    assert StatusHelpers.check_block_lag(chain_id, ids_a["a"], profile_a) == :synced
    assert StatusHelpers.check_block_lag(chain_id, ids_a["a"], profile_b) == :unavailable

    assert {:ok, stale} =
             HeadEvidence.snapshot(profile_a, chain_id, System.system_time(:millisecond) + 61_000)

    assert stale.qualification == :unavailable
    assert stale.voter_count == 0

    assert {:ok, private} = HeadEvidence.snapshot(profile_b, chain_id)
    assert private.qualification == :uncorroborated
    assert private.reference_height == 200
    assert private.voter_count == 1
    assert StatusHelpers.check_block_lag(chain_id, other.instance_id, profile_b) == :unavailable
    refute public.scope_id == private.scope_id

    assert :ok = ConfigStore.unregister_provider_runtime(profile_a, chain_id, "b")
    assert :ok = Lasso.RPC.ChainSupervisor.remove_provider(profile_a, chain_id, "b", ids_a["b"])
    assert Registry.get_observations(chain_id, ids_a["b"]) == []
    assert Registry.get_height(chain_id, ids_a["b"]) == {:error, :not_found}

    assert {:ok, after_removal} = HeadEvidence.snapshot(profile_a, chain_id)
    assert after_removal.qualification == :uncorroborated
    assert after_removal.voter_count == 1
    assert after_removal.reference_height == 100
  end

  test "operator lag status needs a qualified reference and an assessable transport" do
    chain_id = System.unique_integer([:positive])
    profile = "lag-status-#{chain_id}"

    on_exit(fn ->
      Registry.clear_chain(chain_id)
      ConfigStore.unregister_chain_runtime(profile, chain_id)
      Catalog.build_from_config()
    end)

    assert :ok =
             ConfigStore.register_chain_runtime(profile, chain_id, %{
               block_time_ms: 1_000,
               selection: %{max_lag_blocks: 2},
               providers: [provider("ahead-a"), provider("ahead-b"), provider("behind")]
             })

    Catalog.build_from_config()

    ids =
      Map.new(Catalog.get_profile_providers(profile, chain_id), &{&1.provider_id, &1.instance_id})

    assert :ok = Registry.put_height(chain_id, ids["ahead-a"], 100, :ws)
    assert :ok = Registry.put_height(chain_id, ids["ahead-b"], 100, :ws)
    assert :ok = Registry.put_height(chain_id, ids["behind"], 90, :ws)
    assert :ok = Registry.put_height(chain_id, ids["behind"], 90, :http)

    assert {:ok, snapshot} = HeadEvidence.snapshot(profile, chain_id)
    assert snapshot.qualification == :qualified
    assert snapshot.reference_height == 100
    assert StatusHelpers.check_block_lag(chain_id, ids["behind"], profile) == :lagging

    assert {:ok, plan} = Catalog.get_routing_plan(Catalog.snapshot(), profile, chain_id)
    assert plan.max_lag_blocks == 2

    cursor =
      CandidateCursor.new(Catalog.snapshot(), plan, "eth_blockNumber",
        transport: :http,
        strategy: :priority
      )

    assert cursor.filters.head_snapshot.qualification == :qualified

    routes = fn ->
      CandidateListing.list_routing_candidates_from_plan(plan, cursor.filters, :unavailable)
      |> Enum.map(& &1.id)
    end

    assert "behind" in routes.()

    {:ok, reference} = HeadSnapshot.reference(snapshot)

    assert :ok =
             Registry.put_height(chain_id, ids["behind"], 90, :http, %{
               poll_references: [%{reference | captured_at_ms: System.system_time(:millisecond)}]
             })

    assert "behind" not in routes.()
    assert Enum.sort(routes.()) == ["ahead-a", "ahead-b"]

    head_snapshot = HeadEvidence.snapshot_for_plan(plan)
    assert head_snapshot.qualification == :qualified

    candidates =
      CandidateListing.list_routing_candidates_from_plan(plan, cursor.filters, :unavailable)

    assert Enum.sort(Enum.map(candidates, & &1.id)) == ["ahead-a", "ahead-b"]

    assert :ok = Registry.put_height(chain_id, ids["behind"], 100, :ws)
    assert StatusHelpers.check_block_lag(chain_id, ids["behind"], profile) == :synced

    assert :ok = ConfigStore.unregister_provider_runtime(profile, chain_id, "ahead-a")

    assert :ok =
             Lasso.RPC.ChainSupervisor.remove_provider(
               profile,
               chain_id,
               "ahead-a",
               ids["ahead-a"]
             )

    assert :ok = ConfigStore.unregister_provider_runtime(profile, chain_id, "ahead-b")

    assert :ok =
             Lasso.RPC.ChainSupervisor.remove_provider(
               profile,
               chain_id,
               "ahead-b",
               ids["ahead-b"]
             )

    assert StatusHelpers.check_block_lag(chain_id, ids["behind"], profile) == :unavailable
  end

  test "an HTTP poll retains both profile references captured before peer heads change" do
    chain_id = System.unique_integer([:positive])
    profile_a = "poll-a-#{chain_id}"
    profile_b = "poll-b-#{chain_id}"

    on_exit(fn ->
      Registry.clear_chain(chain_id)
      ConfigStore.unregister_chain_runtime(profile_a, chain_id)
      ConfigStore.unregister_chain_runtime(profile_b, chain_id)
      Catalog.build_from_config()
    end)

    assert :ok =
             ConfigStore.register_chain_runtime(profile_a, chain_id, %{
               block_time_ms: 1_000,
               providers: [provider("shared"), provider("peer-a")]
             })

    assert :ok =
             ConfigStore.register_chain_runtime(profile_b, chain_id, %{
               block_time_ms: 1_000,
               providers: [provider("shared"), provider("peer-b")]
             })

    Catalog.build_from_config()

    ids_a =
      Map.new(
        Catalog.get_profile_providers(profile_a, chain_id),
        &{&1.provider_id, &1.instance_id}
      )

    ids_b =
      Map.new(
        Catalog.get_profile_providers(profile_b, chain_id),
        &{&1.provider_id, &1.instance_id}
      )

    shared = ids_a["shared"]
    assert shared == ids_b["shared"]

    for instance <- [shared, ids_a["peer-a"], ids_b["peer-b"]] do
      assert :ok = Registry.put_height(chain_id, instance, 100, :ws)
    end

    assert {:ok, initial_a} = HeadEvidence.snapshot(profile_a, chain_id)
    assert initial_a.qualification == :qualified

    test_pid = self()

    {:ok, strategy} =
      HttpStrategy.start(chain_id, shared,
        parent: self(),
        initial_delay_ms: 0,
        poll_interval_ms: 10_000,
        route_resolver: fn ^shared, ^chain_id -> {:ok, profile_a, "shared"} end,
        poll_runner: fn plan ->
          send(test_pid, {:poll_started, self(), plan})
          receive do: (:release -> {:ok, 99})
        end
      )

    assert_receive {:http_strategy, :poll, ^shared, generation}
    assert {:ok, strategy} = HttpStrategy.handle_message({:poll, generation}, strategy)
    assert_receive {:poll_started, owner, plan}
    assert plan.profile == profile_a
    assert Enum.map(plan.head_references_at_poll_start, & &1.height) == [100, 100]

    scope_ids = Enum.map(plan.head_references_at_poll_start, & &1.scope_id)
    assert length(Enum.uniq(scope_ids)) == 2

    assert :ok = Registry.put_height(chain_id, ids_a["peer-a"], 140, :ws)
    assert :ok = Registry.put_height(chain_id, ids_b["peer-b"], 150, :ws)

    send(owner, :release)
    assert_receive {:http_strategy, :poll_result, ^shared, owner_id, ^owner, {:ok, 99}}

    assert {:ok, strategy} =
             HttpStrategy.handle_message(
               {:poll_result, owner_id, owner, {:ok, 99}},
               strategy
             )

    assert_receive {:block_height, ^shared, 99, metadata}
    assert :ok = Registry.put_height(chain_id, shared, 99, :http, metadata)
    assert {:ok, observation} = Registry.get_observation(chain_id, shared, :http)
    assert observation.poll_references == plan.head_references_at_poll_start

    policy = %HeadComparison.AssessmentPolicy{freshness_ms: 30_000, max_lag_blocks: 2}
    assessment = HeadComparison.assess(initial_a, observation, policy, observation.observed_at_ms)
    assert assessment.status == :eligible
    assert assessment.lag == -1

    HttpStrategy.stop(strategy)
  end

  defp provider(id) do
    %{id: id, name: id, url: "https://#{id}.head-evidence.example"}
  end
end

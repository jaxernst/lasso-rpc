defmodule Lasso.Providers.HeadEvidenceTest do
  use ExUnit.Case, async: false

  alias Lasso.BlockSync.Registry
  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{Catalog, HeadEvidence}

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

    assert {:ok, stale} =
             HeadEvidence.snapshot(profile_a, chain_id, System.system_time(:millisecond) + 61_000)

    assert stale.qualification == :unavailable
    assert stale.voter_count == 0

    assert {:ok, private} = HeadEvidence.snapshot(profile_b, chain_id)
    assert private.qualification == :uncorroborated
    assert private.reference_height == 200
    assert private.voter_count == 1
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

  defp provider(id) do
    %{id: id, name: id, url: "https://#{id}.head-evidence.example"}
  end
end

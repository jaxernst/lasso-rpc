defmodule Lasso.Providers.CatalogTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.BoundedIdentifier

  @profile_a "catalog_test_a"
  @profile_b "catalog_test_b"
  @chain_id 99

  setup do
    on_exit(fn ->
      ConfigStore.unregister_chain_runtime(@profile_a, @chain_id)
      ConfigStore.unregister_chain_runtime(@profile_b, @chain_id)
      Catalog.build_from_config()
    end)

    :ok
  end

  defp register_chain(profile, chain_id, providers) do
    ConfigStore.register_chain_runtime(profile, chain_id, %{
      chain_id: chain_id,
      display_name: "Test Chain #{chain_id}",
      providers: providers
    })
  end

  describe "build_from_config/0" do
    test "is idempotent" do
      register_chain(@profile_a, @chain_id, [
        %{id: "eth_drpc", name: "dRPC", url: "https://eth.drpc.org", priority: 1}
      ])

      Catalog.build_from_config()
      count1 = Catalog.instance_count()

      Catalog.build_from_config()
      count2 = Catalog.instance_count()

      assert count1 == count2
      assert count1 > 0
    end
  end

  describe "cross-profile instance detection" do
    test "same URL providers across profiles share instance_id" do
      url = "https://catalog-test-shared.example.com"

      register_chain(@profile_a, @chain_id, [
        %{id: "shared_p", name: "Shared", url: url, priority: 1}
      ])

      register_chain(@profile_b, @chain_id, [
        %{id: "shared_p", name: "Shared", url: url, priority: 2}
      ])

      Catalog.build_from_config()

      id_a = Catalog.lookup_instance_id(@profile_a, @chain_id, "shared_p")
      id_b = Catalog.lookup_instance_id(@profile_b, @chain_id, "shared_p")

      assert id_a != nil
      assert id_a == id_b
    end

    test "different URL providers get different instance_ids" do
      register_chain(@profile_a, @chain_id, [
        %{id: "provider_1", name: "P1", url: "https://catalog-test-1.example.com", priority: 1},
        %{id: "provider_2", name: "P2", url: "https://catalog-test-2.example.com", priority: 2}
      ])

      Catalog.build_from_config()

      id_1 = Catalog.lookup_instance_id(@profile_a, @chain_id, "provider_1")
      id_2 = Catalog.lookup_instance_id(@profile_a, @chain_id, "provider_2")

      assert id_1 != nil
      assert id_2 != nil
      assert id_1 != id_2
    end

    test "same HTTP URL with same WS URL shares instance_id" do
      url = "https://catalog-test-ws-same.example.com"
      ws_url = "wss://catalog-test-ws-same.example.com"

      register_chain(@profile_a, @chain_id, [
        %{id: "shared_ws", name: "Shared WS", url: url, ws_url: ws_url, priority: 1}
      ])

      register_chain(@profile_b, @chain_id, [
        %{id: "shared_ws", name: "Shared WS", url: url <> "/", ws_url: ws_url <> "/", priority: 2}
      ])

      Catalog.build_from_config()

      id_a = Catalog.lookup_instance_id(@profile_a, @chain_id, "shared_ws")
      id_b = Catalog.lookup_instance_id(@profile_b, @chain_id, "shared_ws")

      assert id_a != nil
      assert id_a == id_b
    end

    test "same HTTP URL with different WS URLs does not share instance_id" do
      url = "https://catalog-test-ws-different.example.com"

      register_chain(@profile_a, @chain_id, [
        %{
          id: "split_ws",
          name: "Split WS A",
          url: url,
          ws_url: "wss://catalog-test-ws-a.example.com",
          priority: 1
        }
      ])

      register_chain(@profile_b, @chain_id, [
        %{
          id: "split_ws",
          name: "Split WS B",
          url: url,
          ws_url: "wss://catalog-test-ws-b.example.com",
          priority: 2
        }
      ])

      Catalog.build_from_config()

      id_a = Catalog.lookup_instance_id(@profile_a, @chain_id, "split_ws")
      id_b = Catalog.lookup_instance_id(@profile_b, @chain_id, "split_ws")

      assert id_a != nil
      assert id_b != nil
      assert id_a != id_b
    end

    test "same HTTP URL with and without WS URL does not share instance_id" do
      url = "https://catalog-test-ws-presence.example.com"

      register_chain(@profile_a, @chain_id, [
        %{id: "ws_presence", name: "HTTP Only", url: url, priority: 1}
      ])

      register_chain(@profile_b, @chain_id, [
        %{
          id: "ws_presence",
          name: "HTTP+WS",
          url: url,
          ws_url: "wss://catalog-test-ws-presence.example.com",
          priority: 2
        }
      ])

      Catalog.build_from_config()

      id_a = Catalog.lookup_instance_id(@profile_a, @chain_id, "ws_presence")
      id_b = Catalog.lookup_instance_id(@profile_b, @chain_id, "ws_presence")

      assert id_a != nil
      assert id_b != nil
      assert id_a != id_b
    end

    test "isolated sharing mode prevents sharing across profiles" do
      url = "https://catalog-test-isolated.example.com"

      register_chain(@profile_a, @chain_id, [
        %{id: "isolated", name: "Isolated A", url: url, priority: 1, sharing_mode: :isolated}
      ])

      register_chain(@profile_b, @chain_id, [
        %{id: "isolated", name: "Isolated B", url: url, priority: 2, sharing_mode: :isolated}
      ])

      Catalog.build_from_config()

      id_a = Catalog.lookup_instance_id(@profile_a, @chain_id, "isolated")
      id_b = Catalog.lookup_instance_id(@profile_b, @chain_id, "isolated")

      assert id_a != nil
      assert id_b != nil
      assert id_a != id_b
    end
  end

  describe "get_instance_refs/1" do
    test "returns all profiles referencing an instance" do
      url = "https://catalog-test-refs.example.com"

      register_chain(@profile_a, @chain_id, [
        %{id: "refs_p", name: "Refs", url: url, priority: 1}
      ])

      register_chain(@profile_b, @chain_id, [
        %{id: "refs_p", name: "Refs", url: url, priority: 2}
      ])

      Catalog.build_from_config()

      instance_id = Catalog.lookup_instance_id(@profile_a, @chain_id, "refs_p")
      refs = Catalog.get_instance_refs(instance_id)

      assert @profile_a in refs
      assert @profile_b in refs
    end
  end

  describe "get_profile_providers/2" do
    test "returns provider list with instance_id cross-references" do
      register_chain(@profile_a, @chain_id, [
        %{id: "p1", name: "P1", url: "https://catalog-test-pp-1.example.com", priority: 1},
        %{id: "p2", name: "P2", url: "https://catalog-test-pp-2.example.com", priority: 2}
      ])

      Catalog.build_from_config()

      providers = Catalog.get_profile_providers(@profile_a, @chain_id)
      assert length(providers) == 2

      p1 = Enum.find(providers, &(&1.provider_id == "p1"))
      assert p1.instance_id != nil
      assert p1.priority == 1
    end
  end

  describe "compiled routing plans" do
    test "publishes immutable provider and selection data with the catalog generation" do
      ConfigStore.register_chain_runtime(@profile_a, @chain_id, %{
        chain_id: @chain_id,
        display_name: "Compiled Plan Chain",
        selection: %{max_lag_blocks: 7, archival_threshold: 64},
        providers: [
          %{
            id: "compiled",
            name: "Compiled",
            url: "https://compiled.example.com",
            api_key: "secret",
            priority: 3,
            capabilities: %{methods: ["eth_blockNumber"]}
          }
        ]
      })

      Catalog.build_from_config()
      snapshot = Catalog.snapshot()

      assert {:ok, plan} = Catalog.get_routing_plan(snapshot, @profile_a, @chain_id)
      assert plan.generation == snapshot.generation
      assert plan.max_lag_blocks == 7
      assert plan.archival_threshold == 64
      assert plan.provider_priorities == %{"compiled" => 3}

      assert [provider] = plan.providers
      assert provider.id == "compiled"
      assert provider.routing_instance_id == BoundedIdentifier.encode(provider.instance_id)
      assert provider.priority == 3
      assert provider.transports == [:http]
      assert provider.config.capabilities == %{methods: ["eth_blockNumber"]}
      assert {"authorization", "Bearer secret"} in provider.config.headers
    end

    test "reads a captured routing plan without copying it through ETS" do
      register_chain(@profile_a, @chain_id, [
        %{
          id: "shared-plan",
          name: "Shared Plan",
          url: "https://shared-plan.example.com",
          priority: 1
        }
      ])

      Catalog.build_from_config()
      snapshot = Catalog.snapshot()

      :erlang.trace_pattern({:ets, :lookup, 2}, true, [:local])
      :erlang.trace(self(), true, [:call])

      on_exit(fn ->
        :erlang.trace(self(), false, [:all])
        :erlang.trace_pattern({:ets, :lookup, 2}, false, [:local])
      end)

      assert {:ok, %Lasso.RPC.RoutingPlan{}} =
               Catalog.get_routing_plan(snapshot, @profile_a, @chain_id)

      refute_receive {:trace, _pid, :call, {:ets, :lookup, _args}}

      :erlang.trace(self(), false, [:all])
      :erlang.trace_pattern({:ets, :lookup, 2}, false, [:local])
    end

    test "rejects a shared plan after its catalog table owner exits" do
      register_chain(@profile_a, @chain_id, [
        %{
          id: "owner-bound-plan",
          name: "Owner Bound Plan",
          url: "https://owner-bound-plan.example.com",
          priority: 1
        }
      ])

      Catalog.build_from_config()
      active = Catalog.snapshot()
      assert {:ok, plan} = Catalog.get_routing_plan(active, @profile_a, @chain_id)

      parent = self()

      {owner, monitor} =
        spawn_monitor(fn ->
          table = :ets.new(:expired_catalog, [:set, :public])
          send(parent, {:expired_catalog, self(), table})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:expired_catalog, ^owner, table}
      send(owner, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

      expired = %{
        table: table,
        generation: active.generation,
        routing_plans: %{{@profile_a, @chain_id} => plan}
      }

      assert {:error, :not_found} = Catalog.get_routing_plan(expired, @profile_a, @chain_id)
    end
  end

  describe "lookup_instance_id/3" do
    test "returns nil for non-existent provider" do
      Catalog.build_from_config()
      assert Catalog.lookup_instance_id("nonexistent", @chain_id, "nope") == nil
    end
  end

  describe "get_instance/1" do
    test "returns instance config" do
      register_chain(@profile_a, @chain_id, [
        %{id: "inst_p", name: "InstP", url: "https://catalog-test-inst.example.com", priority: 1}
      ])

      Catalog.build_from_config()

      instance_id = Catalog.lookup_instance_id(@profile_a, @chain_id, "inst_p")
      assert instance_id != nil

      {:ok, instance} = Catalog.get_instance(instance_id)
      assert instance.chain_id == @chain_id
      assert instance.url == "https://catalog-test-inst.example.com"
    end

    test "returns error for unknown instance" do
      assert {:error, :not_found} = Catalog.get_instance("nonexistent:fake:000000000000")
    end
  end

  describe "account-based isolation" do
    test "providers with different key-in-path URLs produce different instance_ids" do
      # Key-in-path URLs (e.g. Alchemy, Infura) naturally isolate per account
      # because the URL itself encodes the credential. This is the primary
      # BYOK isolation mechanism at the Catalog level.
      register_chain(@profile_a, @chain_id, [
        %{
          id: "iso_p",
          name: "Iso",
          url: "https://eth-mainnet.g.alchemy.com/v2/key_aaa",
          priority: 1
        }
      ])

      register_chain(@profile_b, @chain_id, [
        %{
          id: "iso_p",
          name: "Iso",
          url: "https://eth-mainnet.g.alchemy.com/v2/key_bbb",
          priority: 1
        }
      ])

      Catalog.build_from_config()

      id_a = Catalog.lookup_instance_id(@profile_a, @chain_id, "iso_p")
      id_b = Catalog.lookup_instance_id(@profile_b, @chain_id, "iso_p")

      assert id_a != nil
      assert id_b != nil
      assert id_a != id_b
    end
  end

  describe "BYOK isolation" do
    test "same provider_id with different URLs produces different instance_ids" do
      register_chain(@profile_a, @chain_id, [
        %{
          id: "alchemy",
          name: "Alchemy",
          url: "https://eth-mainnet.g.alchemy.com/v2/key_aaa",
          priority: 1
        }
      ])

      register_chain(@profile_b, @chain_id, [
        %{
          id: "alchemy",
          name: "Alchemy",
          url: "https://eth-mainnet.g.alchemy.com/v2/key_bbb",
          priority: 1
        }
      ])

      Catalog.build_from_config()

      id_a = Catalog.lookup_instance_id(@profile_a, @chain_id, "alchemy")
      id_b = Catalog.lookup_instance_id(@profile_b, @chain_id, "alchemy")

      assert id_a != nil
      assert id_b != nil
      assert id_a != id_b
    end
  end

  describe "list_all_instance_ids/0" do
    test "returns all unique instance_ids" do
      register_chain(@profile_a, @chain_id, [
        %{id: "list_p1", name: "P1", url: "https://catalog-test-list-1.example.com", priority: 1},
        %{id: "list_p2", name: "P2", url: "https://catalog-test-list-2.example.com", priority: 2}
      ])

      Catalog.build_from_config()

      ids = Catalog.list_all_instance_ids()
      assert length(ids) >= 2
      assert Enum.all?(ids, &is_binary/1)
    end
  end
end

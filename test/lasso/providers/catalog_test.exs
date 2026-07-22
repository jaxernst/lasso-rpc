defmodule Lasso.Providers.CatalogTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.Catalog

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

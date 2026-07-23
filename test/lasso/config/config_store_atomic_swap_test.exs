defmodule Lasso.Config.ConfigStoreAtomicSwapTest do
  @moduledoc """
  Concurrency guards for ConfigStore atomic reload and single-profile inject
  semantics. Readers must observe either the old complete snapshot or the new
  complete snapshot, never a partially populated ETS table.
  """

  use ExUnit.Case, async: false

  alias Lasso.Config.{ConfigStore, ProfileId}
  alias Lasso.Config.ChainConfig
  alias Lasso.Config.ChainConfig.{Monitoring, Provider, Selection, Websocket, WebsocketFailover}

  @reads 200

  defmodule BlockingBackend do
    def load_all({owner, specs}) do
      send(owner, {:retry_load_started, self()})

      receive do
        :complete_retry_load -> {:ok, specs}
      end
    end
  end

  test "a degraded retry cannot overwrite runtime mutations made while it loads" do
    alias Lasso.Config.Backend.File, as: FileBackend

    {:ok, backend_state} =
      FileBackend.init(
        profiles_dir: "test/support/profiles",
        legacy_config_path: "test/support/chains.yml"
      )

    {:ok, specs} = FileBackend.load_all(backend_state)
    retry_specs = Enum.reject(specs, &(&1.profile_id == "public"))
    original_state = :sys.get_state(ConfigStore)
    owner = self()
    chain_id = 876_543_210

    on_exit(fn ->
      ConfigStore.unregister_chain_runtime("public", chain_id)
      :sys.replace_state(ConfigStore, fn _ -> original_state end)
    end)

    :sys.replace_state(ConfigStore, fn state ->
      %{
        state
        | backend_module: BlockingBackend,
          backend_state: {owner, retry_specs},
          retry_timer: nil,
          retry_task_ref: nil,
          retry_task_snapshot: nil
      }
    end)

    assert :ok =
             ConfigStore.register_chain_runtime("public", chain_id, %{
               display_name: "Retry-Safe Runtime Chain",
               url_aliases: ["retry-safe-runtime"],
               providers: []
             })

    send(ConfigStore, :retry_eager_load)
    assert_receive {:retry_load_started, retry_task}, 1_000
    send(retry_task, :complete_retry_load)

    assert eventually(fn -> :sys.get_state(ConfigStore).retry_task_ref == nil end)
    assert {:ok, _chain} = ConfigStore.get_chain("public", chain_id)
  end

  test "concurrent readers never observe a missing system profile across reload" do
    # The file backend serves `public` and `testnet` from
    # `test/support/profiles/`. Both should be present in every
    # snapshot ConfigStore publishes.
    expected = ["public", "testnet"]

    parent = self()

    reader =
      Task.async(fn ->
        observed =
          Enum.map(1..@reads, fn _ ->
            for slug <- expected do
              case ConfigStore.resolve(:system, slug) do
                {:ok, profile_id} -> {slug, ConfigStore.get_profile(profile_id)}
                {:error, _} = err -> {slug, err}
              end
            end
          end)

        send(parent, {:done, observed})
      end)

    # Hammer reload while the reader runs.
    Enum.each(1..10, fn _ -> :ok = ConfigStore.reload() end)

    Task.await(reader, 5_000)
    receive do: ({:done, observed} -> assert_no_partial_snapshot(observed))
  end

  defp assert_no_partial_snapshot(observed) do
    for round <- observed, {slug, get_result} <- round do
      assert {:ok, %{slug: ^slug}} = get_result,
             "resolve+get_profile returned #{inspect(get_result)} for #{slug} mid-reload"
    end
  end

  @tag timeout: 10_000
  test "single-profile inject publishes meta + chains + resolve atomically" do
    # The bug class this defends against: `store_profile/2` writing the
    # three rows as separate `:ets.insert/2` calls. A reader between
    # them could observe meta+chains without the resolve entry, or
    # resolve+meta without chains. Batched into a single `:ets.insert(t,
    # [tup1, tup2, tup3])` it cannot.
    slug = "inject_atomic_#{:rand.uniform(999_999_999)}"
    chain = "test_chain_inject_atomic"
    chain_id = 987_654

    spec = %{
      scope: :system,
      profile_id: ProfileId.for_system(slug),
      slug: slug,
      name: "atomic-inject-#{slug}",
      rps_limit: 100,
      burst_limit: 200,
      unlisted: true,
      chains: %{chain => build_chain(slug, chain, chain_id: chain_id)}
    }

    on_exit(fn -> ConfigStore.remove_profile(spec.profile_id) end)

    parent = self()

    reader =
      Task.async(fn ->
        observed =
          for _ <- 1..@reads do
            case ConfigStore.resolve(:system, slug) do
              {:ok, profile_id} ->
                {ConfigStore.get_profile(profile_id), ConfigStore.get_chain(profile_id, chain)}

              {:error, :not_found} ->
                :pre_publish
            end
          end

        send(parent, {:done, observed})
      end)

    # Hammer inject_profile + remove_profile to maximize the chance of a
    # reader landing inside the write window. Each cycle exercises a
    # full rebuild_shared_infrastructure, so we keep the count modest;
    # the reader runs many more iterations against this writer.
    Enum.each(1..10, fn _ ->
      :ok = ConfigStore.inject_profile(spec)
      :ok = ConfigStore.remove_profile(spec.profile_id)
    end)

    Task.await(reader, 5_000)

    receive do
      {:done, observed} ->
        for result <- observed do
          case result do
            :pre_publish ->
              :ok

            {{:ok, %{slug: ^slug}}, {:ok, %ChainConfig{display_name: ^chain}}} ->
              :ok

            other ->
              flunk(
                "Partial snapshot during inject: #{inspect(other)} — expected either :pre_publish " <>
                  "(resolve = :not_found) or both meta + chain present together"
              )
          end
        end
    end
  end

  test "lookup_chain_id_in_profile honors stored URL aliases" do
    slug = "alias_profile_#{:rand.uniform(999_999_999)}"
    profile_id = ProfileId.for_system(slug)
    chain_slug = "my-stable-chain-slug"
    chain_id = 424_242

    spec = %{
      scope: :system,
      profile_id: profile_id,
      slug: slug,
      name: "alias-profile",
      rps_limit: 100,
      burst_limit: 200,
      unlisted: true,
      chains: %{chain_slug => build_chain(slug, chain_slug, chain_id: chain_id)}
    }

    on_exit(fn -> ConfigStore.remove_profile(profile_id) end)

    assert :ok = ConfigStore.inject_profile(spec)
    assert {:ok, ^chain_id} = ConfigStore.lookup_chain_id_in_profile(profile_id, chain_slug)

    assert {:ok, %ChainConfig{chain_id: ^chain_id}} =
             ConfigStore.get_chain(profile_id, chain_slug)
  end

  test "ConfigStore and Owner restarts republish a readable last-good snapshot" do
    slug = "owner-restart-#{:rand.uniform(999_999_999)}"
    chain_id = 799_999
    spec = alias_spec(slug, chain_id, "owner-restart-chain")

    on_exit(fn -> ConfigStore.remove_profile(spec.profile_id) end)

    assert :ok = ConfigStore.inject_profile(spec)
    assert {:ok, profile_id} = ConfigStore.resolve(:system, slug)
    assert {:ok, profile} = ConfigStore.get_profile(profile_id)
    assert {:ok, %ChainConfig{}} = ConfigStore.get_chain(profile_id, chain_id)

    config_store = Process.whereis(ConfigStore)
    config_monitor = Process.monitor(config_store)
    Process.exit(config_store, :kill)
    assert_receive {:DOWN, ^config_monitor, :process, ^config_store, :killed}, 1_000

    assert eventually(fn -> Process.whereis(ConfigStore) not in [nil, config_store] end)
    assert {:ok, ^profile} = ConfigStore.get_profile(profile_id)

    assert :ok =
             ConfigStore.register_provider_runtime(profile_id, chain_id, %{
               id: "runtime-provider",
               name: "Runtime Provider",
               url: "https://runtime.example",
               priority: 10
             })

    assert {:ok, chain_with_runtime_provider} = ConfigStore.get_chain(profile_id, chain_id)
    assert Enum.any?(chain_with_runtime_provider.providers, &(&1.id == "runtime-provider"))

    owner = Process.whereis(Lasso.Config.ConfigStore.Owner)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 1_000

    assert eventually(fn ->
             Process.whereis(Lasso.Config.ConfigStore.Owner) not in [nil, owner]
           end)

    assert eventually(fn -> ConfigStore.get_profile(profile_id) == {:ok, profile} end)
    assert {:ok, ^profile_id} = ConfigStore.resolve(:system, slug)

    assert eventually(fn ->
             ConfigStore.get_chain(profile_id, chain_id) == {:ok, chain_with_runtime_provider}
           end)

    assert :ok = ConfigStore.reload()
  end

  test "configured aliases are profile-local and decimal collisions retain the last-good snapshot" do
    first = alias_spec("alias-a", 700_001, "shared-alias")
    second = alias_spec("alias-b", 700_002, "shared-alias")

    on_exit(fn ->
      ConfigStore.remove_profile(first.profile_id)
      ConfigStore.remove_profile(second.profile_id)
    end)

    assert :ok = ConfigStore.inject_profile(first)
    assert :ok = ConfigStore.inject_profile(second)

    assert {:ok, 700_001} =
             ConfigStore.lookup_chain_id_in_profile(first.profile_id, "shared-alias")

    assert {:ok, 700_002} =
             ConfigStore.lookup_chain_id_in_profile(second.profile_id, "shared-alias")

    original_state = :sys.get_state(ConfigStore)
    original_specs = Application.get_env(:lasso, :config_store_invalid_chain_specs)

    on_exit(fn ->
      :sys.replace_state(ConfigStore, fn _ -> original_state end)
      Application.put_env(:lasso, :config_store_invalid_chain_specs, original_specs)
    end)

    invalid = %{
      first
      | profile_id: "collision",
        slug: "collision",
        chains: %{
          "one" => build_chain("collision", "one", chain_id: 1),
          "other" => %{build_chain("collision", "other", chain_id: 2) | url_aliases: ["1"]}
        }
    }

    assert {:error, {:chain_alias_collides_with_chain_id, 2, "1"}} =
             ConfigStore.inject_profile(invalid)

    assert {:ok, 700_001} =
             ConfigStore.lookup_chain_id_in_profile(first.profile_id, "shared-alias")

    Application.put_env(:lasso, :config_store_invalid_chain_specs, [invalid])

    :sys.replace_state(ConfigStore, fn state ->
      %{
        state
        | backend_module: Lasso.Config.ConfigStoreAtomicSwapTest.InvalidChainBackend,
          backend_state: nil
      }
    end)

    assert {:error, {:chain_alias_collides_with_chain_id, 2, "1"}} = ConfigStore.reload()

    assert {:ok, 700_001} =
             ConfigStore.lookup_chain_id_in_profile(first.profile_id, "shared-alias")
  end

  test "invalid chain IDs leave the last good snapshot active" do
    original_state = :sys.get_state(ConfigStore)
    original_specs = Application.get_env(:lasso, :config_store_invalid_chain_specs)

    on_exit(fn ->
      :sys.replace_state(ConfigStore, fn _ -> original_state end)
      Application.put_env(:lasso, :config_store_invalid_chain_specs, original_specs)
    end)

    assert {:ok, profile_id} = ConfigStore.resolve(:system, "public")

    for {chain_id, expected_error} <- [
          {nil, :invalid_chain_id},
          {0, :invalid_chain_id},
          {"1", :invalid_chain_id}
        ] do
      Application.put_env(:lasso, :config_store_invalid_chain_specs, [invalid_spec(chain_id)])

      :sys.replace_state(ConfigStore, fn state ->
        %{
          state
          | backend_module: Lasso.Config.ConfigStoreAtomicSwapTest.InvalidChainBackend,
            backend_state: nil
        }
      end)

      assert {:error, ^expected_error} = ConfigStore.reload()
      assert {:ok, ^profile_id} = ConfigStore.resolve(:system, "public")
    end

    duplicate = %{
      invalid_spec(1)
      | chains: %{
          "one" => build_chain("invalid", "one", chain_id: 1),
          "two" => build_chain("invalid", "two", chain_id: 1)
        }
    }

    Application.put_env(:lasso, :config_store_invalid_chain_specs, [duplicate])

    :sys.replace_state(ConfigStore, fn state ->
      %{
        state
        | backend_module: Lasso.Config.ConfigStoreAtomicSwapTest.InvalidChainBackend,
          backend_state: nil
      }
    end)

    assert {:error, :duplicate_chain_id} = ConfigStore.reload()
    assert {:ok, ^profile_id} = ConfigStore.resolve(:system, "public")
  end

  defp alias_spec(slug, chain_id, alias_name) do
    %{
      scope: :system,
      profile_id: slug,
      slug: slug,
      name: slug,
      rps_limit: 100,
      burst_limit: 200,
      unlisted: true,
      chains: %{alias_name => build_chain(slug, alias_name, chain_id: chain_id)}
    }
  end

  defp invalid_spec(chain_id) do
    %{
      scope: :system,
      profile_id: "invalid",
      slug: "invalid",
      name: "Invalid",
      rps_limit: 1,
      burst_limit: 1,
      chains: %{"invalid" => build_chain("invalid", "invalid", chain_id: chain_id)}
    }
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp build_chain(slug, name, opts) do
    chain_id = Keyword.get(opts, :chain_id)

    %ChainConfig{
      display_name: name,
      chain_id: chain_id,
      url_aliases: [name],
      block_time_ms: 12_000,
      providers: [
        %Provider{
          id: "p1",
          name: "p1",
          priority: 100,
          url: "https://example.invalid/#{slug}/#{name}/p1",
          ws_url: nil,
          capabilities: nil,
          subscribe_new_heads: false,
          archival: false
        }
      ],
      monitoring: %Monitoring{probe_interval_ms: 60_000, lag_alert_threshold_blocks: 5},
      selection: %Selection{max_lag_blocks: 5},
      websocket: %Websocket{
        subscribe_new_heads: false,
        new_heads_timeout_ms: 30_000,
        failover: %WebsocketFailover{}
      }
    }
  end

  defmodule InvalidChainBackend do
    @behaviour Lasso.Config.Backend

    @impl true
    def init(_config), do: {:ok, :invalid_chain_test}

    @impl true
    def load_all(:invalid_chain_test),
      do: {:ok, Application.fetch_env!(:lasso, :config_store_invalid_chain_specs)}

    @impl true
    def load(_state, _slug), do: {:error, :not_found}
  end
end

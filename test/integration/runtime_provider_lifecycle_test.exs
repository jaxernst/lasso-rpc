defmodule Lasso.Integration.RuntimeProviderLifecycleTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers
  alias Lasso.Providers.{Catalog, InstanceSupervisor}
  alias Lasso.RPC.TransportRegistry

  test "a stalled instance supervisor returns a bounded provider-start error" do
    suffix = System.unique_integer([:positive])
    chain_id = 900_000_000 + rem(suffix, 90_000_000)
    provider_id = "start-stall-#{suffix}"

    provider = %{
      id: provider_id,
      name: provider_id,
      url: "http://127.0.0.1:1/#{suffix}"
    }

    assert :ok =
             ConfigStore.register_chain_runtime("public", chain_id, %{
               display_name: "Provider startup test",
               providers: []
             })

    on_exit(fn ->
      Providers.remove_provider(chain_id, provider_id)
      ConfigStore.unregister_chain_runtime("public", chain_id)
    end)

    assert {:ok, ^provider_id} = Providers.add_provider(chain_id, provider, validate: false)
    instance_id = Catalog.lookup_instance_id("public", chain_id, provider_id)
    assert is_pid(GenServer.whereis(InstanceSupervisor.via_name(instance_id)))

    supervisor = Process.whereis(Lasso.Providers.InstanceDynamicSupervisor)
    :sys.suspend(supervisor)
    on_exit(fn -> if Process.alive?(supervisor), do: :sys.resume(supervisor) end)

    task =
      Task.async(fn ->
        Lasso.RPC.ChainSupervisor.ensure_provider("public", chain_id, provider)
      end)

    result = Task.yield(task, 4_000)
    if is_nil(result), do: Task.shutdown(task, :brutal_kill)

    assert {:ok, {:error, {:instance_supervisor_start_failed, {:supervisor_exit, :timeout}}}} =
             result
  end

  test "replacement waits for the removed provider's channels to close" do
    suffix = System.unique_integer([:positive])
    chain_id = 900_000_000 + rem(suffix, 90_000_000)
    provider_id = "lifecycle-#{suffix}"

    provider = %{
      id: provider_id,
      name: provider_id,
      url: "http://127.0.0.1:1/#{suffix}",
      __mock__: true
    }

    assert :ok =
             ConfigStore.register_chain_runtime("public", chain_id, %{
               display_name: "Lifecycle test",
               providers: []
             })

    on_exit(fn ->
      Providers.remove_provider(chain_id, provider_id)
      ConfigStore.unregister_chain_runtime("public", chain_id)
    end)

    assert {:ok, ^provider_id} = Providers.add_provider(chain_id, provider, validate: false)

    registry = GenServer.whereis(TransportRegistry.via_name("public", chain_id))
    assert is_pid(registry)
    :sys.suspend(registry)
    on_exit(fn -> if Process.alive?(registry), do: :sys.resume(registry) end)

    removal = Task.async(fn -> Providers.remove_provider(chain_id, provider_id) end)

    Lasso.Test.Eventually.assert_eventually(fn ->
      ConfigStore.get_provider("public", chain_id, provider_id) == {:error, :not_found}
    end)

    Lasso.Test.Eventually.assert_eventually(fn ->
      Catalog.lookup_instance_id("public", chain_id, provider_id) == nil
    end)

    addition = Task.async(fn -> Providers.add_provider(chain_id, provider, validate: false) end)
    assert Task.yield(addition, 100) == nil
    assert ConfigStore.get_provider("public", chain_id, provider_id) == {:error, :not_found}

    :sys.resume(registry)
    assert :ok = Task.await(removal, 7_000)
    assert {:ok, ^provider_id} = Task.await(addition, 7_000)
    assert {:ok, _provider} = ConfigStore.get_provider("public", chain_id, provider_id)
  end

  test "timed-out channel cleanup survives ConfigStore restart" do
    suffix = System.unique_integer([:positive])
    chain_id = 900_000_000 + rem(suffix, 90_000_000)
    provider_id = "restart-cleanup-#{suffix}"

    provider = %{
      id: provider_id,
      name: provider_id,
      url: "http://127.0.0.1:1/#{suffix}"
    }

    assert :ok =
             ConfigStore.register_chain_runtime("public", chain_id, %{
               display_name: "Cleanup restart test",
               providers: []
             })

    on_exit(fn ->
      Providers.remove_provider(chain_id, provider_id)
      ConfigStore.unregister_chain_runtime("public", chain_id)
    end)

    assert {:ok, ^provider_id} = Providers.add_provider(chain_id, provider, validate: false)
    instance_id = Catalog.lookup_instance_id("public", chain_id, provider_id)
    assert is_binary(instance_id)
    old_generation = ConfigStore.route_generation()

    registry = GenServer.whereis(TransportRegistry.via_name("public", chain_id))
    :sys.suspend(registry)
    on_exit(fn -> if Process.alive?(registry), do: :sys.resume(registry) end)

    assert {:error, {:runtime_reconcile_pending, _}} =
             Providers.remove_provider(chain_id, provider_id)

    cleanup_key = {"public", chain_id, provider_id}

    assert [{^cleanup_key, {^instance_id, ^old_generation}}] =
             :ets.lookup(:lasso_runtime_provider_cleanup, cleanup_key)

    assert Catalog.lookup_instance_id("public", chain_id, provider_id) == nil

    old_store = Process.whereis(ConfigStore)
    Process.exit(old_store, :kill)

    Lasso.Test.Eventually.assert_eventually(fn ->
      restarted = Process.whereis(ConfigStore)
      is_pid(restarted) and restarted != old_store
    end)

    :sys.resume(registry)

    Lasso.Test.Eventually.assert_eventually(
      fn -> :ets.lookup(:lasso_runtime_provider_cleanup, cleanup_key) == [] end,
      timeout: 10_000
    )

    assert {:ok, ^provider_id} = Providers.add_provider(chain_id, provider, validate: false)
    assert {:ok, _provider} = ConfigStore.get_provider("public", chain_id, provider_id)

    assert {:ok, replacement} =
             TransportRegistry.get_channel("public", chain_id, provider_id, :http)

    assert replacement.route_generation > old_generation

    assert :ok =
             TransportRegistry.close_channel_sync(
               "public",
               chain_id,
               provider_id,
               :http,
               old_generation
             )

    assert {:ok, after_cleanup} =
             TransportRegistry.get_channel("public", chain_id, provider_id, :http)

    assert after_cleanup.raw_channel == replacement.raw_channel
  end

  test "a channel-close timeout leaves the original provider configured during update" do
    suffix = System.unique_integer([:positive])
    chain_id = 900_000_000 + rem(suffix, 90_000_000)
    provider_id = "update-timeout-#{suffix}"
    old_url = "http://127.0.0.1:1/#{suffix}"
    new_url = "http://127.0.0.1:2/#{suffix}"

    assert :ok =
             ConfigStore.register_chain_runtime("public", chain_id, %{
               display_name: "Update timeout test",
               providers: []
             })

    on_exit(fn ->
      Providers.remove_provider(chain_id, provider_id)
      ConfigStore.unregister_chain_runtime("public", chain_id)
    end)

    assert {:ok, ^provider_id} =
             Providers.add_provider(
               chain_id,
               %{id: provider_id, name: provider_id, url: old_url, __mock__: true},
               validate: false
             )

    registry = GenServer.whereis(TransportRegistry.via_name("public", chain_id))
    :sys.suspend(registry)
    on_exit(fn -> if Process.alive?(registry), do: :sys.resume(registry) end)

    assert {:error, _reason} = Providers.update_provider(chain_id, provider_id, %{url: new_url})
    assert {:ok, %{url: ^old_url}} = ConfigStore.get_provider("public", chain_id, provider_id)
    assert Catalog.lookup_instance_id("public", chain_id, provider_id) != nil

    :sys.resume(registry)
    assert :ok = Providers.update_provider(chain_id, provider_id, %{url: new_url})
    assert {:ok, %{url: ^new_url}} = ConfigStore.get_provider("public", chain_id, provider_id)
  end

  test "whole-profile publication cannot let old cleanup close its replacement" do
    suffix = System.unique_integer([:positive])
    profile = "publication-#{suffix}"
    chain_id = 900_000_000 + rem(suffix, 90_000_000)
    provider_id = "publication-provider-#{suffix}"

    spec = %{
      scope: :system,
      profile_id: profile,
      slug: profile,
      name: profile,
      rps_limit: 100,
      burst_limit: 100,
      unlisted: true,
      chains: %{}
    }

    assert :ok = ConfigStore.inject_profile(spec)
    assert :ok = Lasso.Testing.ChainHelper.ensure_chain_exists(chain_id, profile: profile)

    assert {:ok, ^provider_id} =
             Providers.add_provider(
               profile,
               chain_id,
               %{
                 id: provider_id,
                 name: provider_id,
                 url: "http://127.0.0.1:1/#{suffix}",
                 __mock__: true
               },
               validate: false
             )

    assert {:ok, old_chain} = ConfigStore.get_chain(profile, chain_id)
    old_generation = ConfigStore.route_generation()
    registry = GenServer.whereis(TransportRegistry.via_name(profile, chain_id))

    on_exit(fn ->
      if Process.alive?(registry), do: :sys.resume(registry)
      ConfigStore.remove_profile(profile)
    end)

    :sys.suspend(registry)

    assert {:error, {:runtime_reconcile_pending, _}} =
             Providers.remove_provider(profile, chain_id, provider_id)

    :sys.resume(registry)
    assert :ok = ConfigStore.update_profile(%{spec | chains: %{"runtime" => old_chain}})
    assert ConfigStore.route_generation() > old_generation
    assert {:ok, _provider} = ConfigStore.get_provider(profile, chain_id, provider_id)

    assert {:ok, replacement} =
             TransportRegistry.get_channel(profile, chain_id, provider_id, :http)

    assert replacement.route_generation > old_generation

    assert :ok =
             TransportRegistry.close_channel_sync(
               profile,
               chain_id,
               provider_id,
               :http,
               old_generation
             )

    assert {:ok, after_cleanup} =
             TransportRegistry.get_channel(profile, chain_id, provider_id, :http)

    assert after_cleanup.raw_channel == replacement.raw_channel
  end

  test "a stalled instance supervisor does not lose final-reference cleanup" do
    suffix = System.unique_integer([:positive])
    chain_id = 900_000_000 + rem(suffix, 90_000_000)
    removed_id = "removed-#{suffix}"
    survivors = for n <- 1..2, do: "survivor-#{n}-#{suffix}"

    assert :ok =
             ConfigStore.register_chain_runtime("public", chain_id, %{
               display_name: "Supervisor recovery test",
               providers: []
             })

    on_exit(fn ->
      Providers.remove_provider(chain_id, removed_id)
      Enum.each(survivors, &Providers.remove_provider(chain_id, &1))
      ConfigStore.unregister_chain_runtime("public", chain_id)
    end)

    for {provider_id, n} <- Enum.with_index([removed_id | survivors], 1) do
      assert {:ok, ^provider_id} =
               Providers.add_provider(
                 chain_id,
                 %{
                   id: provider_id,
                   name: provider_id,
                   url: "http://127.0.0.1:#{n}/#{suffix}"
                 },
                 validate: false
               )
    end

    instance_id = Catalog.lookup_instance_id("public", chain_id, removed_id)
    assert is_pid(GenServer.whereis(InstanceSupervisor.via_name(instance_id)))
    supervisor = Process.whereis(Lasso.Providers.InstanceDynamicSupervisor)
    :sys.suspend(supervisor)
    on_exit(fn -> if Process.alive?(supervisor), do: :sys.resume(supervisor) end)

    removal = Task.async(fn -> Providers.remove_provider(chain_id, removed_id) end)
    assert {:error, {:runtime_reconcile_pending, _}} = Task.await(removal, 5_000)
    assert ConfigStore.get_provider("public", chain_id, removed_id) == {:error, :not_found}

    # A previous integration case may have raised ConfigStore's global retry
    # backoff above this test's deadline. Exercise the pending reconciliation
    # directly after the supervisor is available again.
    assert ConfigStore.status().runtime_reconcile_pending
    state = :sys.get_state(ConfigStore)
    Process.cancel_timer(state.runtime_reconcile_timer)
    :sys.resume(supervisor)
    send(ConfigStore, :retry_runtime_reconcile)

    Lasso.Test.Eventually.assert_eventually(
      fn -> GenServer.whereis(InstanceSupervisor.via_name(instance_id)) == nil end,
      timeout: 10_000
    )
  end

  test "ConfigStore recovery replays a shared alias removal notification" do
    suffix = System.unique_integer([:positive])
    chain_id = 900_000_000 + rem(suffix, 90_000_000)
    provider_id = "alias-recovery-#{suffix}"
    other_profile = "alias-survivor-#{suffix}"

    spec = %{
      scope: :system,
      profile_id: other_profile,
      slug: other_profile,
      name: other_profile,
      rps_limit: 100,
      burst_limit: 100,
      unlisted: true,
      chains: %{}
    }

    assert :ok = ConfigStore.inject_profile(spec)
    assert :ok = Lasso.Testing.ChainHelper.ensure_chain_exists(chain_id, profile: other_profile)

    assert :ok =
             ConfigStore.register_chain_runtime("public", chain_id, %{
               display_name: "Alias recovery test",
               providers: []
             })

    on_exit(fn ->
      ConfigStore.remove_profile(other_profile)
      ConfigStore.unregister_chain_runtime("public", chain_id)
    end)

    provider = %{
      id: provider_id,
      name: provider_id,
      url: "http://127.0.0.1:1/#{suffix}",
      __mock__: true
    }

    assert {:ok, ^provider_id} = Providers.add_provider(chain_id, provider, validate: false)

    assert {:ok, ^provider_id} =
             Providers.add_provider(other_profile, chain_id, provider, validate: false)

    instance_id = Catalog.lookup_instance_id("public", chain_id, provider_id)
    assert Catalog.lookup_instance_id(other_profile, chain_id, provider_id) == instance_id

    Lasso.Core.Streaming.InstanceEventBus.subscribe(
      Lasso.Topics.instance_sub_manager_restarted(chain_id)
    )

    barrier_ref = make_ref()
    Application.put_env(:lasso, :runtime_provider_removal_barrier, {self(), barrier_ref})
    on_exit(fn -> Application.delete_env(:lasso, :runtime_provider_removal_barrier) end)

    {_remover, remover_ref} =
      spawn_monitor(fn -> Providers.remove_provider(chain_id, provider_id) end)

    assert_receive {:runtime_provider_removal_published, config_store, ^barrier_ref}, 5_000
    assert ConfigStore.get_provider("public", chain_id, provider_id) == {:error, :not_found}
    assert Catalog.get_instance_refs(instance_id) == [other_profile]
    refute_receive {:runtime_provider_removed, "public", ^provider_id, ^instance_id}, 50

    Application.delete_env(:lasso, :runtime_provider_removal_barrier)
    Process.exit(config_store, :kill)
    assert_receive {:DOWN, ^remover_ref, :process, _pid, _reason}, 5_000

    Lasso.Test.Eventually.assert_eventually(fn ->
      restarted = Process.whereis(ConfigStore)
      is_pid(restarted) and restarted != config_store
    end)

    assert_receive {:runtime_provider_removed, "public", ^provider_id, ^instance_id}, 5_000

    Lasso.Test.Eventually.assert_eventually(fn ->
      not ConfigStore.status().runtime_reconcile_pending
    end)

    assert Catalog.get_instance_refs(instance_id) == [other_profile]
  end
end

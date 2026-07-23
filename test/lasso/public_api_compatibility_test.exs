defmodule Lasso.PublicAPICompatibilityTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.{Backend.File, ChainConfig, ConfigStore}
  alias Lasso.RPC.TransportRegistry

  @legacy_exports %{
    ConfigStore => [
      find_chain_name_by_id: 1,
      get_all_chains: 0,
      get_chain: 2,
      get_profile: 1,
      get_profile_chains: 1,
      get_provider: 3,
      get_provider_ids: 2,
      get_providers: 2,
      list_chains: 0,
      list_chains_for_profile: 1,
      list_profiles: 0,
      list_profiles_for_chain: 1,
      load_all_profiles: 0,
      register_chain_runtime: 3,
      register_provider_runtime: 3,
      reload: 0,
      status: 0,
      unregister_chain_runtime: 2,
      unregister_provider_runtime: 3
    ],
    Lasso.Providers => [
      add_provider: 2,
      add_provider: 3,
      add_provider: 4,
      get_provider: 2,
      get_provider: 3,
      list_providers: 1,
      list_providers: 2,
      remove_provider: 2,
      remove_provider: 3,
      remove_provider: 4,
      update_provider: 3,
      update_provider: 4,
      update_provider: 5
    ],
    TransportRegistry => [
      close_channel: 3,
      close_channel: 4,
      get_candidate_channels: 1,
      get_candidate_channels: 2,
      get_candidate_channels: 3,
      get_channel: 4,
      get_channel: 5,
      initialize_provider_channels: 3,
      initialize_provider_channels: 4,
      list_provider_channels: 2,
      list_provider_channels: 3,
      refresh_capabilities: 3,
      refresh_capabilities: 4,
      start_link: 1,
      via_name: 1,
      via_name: 2
    ]
  }

  setup do
    chain_id = 991_337

    :ok =
      ConfigStore.register_chain_runtime("public", chain_id, %{
        name: "Compatibility Chain",
        url_aliases: ["compatibility-chain"],
        providers: []
      })

    on_exit(fn -> ConfigStore.unregister_chain_runtime("public", chain_id) end)
    {:ok, chain_id: chain_id}
  end

  test "legacy callable exports remain available" do
    for {module, exports} <- @legacy_exports,
        {:module, ^module} = Code.ensure_loaded(module),
        {function, arity} <- exports do
      assert function_exported?(module, function, arity),
             "expected #{inspect(module)}.#{function}/#{arity} to remain exported"
    end

    assert {:module, File} = Code.ensure_loaded(File)
    assert function_exported?(File, :load, 2)
  end

  test "legacy ConfigStore path startup remains accepted" do
    assert {:ok, state} = ConfigStore.init("config/chains.yml")
    assert state.backend_module == File
    assert state.backend_config[:legacy_config_path] == "config/chains.yml"
  end

  test "legacy chain names remain available on ChainConfig", %{chain_id: chain_id} do
    config = %ChainConfig{name: "Legacy Name", display_name: "Legacy Name"}
    assert config.name == config.display_name

    assert {:ok, loaded} = ConfigStore.get_chain("public", chain_id)
    assert loaded.name == loaded.display_name
  end

  test "legacy runtime chain registration retains its chain alias" do
    chain_id = 991_339

    assert :ok =
             ConfigStore.register_chain_runtime("public", "legacy-runtime", %{
               chain_id: chain_id,
               name: "Legacy Runtime Display",
               providers: []
             })

    on_exit(fn -> ConfigStore.unregister_chain_runtime("public", chain_id) end)

    assert {:ok, ^chain_id} =
             ConfigStore.lookup_chain_id_in_profile("public", "legacy-runtime")

    assert {:ok, "legacy-runtime"} = ConfigStore.find_chain_name_by_id(chain_id)
  end

  test "standalone legacy TransportRegistry startup remains reachable by chain name" do
    chain_id = 991_338
    chain_name = "standalone-legacy-chain"

    assert {:ok, pid} = TransportRegistry.start_link({chain_name, %{chain_id: chain_id}})
    assert GenServer.whereis(TransportRegistry.via_name(chain_name)) == pid
    GenServer.stop(pid)
  end

  test "legacy chain lookup and transport registry names resolve through loaded aliases", %{
    chain_id: chain_id
  } do
    assert {:ok, ^chain_id} =
             ConfigStore.lookup_chain_id_in_profile("public", "compatibility-chain")

    assert {:ok, "compatibility-chain"} = ConfigStore.find_chain_name_by_id(chain_id)

    assert TransportRegistry.via_name("compatibility-chain") ==
             TransportRegistry.via_name("public", chain_id)

    assert TransportRegistry.via_name("default", "compatibility-chain") ==
             TransportRegistry.via_name("public", chain_id)
  end
end

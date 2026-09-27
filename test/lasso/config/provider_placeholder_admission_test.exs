defmodule Lasso.Config.ProviderPlaceholderAdmissionTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Config.ChainConfig
  alias Lasso.Config.ChainConfig.Provider
  alias Lasso.Config.ChainConfig.Websocket
  alias Lasso.Config.ChainConfig.Monitoring
  alias Lasso.Config.ChainConfig.Selection

  test "runtime chain registration rejects unresolved endpoints and credentials without exposing values" do
    chain_id = System.unique_integer([:positive])
    on_exit(fn -> ConfigStore.unregister_chain_runtime("public", chain_id) end)
    generation = ConfigStore.route_generation()

    provider = %{
      id: "sensitive",
      name: "Sensitive",
      url: "https://user:private@rpc.example/${MISSING_URL}",
      api_key: "Bearer private-${MISSING_KEY}",
      headers: %{"X-Tenant" => "private-${MISSING_TENANT}"},
      auth_headers: %{"Authorization" => "private-${MISSING_AUTH}"},
      credentials: %{nested: ["private-${MISSING_NESTED}"]}
    }

    assert {:error, {:unresolved_env_vars, [{"sensitive", issues}]}} =
             ConfigStore.register_chain_runtime("public", chain_id, %{providers: [provider]})

    assert issues == [
             url: ["MISSING_URL"],
             api_key: ["MISSING_KEY"],
             headers: ["MISSING_TENANT"],
             auth_headers: ["MISSING_AUTH"],
             credentials: ["MISSING_NESTED"]
           ]

    refute inspect(issues) =~ "private"
    assert {:error, :not_found} = ConfigStore.get_chain("public", chain_id)
    assert ConfigStore.route_generation() == generation
  end

  test "runtime provider rejection preserves the active chain" do
    chain_id = System.unique_integer([:positive])
    on_exit(fn -> ConfigStore.unregister_chain_runtime("public", chain_id) end)
    assert :ok = ConfigStore.register_chain_runtime("public", chain_id, %{providers: []})
    generation = ConfigStore.route_generation()

    assert {:error, {:unresolved_env_vars, [{"pending", [auth_headers: ["MISSING_AUTH"]]}]}} =
             ConfigStore.register_provider_runtime("public", chain_id, %{
               id: "pending",
               name: "Pending",
               url: "https://rpc.example",
               auth_headers: %{"Authorization" => "Bearer ${MISSING_AUTH}"}
             })

    assert {:ok, %{providers: []}} = ConfigStore.get_chain("public", chain_id)
    assert ConfigStore.route_generation() == generation

    assert :ok =
             ConfigStore.register_provider_runtime("public", chain_id, %{
               id: "ready",
               name: "Ready",
               url: "https://rpc.example",
               auth_headers: %{"Authorization" => "Bearer ready"}
             })

    assert {:ok, %{providers: [%{id: "ready"}]}} = ConfigStore.get_chain("public", chain_id)
  end

  test "profile injection and update reject unresolved credentials before publication" do
    profile_id = "placeholder-profile-#{System.unique_integer([:positive])}"
    chain_id = System.unique_integer([:positive])
    on_exit(fn -> ConfigStore.remove_profile(profile_id) end)

    provider = %Provider{id: "primary", name: "Primary", url: "https://rpc.example"}

    chain = %ChainConfig{
      chain_id: chain_id,
      providers: [provider],
      websocket: %Websocket{subscribe_new_heads: false},
      monitoring: %Monitoring{},
      selection: %Selection{}
    }

    spec = %{
      scope: :system,
      profile_id: profile_id,
      slug: profile_id,
      name: profile_id,
      rps_limit: 100,
      burst_limit: 200,
      unlisted: true,
      chains: %{"main" => chain}
    }

    unresolved = %{
      spec
      | chains: %{
          "main" => %{chain | providers: [%{provider | api_key: "private-${MISSING_KEY}"}]}
        }
    }

    assert {:error, {:unresolved_env_vars, [{"main", [{"primary", [api_key: ["MISSING_KEY"]]}]}]}} =
             ConfigStore.inject_profile(unresolved)

    assert {:error, :not_found} = ConfigStore.get_profile(profile_id)
    assert :ok = ConfigStore.inject_profile(spec)

    assert {:error, {:unresolved_env_vars, [{"main", [{"primary", [api_key: ["MISSING_KEY"]]}]}]}} =
             ConfigStore.update_profile(unresolved)

    assert {:ok, ^chain} = ConfigStore.get_chain(profile_id, chain_id)
  end
end

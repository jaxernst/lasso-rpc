defmodule Lasso.Providers.SharedWSRuntimeTest do
  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.Catalog
  alias Lasso.Providers.InstanceSupervisor

  setup do
    chain = "shared_ws_#{System.unique_integer([:positive])}"
    default_provider_id = "default_ws_#{System.unique_integer([:positive])}"
    premium_provider_id = "premium_ws_#{System.unique_integer([:positive])}"

    default_profile = "default"

    existing_secondary_profile =
      ConfigStore.list_profiles()
      |> Enum.reject(&(&1 == default_profile))
      |> List.first()

    {secondary_profile, created_secondary_profile?} =
      if existing_secondary_profile do
        {existing_secondary_profile, false}
      else
        synthetic = "shared_ws_profile_#{System.unique_integer([:positive])}"
        {synthetic, true}
      end

    chain_config = %{
      chain_id: 0,
      name: chain,
      providers: [],
      websocket: %{
        subscribe_new_heads: true,
        new_heads_timeout_ms: 42_000,
        failover: %{max_backfill_blocks: 32, backfill_timeout_ms: 30_000}
      },
      monitoring: %{probe_interval_ms: 15_000, lag_alert_threshold_blocks: 3}
    }

    provider_common = %{
      name: "Shared WS",
      url: "https://shared-ws.test/http",
      ws_url: "ws://test.local/ws",
      priority: 10
    }

    Application.put_env(:lasso, :ws_client_module, TestSupport.MockWSClient)

    if created_secondary_profile? do
      :ets.insert(:lasso_config_store, {
        {:profile, secondary_profile, :meta},
        %{slug: secondary_profile, name: "Shared WS Test", rps_limit: 1_000, burst_limit: 2_000}
      })

      :ets.insert(:lasso_config_store, {{:profile, secondary_profile, :chains}, %{}})

      profile_list =
        case :ets.lookup(:lasso_config_store, {:profile_list}) do
          [{{:profile_list}, profiles}] -> profiles
          [] -> []
        end

      :ets.insert(
        :lasso_config_store,
        {{:profile_list}, Enum.uniq([secondary_profile | profile_list])}
      )
    end

    :ok = ConfigStore.register_chain_runtime(default_profile, chain, chain_config)
    :ok = ConfigStore.register_chain_runtime(secondary_profile, chain, chain_config)

    :ok =
      ConfigStore.register_provider_runtime(
        default_profile,
        chain,
        Map.put(provider_common, :id, default_provider_id)
      )

    :ok =
      ConfigStore.register_provider_runtime(
        secondary_profile,
        chain,
        Map.put(provider_common, :id, premium_provider_id)
      )

    Catalog.build_from_config()

    on_exit(fn ->
      _ = ConfigStore.unregister_provider_runtime(default_profile, chain, default_provider_id)
      _ = ConfigStore.unregister_provider_runtime(secondary_profile, chain, premium_provider_id)
      _ = ConfigStore.unregister_chain_runtime(default_profile, chain)
      _ = ConfigStore.unregister_chain_runtime(secondary_profile, chain)

      if created_secondary_profile? do
        :ets.delete(:lasso_config_store, {:profile, secondary_profile, :meta})
        :ets.delete(:lasso_config_store, {:profile, secondary_profile, :chains})

        profile_list =
          case :ets.lookup(:lasso_config_store, {:profile_list}) do
            [{{:profile_list}, profiles}] -> List.delete(profiles, secondary_profile)
            [] -> []
          end

        :ets.insert(:lasso_config_store, {{:profile_list}, profile_list})
      end

      Application.delete_env(:lasso, :ws_client_module)
      Catalog.build_from_config()
    end)

    %{
      chain: chain,
      default_profile: default_profile,
      premium_profile: secondary_profile,
      default_provider_id: default_provider_id,
      premium_provider_id: premium_provider_id
    }
  end

  test "starts one shared WS connection and fans out profile-local events", ctx do
    default_provider_id = ctx.default_provider_id
    premium_provider_id = ctx.premium_provider_id

    default_instance_id =
      Catalog.lookup_instance_id(ctx.default_profile, ctx.chain, ctx.default_provider_id)

    premium_instance_id =
      Catalog.lookup_instance_id(ctx.premium_profile, ctx.chain, ctx.premium_provider_id)

    assert is_binary(default_instance_id)
    assert default_instance_id == premium_instance_id

    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{ctx.default_profile}:#{ctx.chain}")
    Phoenix.PubSub.subscribe(Lasso.PubSub, "ws:conn:#{ctx.premium_profile}:#{ctx.chain}")

    {:ok, supervisor_pid} =
      DynamicSupervisor.start_child(
        Lasso.Providers.InstanceDynamicSupervisor,
        {InstanceSupervisor, default_instance_id}
      )

    assert_receive {:ws_connected, ^default_provider_id, _connection_id}, 2_000
    assert_receive {:ws_connected, ^premium_provider_id, _connection_id}, 2_000

    assert [{shared_ws_pid, _}] =
             Registry.lookup(Lasso.Registry, {:ws_conn_instance, default_instance_id})

    assert Process.alive?(shared_ws_pid)
    assert Process.alive?(supervisor_pid)

    assert Registry.lookup(Lasso.Registry, {
             :ws_conn,
             ctx.default_profile,
             ctx.chain,
             ctx.default_provider_id
           }) == []

    assert Registry.lookup(Lasso.Registry, {
             :ws_conn,
             ctx.premium_profile,
             ctx.chain,
             ctx.premium_provider_id
           }) == []
  end
end

defmodule Lasso.RPC.RouteGenerationIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration

  test "selection-owned generation rebinds an unchanged cached physical channel",
       %{
         chain: chain
       } do
    before_publication = Lasso.Config.ConfigStore.route_generation()

    setup_providers([%{id: "first", priority: 10, behavior: :healthy}])
    first_publication = Lasso.Config.ConfigStore.route_generation()
    assert first_publication > before_publication

    assert {:ok, existing} =
             Lasso.RPC.TransportRegistry.get_channel("public", chain, "first", :http)

    assert existing.route_generation == first_publication

    setup_providers([%{id: "second", priority: 20, behavior: :healthy}])
    second_publication = Lasso.Config.ConfigStore.route_generation()
    assert second_publication > first_publication

    assert {:ok, retained} =
             Lasso.RPC.TransportRegistry.get_channel("public", chain, "first", :http)

    assert retained.route_generation == first_publication

    snapshot = Lasso.Providers.Catalog.snapshot()
    instance_id = Lasso.Providers.Catalog.lookup_instance_id("public", chain, "first")
    assert {:ok, instance} = Lasso.Providers.Catalog.get_instance(snapshot, instance_id)

    assert {:ok, rebound} =
             Lasso.RPC.TransportRegistry.get_channel("public", chain, "first", :http,
               provider_config: instance,
               instance_id: instance_id,
               route_generation: second_publication
             )

    assert rebound.route_generation == second_publication
    assert rebound.instance_id == retained.instance_id
    assert rebound.raw_channel == retained.raw_channel
    assert existing.route_generation == first_publication

    changed_identity =
      Map.put(instance.identity_config, :url, "http://mock-first-replaced.test")

    changed_config =
      Map.merge(instance, %{
        url: "http://mock-first-replaced.test",
        identity_config: changed_identity,
        __mock__: true
      })

    changed_instance_id =
      Lasso.Providers.InstanceId.derive(chain, changed_identity,
        profile_id: "public",
        sharing_mode: :shared
      )

    assert changed_instance_id != instance_id

    assert {:ok, replaced} =
             Lasso.RPC.TransportRegistry.get_channel("public", chain, "first", :http,
               provider_config: changed_config,
               instance_id: changed_instance_id,
               route_generation: second_publication
             )

    assert replaced.instance_id == changed_instance_id
    assert replaced.route_generation == second_publication
    assert replaced.raw_channel != retained.raw_channel
  end
end

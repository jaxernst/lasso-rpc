defmodule Lasso.RPC.RouteGenerationIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration

  test "configuration publication advances generation while existing channels remain immutable",
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
  end
end

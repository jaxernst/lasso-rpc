defmodule Lasso.RPC.HttpInclusionWithWsDisconnectIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration
  @moduletag timeout: 10_000

  alias Lasso.RPC.{RequestPipeline, ProviderPool, RequestOptions}

  test "WS disconnect does not exclude provider from HTTP selection", %{chain: chain} do
    profile = "default"

    setup_providers([
      %{id: "dual", priority: 10, behavior: :healthy, profile: profile}
    ])

    # Simulate WS closed event for the provider using the tuple form
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "ws:conn:#{profile}:#{chain}",
      {:ws_closed, "dual", 1006, %Lasso.JSONRPC.Error{message: "test", code: -32_000}}
    )

    Process.sleep(50)

    # Should still be able to make unary HTTP request
    {:ok, _result, _ctx} =
      RequestPipeline.execute_via_channels(
        chain,
        "eth_blockNumber",
        [],
        %RequestOptions{transport: :http, strategy: :round_robin, timeout_ms: 30_000}
      )

    # HTTP candidates should include the provider
    http_candidates = ProviderPool.list_candidates("default", chain, %{protocol: :http})
    assert Enum.any?(http_candidates, &(&1.id == "dual"))

    {:ok, status} = ProviderPool.get_status("default", chain)
    p = Enum.find(status.providers, &(&1.id == "dual"))
    # WS status may be :disconnected or still :connecting depending on background ws init timing
    assert p.ws_status in [:disconnected, :connecting]
  end
end

defmodule Lasso.RPC.RequestContextTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.{BoundedIdentifier, Channel, RequestContext, RequestOptions}

  test "typed options initialize a bounded request context directly" do
    request_id = String.duplicate("request-id", 100)
    plug_start = System.monotonic_time(:microsecond)

    context =
      RequestContext.new(1, "eth_chainId", [], %RequestOptions{
        timeout_ms: 100,
        request_id: request_id,
        transport: nil,
        strategy: :fastest,
        plug_start_time: plug_start
      })

    assert context.request_id == BoundedIdentifier.encode(request_id)
    assert context.transport == :http
    assert context.strategy == :fastest
    assert context.start_time == plug_start
    assert context.plug_start_time == plug_start
  end

  test "selection stores a bounded channel identity before any attempt executes" do
    provider_id = String.duplicate("provider-a", 32)

    channel = %Channel{
      profile: "public",
      chain_id: 1,
      provider_id: provider_id,
      instance_id: "instance-a",
      route_generation: 3,
      transport: :http,
      raw_channel: :unused,
      transport_module: __MODULE__,
      capabilities: nil
    }

    context =
      1
      |> RequestContext.new("eth_chainId", [])
      |> RequestContext.mark_selection_end(selected: channel)

    assert context.selected_provider == %{
             id: BoundedIdentifier.encode(provider_id),
             protocol: :http
           }
  end
end

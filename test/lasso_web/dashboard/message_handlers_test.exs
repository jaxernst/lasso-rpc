defmodule LassoWeb.Dashboard.MessageHandlersTest do
  use ExUnit.Case, async: true

  test "subscription events use the dashboard chain identity in both feeds" do
    event = %Lasso.Events.Subscription.Established{
      chain_id: 1,
      provider_id: "local",
      subscription_type: :new_heads,
      ts: System.system_time(:millisecond)
    }

    socket =
      Phoenix.Component.assign(%Phoenix.LiveView.Socket{},
        profile_chains: [1],
        routing_events: []
      )

    socket =
      LassoWeb.Dashboard.MessageHandlers.handle_subscription_event(event, socket, fn socket,
                                                                                     entry ->
        Phoenix.Component.assign(socket, :event, entry)
      end)

    assert [%{chain: 1, type: :ws_lifecycle}] = socket.assigns.routing_events
    assert socket.assigns.event.chain == 1
  end
end

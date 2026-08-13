defmodule Lasso.RPC.ChannelTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.Channel

  test "channel incarnations retain an explicitly published route generation" do
    first =
      Channel.new("public", 1, "provider", :http, %{}, Lasso.RPC.Transports.HTTP,
        instance_id: "shared",
        route_generation: 41
      )

    replacement =
      Channel.new("public", 1, "provider", :http, %{}, Lasso.RPC.Transports.HTTP,
        instance_id: "shared",
        route_generation: 42
      )

    assert first.route_generation == 41
    assert replacement.route_generation == 42
  end

  test "explicit endpoint identity is authoritative over catalog state" do
    channel =
      Channel.new(
        "public",
        1,
        "provider",
        :http,
        %{url: "https://old.example"},
        Lasso.RPC.Transports.HTTP,
        instance_id: "old-endpoint-instance"
      )

    assert channel.instance_id == "old-endpoint-instance"
  end
end

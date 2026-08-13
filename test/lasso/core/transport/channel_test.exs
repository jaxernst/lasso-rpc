defmodule Lasso.RPC.ChannelTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.Channel

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

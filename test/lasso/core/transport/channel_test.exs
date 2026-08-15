defmodule Lasso.RPC.ChannelTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.{Channel, PreparedRequest}

  defmodule LegacyTransport do
    def request(_raw_channel, rpc_request, timeout), do: {:ok, {rpc_request, timeout}, 0}
  end

  defmodule PreparedTransport do
    def request_prepared(_raw_channel, prepared, timeout), do: {:ok, {prepared, timeout}, 0}
  end

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

  test "legacy transports receive a task-local request with the original client id" do
    channel = channel(LegacyTransport)
    request = %{"jsonrpc" => "2.0", "method" => "eth_call", "params" => [], "id" => nil}
    assert {:ok, prepared} = PreparedRequest.new(request, "lasso-channel-legacy")

    assert {:ok, {%{"id" => nil, "method" => "eth_call"}, 25}, 0} =
             Channel.request(channel, prepared, 25)
  end

  test "prepared transports receive the exact prepared value" do
    channel = channel(PreparedTransport)
    request = %{"jsonrpc" => "2.0", "method" => "eth_call", "params" => [], "id" => 7}
    assert {:ok, prepared} = PreparedRequest.new(request, "lasso-channel-prepared")

    assert {:ok, {received, 25}, 0} = Channel.request(channel, prepared, 25)
    assert received === prepared
    assert :erts_debug.same(received.encoded, prepared.encoded)
  end

  defp channel(transport_module) do
    %Channel{
      profile: "public",
      chain_id: 1,
      provider_id: "provider",
      instance_id: "instance",
      route_generation: 1,
      transport: :http,
      raw_channel: :raw,
      transport_module: transport_module
    }
  end
end

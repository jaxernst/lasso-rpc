defmodule Lasso.RPC.Providers.AdapterFilterTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.Channel
  alias Lasso.RPC.Providers.AdapterFilter

  test "uses capabilities bound to the captured route instead of mutable config" do
    unsupported =
      channel("unsupported", %{unsupported_methods: ["eth_call"]})

    supported = channel("supported", nil)

    assert {:ok, [^supported], [^unsupported]} =
             AdapterFilter.filter_channels([unsupported, supported], "eth_call")
  end

  test "uses bound capability limits during parameter validation" do
    channel = channel("limited", %{limits: %{max_block_range: 2}})

    params = [%{"fromBlock" => "0x1", "toBlock" => "0x4"}]

    assert {:error, {:param_limit, "max 2 block range (got 3)"}} =
             AdapterFilter.validate_params(channel, "eth_getLogs", params)
  end

  defp channel(provider_id, capabilities) do
    %Channel{
      profile: "missing-profile",
      chain_id: 1,
      provider_id: provider_id,
      instance_id: provider_id,
      route_generation: 1,
      transport: :http,
      provider_capabilities: capabilities
    }
  end
end

defmodule Lasso.Harness.HistoricalRetentionTest do
  use ExUnit.Case, async: false
  alias Lasso.Events.HeadObserved
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-routing-11"]
  @address "0x1111111111111111111111111111111111111111"
  @head "0x2710"
  @old "0x25e4"
  # Geth's hash-scheme refusal for a state root outside its 128 retained layers.
  @pruned "missing trie node 9c2b0d3a6e5f41c7b8a9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5 (path ) state 0x9c2b0d3a6e5f41c7b8a9d0e1f2a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5 is not available"

  test "a 300-block-old state read reaches the archive behind three pruned full nodes, then tries it first; block and log reads stay on the full nodes" do
    fleets =
      for name <- ["full-a", "full-b", "full-c", "archive"],
          do: Fleet.start!(self(), "#{name}-#{System.unique_integer([:positive])}")

    [full_a | _] = fleets
    {full_nodes, [archive]} = Enum.split(fleets, 3)

    try do
      for fleet <- fleets, do: Fleet.script(fleet, "eth_blockNumber", [], {:answer, @head})
      tenant = Tenant.open!(fleets)

      try do
        observe_heads(tenant, fleets)

        for fleet <- full_nodes,
            do: Fleet.script(fleet, "eth_getBalance", [], {:error, -32_000, @pruned})

        Fleet.script(archive, "eth_getBalance", [], {:answer, "0x20"})

        # A pruned-state refusal to a past-block state read spends no dispatch, so the first
        # read walks past every full node to the archive.
        {response, sends} = call(tenant, fleets, "eth_getBalance", [@address, @old])
        assert %{status: 200, body: %{"result" => "0x20"}} = response
        assert Enum.map(sends, & &1.fleet) == Enum.map(fleets, & &1.name)

        # Repeated refusals form each full node's learned state cutoff, and later reads of
        # that state try the archive first.
        Settle.await("state reads try the archive first", fn ->
          case call(tenant, fleets, "eth_getBalance", [@address, @old]) do
            {%{body: %{"result" => "0x20"}}, [%{fleet: first}]} when first == archive.name ->
              {:ok, :learned}

            {response, sends} ->
              assert response.body["result"] == "0x20"
              Enum.map(sends, & &1.fleet)
          end
        end)

        # The cutoff belongs to the state class, not the method, so an eth_call of the same
        # past state also tries the archive first.
        for fleet <- full_nodes,
            do: Fleet.script(fleet, "eth_call", [], {:error, -32_000, @pruned})

        Fleet.script(archive, "eth_call", [], {:answer, "0x"})
        call_params = [%{"to" => @address, "data" => "0x70a08231"}, @old]
        {response, sends} = call(tenant, fleets, "eth_call", call_params)
        assert %{status: 200, body: %{"result" => "0x"}} = response
        assert Enum.map(sends, & &1.fleet) == [archive.name]

        # Blocks and logs are a different class, so they stay on the first full node.
        block = %{number: @old, hash: "0x" <> String.duplicate("c", 64), transactions: []}
        Fleet.script(full_a, "eth_getBlockByNumber", [{:answer, block}])
        {response, sends} = call(tenant, fleets, "eth_getBlockByNumber", [@old, false])
        assert %{status: 200, body: %{"result" => %{"number" => @old}}} = response
        assert Enum.map(sends, & &1.fleet) == [full_a.name]

        logs = [%{"fromBlock" => @old, "toBlock" => @old}]
        Fleet.script(full_a, "eth_getLogs", [{:answer, []}])
        {response, sends} = call(tenant, fleets, "eth_getLogs", logs)
        assert %{status: 200, body: %{"result" => []}} = response
        assert Enum.map(sends, & &1.fleet) == [full_a.name]
      after
        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  defp observe_heads(tenant, fleets) do
    topic = Lasso.Topics.block_sync(tenant.profile, 31_337)
    :ok = Phoenix.PubSub.subscribe(Lasso.PubSub, topic)
    profile = tenant.profile

    try do
      for fleet <- fleets do
        provider = fleet.name
        {response, _sends} = call(tenant, fleets, "eth_blockNumber", [], provider)
        assert response.body["result"] == @head
        assert_receive %HeadObserved{profile: ^profile, provider_id: ^provider}
      end
    after
      Phoenix.PubSub.unsubscribe(Lasso.PubSub, topic)
    end
  end

  defp call(tenant, fleets, method, params, provider \\ nil) do
    query = if provider, do: "?provider_override=" <> provider, else: ""

    Settle.closed(
      fn -> Rpc.call(%{rpc_url: tenant.rpc_url <> query}, method, params) end,
      fleets,
      %{method: method, params: params}
    )
  end
end

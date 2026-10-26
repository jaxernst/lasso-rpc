defmodule Lasso.Harness.DepthDeclarationsTest do
  use ExUnit.Case, async: false

  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-depth-declarations-1"]
  @address "0x0000000000000000000000000000000000000001"

  test "a file-profile depth declaration outranks retained historical learning" do
    fleets = for name <- ["depth-primary", "depth-backup"], do: Fleet.start!(self(), name)
    [primary, backup] = fleets

    try do
      tenant = Tenant.open!(fleets)

      try do
        owners = Tenant.serving_owners()
        method = "eth_getBalance"
        params = [@address, "0x1"]
        for fleet <- fleets, do: call(tenant, fleets, "eth_blockNumber", [], fleet.name)
        Fleet.script(primary, method, [], {:error, -32_000, "missing trie node"})
        Fleet.script(backup, method, [], {:answer, "0x10"})
        for _ <- 1..4, do: call(tenant, fleets, method, params, primary.name)

        hint =
          Settle.await("historical hint visible", fn ->
            case depth_hint(tenant, primary) do
              nil -> :pending
              hint -> {:ok, hint}
            end
          end)

        {response, sends} = call(tenant, fleets, method, params)
        assert response.body["result"] == "0x10"

        expected =
          if System.get_env("LASSO_PROVIDER_KNOWLEDGE_HISTORICAL_DEPTH_MODE") == "off",
            do: [primary.name, backup.name],
            else: [backup.name]

        assert Enum.map(sends, & &1.fleet) == expected

        Tenant.replace!(tenant, fleets,
          providers: %{
            primary.name => %{
              "capabilities" => %{
                "limits" => %{"max_block_age" => 10_000, "block_age_methods" => [method]}
              }
            }
          }
        )

        assert depth_hint(tenant, primary)["value"] == hint["value"]
        Fleet.script(primary, method, [], {:answer, "0x10"})
        {response, sends} = call(tenant, fleets, method, params)
        assert response.body["result"] == "0x10"
        assert Enum.map(sends, & &1.fleet) == [primary.name]
        uri = URI.parse(tenant.rpc_url)

        assert {:ok, %{status: 200}} =
                 Finch.build(:get, "#{uri.scheme}://#{uri.host}:#{uri.port}/api/health")
                 |> Finch.request(Lasso.Finch)

        for {name, pid} <- owners do
          assert is_pid(pid)
          assert Process.whereis(name) == pid
        end
      after
        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  defp depth_hint(tenant, fleet) do
    Enum.find(Tenant.knowledge!(tenant, fleet), fn hint ->
      hint["kind"] == "historical_depth" and hint["source"] == "learned"
    end)
  end

  defp call(tenant, fleets, method, params, provider \\ nil) do
    query = if provider, do: "?provider_override=" <> provider, else: ""

    Settle.closed(
      fn -> Rpc.call(%{rpc_url: tenant.rpc_url <> query}, method, params) end,
      fleets,
      %{
        method: method,
        params: params
      }
    )
  end
end

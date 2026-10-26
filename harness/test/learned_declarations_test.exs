defmodule Lasso.Harness.LearnedDeclarationsTest do
  use ExUnit.Case, async: false

  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-learned-declarations-1"]
  @address "0x0000000000000000000000000000000000000001"

  test "published span and method declarations preserve learned evidence and control routing" do
    for {kind, method, params, failure, limits} <- [
          {"span_limit", "eth_getLogs",
           [%{"fromBlock" => "0x1", "toBlock" => "0x2bd", "address" => @address}],
           {:error, -32_600, "You can make eth_getLogs requests with up to a 500 block range"},
           %{"logs_span" => 10_000}},
          {"method_refusal", "eth_getCode", [@address, "latest"],
           {:error, -32_601, "method not found"}, %{"methods_blocked" => ["eth_getCode"]}}
        ] do
      journey(fn tenant, [primary, backup] = fleets ->
        owners = Tenant.serving_owners()
        Fleet.script(primary, method, [], failure)
        answer = if method == "eth_getLogs", do: [], else: "0x10"
        Fleet.script(backup, method, [], {:answer, answer})

        learning_params =
          if kind == "span_limit",
            do: [%{"fromBlock" => "0x1", "toBlock" => "0x1f5", "address" => @address}],
            else: params

        for _ <- 1..4, do: call(tenant, fleets, method, learning_params, primary.name)

        hint =
          Settle.await("learned #{kind} visible", fn ->
            case learned_hint(tenant, primary, kind) do
              nil -> :pending
              hint -> {:ok, hint}
            end
          end)

        if kind == "span_limit", do: assert(hint["value"] == 500)
        {response, sends} = call(tenant, fleets, method, params)
        assert response.body["result"] == answer
        env = "LASSO_PROVIDER_KNOWLEDGE_#{String.upcase(kind)}_MODE"

        expected =
          if System.get_env(env) == "off", do: [primary.name, backup.name], else: [backup.name]

        assert Enum.map(sends, & &1.fleet) == expected

        Tenant.replace!(tenant, fleets, providers: %{primary.name => %{"limits" => limits}})
        retained = learned_hint(tenant, primary, kind)
        assert retained["value"] == hint["value"]
        assert retained["source"] == "learned"
        Fleet.script(primary, method, [], {:answer, answer})
        {response, sends} = call(tenant, fleets, method, params)
        assert response.body["result"] == answer
        expected = if kind == "method_refusal", do: [backup.name], else: [primary.name]
        assert Enum.map(sends, & &1.fleet) == expected
        assert_serving(tenant, owners)
      end)
    end
  end

  test "malformed capability lists cannot replace a live profile or stop healthy routing" do
    for capabilities <- [
          %{"unsupported_methods" => nil},
          %{"unsupported_methods" => "eth_getCode"},
          %{"unsupported_categories" => nil},
          %{"unsupported_categories" => "state"},
          %{"limits" => %{"max_block_age" => 100, "block_age_methods" => nil}},
          %{"limits" => %{"block_age_methods" => "eth_getCode"}},
          %{"error_rules" => nil}
        ] do
      journey(fn tenant, [healthy, malformed] = fleets ->
        owners = Tenant.serving_owners()

        Tenant.reject_replace!(tenant, fleets,
          providers: %{malformed.name => %{"capabilities" => capabilities}}
        )

        {response, sends} = call(tenant, fleets, "eth_getCode", [@address, "latest"])
        assert response.body["result"] == "0x10"
        assert Enum.map(sends, & &1.fleet) == [healthy.name]
        assert_serving(tenant, owners)
      end)
    end
  end

  defp learned_hint(tenant, fleet, kind) do
    Enum.find(Tenant.knowledge!(tenant, fleet), fn hint ->
      hint["kind"] == kind and hint["source"] == "learned" and hint["transport"] == "http"
    end)
  end

  defp journey(run) do
    fleets = for name <- ["declared-primary", "declared-backup"], do: Fleet.start!(self(), name)

    try do
      tenant = Tenant.open!(fleets)

      try do
        run.(tenant, fleets)
      after
        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  defp assert_serving(tenant, owners) do
    uri = URI.parse(tenant.rpc_url)

    assert {:ok, %{status: 200}} =
             Finch.build(:get, "#{uri.scheme}://#{uri.host}:#{uri.port}/api/health")
             |> Finch.request(Lasso.Finch)

    for {name, pid} <- owners do
      assert is_pid(pid)
      assert Process.whereis(name) == pid
    end
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

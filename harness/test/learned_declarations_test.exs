defmodule Lasso.Harness.LearnedDeclarationsTest do
  use ExUnit.Case, async: false

  alias Lasso.Events.HeadObserved
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.ProviderKnowledge
  alias Lasso.RPC.TransportRegistry
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-learned-declarations-1"]
  @address "0x0000000000000000000000000000000000000001"

  test "republished declarations outrank retained learned span, depth and method hints" do
    for {kind, method, params, failure, capabilities} <- [
          {:span_limit, "eth_getLogs",
           [%{"fromBlock" => "0x1", "toBlock" => "0x2bd", "address" => @address}],
           {:error, -32_600, "You can make eth_getLogs requests with up to a 500 block range"},
           %{"limits" => %{"max_block_range" => 10_000}}},
          {:historical_depth, "eth_getBalance", [@address, "0x1"],
           {:error, -32_000, "missing trie node"},
           %{"limits" => %{"max_block_age" => 10_000, "block_age_methods" => ["eth_getBalance"]}}},
          {:method_refusal, "eth_getCode", [@address, "latest"],
           {:error, -32_601, "method not found"}, %{"unsupported_methods" => ["eth_getCode"]}}
        ] do
      fleets = for name <- ["declared-primary", "declared-backup"], do: Fleet.start!(self(), name)
      [primary, backup] = fleets

      try do
        tenant = Tenant.open!(fleets)

        try do
          owners = Tenant.serving_owners()
          if kind == :historical_depth, do: observe_heads(tenant, fleets)
          Fleet.script(primary, method, [], failure)
          answer = if method == "eth_getLogs", do: [], else: "0x10"
          Fleet.script(backup, method, [], {:answer, answer})
          subject = subject(tenant, primary)
          scope = scope(tenant, subject, method)

          learning_params =
            if kind == :span_limit,
              do: [%{"fromBlock" => "0x1", "toBlock" => "0x1f5", "address" => @address}],
              else: params

          for _ <- 1..4 do
            call(tenant, fleets, method, learning_params, primary.name)
          end

          Settle.await("learned #{kind} published", fn -> hint(scope, kind, method) end)
          if kind == :span_limit, do: assert({:ok, %{value: 500}} = hint(scope, kind, method))
          {response, sends} = call(tenant, fleets, method, params)
          assert response.body["result"] == answer
          env = "LASSO_PROVIDER_KNOWLEDGE_#{kind |> Atom.to_string() |> String.upcase()}_MODE"

          expected =
            if System.get_env(env) == "off", do: [primary.name, backup.name], else: [backup.name]

          assert Enum.map(sends, & &1.fleet) == expected

          Tenant.declare_capabilities!(tenant, primary, capabilities)
          assert subject(tenant, primary) == subject
          assert {:ok, %{source: :local}} = hint(scope, kind, method)
          Fleet.script(primary, method, [], {:answer, answer})
          {response, sends} = call(tenant, fleets, method, params)
          assert response.body["result"] == answer
          expected = if kind == :method_refusal, do: [backup.name], else: [primary.name]
          assert Enum.map(sends, & &1.fleet) == expected

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
  end

  defp subject(tenant, fleet) do
    {:ok, plan} = Catalog.get_routing_plan(Catalog.snapshot(), tenant.profile, 31_337)
    provider = Enum.find(plan.providers, &(&1.id == fleet.name))
    TransportRegistry.learning_subject_for(tenant.profile, 31_337, :http, provider.config)
  end

  defp scope(tenant, subject, method) do
    %{
      subject: subject.id,
      profile: tenant.profile,
      chain_id: 31_337,
      method: method,
      partition: Lasso.RPC.RoutingEvidence.Workload.for_request(:client, method)
    }
  end

  defp hint(scope, :span_limit, _method), do: ProviderKnowledge.span_limit(scope, :logs)

  defp hint(scope, :historical_depth, _method),
    do: ProviderKnowledge.historical_depth(scope, :balance)

  defp hint(scope, :method_refusal, method), do: ProviderKnowledge.method_refusal(scope, method)

  defp observe_heads(tenant, fleets) do
    topic = Lasso.Topics.block_sync(tenant.profile, 31_337)
    :ok = Phoenix.PubSub.subscribe(Lasso.PubSub, topic)

    try do
      for fleet <- fleets do
        call(tenant, fleets, "eth_blockNumber", [], fleet.name)
        profile = tenant.profile
        provider = fleet.name
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
      %{
        method: method,
        params: params
      }
    )
  end
end

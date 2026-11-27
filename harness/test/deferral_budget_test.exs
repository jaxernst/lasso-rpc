defmodule Lasso.Harness.DeferralBudgetTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-routing-12"]
  @address "0x0000000000000000000000000000000000000001"
  @declined {:error, -32_000, "upstream could not serve this request"}

  test "a route deferred for a method refusal still serves once its peers fail" do
    with_fleets(fn tenant, [first | peers] = fleets ->
      method = "eth_getCode"

      learn(tenant, fleets, first, method, fn -> [@address, "latest"] end, %{
        failure: {:error, -32_601, "method not found"},
        kind: "method_refusal"
      })

      Fleet.script(first, method, [], {:answer, "0x11"})
      for peer <- peers, do: Fleet.script(peer, method, [], @declined)

      for _ <- 1..10 do
        {response, _sends} = call(tenant, fleets, method, [unique_address(), "latest"])
        assert %{"result" => "0x11"} = response.body
      end
    end)
  end

  test "a route deferred for a span limit still serves once its peers fail" do
    with_fleets(fn tenant, [first | peers] = fleets ->
      method = "eth_getLogs"

      params = fn ->
        [%{"fromBlock" => "0x1", "toBlock" => "0x1f4", "address" => unique_address()}]
      end

      learn(tenant, fleets, first, method, params, %{
        failure:
          {:error, -32_600, "You can make eth_getLogs requests with up to a 10 block range"},
        kind: "span_limit"
      })

      Fleet.script(first, method, [], {:answer, []})
      for peer <- peers, do: Fleet.script(peer, method, [], @declined)

      for _ <- 1..10 do
        {response, _sends} = call(tenant, fleets, method, params.())
        assert %{"result" => []} = response.body
      end
    end)
  end

  # The first route fails the method pinned to it until its knowledge report
  # carries the learned deferral.
  defp learn(tenant, fleets, first, method, params, %{failure: failure, kind: kind}) do
    Fleet.script(first, method, [], failure)

    for _ <- 1..4 do
      call(tenant, fleets, method, params.(), first.name)
      settle()
    end

    Settle.await("#{kind} learned", fn ->
      if Enum.any?(Tenant.knowledge!(tenant, first), &(&1["kind"] == kind)),
        do: {:ok, :learned},
        else: :pending
    end)
  end

  defp settle do
    Settle.await("learned feedback applied", fn ->
      case Lasso.Core.ProjectionDispatcher.stats(
             Lasso.ExecutionProjectionDispatcher,
             :learned_feedback
           ) do
        %{retained_items: 0} -> {:ok, :drained}
        stats -> stats
      end
    end)
  end

  defp call(tenant, fleets, method, params, provider \\ nil) do
    query = if provider, do: "?provider_override=" <> provider, else: ""

    Settle.closed(
      fn -> Rpc.call(%{rpc_url: tenant.rpc_url <> query}, method, params) end,
      fleets,
      %{method: method, params: params}
    )
  end

  defp unique_address do
    "0x" <>
      (System.unique_integer([:positive])
       |> Integer.to_string(16)
       |> String.pad_leading(40, "0"))
  end

  defp with_fleets(scenario) do
    fleets = for name <- ~w(budget-a budget-b budget-c budget-d), do: Fleet.start!(self(), name)

    try do
      tenant = Tenant.open!(fleets)

      try do
        scenario.(tenant, fleets)
      after
        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end
end

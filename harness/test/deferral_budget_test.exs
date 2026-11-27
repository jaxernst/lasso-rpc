defmodule Lasso.Harness.DeferralBudgetTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-routing-12"]
  @declined {:error, -32_000, "upstream could not serve this request"}
  @refusal {:error, -32_601, "method not found"}
  @span_refusal {:error, -32_600, "You can make eth_getLogs requests with up to a 10 block range"}

  test "a route held back by a learned refusal serves once its only peer fails" do
    with_fleets(2, fn tenant, [refuser, peer] = fleets ->
      learn(tenant, fleets, refuser, "eth_getCode", @refusal, "method_refusal")
      Fleet.script(refuser, "eth_getCode", [], {:answer, "0x11"})
      Fleet.script(peer, "eth_getCode", [], @declined)

      {response, sends} = call(tenant, fleets, "eth_getCode", params("eth_getCode"))
      assert %{"result" => "0x11"} = response.body
      assert Enum.sort(Enum.map(sends, & &1.fleet)) == Enum.sort([refuser.name, peer.name])
    end)
  end

  test "a route held back by a learned refusal keeps time to serve after its peer hangs" do
    previous = Application.get_env(:lasso, :method_timeouts, %{})
    Application.put_env(:lasso, :method_timeouts, Map.put(previous, "eth_getCode", 1_000))

    try do
      with_fleets(2, fn tenant, [refuser, peer] = fleets ->
        learn(tenant, fleets, refuser, "eth_getCode", @refusal, "method_refusal")
        Fleet.script(refuser, "eth_getCode", [], {:answer, "0x11"})

        # A rate limit queues the peer behind the closed routes, so the cursor
        # has already set the refusing route aside when the peer is sent.
        Fleet.script(peer, "eth_getCode", [], {:status, 429, [{"retry-after", "30"}], ""})
        call(tenant, fleets, "eth_getCode", params("eth_getCode"), peer.name)
        Fleet.script(peer, "eth_getCode", [], {:respond, fn _ -> {:hold, make_ref()} end})

        {response, sends} = call(tenant, fleets, "eth_getCode", params("eth_getCode"))
        assert %{"result" => "0x11"} = response.body
        assert Enum.sort(Enum.map(sends, & &1.fleet)) == Enum.sort([refuser.name, peer.name])
      end)
    after
      Application.put_env(:lasso, :method_timeouts, previous)
    end
  end

  test "routes learned to refuse stay behind every ordinary route" do
    for {method, refusal, kind, answer} <- [
          {"eth_getCode", @refusal, "method_refusal", "0x11"},
          {"eth_getLogs", @span_refusal, "span_limit", []}
        ] do
      with_fleets(6, fn tenant, [a, b, c, d | serving] = fleets ->
        for refuser <- [a, b], do: learn(tenant, fleets, refuser, method, refusal, kind)

        for failing <- [c, d],
            do: Fleet.script(failing, method, [], {:status, 503, [], "unavailable"})

        for fleet <- serving, do: Fleet.script(fleet, method, [], {:answer, answer})

        for _ <- 1..3 do
          {response, sends} = call(tenant, fleets, method, params(method))
          assert %{"result" => ^answer} = response.body

          assert Enum.sort(Enum.map(sends, & &1.fleet)) ==
                   Enum.sort([c.name, d.name, hd(serving).name])
        end
      end)
    end
  end

  # Reads pinned to the route fail until its knowledge report carries the hint.
  defp learn(tenant, fleets, fleet, method, refusal, kind) do
    Fleet.script(fleet, method, [], refusal)

    for _ <- 1..4 do
      call(tenant, fleets, method, params(method), fleet.name)

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

    Settle.await("#{kind} learned for #{fleet.name}", fn ->
      if Enum.any?(Tenant.knowledge!(tenant, fleet), &(&1["kind"] == kind)),
        do: {:ok, :learned},
        else: :pending
    end)
  end

  defp params("eth_getCode"), do: [unique_address(), "latest"]

  defp params("eth_getLogs"),
    do: [%{"fromBlock" => "0x1", "toBlock" => "0x1f4", "address" => unique_address()}]

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

  defp with_fleets(count, scenario) do
    fleets = for i <- 1..count, do: Fleet.start!(self(), "budget-#{i}")

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

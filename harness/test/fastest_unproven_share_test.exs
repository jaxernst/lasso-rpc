defmodule Lasso.Harness.FastestUnprovenShareTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-routing-9"]

  @method "eth_getBalance"
  @params ["0x" <> String.duplicate("22", 20), "latest"]

  test "fastest gives an unproven upstream that only returns errors a small share of first picks" do
    fleets = [measured, broken] = Enum.map(["a-measured", "z-broken"], &Fleet.start!(self(), &1))
    tenant = Tenant.open!(fleets)
    fastest = String.replace(tenant.rpc_url, "/priority/", "/fastest/")

    try do
      for _ <- 1..3 do
        {response, [%{fleet: name}]} =
          request(fleets, fastest <> "?provider_override=" <> measured.name)

        assert name == measured.name
        assert response.body["result"] == "0x10"
      end

      # -32000 with unrecognized wording is unclassified, so it records no evidence and the
      # broken upstream stays unproven for the whole run.
      Fleet.script(broken, @method, [], {:error, -32_000, "internal server error"})

      firsts =
        Enum.count(1..200, fn _ ->
          {response, sends} = request(fleets, fastest)
          assert response.body["result"] == "0x10"
          Enum.any?(sends, &(&1.fleet == broken.name))
        end)

      # The broken upstream reaches a read only when it ranks first, and it weighs 1/8 of the
      # only measured one, so each read reaches it with probability 1/9, independently. Its count
      # is Binomial(200, 1/9), which exceeds 53 with probability below 4.4e-10. At the weight of
      # the quickest it would be Binomial(200, 1/2), which stays at or below 53 with probability
      # below 2e-11.
      assert firsts <= 53, "the broken upstream was reached on #{firsts} of 200 reads"
    after
      Tenant.close!(tenant)
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  defp request(fleets, url) do
    Settle.closed(
      fn -> Rpc.call(%{rpc_url: url}, @method, @params) end,
      fleets,
      %{method: @method, params: @params}
    )
  end
end

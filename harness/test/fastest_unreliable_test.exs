defmodule Lasso.Harness.FastestUnreliableTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-routing-8"]

  @method "eth_getBalance"
  @params ["0x" <> String.duplicate("11", 20), "latest"]

  test "fastest tries an untried route before one with recent failures when none is qualified" do
    fleets = [failing, untried] = Enum.map(["a-failing", "z-untried"], &Fleet.start!(self(), &1))
    tenant = Tenant.open!(fleets)
    fastest = String.replace(tenant.rpc_url, "/priority/", "/fastest/")

    try do
      for _ <- 1..3 do
        Fleet.script(failing, @method, [{:status, 503, [], "unavailable"}])

        {response, [%{fleet: name}]} =
          request(fleets, fastest <> "?provider_override=" <> failing.name)

        assert name == failing.name
        assert response.body["error"]
      end

      # The three failures reach the ranking once their evidence is projected.
      response =
        Settle.await("fastest sends to the untried route", fn ->
          with {response, [%{fleet: name}]} <- request(fleets, fastest),
               true <- name == untried.name do
            {:ok, response}
          end
        end)

      assert response.body["result"] == "0x10"
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

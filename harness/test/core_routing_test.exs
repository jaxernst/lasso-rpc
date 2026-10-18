defmodule Lasso.Test.Harness.CoreRoutingTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-routing-1", "core-failover-1"]

  setup do
    # Adapter owns database isolation in Cloud; Core's implementation is a no-op.
    Tenant.isolate!()
    :ok
  end

  test "priority failover preserves JSON-RPC and sends once to each real upstream" do
    fleet = Enum.map(["primary", "alternate"], &Fleet.start!(self(), &1))
    tenant = Tenant.open!(fleet)

    try do
      [primary, _] = fleet
      params = ["0x0000000000000000000000000000000000000001", "pending"]

      {first, first_sends} =
        Settle.closed(
          fn ->
            Rpc.call(Tenant.credentials(tenant), "eth_getBalance", params)
          end,
          fleet,
          %{method: "eth_getBalance", params: params}
        )

      assert %{status: 200, body: %{"result" => "0x10"}} = first
      assert [%{fleet: "primary", transport: :http}] = first_sends

      Fleet.script(primary, "eth_getBalance", [{:status, 503, [], "<html>unavailable</html>"}])
      id = "core-#{System.unique_integer([:positive])}"

      {response, sends} =
        Settle.closed(
          fn ->
            Rpc.call(
              Tenant.credentials(tenant),
              "eth_getBalance",
              ["0x0000000000000000000000000000000000000001", "latest"],
              id: id
            )
          end,
          fleet,
          %{
            method: "eth_getBalance",
            params: ["0x0000000000000000000000000000000000000001", "latest"]
          }
        )

      assert response.status == 200
      assert %{"id" => ^id, "result" => "0x10"} = response.body
      assert Enum.sort(Enum.map(sends, & &1.fleet)) == ["alternate", "primary"]
      assert Enum.all?(sends, &(&1.transport == :http))
    after
      :ok = Tenant.close!(tenant)
      for upstream <- fleet, do: Fleet.stop(upstream)
    end
  end
end

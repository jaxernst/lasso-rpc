defmodule Lasso.Test.Harness.UnopenedConnectionTest do
  use ExUnit.Case, async: false

  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness

  @moduletag feature: ["core-failover-1"]

  test "refused reads fail over and open the HTTP circuit after three failures" do
    refused_connections("eth_getBalance", ["0x0", "latest"])
  end

  test "refused sends fail over once and open the HTTP circuit after three failures" do
    refused_connections("eth_sendRawTransaction", ["0x02"])
  end

  defp refused_connections(method, params) do
    primary = Fleet.start!(self(), "connect-primary-#{System.unique_integer([:positive])}")
    backup = Fleet.start!(self(), "connect-backup-#{System.unique_integer([:positive])}")
    tenant = Tenant.open!([primary, backup])

    try do
      Fleet.stop(primary)

      for attempt <- 1..4 do
        assert %{status: 200, body: %{"result" => "0x10"}} =
                 Rpc.call(Tenant.credentials(tenant), method, params)

        expected = if(attempt < 3, do: :closed, else: :open)

        Settle.await("HTTP circuit reflects refused connection", fn ->
          instance =
            Lasso.Providers.Catalog.lookup_instance_id(tenant.profile, 31_337, primary.name)

          state = Lasso.Core.Support.CircuitBreaker.get_state({instance, :http}).state
          if state == expected, do: {:ok, state}, else: {:waiting, state}
        end)
      end

      calls = Enum.filter(Fleet.drain(backup), &(&1.request["method"] == method))
      assert length(calls) == 4
    after
      Tenant.close!(tenant)
      if Process.alive?(primary.pid), do: Fleet.stop(primary)
      Fleet.stop(backup)
    end
  end
end

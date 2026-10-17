defmodule Lasso.Test.Harness.TenantContractTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  test "retirement rejects a live profile and preserves another profile's shared upstream" do
    fleet = Fleet.start!(self(), "shared")

    try do
      first = Tenant.open!([fleet])
      second = Tenant.open!([fleet])

      try do
        marker = Settle.listen([:lasso, :tenant, :retired])
        assert {:error, :profile_still_present} = Lasso.Diagnostics.retire_tenant(first.profile)
        refute_received {:surface, _, [:lasso, :tenant, :retired], _, _}
        invalid = Path.join(System.fetch_env!("LASSO_PROFILES_DIR"), "invalid.yml")
        File.write!(invalid, "---\nname: Invalid\nslug: invalid\n---\nchains: false\n")

        try do
          assert {:error, _} = Lasso.Diagnostics.retire_tenant(first.profile)
          refute_received {:surface, _, [:lasso, :tenant, :retired], _, _}
        after
          File.rm!(invalid)
        end

        Settle.unlisten(marker)
        assert :ok = Tenant.close!(first)

        assert %{status: 200, body: %{"result" => "0x10"}} =
                 Rpc.call(Tenant.credentials(second), "eth_getBalance", ["account", "latest"])

        response = Rpc.call(Tenant.credentials(first), "eth_getBalance", ["account", "latest"])
        refute match?(%{status: 200, body: %{"result" => _}}, response)
      after
        Tenant.close!(second)
      end
    after
      Fleet.stop(fleet)
    end
  end
end

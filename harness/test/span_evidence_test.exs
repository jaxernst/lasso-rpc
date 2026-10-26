defmodule Lasso.Harness.SpanEvidenceTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}
  @moduletag :harness

  @span_claim "You can make eth_getLogs requests with up to a 10 block range. Based on your parameters, this block range should work: [0x1ec6e612, 0x1ec6e61b]"
  @range_claim "ranges over 10000 blocks are not supported on free plan"
  @plan_claim "Under the Free tier plan, you can make eth_getLogs requests with up to a 10 block range. Upgrade to PAYG for expanded block range."
  @maximum_claim "Block range too large: maximum allowed is 50 blocks on your current plan."

  @tag feature: ["core-span-1"]
  test "captured physical span claims are visible to the owner and passive success retracts them" do
    for {code, message} <- [
          {-32_600, @span_claim},
          {-32_600, @plan_claim},
          {35, @range_claim},
          {-32_001, @maximum_claim}
        ] do
      journey(fn tenant, fleet ->
        owners =
          Map.new(
            [Lasso.Config.ConfigStore, Lasso.Providers.Catalog.Owner, LassoWeb.Endpoint],
            &{&1, Process.whereis(&1)}
          )

        for {filter, witnesses} <- [dense: 1, sparse: 2] do
          Fleet.script(fleet, "eth_getLogs", [{:error, code, message}])
          response = Rpc.call(tenant, "eth_getLogs", logs(filter))
          assert response.body["error"]
          settle()

          if witnesses == 1 do
            assert hints(tenant) == []
          else
            assert [%{value: 499, support: %{smallest_failure: 499}} = hint] = hints(tenant)
            assert (hint.expires_at_ms - hint.observed_at_ms) in 1..1_800_000
          end

          assert %{status: 200, body: %{"result" => "0x7a69"}} = Rpc.call(tenant, "eth_chainId")
          assert_health(tenant)
          for {name, pid} <- owners, do: assert(Process.whereis(name) == pid)
        end

        Fleet.script(fleet, "eth_getLogs", [{:answer, []}])

        assert %{status: 200, body: %{"result" => []}} =
                 Rpc.call(tenant, "eth_getLogs", logs(:sparse))

        settle()
        assert hints(tenant) == []
      end)
    end
  end

  @tag feature: ["core-span-2"]
  test "volume and mixed claims cannot publish span hints even with range-reduction guidance" do
    journey(fn tenant, fleet ->
      owners =
        Map.new(
          [Lasso.Config.ConfigStore, Lasso.Providers.Catalog.Owner, LassoWeb.Endpoint],
          &{&1, Process.whereis(&1)}
        )

      for message <- [
            "query returned more than 10000 results",
            "too many results; reduce the block range",
            "result set too large",
            "response too large",
            "response size exceeded",
            @range_claim <> "; query returned more than 10000 results",
            @span_claim <> "; too many results",
            @plan_claim <> " Too many results"
          ],
          filter <- [:dense, :sparse] do
        Fleet.script(fleet, "eth_getLogs", [{:error, -32_000, message}])
        assert %{body: %{"error" => _}} = Rpc.call(tenant, "eth_getLogs", logs(filter))
        settle()
        assert hints(tenant) == []
        assert %{status: 200, body: %{"result" => "0x7a69"}} = Rpc.call(tenant, "eth_chainId")
        assert_health(tenant)
        for {name, pid} <- owners, do: assert(Process.whereis(name) == pid)
      end
    end)
  end

  defp journey(run) do
    fleet = Fleet.start!(self(), "span-provider")

    try do
      tenant = Tenant.open!([fleet])

      try do
        run.(tenant, fleet)
      after
        Tenant.close!(tenant)
      end
    after
      Fleet.stop(fleet)
    end
  end

  defp hints(tenant) do
    {:ok, hints} = Lasso.Diagnostics.provider_knowledge(tenant.profile, 31_337, "span-provider")
    Enum.filter(hints.http, &(&1.kind == :span_limit))
  end

  defp logs(filter) do
    range = %{"fromBlock" => "0x1", "toBlock" => "0x1f4"}

    [
      if(filter == :sparse,
        do: Map.put(range, "address", "0x0000000000000000000000000000000000000001"),
        else: range
      )
    ]
  end

  defp settle do
    Settle.await("span feedback applied", fn ->
      case Lasso.Core.ProjectionDispatcher.stats(
             Lasso.ExecutionProjectionDispatcher,
             :learned_feedback
           ) do
        %{retained_items: 0} -> {:ok, :drained}
        stats -> stats
      end
    end)
  end

  defp assert_health(tenant) do
    uri = URI.parse(tenant.rpc_url)

    assert {:ok, %{status: 200}} =
             Finch.build(:get, "#{uri.scheme}://#{uri.host}:#{uri.port}/api/health")
             |> Finch.request(Lasso.Finch)
  end
end

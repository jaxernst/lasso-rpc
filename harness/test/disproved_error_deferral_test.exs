defmodule Lasso.Harness.DisprovedErrorDeferralTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-routing-13"]
  @declined {:error, -32_000, "upstream could not serve this request"}

  test "a disproved error moves the provider behind its peer for matching requests only" do
    with_tenant(fn tenant, [primary, backup] = fleets ->
      Fleet.script(primary, "eth_getBalance", [], @declined)
      Fleet.script(backup, "eth_getBalance", [], {:answer, "0x22"})
      Fleet.script(primary, "eth_getCode", [], {:answer, "0x"})

      {response, sends} = call(tenant, fleets, "eth_getBalance")
      assert %{"result" => "0x22"} = response.body
      assert Enum.map(sends, & &1.fleet) == [primary.name, backup.name]

      hint = disproval!(tenant, primary)
      assert hint.dimension == "eth_getBalance"
      assert hint.support.witness == backup.name
      assert hint.support.error_code == -32_000
      assert hint.expires_at_ms - hint.observed_at_ms == :timer.minutes(30)

      firsts =
        for _ <- 1..20 do
          {response, [first | _]} = call(tenant, fleets, "eth_getBalance")
          assert %{"result" => "0x22"} = response.body
          first.fleet
        end

      deferred =
        Settle.await("a read deferred behind the peer", fn ->
          case call(tenant, fleets, "eth_getBalance") do
            {response, [%{fleet: first}]} when first == backup.name -> {:ok, response}
            _ -> :sampled
          end
        end)

      assert %{"kind" => "disproved_error", "method" => "eth_getBalance", "hints" => [_]} =
               deferred.body["lasso_meta"]["learning_decision"]

      assert applied_deferrals(tenant) > 0

      # Only the sampled share (about 5%) still tries the deferred provider first.
      assert Enum.count(firsts, &(&1 == primary.name)) <= 6

      {response, sends} = call(tenant, fleets, "eth_getCode")
      assert %{"result" => "0x"} = response.body
      assert Enum.map(sends, & &1.fleet) == [primary.name]
    end)
  end

  test "the sampled share still reaches the deferred provider, and its success retracts the deferral" do
    with_tenant(fn tenant, [primary, backup] = fleets ->
      Fleet.script(primary, "eth_getBalance", [@declined], {:answer, "0x11"})
      Fleet.script(backup, "eth_getBalance", [], {:answer, "0x22"})

      {_response, sends} = call(tenant, fleets, "eth_getBalance")
      assert Enum.map(sends, & &1.fleet) == [primary.name, backup.name]
      disproval!(tenant, primary)

      deferred =
        Settle.await(
          "a sampled request reaches the deferred provider",
          fn ->
            {response, sends} = call(tenant, fleets, "eth_getBalance")

            case Enum.map(sends, & &1.fleet) do
              [first] when first == primary.name -> {:ok, response}
              [first] when first == backup.name -> :deferred
            end
          end,
          30_000
        )

      assert %{"result" => "0x11"} = deferred.body

      Settle.await("the served success retracts the disproval", fn ->
        if disprovals(tenant, primary) == [], do: {:ok, :retracted}, else: :held
      end)

      {response, sends} = call(tenant, fleets, "eth_getBalance")
      assert %{"result" => "0x11"} = response.body
      assert Enum.map(sends, & &1.fleet) == [primary.name]
    end)
  end

  test "a profile's sole route is never deferred" do
    with_tenant(fn tenant, [primary, backup] = fleets ->
      Fleet.script(primary, "eth_getBalance", [@declined], {:answer, "0x11"})
      Fleet.script(backup, "eth_getBalance", [], {:answer, "0x22"})

      {_response, sends} = call(tenant, fleets, "eth_getBalance")
      assert Enum.map(sends, & &1.fleet) == [primary.name, backup.name]
      disproval!(tenant, primary)

      Tenant.replace!(tenant, [primary])

      {response, sends} = call(tenant, [primary], "eth_getBalance")
      assert %{"result" => "0x11"} = response.body
      assert Enum.map(sends, & &1.fleet) == [primary.name]
    end)
  end

  defp disproval!(tenant, fleet) do
    Settle.await("#{fleet.name} holds a disproval", fn ->
      case disprovals(tenant, fleet) do
        [hint] -> {:ok, hint}
        other -> other
      end
    end)
  end

  defp disprovals(tenant, fleet) do
    {:ok, hints} = Lasso.Diagnostics.provider_knowledge(tenant.profile, 31_337, fleet.name)
    for %{kind: :disproved_error} = hint <- Map.get(hints, :http, []), do: hint
  end

  defp applied_deferrals(tenant) do
    uri = URI.parse(tenant.rpc_url)

    {:ok, %{status: 200, body: metrics}} =
      Finch.build(:get, "#{uri.scheme}://#{uri.host}:#{uri.port}/metrics")
      |> Finch.request(Lasso.Finch)

    [_, count] =
      Regex.run(
        ~r/^lasso_provider_knowledge_applied_deferrals_total\{kind="disproved_error"\} (\d+)/m,
        metrics
      )

    String.to_integer(count)
  end

  defp call(tenant, fleets, method) do
    params = [unique_address(), "latest"]

    Settle.closed(
      fn -> Rpc.call(%{rpc_url: tenant.rpc_url <> "?include_meta=body"}, method, params) end,
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

  defp with_tenant(scenario) do
    fleets = for name <- ["disproved-primary", "disproved-backup"], do: Fleet.start!(self(), name)

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

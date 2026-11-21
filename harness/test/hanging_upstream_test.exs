defmodule Lasso.Harness.HangingUpstreamTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-failover-5"]

  test "upstreams that accept requests and never answer leave the priority route" do
    journey(3, fn tenant, [hung_a, hung_b, healthy] ->
      for fleet <- [hung_a, hung_b],
          method <- ["eth_getBalance", "eth_chainId"],
          do: hang(fleet, method)

      Fleet.script(healthy, "eth_getBalance", [], {:answer, "0x20"})

      # Each hung upstream needs two probe timeouts, at least one probe budget apart.
      Settle.await(
        "hung upstreams leave the priority route",
        fn ->
          before = held_reads([hung_a, hung_b])
          result = balance(Tenant.credentials(tenant), 1)

          if result == "0x20" and held_reads([hung_a, hung_b]) == before,
            do: {:ok, result},
            else: result
        end,
        20_000
      )

      held = held_reads([hung_a, hung_b])

      assert Enum.map(2..5, &balance(Tenant.credentials(tenant), &1)) ==
               List.duplicate("0x20", 4)

      assert held_reads([hung_a, hung_b]) == held
    end)
  end

  test "reads that time out for one profile leave a shared provider serving its other profiles" do
    journey(2, fn owner, [slow, fast] ->
      sibling = Tenant.open!([slow])

      try do
        hang(slow, "eth_getBalance")
        Fleet.script(fast, "eth_getBalance", [], {:answer, "0x20"})

        assert Enum.map(1..3, &balance(Tenant.credentials(owner), &1)) ==
                 List.duplicate("0x20", 3)

        held = held_reads([slow])
        read = Task.async(fn -> balance(Tenant.credentials(sibling), 4) end)

        token =
          Settle.await("sibling read reaches the shared provider", fn ->
            case held_reads([slow]) -- held do
              [token] -> {:ok, token}
              other -> other
            end
          end)

        :ok = Fleet.release(slow, token, {:answer, "0x14"})
        assert Task.await(read) == "0x14"
      after
        release_holds([slow])
        Tenant.close!(sibling)
      end
    end)
  end

  defp journey(count, fun) do
    unique = System.unique_integer([:positive])
    fleets = for n <- 1..count, do: Fleet.start!(self(), "hang-#{n}-#{unique}")

    try do
      tenant = Tenant.open!(fleets)

      try do
        fun.(tenant, fleets)
      after
        release_holds(fleets)
        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  defp hang(fleet, method),
    do: Fleet.script(fleet, method, [], {:respond, fn _ -> {:hold, make_ref()} end})

  defp balance(credentials, n) do
    response = Rpc.call(credentials, "eth_getBalance", ["0x#{n}", "latest"])
    response.body["result"] || response.body["error"]["message"]
  end

  defp held_reads(fleets) do
    for fleet <- fleets,
        %{action: {:hold, token}, request: %{"method" => "eth_getBalance"}} <- Fleet.drain(fleet),
        do: token
  end

  defp release_holds(fleets) do
    for fleet <- fleets,
        %{action: {:hold, token}} <- Fleet.drain(fleet),
        do: Fleet.release(fleet, token, {:answer, "0x0"})
  end
end

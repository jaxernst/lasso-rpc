defmodule Lasso.Harness.RateLimitRecoveryTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-failover-6"]

  @limited {:status, 429, [{"retry-after", "1"}],
            %{error: %{code: -32_005, message: "Too many requests"}}}

  test "rate-limited reads leave an upstream reliable once its retry hint passes" do
    unique = System.unique_integer([:positive])
    fleets = for role <- ["limited", "other"], do: Fleet.start!(self(), "#{role}-#{unique}")
    [limited, _other] = fleets

    try do
      tenant = Tenant.open!(fleets)

      try do
        override = tenant.rpc_url <> "?provider_override=" <> limited.name

        for _ <- 1..3 do
          assert {%{body: %{"result" => "0x10"}}, [_]} = read(fleets, override)
        end

        for _ <- 1..3 do
          Fleet.script(limited, "eth_getBalance", [@limited])
          assert {%{body: %{"error" => _}}, [_]} = read(fleets, override)
        end

        balanced = String.replace(tenant.rpc_url, "/priority/", "/balanced-fast/")

        Settle.await("balanced-fast reaches the limited upstream again", fn ->
          case read(fleets, balanced) do
            {_response, [%{fleet: name}]} when name == limited.name -> {:ok, :serving}
            {_response, sends} -> Enum.map(sends, & &1.fleet)
          end
        end)
      after
        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  defp read(fleets, url) do
    params = [
      "0x" <>
        (System.unique_integer([:positive])
         |> Integer.to_string(16)
         |> String.pad_leading(40, "0")),
      "latest"
    ]

    Settle.closed(fn -> Rpc.call(%{rpc_url: url}, "eth_getBalance", params) end, fleets, %{
      method: "eth_getBalance",
      params: params
    })
  end
end

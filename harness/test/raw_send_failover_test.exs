defmodule Lasso.Test.Harness.RawSendFailoverTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-failover-6"]

  @send "eth_sendRawTransaction"
  @lookup "eth_getTransactionByHash"
  @raw "0x02f86c0180843b9aca0082520894111111111111111111111111111111111111111180c0"

  test "a send the first upstream broadcast returns its hash when the second says already known" do
    journey(fn tenant, [first, second] = fleets ->
      Fleet.script(first, @send, [], {:error, -32_000, "internal server error"})
      Fleet.script(second, @send, [], {:error, -32_000, "already known"})
      Fleet.script(second, @lookup, [], {:answer, %{hash: hash()}})

      {body, sends, lookups} = submit(tenant, fleets)
      assert body["result"] == hash(), inspect(body)
      refute body["error"]
      assert sends == [first.name, second.name]
      assert lookups == [second.name]
    end)
  end

  test "an unlisted rejection after the broadcast still returns the hash the lookup finds" do
    journey(fn tenant, [first, second] = fleets ->
      Fleet.script(first, @send, [], {:error, -32_000, "internal server error"})
      Fleet.script(second, @send, [], {:error, -32_010, "submission refused by gateway"})
      Fleet.script(second, @lookup, [], {:answer, %{hash: hash()}})

      {body, sends, lookups} = submit(tenant, fleets)
      assert body["result"] == hash(), inspect(body)
      refute body["error"]
      assert sends == [first.name, second.name]
      assert lookups == [second.name]
    end)
  end

  test "a send the first upstream rate limits succeeds on the second without a lookup" do
    journey(fn tenant, [first, second] = fleets ->
      Fleet.script(first, @send, [], {:status, 429, [], "Too Many Requests"})
      Fleet.script(second, @send, [], {:answer, hash()})

      {body, sends, lookups} = submit(tenant, fleets)
      assert body["result"] == hash(), inspect(body)
      refute body["error"]
      assert sends == [first.name, second.name]
      assert lookups == []
    end)
  end

  defp journey(scenario) do
    fleets = Enum.map(["first", "second"], &Fleet.start!(self(), &1))
    tenant = Tenant.open!(fleets)

    try do
      for fleet <- fleets, do: Fleet.script(fleet, @lookup, [], {:answer, nil})
      scenario.(tenant, fleets)
    after
      Tenant.close!(tenant)
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  defp submit(tenant, fleets) do
    cursors = Enum.map(fleets, &length(Fleet.drain(&1)))

    {response, sends} =
      Settle.closed(fn -> Rpc.call(tenant, @send, [@raw]) end, fleets, %{
        method: @send,
        params: [@raw]
      })

    lookups =
      Enum.zip(fleets, cursors)
      |> Enum.flat_map(fn {fleet, cursor} -> fleet |> Fleet.drain() |> Enum.drop(cursor) end)
      |> Enum.filter(&(&1.request["method"] == @lookup and &1.request["params"] == [hash()]))

    {response.body, names(sends, fleets), names(lookups, fleets)}
  end

  # Each fleet ledger is ordered, so listing by fleet priority checks one send per upstream.
  defp names(reports, fleets) do
    for fleet <- fleets, report <- reports, report.fleet == fleet.name, do: fleet.name
  end

  defp hash do
    "0x" <> raw = @raw

    "0x" <>
      Base.encode16(ExKeccak.hash_256(Base.decode16!(raw, case: :mixed)), case: :lower)
  end
end

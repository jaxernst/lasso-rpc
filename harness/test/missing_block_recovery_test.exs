defmodule Lasso.Harness.MissingBlockRecoveryTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-failover-9"]

  @behind 9_950
  @start 10_000
  @rounds 10

  # On a 20 ms chain the band is 20 blocks, so the round keeps the laggard 50 blocks behind
  # out of head reads. Age credit lifts its observation past the blocks the client reads,
  # so it keeps its strategy position for them and answers null for blocks it lacks.
  test "a block the client was just told about is recovered from the route that told it" do
    world([:laggard, :peer, :peer], fn tenant, [laggard, peer, _other] = fleets, head ->
      deferred!(tenant, fleets, laggard)

      for round <- 1..@rounds do
        credited!(tenant, fleets, laggard, @start + 2 * round)
        # A client polls the head faster than once per 250 ms, then reads the block it saw.
        height = advance(tenant, head, 2)
        params = [hex(height), false]

        {response, sent} =
          Settle.closed(fn -> block_read(tenant, params) end, fleets, %{
            method: "eth_getBlockByNumber",
            params: params
          })

        assert {round, get_in(response.body, ["result", "number"])} == {round, hex(height)}
        assert {round, Enum.map(sent, & &1.fleet)} == {round, [laggard.name, peer.name]}
      end
    end)
  end

  test "an error from the only route that reported the block leaves the laggard's null" do
    world([:peer, :laggard], fn tenant, [peer, laggard] = fleets, head ->
      deferred!(tenant, fleets, laggard)
      decisions = Settle.listen([:lasso, :rpc, :null_recovery, :decision])
      height = advance(tenant, head, 2)
      params = [hex(height), false]

      Fleet.script(
        peer,
        "eth_getBlockByNumber",
        [{:status, 503, [], "unavailable"}],
        blocks(head)
      )

      {response, sent} =
        Settle.closed(fn -> block_read(tenant, params) end, fleets, %{
          method: "eth_getBlockByNumber",
          params: params
        })

      # The error failover leaves the extra send unspent, but the one route that reported
      # the block was already tried and is not sent the read again, so the null stands.
      assert %{"result" => nil} = response.body
      assert Enum.map(sent, & &1.fleet) == [peer.name, laggard.name]

      Settle.event(
        decisions,
        &(&1.profile == tenant.profile and &1.result == :alternate_unavailable)
      )
    end)
  end

  defp world(roles, action) do
    head = :atomics.new(1, signed: false)
    :atomics.put(head, 1, @start)

    fleets =
      for {role, i} <- Enum.with_index(roles) do
        fleet = Fleet.start!(self(), "missing-block-#{role}-#{i}")
        script(fleet, role, head)
        fleet
      end

    try do
      tenant =
        Tenant.open!(fleets,
          chain: %{
            "block_time_ms" => 20,
            "monitoring" => %{
              "probe_interval_ms" => 600_000,
              "http_heads_interval_ms" => 600_000
            }
          },
          providers: Map.new(fleets, &{&1.name, %{"background_observations" => true}})
        )

      try do
        action.(tenant, fleets, head)
      after
        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  defp script(fleet, :laggard, _head) do
    Fleet.script(fleet, "eth_blockNumber", [], {:answer, hex(@behind)})
    Fleet.script(fleet, "eth_getBlockByNumber", [], {:respond, &block(&1, @behind)})
  end

  defp script(fleet, :peer, head) do
    Fleet.script(
      fleet,
      "eth_blockNumber",
      [],
      {:respond, fn _ -> {:answer, hex(current(head))} end}
    )

    Fleet.script(fleet, "eth_getBlockByNumber", [], blocks(head))
  end

  defp blocks(head), do: {:respond, &block(&1, current(head))}

  # An upstream at `have` answers a numeric block above it with null.
  defp block(%{"params" => [selector | _]}, have) do
    wanted =
      if selector == "latest",
        do: have,
        else: String.to_integer(String.trim_leading(selector, "0x"), 16)

    {:answer,
     if(wanted <= have,
       do: %{
         "number" => hex(wanted),
         "hash" => "0x" <> String.pad_leading(Integer.to_string(wanted, 16), 64, "0"),
         "timestamp" => hex(System.system_time(:second)),
         "transactions" => []
       }
     )}
  end

  defp deferred!(tenant, fleets, laggard) do
    Settle.await("the round keeps head reads off the laggard", fn ->
      case sends(tenant, fleets, "eth_blockNumber", []) do
        [name] = sent when name != laggard.name -> {:ok, sent}
        other -> other
      end
    end)
  end

  # The peers support block @start at any age, so the laggard goes first for it only once
  # no round has polled for the 50 blocks of credit it needs. The second peer, polled in
  # those rounds alone, is then credited past `height` too, so the laggard going first for
  # `height` shows its own credit reaches it. No head read lands between the two reads.
  defp credited!(tenant, fleets, laggard, height) do
    Settle.await("the laggard's credit reaches block #{height}", fn ->
      head_reads = head_reads(fleets)
      supported = sends(tenant, fleets, "eth_getBlockByNumber", [hex(@start), false])
      target = sends(tenant, fleets, "eth_getBlockByNumber", [hex(height), false])

      case {supported, target, head_reads(fleets) - head_reads} do
        {[first | _], [first | _], 0} = routes when first == laggard.name -> {:ok, routes}
        other -> other
      end
    end)
  end

  defp head_reads(fleets),
    do:
      fleets
      |> Enum.flat_map(&Fleet.drain/1)
      |> Enum.count(&(&1.request["method"] == "eth_blockNumber"))

  defp sends(tenant, fleets, method, params) do
    {response, reports} =
      Settle.closed(
        fn -> Rpc.call(Tenant.credentials(tenant), method, params) end,
        fleets,
        %{method: method, params: params}
      )

    assert response.status == 200
    Enum.map(reports, & &1.fleet)
  end

  # Advances the upstream head one block at a time and reads each new head through Lasso.
  defp advance(tenant, head, blocks) do
    for _ <- 1..blocks, reduce: nil do
      _ ->
        height = :atomics.add_get(head, 1, 1)

        assert %{body: %{"result" => result}} =
                 Rpc.call(Tenant.credentials(tenant), "eth_blockNumber")

        assert result == hex(height)
        height
    end
  end

  defp block_read(tenant, params) do
    response = Rpc.call(Tenant.credentials(tenant), "eth_getBlockByNumber", params)
    assert response.status == 200
    response
  end

  defp current(head), do: :atomics.get(head, 1)

  defp hex(n), do: "0x" <> String.downcase(Integer.to_string(n, 16))
end

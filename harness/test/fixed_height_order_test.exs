defmodule Lasso.Harness.FixedHeightOrderTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-routing-7"]
  @moduletag timeout: 120_000

  @address "0x" <> String.duplicate("11", 20)
  @block_ms 2_000
  @lag 5
  @peer_ms 60
  @catching_up 1_000

  # One upstream answers at once but 5 blocks behind; two answer in 60 ms at the head, and the
  # chain makes a block every 2 s. Head rounds poll all three every 5 s. When one of the
  # laggard's polls fails, its observation ages to 10 s, which is more than the 5 blocks it
  # lacks. A route counts only the blocks it was seen to have, so its age never lets the
  # laggard look caught up to the block below the head.
  test "fastest keeps reads at a fixed block off a quick lagging upstream through a missed head poll" do
    moving_world([], fn %{laggard: laggard, poll: poll} = world ->
      Fleet.script(laggard, "eth_blockNumber", [{:status, 503, [], "unavailable"}], poll)
      polls = head_polls(laggard)

      outage =
        world
        |> reads()
        |> Enum.take_while(fn _read -> head_polls(laggard) < polls + 2 end)

      refute_served(outage, laggard)
    end)
  end

  # A fourth upstream starts 1,000 blocks behind and then answers at the head. Its own head
  # gains 1,000 blocks between two polls, which says nothing about how fast the chain makes
  # blocks or about the laggard's head.
  test "an upstream catching up from far behind leaves fixed-height reads off the quick lagging upstream" do
    moving_world(["order-catching-up"], fn %{laggard: laggard, head: head} = world ->
      [catcher] = world.others

      Fleet.script(
        catcher,
        "eth_blockNumber",
        [],
        {:respond, fn _ -> later(catcher, {:answer, hex(head.())}) end}
      )

      polls = head_polls(catcher)

      world
      |> reads()
      |> Stream.take_while(fn _read -> head_polls(catcher) < polls + 2 end)
      |> Stream.run()

      refute_served(world |> reads() |> Enum.take(60), laggard)
    end)
  end

  # Every route was last seen below the requested block: the peers at 10,000 and the quick
  # laggard at 9,995, with a read at 10,002. All three are deferred, and the routes nearest
  # the block go first, so neither strategy sends the read to the laggard.
  test "when every route is behind a fixed block, the highest observed route serves it first" do
    [laggard | peers] =
      fleets = Enum.map(~w(order-laggard order-peer-1 order-peer-2), &Fleet.start!(self(), &1))

    Fleet.script(laggard, "eth_blockNumber", [], {:answer, hex(10_000 - @lag)})

    for peer <- peers do
      Fleet.script(peer, "eth_blockNumber", [], {:answer, hex(10_000)})

      Fleet.script(
        peer,
        "eth_getBalance",
        [],
        {:respond, fn _ -> later(peer, {:answer, "0x10"}) end}
      )
    end

    tenant =
      Tenant.open!(fleets,
        providers: Map.new(fleets, &{&1.name, %{"background_observations" => true}})
      )

    try do
      Settle.await("every upstream answers a head poll", fn ->
        if Enum.all?(fleets, &(head_polls(&1) >= 1)), do: {:ok, :polled}
      end)

      for strategy <- ["fastest", "load-balanced"] do
        url = String.replace(tenant.rpc_url, "/priority/", "/#{strategy}/")
        world = %{fleets: fleets, credentials: %{rpc_url: url}}

        # Reads at a block every route has teach fastest that the laggard is quickest.
        for _ <- 1..20, do: read(world, hex(9_000))

        served = for _ <- 1..20, {_response, sent} = read(world, hex(10_002)), do: sent
        assert laggard.name not in served, "#{strategy}: #{inspect(Enum.frequencies(served))}"
      end
    after
      Tenant.close!(tenant)
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  # Waits until every upstream has answered two head rounds, so the first round has closed
  # and each route has a fresh observation and a round lag before the action reads.
  defp moving_world(other_names, action) do
    started = System.monotonic_time(:millisecond)
    head = fn -> 10_000 + div(System.monotonic_time(:millisecond) - started, @block_ms) end

    [laggard | peers] =
      fleets =
      Enum.map(
        ~w(order-laggard order-peer-1 order-peer-2) ++ other_names,
        &Fleet.start!(self(), &1)
      )

    others = Enum.drop(peers, 2)
    poll = {:respond, fn _ -> {:answer, hex(head.() - @lag)} end}
    Fleet.script(laggard, "eth_blockNumber", [], poll)

    for peer <- peers, method <- ["eth_blockNumber", "eth_getBalance"] do
      behind = if peer in others and method == "eth_blockNumber", do: @catching_up, else: 0

      Fleet.script(
        peer,
        method,
        [],
        {:respond, fn _ -> later(peer, answer(method, head.() - behind)) end}
      )
    end

    tenant =
      Tenant.open!(fleets,
        chain: %{"block_time_ms" => @block_ms},
        providers: Map.new(fleets, &{&1.name, %{"background_observations" => true}})
      )

    world = %{
      fleets: fleets,
      laggard: laggard,
      others: others,
      head: head,
      poll: poll,
      credentials: %{rpc_url: String.replace(tenant.rpc_url, "/priority/", "/fastest/")}
    }

    try do
      Settle.await(
        "every upstream answers two head rounds",
        fn -> if Enum.all?(fleets, &(head_polls(&1) >= 2)), do: {:ok, :polled} end,
        20_000
      )

      action.(world)
    after
      Tenant.close!(tenant)
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  defp refute_served(reads, fleet) do
    served = for {response, sent} <- reads, sent == fleet.name, do: response.request
    latest = Enum.count(served, &match?([_address, "latest"], &1))

    assert length(reads) >= 20

    assert served == [],
           "#{fleet.name} served #{length(served)} of #{length(reads)} reads, #{latest} at latest"
  end

  # Alternates latest reads with reads at the block below the head, which the laggard lacks.
  defp reads(world) do
    Stream.iterate(0, &(&1 + 1))
    |> Stream.map(fn i ->
      read(world, if(rem(i, 2) == 0, do: "latest", else: hex(world.head.() - 1)))
    end)
  end

  # The response, tagged with its params, and the upstream that received the first send.
  defp read(world, selector) do
    params = [@address, selector]

    {response, reports} =
      Settle.closed(
        fn -> Rpc.call(world.credentials, "eth_getBalance", params) end,
        world.fleets,
        %{method: "eth_getBalance", params: params}
      )

    assert response.status == 200
    {Map.put(response, :request, params), reports |> hd() |> Map.fetch!(:fleet)}
  end

  defp head_polls(fleet),
    do: Enum.count(Fleet.drain(fleet), &(&1.request["method"] == "eth_blockNumber"))

  defp answer("eth_blockNumber", head), do: {:answer, hex(head)}
  defp answer("eth_getBalance", _head), do: {:answer, "0x10"}

  defp later(fleet, action) do
    token = make_ref()
    {:ok, _timer} = :timer.apply_after(@peer_ms, Fleet, :release, [fleet, token, action])
    {:hold, token}
  end

  defp hex(height), do: "0x" <> String.downcase(Integer.to_string(height, 16))
end

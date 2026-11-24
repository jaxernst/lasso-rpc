defmodule Lasso.Harness.LoadBalancedDeferralTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-routing-10"]
  @method "eth_getBalance"

  test "load-balanced defers a route that times out on one read in ten, then restores it" do
    world(["flaky", "peer-a", "peer-b"], fn tenant, [flaky, peer_a, peer_b] = fleets ->
      # Every tenth read the flaky upstream receives is held until its attempt times out, and the
      # client's read waits out that timeout before a peer answers it.
      Fleet.script(flaky, @method, for(n <- 1..600, do: flaky_action(n)), {:answer, "0x20"})
      for peer <- [peer_a, peer_b], do: Fleet.script(peer, @method, [], {:answer, "0x20"})

      warmup = reads(tenant, fleets, 1..200)
      window = reads(tenant, fleets, 201..600)
      assert warmup.served == 200 and window.served == 400

      # Undeferred, the flaky route takes a third of first attempts (about 133 of 400, standard
      # deviation 9.4) and every tenth of those times out (about 13). Deferral leaves it at most
      # 61 first attempts and 6 timeouts in 20,000 simulated runs of this journey.
      assert window.arrivals[flaky.name] <= 80
      assert window.timeouts <= 8

      # The peers keep sharing the load rather than one taking it all.
      assert window.arrivals[peer_a.name] >= 100
      assert window.arrivals[peer_b.name] >= 100

      Fleet.script(flaky, @method, [], {:answer, "0x20"})

      # Once it answers again it returns to a fair share, a third of 90 reads, within 12 blocks
      # of 90; simulated recovery needs at most 671 reads.
      recovered =
        Enum.reduce_while(0..11, nil, fn block, _ ->
          first = 601 + block * 90
          counts = reads(tenant, fleets, first..(first + 89))
          assert counts.timeouts == 0

          if counts.arrivals[flaky.name] >= 20,
            do: {:halt, counts},
            else: {:cont, nil}
        end)

      assert recovered, "the recovered route never regained a fair share"
    end)
  end

  defp flaky_action(n) when rem(n, 10) == 0, do: {:hold, make_ref()}
  defp flaky_action(_n), do: {:answer, "0x20"}

  # Reads run sequentially, each ranked on the evidence its predecessors left.
  defp reads(tenant, fleets, range) do
    before = Map.new(fleets, &{&1.name, arrivals(&1)})

    failed =
      for n <- range,
          response = Rpc.call(Tenant.credentials(tenant), @method, [address(n), "latest"]),
          response.body["result"] != "0x20",
          do: {n, response.status, response.body}

    assert failed == []
    served = Enum.count(range) - length(failed)
    received = Map.new(fleets, &{&1.name, Enum.drop(arrivals(&1), length(before[&1.name]))})

    timeouts =
      for fleet <- fleets, %{action: {:hold, token}} <- received[fleet.name] do
        Fleet.release(fleet, token, {:answer, "0x20"})
      end

    %{
      served: served,
      timeouts: length(timeouts),
      arrivals: Map.new(received, fn {name, reports} -> {name, length(reports)} end)
    }
  end

  defp arrivals(fleet),
    do: for(%{request: %{"method" => @method}} = report <- Fleet.drain(fleet), do: report)

  defp address(n), do: "0x" <> (n |> Integer.to_string(16) |> String.pad_leading(40, "0"))

  defp world(names, scenario) do
    unique = System.unique_integer([:positive])
    fleets = for name <- names, do: Fleet.start!(self(), "#{name}-#{unique}")

    try do
      tenant = Tenant.open!(fleets)

      balanced = %{
        tenant
        | rpc_url: String.replace(tenant.rpc_url, "/priority/", "/load-balanced/")
      }

      try do
        scenario.(balanced, fleets)
      after
        for fleet <- fleets,
            %{action: {:hold, token}} <- Fleet.drain(fleet),
            do: Fleet.release(fleet, token, {:answer, "0x20"})

        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end
end

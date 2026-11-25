defmodule Lasso.Harness.ProbeRateLimitTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-failover-6"]
  @moduletag timeout: 120_000

  @limited %{jsonrpc: "2.0", id: 1, error: %{code: -32_005, message: "Too many requests"}}

  test "a rate-limited identity probe holds its upstream out only for its retry hint" do
    journey(fn tenant, [primary, backup] = fleets ->
      assert_read(tenant, fleets, primary.name)

      assert held_ms(tenant, fleets, primary, backup, [{"retry-after", "1"}]) < 1_500
    end)
  end

  test "a rate-limited identity probe without a retry hint holds its upstream for 30 s" do
    journey(fn tenant, [primary, backup] = fleets ->
      assert_read(tenant, fleets, primary.name)

      assert held_ms(tenant, fleets, primary, backup, [], 29_000) in 30_000..31_500
    end)
  end

  defp journey(fun) do
    unique = System.unique_integer([:positive])

    fleets =
      for name <- ["probe-limited", "probe-backup"], do: Fleet.start!(self(), "#{name}-#{unique}")

    try do
      tenant =
        Tenant.open!(fleets,
          chain: %{"monitoring" => %{"probe_interval_ms" => 1_000}},
          providers: Map.new(fleets, &{&1.name, %{"background_observations" => true}})
        )

      try do
        fun.(tenant, fleets)
      after
        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  # The probe's 429 is held and timed from just before its release, so a late
  # observer only lengthens the measurement. Reads resume checking only after
  # `quiet_ms`, which keeps a long cooldown from costing thousands of reads.
  defp held_ms(tenant, fleets, fleet, backup, headers, quiet_ms \\ 0) do
    token = make_ref()
    pid = fleet.pid
    Fleet.script(fleet, "eth_chainId", [{:hold, token}])
    assert_receive {:fleet, ^pid, %{action: {:hold, ^token}}}, 5_000

    sent_at = System.monotonic_time(:millisecond)
    :ok = Fleet.release(fleet, token, {:status, 429, headers, @limited})

    Settle.await("the probe's 429 holds the route", fn ->
      if read(tenant, fleets) == [backup.name], do: {:ok, :held}
    end)

    receive do
    after
      max(0, sent_at + quiet_ms - System.monotonic_time(:millisecond)) -> :ok
    end

    Settle.await(
      "the cooldown ends and the route serves reads",
      fn -> if read(tenant, fleets) == [fleet.name], do: {:ok, :released} end,
      40_000
    )

    System.monotonic_time(:millisecond) - sent_at
  end

  defp assert_read(tenant, fleets, expected), do: assert(read(tenant, fleets) == [expected])

  defp read(tenant, fleets) do
    params = [
      "0x" <>
        (System.unique_integer([:positive])
         |> Integer.to_string(16)
         |> String.pad_leading(40, "0")),
      "latest"
    ]

    {response, sends} =
      Settle.closed(
        fn -> Rpc.call(Tenant.credentials(tenant), "eth_getBalance", params) end,
        fleets,
        %{method: "eth_getBalance", params: params}
      )

    assert %{status: 200, body: %{"result" => "0x10"}} = response
    Enum.map(sends, & &1.fleet)
  end
end

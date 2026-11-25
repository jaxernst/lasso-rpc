defmodule Lasso.Harness.HeadPollQuotaBackoffTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-failover-8"]
  @moduletag timeout: 120_000

  # Longer than the one-second Retry-After, so the route's release and its next
  # poll are separate events.
  @interval_ms 3_000
  @throttled {:status, 429, [{"retry-after", "1"}],
              %{error: %{code: 429, message: "Too many requests"}}}

  test "an HTTP 429 naming exhausted monthly capacity holds head polling for an hour" do
    unique = System.unique_integer([:positive])

    [quota, throttle, backup] =
      fleets =
      for name <- ["poll-quota-429", "poll-throttle-429", "poll-backup"],
          do: Fleet.start!(self(), "#{name}-#{unique}")

    try do
      tenant =
        Tenant.open!(fleets,
          chain: %{"monitoring" => %{"http_heads_interval_ms" => @interval_ms}},
          providers: Map.new(fleets, &{&1.name, %{"background_observations" => true}})
        )

      try do
        # Both routes answer their next poll with the same HTTP 429 and a one-second
        # Retry-After; only the JSON-RPC message differs. The throttle's answer is held
        # so its cooldown can be timed from the moment it is sent.
        token = make_ref()

        Fleet.script(
          quota,
          "eth_blockNumber",
          [
            {:status, 429, [{"retry-after", "1"}],
             %{
               error: %{
                 code: 429,
                 message:
                   "Monthly capacity limit exceeded. Upgrade your scaling policy for continued service."
               }
             }}
          ],
          {:answer, "0x3e8"}
        )

        Fleet.script(throttle, "eth_blockNumber", [{:hold, token}], {:answer, "0x3e8"})

        quota_pid = quota.pid
        throttle_pid = throttle.pid

        assert_receive {:fleet, ^quota_pid,
                        %{request: %{"method" => "eth_blockNumber"}, action: {:status, 429, _, _}}},
                       @interval_ms + 1_000

        quota_at = System.monotonic_time(:millisecond)
        assert_receive {:fleet, ^throttle_pid, %{action: {:hold, ^token}}}, @interval_ms + 1_000
        sent_at = System.monotonic_time(:millisecond)
        quota_polls = polls(quota)
        throttle_polls = polls(throttle)
        :ok = Fleet.release(throttle, token, @throttled)

        # With the quota route held, reads skip to the backup while the throttle is held
        # and return to the throttle once its cooldown ends; a late observer only
        # lengthens the measurement.
        Settle.await("throttled route held", fn ->
          if read(tenant, fleets) == [backup.name], do: {:ok, :held}
        end)

        Settle.await(
          "throttled route released",
          fn -> if read(tenant, fleets) == [throttle.name], do: {:ok, :released} end,
          10_000
        )

        # A transient throttle holds its route for the upstream's one-second hint.
        assert System.monotonic_time(:millisecond) - sent_at < 1_500
        assert polls(throttle) == throttle_polls

        # The released route serves reads, but its next poll waits a full interval from
        # the answer; the ledger is read only after that interval ends.
        wait_until(sent_at + @interval_ms)
        assert polls(throttle) == throttle_polls

        Settle.await(
          "throttled route polled again",
          fn -> if polls(throttle) > throttle_polls, do: {:ok, :polled} end,
          2 * @interval_ms + 1_000
        )

        # Past a 30 s floor, the quota route still serves no read and takes no poll.
        wait_until(quota_at + 31_000)
        assert read(tenant, fleets) == [throttle.name]
        assert polls(quota) == quota_polls
      after
        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  test "a round that opens early leaves a throttled route unpolled for a full interval" do
    # A six-second interval lets a round triggered three seconds in poll every route
    # whose half-interval tolerance has passed.
    interval_ms = 6_000
    unique = System.unique_integer([:positive])

    [throttle, backup] =
      fleets =
      for name <- ["early-throttle-429", "early-backup"],
          do: Fleet.start!(self(), "#{name}-#{unique}")

    joiner = Fleet.start!(self(), "early-joiner-#{unique}")
    observed = %{"background_observations" => true}

    try do
      tenant =
        Tenant.open!(fleets,
          chain: %{"monitoring" => %{"http_heads_interval_ms" => interval_ms}},
          providers: Map.new(fleets, &{&1.name, observed})
        )

      try do
        token = make_ref()
        throttle_pid = throttle.pid
        Fleet.script(throttle, "eth_blockNumber", [{:hold, token}], {:answer, "0x3e8"})

        assert_receive {:fleet, ^throttle_pid, %{action: {:hold, ^token}}}, interval_ms + 1_000
        sent_at = System.monotonic_time(:millisecond)
        throttle_polls = polls(throttle)
        backup_polls = polls(backup)
        :ok = Fleet.release(throttle, token, @throttled)

        # A new upstream's worker joins the chain's round, which opens shortly after,
        # well before the next regular round.
        wait_until(sent_at + div(interval_ms, 2))

        early =
          Tenant.open!([joiner],
            chain: %{"monitoring" => %{"http_heads_interval_ms" => interval_ms}},
            providers: %{joiner.name => observed}
          )

        try do
          Settle.await("a round opens before the regular one", fn ->
            if polls(backup) > backup_polls, do: {:ok, :early}
          end)

          assert System.monotonic_time(:millisecond) - sent_at < interval_ms - 1_000

          wait_until(sent_at + interval_ms)
          assert polls(throttle) == throttle_polls
        after
          Tenant.close!(early)
        end
      after
        Tenant.close!(tenant)
      end
    after
      Enum.each([joiner | fleets], &Fleet.stop/1)
    end
  end

  defp wait_until(deadline_ms) do
    receive do
    after
      max(0, deadline_ms - System.monotonic_time(:millisecond)) -> :ok
    end
  end

  defp polls(fleet),
    do: Enum.count(Fleet.drain(fleet), &(&1.request["method"] == "eth_blockNumber"))

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

defmodule Lasso.Test.Harness.SendPolicyTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-routing-1"]
  @send "eth_sendRawTransaction"
  @lookup "eth_getTransactionByHash"
  @raw "0x02f86c0180843b9aca0082520894111111111111111111111111111111111180c0"
  @balance ["0x0000000000000000000000000000000000000001", "latest"]

  test "stored chain policy bounds dispatch, pins, reads, recovery and public fallback" do
    journey(fn tenant, [public, relay] = fleets ->
      # An unset chain retains priority routing to the public provider.
      assert submit(tenant, fleets).body["result"] == hash()
      assert sends(public) != []
      assert sends(relay) == []

      Fleet.script(public, "eth_blockNumber", [], {:answer, "0x1000"})
      Fleet.script(relay, "eth_blockNumber", [], {:answer, "0x1"})
      assert Rpc.call(pinned(tenant, public), "eth_blockNumber").body["result"] == "0x1000"
      assert Rpc.call(pinned(tenant, relay), "eth_blockNumber").body["result"] == "0x1"

      Tenant.replace!(tenant, fleets, chain: policy(relay))

      # Relay head evidence trails the read provider but still admits a send.
      before = cursors(fleets)
      accepted = submit(tenant, fleets)
      assert accepted.body["result"] == hash()
      assert accepted.body["lasso_meta"]["selected_provider"]["id"] == relay.name
      assert accepted.body["lasso_meta"]["send_policy"] == metadata(relay, false, "relays")
      assert ledger(fleets, before, @send) |> names() == [relay.name]

      before = cursors(fleets)
      assert Rpc.call(tenant, "eth_getBalance", @balance).body["result"] == "0x10"
      assert ledger(fleets, before, "eth_getBalance") |> names() == [public.name]

      for {fleet, method, params, reason} <- [
            {public, @send, [@raw], "pin_outside_relays"},
            {relay, "eth_getBalance", @balance, "relay_send_only"}
          ] do
        before = cursors(fleets)
        response = Rpc.call(pinned(tenant, fleet), method, params)
        assert response.body["error"]["code"] == -32_602
        assert response.body["error"]["data"]["reason"] == reason
        assert ledger(fleets, before, method) == []
      end

      # Titan's mined-byte response remains null; it never triggers public dispatch.
      Fleet.script(relay, "eth_getBalance", [], {:error, -32_601, "method not found"})
      Fleet.script(relay, "eth_blockNumber", [], {:error, -32_601, "method not found"})
      Fleet.script(relay, @send, [], {:answer, nil})
      Fleet.script(relay, @lookup, [], {:error, -32_601, "method not found"})
      before = cursors(fleets)
      response = submit(tenant, fleets)
      assert response.body["result"] == nil
      assert response.body["lasso_meta"]["send_policy"] == metadata(relay, false, "relays")
      assert ledger(fleets, before, @send) |> names() == [relay.name]
      refute public.name in names(ledger(fleets, before, @lookup))

      Fleet.script(relay, @send, [], unavailable())
      before = cursors(fleets)
      response = submit(tenant, fleets)
      assert response.body["error"]["data"]["send_policy"] == metadata(relay, false, "relays")
      assert ledger(fleets, before, @send) |> names() == [relay.name]
      refute public.name in names(ledger(fleets, before, @lookup))

      Fleet.script(relay, @lookup, [], {:answer, %{"hash" => hash()}})
      before = cursors(fleets)
      confirmed = submit(tenant, fleets)
      assert confirmed.body["result"] == hash()
      assert ledger(fleets, before, @lookup) |> names() == [relay.name]
      assert ledger(fleets, before, @send) |> names() == [relay.name]
      Fleet.script(relay, @lookup, [], {:answer, nil})

      Tenant.replace!(tenant, fleets, chain: policy(relay, true))
      token = make_ref()
      Fleet.script(relay, @send, [{:hold, token}], unavailable())
      before = cursors(fleets)
      task = Task.async(fn -> submit(tenant, fleets) end)
      relay_pid = relay.pid

      assert_receive {:fleet, ^relay_pid,
                      %{request: %{"method" => @send}, action: {:hold, ^token}}}

      assert ledger([public], [hd(before)], @send) == []
      assert :ok = Fleet.release(relay, token, unavailable())
      response = Task.await(task, 5_000)
      assert response.body["result"] == hash(), inspect(response.body)
      assert response.body["lasso_meta"]["send_policy"] == metadata(relay, true, "public")

      assert Enum.sort(names(ledger(fleets, before, @send))) ==
               Enum.sort([public.name, relay.name])

      Tenant.replace!(tenant, fleets, chain: policy(relay))

      Fleet.script(relay, @lookup, [], unavailable())

      closed =
        Enum.reduce_while(1..12, nil, fn _, _ ->
          before = cursors(fleets)
          response = submit(tenant, fleets)

          if get_in(response.body, ["error", "data", "reason"]) == "relays_unavailable",
            do: {:halt, {response, before}},
            else: {:cont, nil}
        end)

      assert {closed_response, closed_cursor} = closed
      assert closed_response.body["error"]["code"] == -32_000
      assert closed_response.body["error"]["data"]["retry_after_ms"] > 0
      assert closed_response.body["error"]["data"]["error_type"] == "relay_unavailable"
      assert ledger(fleets, closed_cursor, @send) == []
      refute public.name in names(ledger(fleets, closed_cursor, @lookup))

      for block <- [
            %{"relays" => []},
            %{"relays" => ["missing"]},
            %{"relays" => [relay.name, relay.name]},
            %{"relays" => [relay.name, public.name]},
            %{"relays" => [relay.name], "public_fallback" => "yes"}
          ] do
        Tenant.reject_replace!(tenant, fleets, chain: %{"transactions" => block})
      end
    end)
  end

  test "a held relay send times out without public sends or hash disclosure" do
    journey(fn tenant, [public, relay] = fleets ->
      Tenant.replace!(tenant, fleets, chain: policy(relay))
      token = make_ref()
      Fleet.script(relay, @send, [], {:hold, token})
      before = cursors(fleets)
      task = Task.async(fn -> submit(tenant, fleets) end)
      relay_pid = relay.pid

      assert_receive {:fleet, ^relay_pid,
                      %{request: %{"method" => @send}, action: {:hold, ^token}}}

      response = Task.await(task, 5_000)
      assert response.body["error"]["data"]["send_policy"] == metadata(relay, false, "relays")
      assert ledger(fleets, before, @send) |> names() == [relay.name]
      refute public.name in names(ledger(fleets, before, @lookup))
      Fleet.release(relay, token, {:answer, hash()})
    end)
  end

  test "a retained subscription moves to the read view after a policy update" do
    fleets = Enum.map(["ws-relay", "ws-read"], &Fleet.start!(self(), &1))
    [relay, read] = fleets

    for fleet <- fleets do
      Fleet.script(fleet, "eth_getBlockByNumber", [], {:answer, head(1000)})
      Fleet.script(fleet, "eth_blockNumber", [], {:answer, "0x3e8"})
    end

    overrides =
      Map.new(fleets, &{&1.name, %{"ws_url" => &1.ws_url, "subscribe_new_heads" => true}})

    tenant = Tenant.open!(fleets, providers: overrides)

    uri = %{
      URI.parse(tenant.rpc_url)
      | scheme: "ws",
        path: "/ws/rpc/profile/#{tenant.profile}/priority/31337"
    }

    wire = Rpc.wire!(URI.to_string(uri))
    backup_uri = %{uri | path: "/ws/rpc/profile/#{tenant.profile}/provider/#{read.name}/31337"}
    backup = Rpc.wire!(URI.to_string(backup_uri))

    try do
      Rpc.send!(wire, "eth_subscribe", ["newHeads"], 1)
      ref = wire.reference
      assert_receive {:rpc_frame, ^ref, {:text, bytes}}, 5_000
      subscription = Jason.decode!(bytes)["result"]

      original =
        Settle.await("original relay subscription", fn ->
          case Enum.find(Fleet.drain(relay), &(&1.request["method"] == "eth_subscribe")) do
            nil -> :pending
            report -> {:ok, report}
          end
        end)

      Fleet.notify(original, head(1000))
      assert_head(wire, subscription, 1000)
      completed = Settle.listen([:lasso, :subs, :failover, :completed])
      Tenant.replace!(tenant, fleets, providers: overrides, chain: policy(relay))
      Rpc.send!(backup, "eth_subscribe", ["newHeads"], 3)

      replacement =
        Settle.await("replacement read subscription", fn ->
          case Enum.find(Fleet.drain(read), &(&1.request["method"] == "eth_subscribe")) do
            nil -> :pending
            report -> {:ok, report}
          end
        end)

      Settle.event(completed, &(&1.chain_id == 31337 and &1.key == "{:newHeads}"))
      Fleet.notify(replacement, head(1001))
      assert_head(wire, subscription, 1001)
      Rpc.send!(wire, "eth_chainId", [], 2)
      assert_receive {:rpc_frame, ^ref, {:text, bytes}}, 5_000
      assert %{"id" => 2, "result" => chain_id} = Jason.decode!(bytes)
      assert String.downcase(chain_id) == "0x7a69"
    after
      if Process.alive?(wire.pid), do: Rpc.close!(wire)
      if Process.alive?(backup.pid), do: Rpc.close!(backup)
      Tenant.close!(tenant)
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  defp head(height) do
    hex = fn n -> "0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0") end

    %{
      "number" => "0x" <> Integer.to_string(height, 16),
      "hash" => hex.(height),
      "parentHash" => hex.(height - 1),
      "timestamp" => "0x" <> Integer.to_string(System.system_time(:second), 16)
    }
  end

  defp assert_head(wire, subscription, height) do
    ref = wire.reference
    assert_receive {:rpc_frame, ^ref, {:text, bytes}}, 5_000

    assert %{
             "method" => "eth_subscription",
             "params" => %{"subscription" => ^subscription, "result" => result}
           } = Jason.decode!(bytes)

    observed = String.to_integer(String.replace_prefix(result["number"], "0x", ""), 16)

    if observed < height,
      do: assert_head(wire, subscription, height),
      else: assert(observed == height)
  end

  defp journey(scenario) do
    fleets = Enum.map(["public", "relay"], &Fleet.start!(self(), &1))

    try do
      for fleet <- fleets do
        Fleet.script(fleet, @send, [], {:answer, hash()})
        Fleet.script(fleet, @lookup, [], {:answer, nil})
      end

      tenant =
        Tenant.open!(fleets, providers: Map.new(fleets, &{&1.name, %{"heads" => "passive"}}))

      owners = Tenant.serving_owners()

      try do
        scenario.(tenant, fleets)
        assert Rpc.call(tenant, "eth_getBalance", @balance).body["result"] == "0x10"
        uri = %{URI.parse(tenant.rpc_url) | path: "/api/ready", query: nil}

        assert {:ok, %{status: 200}} =
                 Finch.build(:get, URI.to_string(uri)) |> Finch.request(Lasso.Finch)

        for {name, pid} <- owners,
            do: assert(is_pid(pid) and Process.whereis(name) == pid and Process.alive?(pid))
      after
        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  defp submit(tenant, _fleets),
    do: Rpc.call(%{rpc_url: tenant.rpc_url <> "?include_meta=body"}, @send, [@raw])

  defp pinned(tenant, fleet), do: %{rpc_url: tenant.rpc_url <> "?provider=" <> fleet.name}

  defp policy(relay, fallback \\ false),
    do: %{
      "selection" => %{"max_lag_blocks" => 1},
      "transactions" => %{"relays" => [relay.name], "public_fallback" => fallback}
    }

  defp metadata(relay, fallback, phase),
    do: %{"relays" => [relay.name], "public_fallback" => fallback, "phase" => phase}

  defp unavailable, do: {:status, 503, [], "Service Unavailable"}
  defp cursors(fleets), do: Enum.map(fleets, &length(Fleet.drain(&1)))

  defp ledger(fleets, cursors, method),
    do:
      Enum.zip(fleets, cursors)
      |> Enum.flat_map(fn {f, n} -> Enum.drop(Fleet.drain(f), n) end)
      |> Enum.filter(&(&1.request["method"] == method))

  defp sends(fleet), do: Enum.filter(Fleet.drain(fleet), &(&1.request["method"] == @send))
  defp names(reports), do: Enum.map(reports, & &1.fleet)

  defp hash,
    do:
      "0x" <>
        Base.encode16(
          ExKeccak.hash_256(Base.decode16!(String.slice(@raw, 2..-1//1), case: :mixed)),
          case: :lower
        )
end

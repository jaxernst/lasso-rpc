defmodule Lasso.Test.Harness.RawSendFailoverTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-failover-6"]

  @send "eth_sendRawTransaction"
  @lookup "eth_getTransactionByHash"
  @raw "0x02f86c0180843b9aca0082520894111111111111111111111111111111111111111180c0"
  @retry "It is safe to resend the same signed transaction."
  @stop "Check this transaction's hash for a receipt before signing a new one, then address the cause in the error message before retrying."

  test "a send the first upstream broadcast returns its hash when the second says already known" do
    journey(2, fn tenant, [first, second] = fleets ->
      Fleet.script(first, @send, [], {:error, -32_000, "internal server error"})
      Fleet.script(second, @send, [], {:error, -32_000, "already known"})
      Fleet.script(second, @lookup, [], {:answer, %{hash: hash()}})

      {body, sends, lookups} = submit(tenant, fleets)
      assert body["result"] == hash(), inspect(body)
      refute body["error"]
      assert_sends(sends, [first.name, second.name])
      assert_lookup(lookups, second.name)
    end)
  end

  test "an unlisted rejection after the broadcast still returns the hash the lookup finds" do
    journey(2, fn tenant, [first, second] = fleets ->
      Fleet.script(first, @send, [], {:error, -32_000, "internal server error"})
      Fleet.script(second, @send, [], {:error, -32_010, "submission refused by gateway"})
      Fleet.script(second, @lookup, [], {:answer, %{hash: hash()}})

      {body, sends, lookups} = submit(tenant, fleets)
      assert body["result"] == hash(), inspect(body)
      refute body["error"]
      assert_sends(sends, [first.name, second.name])
      assert_lookup(lookups, second.name)
    end)
  end

  test "a send the first upstream rate limits succeeds on the second without a lookup" do
    journey(2, fn tenant, [first, second] = fleets ->
      Fleet.script(first, @send, [], {:status, 429, [], "Too Many Requests"})
      Fleet.script(second, @send, [], {:answer, hash()})

      {body, sends, lookups} = submit(tenant, fleets)
      assert body["result"] == hash(), inspect(body)
      refute body["error"]
      assert_sends(sends, [first.name, second.name])
      assert lookups == []
    end)
  end

  test "a plaintext stop-list rejection in an HTTP 500 body stops at the first upstream" do
    for body <- [
          "insufficient funds for gas * price + value",
          "intrinsic gas too low",
          "nonce too high"
        ] do
      journey(2, fn tenant, [first, second] = fleets ->
        Fleet.script(first, @send, [], {:status, 500, [], body})
        Fleet.script(second, @send, [], {:answer, hash()})

        {response, sends, lookups} = submit(tenant, fleets)
        assert %{"code" => -32_000, "data" => %{"retryable" => false}} = response["error"]
        refute response["result"]
        assert_sends(sends, [first.name])
        assert_lookup(lookups, first.name)
      end)
    end
  end

  test "a possible broadcast is confirmed on its own upstream before a later nonce too low stands" do
    confirm_possible_broadcast("nonce too low")
  end

  test "a possible broadcast is confirmed on its own upstream before a later already known stands" do
    confirm_possible_broadcast("already known")
  end

  test "an unanswered lookup of a possible broadcast ends indeterminate instead of rejected" do
    for transport <- [:http, :ws],
        lookup <- [
          {:error, -32_000, "transaction indexing is in progress"},
          {:status, 503, [], "lookup unavailable"},
          {:disconnect, 1011}
        ] do
      journey(2, fn tenant, [primary, backup] = fleets ->
        Fleet.script(primary, @send, [], {:error, -32_000, "internal server error"})
        Fleet.script(primary, @lookup, [], lookup)
        Fleet.script(backup, @send, [], {:error, -32_000, "nonce too low"})
        {body, sends, lookups} = submit(tenant, fleets, transport)
        refute body["result"]
        assert body["error"]["code"] == -32_000
        assert body["error"]["message"] == "Upstream dispatch outcome is indeterminate"
        assert_sends(sends, [primary.name, backup.name])
        assert_lookups(lookups, [primary.name, backup.name])
      end)
    end
  end

  test "a stop stands once every send that may have broadcast reports the hash absent" do
    for transport <- [:http, :ws] do
      journey(2, fn tenant, [primary, backup] = fleets ->
        Fleet.script(primary, @send, [], {:error, -32_000, "internal server error"})
        Fleet.script(backup, @send, [], {:error, -32_000, "nonce too low"})
        {body, sends, lookups} = submit(tenant, fleets, transport)
        assert %{"code" => -32_000, "message" => "nonce too low", "data" => data} = body["error"]
        assert data["next_action"] == @stop
        assert_sends(sends, [primary.name, backup.name])
        assert_lookups(lookups, [primary.name, backup.name])
      end)
    end
  end

  test "a stop after recognized rejections or a single send keeps its one lookup" do
    for transport <- [:http, :ws] do
      journey(2, fn tenant, [primary, backup] = fleets ->
        Fleet.script(
          primary,
          @send,
          [],
          {:error, -32_000, "replacement transaction underpriced"}
        )

        Fleet.script(primary, @lookup, [], {:error, -32_000, "lookup unavailable"})
        Fleet.script(backup, @send, [], {:error, -32_000, "nonce too low"})
        {body, sends, lookups} = submit(tenant, fleets, transport)
        assert body["error"]["message"] == "nonce too low"
        assert_sends(sends, [primary.name, backup.name])
        assert_lookup(lookups, backup.name)
      end)

      journey(1, fn tenant, [primary] = fleets ->
        Fleet.script(primary, @send, [], {:error, -32_000, "nonce too low"})
        {body, sends, lookups} = submit(tenant, fleets, transport)
        assert %{"code" => -32_000, "message" => "nonce too low", "data" => data} = body["error"]
        assert data["next_action"] == @stop
        assert_sends(sends, [primary.name])
        assert_lookup(lookups, primary.name)

        Fleet.script(primary, @send, [], {:error, -32_000, "internal server error"})
        Fleet.script(primary, @lookup, [], {:error, -32_000, "lookup unavailable"})
        {body, sends, lookups} = submit(tenant, fleets, transport)
        assert body["error"]["message"] == "internal server error"
        assert_retry(body)
        assert_sends(sends, [primary.name])
        assert_lookup(lookups, primary.name)
      end)
    end
  end

  defp confirm_possible_broadcast(message) do
    for transport <- [:http, :ws],
        first <- [{:error, -32_000, "internal server error"}, {:disconnect, 1011}] do
      journey(2, fn tenant, [primary, backup] = fleets ->
        Fleet.script(primary, @send, [], first)
        Fleet.script(primary, @lookup, [], {:answer, %{hash: hash(), blockHash: nil}})
        Fleet.script(backup, @send, [], {:error, -32_000, message})
        {body, sends, lookups} = submit(tenant, fleets, transport)
        assert body["result"] == hash()
        refute body["error"]
        assert_sends(sends, [primary.name, backup.name])
        assert_lookups(lookups, [primary.name, backup.name])
      end)
    end
  end

  defp journey(count, scenario) do
    fleets = for n <- 1..count, do: Fleet.start!(self(), "transaction-#{n}")

    try do
      tenant = Tenant.open!(fleets)
      owners = Tenant.serving_owners()

      try do
        for fleet <- fleets, do: Fleet.script(fleet, @lookup, [], {:answer, nil})
        scenario.(tenant, fleets)
        assert %{body: %{"result" => "0x7a69"}} = Rpc.call(tenant, "eth_chainId")
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

  defp submit(tenant, fleets, transport \\ :http) do
    cursors = Enum.map(fleets, &length(Fleet.drain(&1)))
    id = "signed-transaction-#{System.unique_integer([:positive])}"

    {body, sends} =
      Settle.closed(
        fn ->
          body =
            case transport do
              :http ->
                response = Rpc.call(tenant, @send, [@raw], id: id)
                assert response.status == 200
                response.body

              :ws ->
                wire =
                  Rpc.wire!(
                    String.replace(tenant.rpc_url, "http://", "ws://")
                    |> String.replace("/rpc/", "/ws/rpc/")
                  )

                try do
                  Rpc.send!(wire, @send, [@raw], id)
                  assert_receive {:rpc_frame, reference, {:text, bytes}}
                  assert reference == wire.reference
                  Jason.decode!(bytes)
                after
                  Rpc.close!(wire)
                end
            end

          assert body["id"] == id
          body
        end,
        fleets,
        %{method: @send, params: [@raw]}
      )

    lookups =
      Enum.zip(fleets, cursors)
      |> Enum.flat_map(fn {fleet, cursor} -> Fleet.drain(fleet) |> Enum.drop(cursor) end)
      |> Enum.filter(&(&1.request["method"] == @lookup))

    {body, sends, lookups}
  end

  defp assert_sends(sends, names) do
    assert Enum.map(sends, & &1.fleet) == names
    assert length(Enum.uniq_by(sends, & &1.fleet)) == length(sends)
    assert Enum.all?(sends, &(&1.request["params"] == [@raw]))
  end

  defp assert_lookup(lookups, name) do
    assert [%{fleet: ^name, request: %{"params" => [expected]}}] = lookups
    assert expected == hash()
  end

  defp assert_lookups(lookups, names) do
    assert Enum.map(lookups, & &1.fleet) == names
    assert Enum.all?(lookups, &(&1.request["params"] == [hash()]))
  end

  defp assert_retry(body) do
    assert body["error"]["data"]["retryable"] == true
    assert body["error"]["data"]["next_action"] == @retry
  end

  defp hash do
    "0x" <> raw = @raw

    "0x" <>
      Base.encode16(ExKeccak.hash_256(Base.decode16!(raw, case: :mixed)), case: :lower)
  end
end

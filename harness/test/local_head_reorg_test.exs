defmodule Lasso.Harness.LocalHeadReorgTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-head-policy-1"]

  test "the floor provider can replace its head while a fallback retains the orphan" do
    world(fn tenant, primary, fallback ->
      a = header(100, "a")
      b = header(100, "b")
      serve(primary, a, a)
      serve(fallback, a, b)
      assert head(tenant) == a
      serve(primary, b, b)
      assert head(tenant) == b
      canonical_read(tenant, b)
      # A conflicting fallback cannot restore the displaced hash during failover.
      Fleet.script(primary, "eth_getBlockByNumber", [], {:error, -32_603, "internal error"})
      assert %{"error" => _} = Rpc.call(tenant, "eth_getBlockByNumber", ["latest", false]).body
      serve(fallback, b, b)
      assert head(tenant) == b
      canonical_read(tenant, b)
      serve(primary, header(99, "c"), b)
      serve(fallback, header(99, "c"), b)
      assert %{"error" => _} = Rpc.call(tenant, "eth_getBlockByNumber", ["latest", false]).body
    end)
  end

  test "replacement succeeds when all providers have moved, but a different provider cannot invent it" do
    world(fn tenant, primary, fallback ->
      a = header(100, "a")
      b = header(100, "b")
      serve(primary, a, a)
      serve(fallback, b, b)
      assert head(tenant) == a
      pinned = %{rpc_url: tenant.rpc_url <> "?provider_override=" <> fallback.name}
      assert %{"error" => _} = Rpc.call(pinned, "eth_getBlockByNumber", ["latest", false]).body
      serve(primary, b, b)
      assert head(tenant) == b
      canonical_read(tenant, b)
    end)
  end

  test "an old in-flight answer cannot restore the displaced hash" do
    world(fn tenant, primary, fallback ->
      a = header(100, "a")
      b = header(100, "b")
      serve(primary, a, a)
      serve(fallback, a, b)
      assert head(tenant) == a
      token = make_ref()
      Fleet.script(primary, "eth_getBlockByNumber", [{:hold, token}], {:answer, b})
      old = Task.async(fn -> Rpc.call(tenant, "eth_getBlockByNumber", ["latest", false]) end)

      try do
        Settle.await("old head response held", fn ->
          if Enum.any?(Fleet.drain(primary), &(&1.action == {:hold, token})), do: {:ok, :held}
        end)

        assert head(tenant) == b
        Fleet.release(primary, token, {:answer, a})
        assert %{"error" => _} = Task.await(old, :infinity).body
        assert head(tenant) == b
      after
        if Process.alive?(old.pid), do: Task.shutdown(old, :brutal_kill)
      end
    end)
  end

  test "a higher block transfers authority to the provider that advances the floor" do
    world(fn tenant, primary, fallback ->
      a = header(100, "a")
      b = header(101, "b")
      c = header(101, "c")
      serve(primary, a, a)
      serve(fallback, b, b)
      assert head(tenant) == a
      pinned = %{rpc_url: tenant.rpc_url <> "?provider_override=" <> fallback.name}
      assert head(pinned) == b
      serve(primary, c, c)

      assert %{"error" => _} =
               Rpc.call(
                 %{rpc_url: tenant.rpc_url <> "?provider_override=" <> primary.name},
                 "eth_getBlockByNumber",
                 ["latest", false]
               ).body

      serve(fallback, c, c)
      assert head(pinned) == c
      canonical_read(pinned, c)
    end)
  end

  defp world(action) do
    primary = Fleet.start!(self(), "reorg-primary")
    fallback = Fleet.start!(self(), "reorg-fallback")

    try do
      tenant =
        Tenant.open!([primary, fallback],
          chain: %{"head_policy" => "local"}
        )

      try do
        action.(tenant, primary, fallback)
      after
        Tenant.close!(tenant)
      end
    after
      Fleet.stop(primary)
      Fleet.stop(fallback)
    end
  end

  defp serve(fleet, latest, canonical) do
    Fleet.script(fleet, "eth_getBlockByNumber", [], {:answer, latest})
    canonical_hash = canonical["hash"]

    Fleet.script(
      fleet,
      "eth_call",
      [],
      {:respond,
       fn request ->
         case request["params"] do
           [_, %{"blockHash" => hash, "requireCanonical" => true}] when hash == canonical_hash ->
             {:answer, "0x01"}

           _ ->
             {:error, -32_001, "block not found: canonical hash"}
         end
       end}
    )
  end

  defp head(tenant) do
    response = Rpc.call(tenant, "eth_getBlockByNumber", ["latest", false])
    assert %{"result" => header} = response.body
    header
  end

  defp canonical_read(tenant, header) do
    response =
      Rpc.call(tenant, "eth_call", [
        %{"to" => "0x" <> String.duplicate("11", 20)},
        %{"blockHash" => header["hash"], "requireCanonical" => true}
      ])

    assert response.body["result"] == "0x01"
  end

  defp header(height, digit) do
    %{
      "number" => "0x" <> Integer.to_string(height, 16),
      "hash" => "0x" <> String.duplicate(digit, 64),
      "timestamp" => "0x" <> Integer.to_string(System.system_time(:second), 16)
    }
  end
end

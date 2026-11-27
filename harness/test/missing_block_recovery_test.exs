defmodule Lasso.Harness.MissingBlockRecoveryTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-failover-9"]

  @block 10_001
  @params ["0x" <> String.duplicate("11", 20), "0x2711"]

  # Breakers read their recovery timeout when an upstream's instance starts, so a
  # short one lets a supporter whose breaker opened reach half-open within the journey.
  setup do
    previous = Application.get_env(:lasso, :circuit_breaker, [])
    Application.put_env(:lasso, :circuit_breaker, Keyword.put(previous, :recovery_timeout, 50))
    on_exit(fn -> Application.put_env(:lasso, :circuit_breaker, previous) end)
    :ok
  end

  test "a block laggards refuse as header not found reaches the half-open upstream that has it" do
    behind = @block - 1_001

    for strategy <- ~w(priority fastest balanced-fast load-balanced) do
      world("missing-#{strategy}", [behind, behind, behind, @block + 1], fn tenant, fleets ->
        {laggards, [supporter]} = Enum.split(fleets, 3)
        lagging = Enum.map(laggards, & &1.name)

        for fleet <- laggards,
            do: Fleet.script(fleet, "eth_getBalance", [], {:error, -32_000, "header not found"})

        instance = half_open!(tenant, supporter)
        closed = Settle.listen([:lasso, :circuit_breaker, :close])

        # The half-open supporter is the cursor's last candidate, behind three closed
        # laggards, until two admitted reads close its breaker.
        for _read <- 1..2 do
          {response, sent} = read(tenant, fleets, strategy)

          assert response.body["result"] == "0x10",
                 "#{strategy}: #{inspect({response.body, sent})}"

          assert [first, last] = sent, "#{strategy}: #{inspect(sent)}"
          assert first in lagging
          assert last == supporter.name
        end

        Settle.event(closed, &(&1.instance_id == instance and &1.transport == :http))
        Settle.unlisten(closed)

        {response, sent} = read(tenant, fleets, strategy)
        assert response.body["result"] == "0x10"
        assert sent == [supporter.name]
      end)
    end
  end

  test "a supporter ahead of a demoted laggard that fails still fails over to the next one" do
    behind = @block - 1_001

    world("past-laggard", [@block + 1, behind, @block + 1, @block + 1], fn tenant, fleets ->
      [missing, lagging, failing, serving] = fleets
      Fleet.script(missing, "eth_getBalance", [], {:error, -32_000, "header not found"})
      Fleet.script(lagging, "eth_getBalance", [], {:error, -32_000, "header not found"})
      Fleet.script(failing, "eth_getBalance", [], {:status, 503, [], "<html>unavailable</html>"})
      half_open!(tenant, failing)
      half_open!(tenant, serving)

      # The closed laggard precedes both half-open supporters, so a read that sent to
      # it would spend its third dispatch on the failing supporter and never reach
      # the serving one.
      {response, sent} = read(tenant, fleets, "priority")
      assert response.body["result"] == "0x10", inspect({response.body, sent})
      assert sent == [missing.name, failing.name, serving.name]
    end)
  end

  test "an upstream with an unknown head keeps its place after a missing-block error" do
    world("unknown", [@block + 1, nil, @block + 1], fn tenant, fleets ->
      [missing, unknown, failing] = fleets
      Fleet.script(missing, "eth_getBalance", [], {:error, -32_000, "header not found"})
      Fleet.script(failing, "eth_getBalance", [], {:status, 503, [], "<html>unavailable</html>"})
      half_open!(tenant, failing)

      {response, sent} = read(tenant, fleets, "priority")
      assert response.body["result"] == "0x10", inspect({response.body, sent})
      assert sent == [missing.name, unknown.name]
    end)
  end

  test "a slow half-open supporter leaves the deadline to a ready upstream with an unknown head" do
    timeouts = Application.get_env(:lasso, :method_timeouts, %{})
    Application.put_env(:lasso, :method_timeouts, Map.put(timeouts, "eth_getBalance", 350))
    on_exit(fn -> Application.put_env(:lasso, :method_timeouts, timeouts) end)

    world("slow", [@block + 1, nil, @block + 1], fn tenant, fleets ->
      [missing, serving, slow] = fleets
      Fleet.script(missing, "eth_getBalance", [], {:error, -32_000, "header not found"})
      half_open!(tenant, slow)
      token = make_ref()
      Fleet.script(slow, "eth_getBalance", [], {:hold, token})

      try do
        {response, sent} = read(tenant, fleets, "priority")
        assert response.body["result"] == "0x10", inspect({response.body, sent})
        assert sent == [missing.name, serving.name]
      after
        Fleet.release(slow, token, {:answer, "0x10"})
      end
    end)
  end

  test "a missing-block error leaves the extra send for a null that follows it" do
    world("then-null", [@block + 1, @block + 1, @block + 1], fn tenant, fleets ->
      [missing, null, serving] = fleets
      block = %{"number" => hex(@block), "hash" => "0x" <> String.duplicate("ab", 32)}
      params = [hex(@block), false]
      Fleet.script(missing, "eth_getBlockByNumber", [], {:error, -32_000, "header not found"})
      Fleet.script(null, "eth_getBlockByNumber", [], {:answer, nil})
      Fleet.script(serving, "eth_getBlockByNumber", [], {:answer, block})

      {response, sent} = read(tenant, fleets, "priority", "eth_getBlockByNumber", params)
      assert response.body["result"] == block, inspect({response.body, sent})
      assert sent == Enum.map(fleets, & &1.name)
    end)
  end

  test "an upstream that caught up since its last head poll still serves the block" do
    for strategy <- ~w(priority fastest balanced-fast load-balanced) do
      world("catchup-#{strategy}", [@block + 1, @block - 1_001], fn tenant, fleets ->
        [missing, caught_up] = fleets
        Fleet.script(caught_up, "eth_blockNumber", [], {:answer, hex(@block + 1)})

        assert Rpc.call(%{rpc_url: caught_up.url}, "eth_blockNumber").body["result"] ==
                 hex(@block + 1)

        Fleet.script(missing, "eth_getBalance", [], {:error, -32_000, "header not found"})
        Fleet.script(caught_up, "eth_getBalance", [], {:answer, "0x42"})

        # Lasso still holds the poll that saw 9,000, which stays short of the block.
        {response, sent} = read(tenant, fleets, strategy)
        assert response.body["result"] == "0x42", "#{strategy}: #{inspect({response.body, sent})}"
        assert caught_up.name in sent
        assert length(sent) <= 2
      end)
    end
  end

  test "a laggard stays behind the supporter after an ordinary failure follows the missing-block error" do
    behind = @block - 1_001

    world("after-503", [@block + 1, nil, behind, @block + 1], fn tenant, fleets ->
      [missing, unknown, lagging, supporter] = fleets
      Fleet.script(missing, "eth_getBalance", [], {:error, -32_000, "header not found"})
      Fleet.script(unknown, "eth_getBalance", [], {:status, 503, [], "<html>unavailable</html>"})
      Fleet.script(lagging, "eth_getBalance", [], {:error, -32_000, "header not found"})
      half_open!(tenant, supporter)

      # The unknown route's 503 carries no head evidence, so a read that forgot the
      # missing-block error would spend its third dispatch on the laggard.
      {response, sent} = read(tenant, fleets, "priority")
      assert response.body["result"] == "0x10", inspect({response.body, sent})
      assert sent == [missing.name, unknown.name, supporter.name]
    end)
  end

  defp world(prefix, heads, fun) do
    fleets =
      for {head, i} <- Enum.with_index(heads, 1) do
        fleet = Fleet.start!(self(), "#{prefix}-#{i}")
        Fleet.script(fleet, "eth_blockNumber", [], head_answer(head))
        fleet
      end

    tenant =
      Tenant.open!(fleets,
        chain: %{
          "block_time_ms" => 2_000,
          "monitoring" => %{"http_heads_interval_ms" => 600_000}
        },
        providers: Map.new(fleets, &{&1.name, %{"background_observations" => true}})
      )

    try do
      Settle.await("every upstream reports its head", fn ->
        if Enum.all?(fleets, &head_polled?/1), do: {:ok, :polled}
      end)

      fun.(tenant, fleets)
    after
      Tenant.close!(tenant)
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  # Five HTTP 503s to a pinned read open the upstream's breaker, which turns
  # half-open once its recovery timeout passes.
  defp half_open!(tenant, fleet) do
    instance = Lasso.Providers.Catalog.lookup_instance_id(tenant.profile, 31_337, fleet.name)
    recovered = Settle.listen([:lasso, :circuit_breaker, :proactive_recovery])

    try do
      Fleet.script(fleet, "fixture_breaker", [], {:status, 503, [], "unavailable"})
      pinned = %{rpc_url: tenant.rpc_url <> "?provider=" <> fleet.name}
      for _ <- 1..5, do: assert(Rpc.call(pinned, "fixture_breaker").body["error"])
      Settle.event(recovered, &(&1.instance_id == instance and &1.transport == :http))
      instance
    after
      Settle.unlisten(recovered)
    end
  end

  defp read(tenant, fleets, strategy, method \\ "eth_getBalance", params \\ @params) do
    url = String.replace(tenant.rpc_url, "/priority/", "/#{strategy}/")

    {response, sends} =
      Settle.closed(
        fn -> Rpc.call(%{rpc_url: url}, method, params) end,
        fleets,
        %{method: method, params: params}
      )

    # Sends come back grouped by fleet, in the order the fleets are passed.
    {response, Enum.map(sends, & &1.fleet)}
  end

  defp head_polled?(fleet),
    do: Enum.any?(Fleet.drain(fleet), &(&1.request["method"] == "eth_blockNumber"))

  defp head_answer(nil), do: {:error, -32_603, "internal error"}
  defp head_answer(head), do: {:answer, hex(head)}

  defp hex(n), do: "0x" <> Integer.to_string(n, 16)
end

defmodule Lasso.Harness.HeadFreshnessTest do
  use ExUnit.Case, async: false
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-routing-7"]

  @behind 9_950
  @current 10_000
  @address "0x" <> String.duplicate("11", 20)
  @hash "0x" <> String.duplicate("ab", 32)

  test "a lagging primary keeps historical reads and loses every read that needs the head" do
    world(fn tenant, [primary | current] = fleets ->
      lead(tenant, fleets)
      tx = %{"to" => @address, "data" => "0x12345678"}

      for strategy <- ["priority", "load-balanced", "fastest", "balanced-fast"],
          {method, params} <- [
            {"eth_getBalance", [@address, "latest"]},
            {"eth_getBalance", [@address]},
            {"eth_call", [tx]},
            {"eth_estimateGas", [tx]},
            {"eth_getTransactionCount", [@address]},
            {"eth_blockNumber", []},
            {"eth_getTransactionReceipt", [@hash]},
            {"eth_getLogs", [%{"fromBlock" => hex(9_990), "toBlock" => "latest"}]},
            {"eth_getLogs", [%{"fromBlock" => hex(9_990)}]},
            {"eth_getLogs", [%{"fromBlock" => hex(9_990), "toBlock" => hex(@current)}]}
          ] do
        assert [sent] = sends(tenant, fleets, method, params, strategy)
        assert sent in Enum.map(current, & &1.name), "#{strategy} #{method} #{inspect(params)}"
      end

      for {method, params} <- [
            {"eth_getBalance", [@address, hex(9_000)]},
            {"eth_call", [tx, hex(9_000)]},
            {"eth_call", [tx, "finalized"]},
            {"eth_getBlockByHash", [@hash, false]},
            {"eth_getLogs", [%{"fromBlock" => hex(8_990), "toBlock" => hex(9_000)}]},
            {"eth_sendRawTransaction", ["0x02f86c0180843b9aca00825208"]}
          ] do
        assert sends(tenant, fleets, method, params) == [primary.name],
               "#{method} #{inspect(params)}"
      end
    end)
  end

  test "a deferred lagging route still serves when the current routes fail" do
    world(fn tenant, [primary | current] = fleets ->
      lead(tenant, fleets)

      for fleet <- current,
          do:
            Fleet.script(fleet, "eth_getBalance", [{:status, 503, [], "<html>unavailable</html>"}])

      Fleet.script(primary, "eth_getBalance", [], {:answer, "0x5"})
      params = [@address, "latest"]

      {response, reports} =
        Settle.closed(
          fn -> Rpc.call(Tenant.credentials(tenant), "eth_getBalance", params) end,
          fleets,
          %{method: "eth_getBalance", params: params}
        )

      # Every route answers only when the current routes are tried first.
      assert %{status: 200, body: %{"result" => "0x5"}} = response
      assert Enum.sort(Enum.map(reports, & &1.fleet)) == Enum.sort(Enum.map(fleets, & &1.name))
    end)
  end

  test "a primary its round found behind stays deferred while passive reads raise the mark" do
    # A 20 ms block time caps the band at 20 blocks and makes request time worth many blocks
    # of credit. Pinned reads keep the current routes' observations new while the primary's
    # ages, so crediting that age would undefer the primary within a few hundred milliseconds.
    world(
      fn tenant, [primary, current | _rest] = fleets ->
        lead(tenant, fleets)
        pinned = %{rpc_url: tenant.rpc_url <> "?provider_override=" <> current.name}
        deadline = System.monotonic_time(:millisecond) + 1_000

        Stream.repeatedly(fn ->
          assert %{body: %{"result" => result}} = Rpc.call(pinned, "eth_blockNumber")
          assert result == hex(@current)
          assert [sent] = sends(tenant, fleets, "eth_getBalance", [@address, "latest"])
          assert sent != primary.name
        end)
        |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
        |> Stream.run()
      end,
      behind: @current - 50,
      chain: %{"block_time_ms" => 20}
    )
  end

  test "a two-route profile defers its lagging primary until a round finds it caught up" do
    world(
      fn tenant, [primary, _current] = fleets ->
        lead(tenant, fleets)
        Fleet.script(primary, "eth_blockNumber", [], {:answer, hex(@current)})

        Settle.await("the next round returns latest reads to the caught-up primary", fn ->
          case sends(tenant, fleets, "eth_getBalance", [@address, "latest"]) do
            [name] = sent when name == primary.name -> {:ok, sent}
            other -> other
          end
        end)
      end,
      upstreams: 2,
      behind: @current - 50,
      chain: %{"monitoring" => %{"http_heads_interval_ms" => 1_000}}
    )
  end

  test "another profile's rounds leave a profile's measured lag in place" do
    slow = fleets!("freshness-slow", [@behind, @current, @current])
    fast = fleets!("freshness-fast", [@current, @current, @current])

    try do
      slow_tenant = open!(slow)

      try do
        lead(slow_tenant, slow)
        fast_tenant = open!(fast, %{"monitoring" => %{"http_heads_interval_ms" => 1_000}})

        try do
          Settle.await(
            "the other profile's upstreams answer five rounds",
            fn -> if Enum.all?(fast, &(head_polls(&1) >= 5)), do: {:ok, :polled} end,
            10_000
          )

          assert [sent] = sends(slow_tenant, slow, "eth_getBalance", [@address, "latest"])
          assert sent != hd(slow).name
          assert Enum.all?(slow, &(head_polls(&1) == 1))
        after
          Tenant.close!(fast_tenant)
        end
      after
        Tenant.close!(slow_tenant)
      end
    after
      Enum.each(slow ++ fast, &Fleet.stop/1)
    end
  end

  test "a measured lag lasts as long as the route's head observations, not three probes" do
    world(
      fn tenant, [primary | _current] = fleets ->
        lead(tenant, fleets)
        deadline = System.monotonic_time(:millisecond) + 4_000

        Stream.repeatedly(fn ->
          assert [sent] = sends(tenant, fleets, "eth_getBalance", [@address, "latest"])
          assert sent != primary.name
        end)
        |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
        |> Stream.run()

        assert Enum.all?(fleets, &(head_polls(&1) == 1))
      end,
      chain: %{
        "monitoring" => %{"probe_interval_ms" => 1_000, "http_heads_interval_ms" => 10_000}
      }
    )
  end

  test "a profile with background observations off keeps strategy order on judged upstreams" do
    [primary | _current] = fleets = fleets!("freshness-shared", [@behind, @current, @current])

    try do
      heads_off = Tenant.open!(fleets)

      try do
        observed = open!(fleets)

        try do
          lead(observed, fleets)

          assert sends(heads_off, fleets, "eth_getBalance", [@address, "latest"]) == [
                   primary.name
                 ]
        after
          Tenant.close!(observed)
        end
      after
        Tenant.close!(heads_off)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  test "a round counts answers that arrive after the next tick" do
    [primary | current] = fleets = fleets!("freshness-late", [@behind, @current, @current])

    for fleet <- current,
        do:
          Fleet.script(fleet, "eth_blockNumber", [], {:respond, fn _ -> {:hold, make_ref()} end})

    release = fn ->
      for fleet <- current,
          %{action: {:hold, token}} <- Fleet.drain(fleet),
          do: Fleet.release(fleet, token, {:answer, hex(@current)})
    end

    try do
      tenant = open!(fleets, %{"monitoring" => %{"http_heads_interval_ms" => 1_000}})

      try do
        # The primary's second poll belongs to the next tick, which opens while the current
        # routes still owe the first round their answers.
        Settle.await("the next tick opens while the first round waits", fn ->
          if head_polls(primary) >= 2 and Enum.all?(current, &(head_polls(&1) >= 1)),
            do: {:ok, :waiting}
        end)

        release.()
        lead(tenant, fleets)
      after
        Tenant.close!(tenant)
      end
    after
      release.()
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  # Three upstreams by default, so the round's outlier rule applies. The round polls each
  # once when the tenant opens; its long interval keeps later rounds out of the sends.
  defp world(action, opts \\ []) do
    heights = [Keyword.get(opts, :behind, @behind), @current, @current]
    fleets = fleets!("freshness", Enum.take(heights, Keyword.get(opts, :upstreams, 3)))

    try do
      tenant = open!(fleets, Keyword.get(opts, :chain, %{}))

      try do
        action.(tenant, fleets)
      after
        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
  end

  defp fleets!(prefix, heights) do
    for {height, i} <- Enum.with_index(heights) do
      fleet = Fleet.start!(self(), "#{prefix}-#{i}")
      Fleet.script(fleet, "eth_blockNumber", [], {:answer, hex(height)})
      fleet
    end
  end

  # A retired lag limit still loads and no longer excludes the lagging route.
  defp open!(fleets, chain \\ %{}) do
    Tenant.open!(fleets,
      chain:
        Map.merge(
          %{
            "selection" => %{"max_lag_blocks" => 10},
            "monitoring" => %{"http_heads_interval_ms" => 600_000}
          },
          chain
        ),
      providers: Map.new(fleets, &{&1.name, %{"background_observations" => true}})
    )
  end

  defp lead(tenant, [primary | _current] = fleets) do
    Settle.await("a round defers the lagging primary for latest reads", fn ->
      case sends(tenant, fleets, "eth_getBalance", [@address, "latest"]) do
        [name] = sent when name != primary.name -> {:ok, sent}
        other -> other
      end
    end)
  end

  defp sends(tenant, fleets, method, params, strategy \\ "priority") do
    credentials = %{rpc_url: String.replace(tenant.rpc_url, "/priority/", "/#{strategy}/")}

    {response, reports} =
      Settle.closed(
        fn -> Rpc.call(credentials, method, params) end,
        fleets,
        %{method: method, params: params}
      )

    assert response.status == 200
    Enum.map(reports, & &1.fleet)
  end

  defp head_polls(fleet),
    do: Enum.count(Fleet.drain(fleet), &(&1.request["method"] == "eth_blockNumber"))

  defp hex(height), do: "0x" <> String.downcase(Integer.to_string(height, 16))
end

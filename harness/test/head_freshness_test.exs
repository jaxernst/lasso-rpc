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

  # Three upstreams so the round's outlier rule can judge them. The round polls each once
  # when the tenant opens; its long interval keeps later rounds out of the sends.
  defp world(action, opts \\ []) do
    behind = Keyword.get(opts, :behind, @behind)

    fleets =
      for {name, height} <- [
            {"freshness-primary", behind},
            {"freshness-current", @current},
            {"freshness-current-2", @current}
          ] do
        fleet = Fleet.start!(self(), name)
        Fleet.script(fleet, "eth_blockNumber", [], {:answer, hex(height)})
        fleet
      end

    try do
      # A retired lag limit still loads and no longer excludes the lagging route.
      tenant =
        Tenant.open!(fleets,
          chain:
            Map.merge(
              %{
                "selection" => %{"max_lag_blocks" => 10},
                "monitoring" => %{"http_heads_interval_ms" => 600_000}
              },
              Keyword.get(opts, :chain, %{})
            ),
          providers: Map.new(fleets, &{&1.name, %{"background_observations" => true}})
        )

      try do
        action.(tenant, fleets)
      after
        Tenant.close!(tenant)
      end
    after
      Enum.each(fleets, &Fleet.stop/1)
    end
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

  defp hex(height), do: "0x" <> String.downcase(Integer.to_string(height, 16))
end

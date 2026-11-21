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
    world(fn tenant, primary, current ->
      observe(tenant, primary, current)
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
        assert sends(tenant, [primary, current], method, params, strategy) == [current.name],
               "#{strategy} #{method} #{inspect(params)}"
      end

      for {method, params} <- [
            {"eth_getBalance", [@address, hex(9_000)]},
            {"eth_call", [tx, hex(9_000)]},
            {"eth_call", [tx, "finalized"]},
            {"eth_getBlockByHash", [@hash, false]},
            {"eth_getLogs", [%{"fromBlock" => hex(8_990), "toBlock" => hex(9_000)}]},
            {"eth_sendRawTransaction", ["0x02f86c0180843b9aca00825208"]}
          ] do
        assert sends(tenant, [primary, current], method, params) == [primary.name],
               "#{method} #{inspect(params)}"
      end
    end)
  end

  test "a deferred lagging route still serves when the current route fails" do
    world(fn tenant, primary, current ->
      observe(tenant, primary, current)
      Fleet.script(current, "eth_getBalance", [{:status, 503, [], "<html>unavailable</html>"}])
      Fleet.script(primary, "eth_getBalance", [], {:answer, "0x5"})
      params = [@address, "latest"]

      {response, reports} =
        Settle.closed(
          fn -> Rpc.call(Tenant.credentials(tenant), "eth_getBalance", params) end,
          [primary, current],
          %{method: "eth_getBalance", params: params}
        )

      # Both routes answer only when the current route is tried first.
      assert %{status: 200, body: %{"result" => "0x5"}} = response
      assert Enum.sort(Enum.map(reports, & &1.fleet)) == Enum.sort([current.name, primary.name])
    end)
  end

  test "a primary steadily behind the mark stays deferred for latest reads as both observations age" do
    # A 20 ms block time caps the band at 20 blocks and makes ordinary request time worth
    # many blocks of credit, while observations stay fresh for 30 s. Observed together, the
    # primary is thirty blocks past the band, so crediting its own age alone would undefer it.
    world(
      fn tenant, primary, current ->
        observe(tenant, primary, current, @current - 50)
        deadline = System.monotonic_time(:millisecond) + 600

        Stream.repeatedly(fn ->
          assert sends(tenant, [primary, current], "eth_getBalance", [@address, "latest"]) ==
                   [current.name]
        end)
        |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
        |> Stream.run()
      end,
      %{"block_time_ms" => 20}
    )
  end

  defp world(action, chain \\ %{}) do
    primary = Fleet.start!(self(), "freshness-primary")
    current = Fleet.start!(self(), "freshness-current")

    try do
      # A retired lag limit still loads and no longer excludes the lagging route.
      tenant =
        Tenant.open!([primary, current],
          chain: Map.merge(%{"selection" => %{"max_lag_blocks" => 10}}, chain)
        )

      try do
        action.(tenant, primary, current)
      after
        Tenant.close!(tenant)
      end
    after
      Fleet.stop(primary)
      Fleet.stop(current)
    end
  end

  # Pinned head reads record each route's head; the moving-head preference
  # becomes visible once both observations are published.
  defp observe(tenant, primary, current, behind \\ @behind) do
    for {fleet, height} <- [{primary, behind}, {current, @current}] do
      Fleet.script(fleet, "eth_blockNumber", [], {:answer, hex(height)})
      pinned = %{rpc_url: tenant.rpc_url <> "?provider_override=" <> fleet.name}
      assert %{body: %{"result" => result}} = Rpc.call(pinned, "eth_blockNumber")
      assert result == hex(height)
    end

    Settle.await("current route leads latest reads", fn ->
      case sends(tenant, [primary, current], "eth_getBalance", [@address, "latest"]) do
        [name] = sent when name == current.name -> {:ok, sent}
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

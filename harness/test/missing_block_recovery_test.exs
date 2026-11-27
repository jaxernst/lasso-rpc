defmodule Lasso.Harness.MissingBlockRecoveryTest do
  use ExUnit.Case, async: false
  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Test.Harness.{Fleet, Rpc, Settle, Tenant}

  @moduletag :harness
  @moduletag feature: ["core-failover-9"]

  @block 10_001
  @params ["0x" <> String.duplicate("11", 20), "0x2711"]

  # Breakers read their recovery timeout when an upstream's instance starts, so a
  # short one lets an opened supporter reach half-open within the journey.
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

        breaker = half_open!(tenant, supporter)

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

        Settle.await("#{strategy} supporter breaker closes", fn ->
          case CircuitBreaker.get_state(breaker) do
            %{state: :closed} -> {:ok, :closed}
            other -> other
          end
        end)

        {response, sent} = read(tenant, fleets, strategy)
        assert response.body["result"] == "0x10"
        assert sent == [supporter.name]
      end)
    end
  end

  test "a steered send that fails still fails over to the next upstream with the block" do
    world("steered", [@block + 1, @block + 1, @block + 1], fn tenant, fleets ->
      [missing, failing, _serving] = fleets
      Fleet.script(missing, "eth_getBalance", [], {:error, -32_000, "header not found"})
      Fleet.script(failing, "eth_getBalance", [], {:status, 503, [], "<html>unavailable</html>"})

      {response, sent} = read(tenant, fleets, "priority")
      assert response.body["result"] == "0x10", inspect({response.body, sent})
      assert sent == Enum.map(fleets, & &1.name)
    end)
  end

  defp world(prefix, heads, fun) do
    fleets =
      for {head, i} <- Enum.with_index(heads, 1) do
        fleet = Fleet.start!(self(), "#{prefix}-#{i}")
        Fleet.script(fleet, "eth_blockNumber", [], {:answer, hex(head)})
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

  defp half_open!(tenant, fleet) do
    instance = Lasso.Providers.Catalog.lookup_instance_id(tenant.profile, 31_337, fleet.name)
    breaker = {instance, :http}
    recovered = Settle.listen([:lasso, :circuit_breaker, :proactive_recovery])

    try do
      CircuitBreaker.open(breaker)
      Settle.event(recovered, &(&1.instance_id == instance and &1.transport == :http))
      breaker
    after
      Settle.unlisten(recovered)
    end
  end

  defp read(tenant, fleets, strategy) do
    url = String.replace(tenant.rpc_url, "/priority/", "/#{strategy}/")

    {response, sends} =
      Settle.closed(
        fn -> Rpc.call(%{rpc_url: url}, "eth_getBalance", @params) end,
        fleets,
        %{method: "eth_getBalance", params: @params}
      )

    {response, Enum.map(sends, & &1.fleet)}
  end

  defp head_polled?(fleet),
    do: Enum.any?(Fleet.drain(fleet), &(&1.request["method"] == "eth_blockNumber"))

  defp hex(n), do: "0x" <> Integer.to_string(n, 16)
end

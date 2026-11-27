defmodule Lasso.Harness.WebSocketMethodTimeoutTest do
  use ExUnit.Case, async: false
  alias Lasso.Config.MethodPolicy
  alias Lasso.Test.Harness.{Fleet, Rpc, Tenant}
  @moduletag :harness
  @moduletag feature: ["core-websocket-7"]

  @long_method "debug_traceTransaction"
  @short_method "eth_getBalance"
  @short_budget_ms 1_500
  @slow_answer_ms 11_000

  setup do
    previous = Application.get_env(:lasso, :method_timeouts, %{})

    Application.put_env(
      :lasso,
      :method_timeouts,
      Map.put(previous, @short_method, @short_budget_ms)
    )

    on_exit(fn -> Application.put_env(:lasso, :method_timeouts, previous) end)
  end

  test "a method budgeted beyond ten seconds waits for a slow upstream over WebSocket as over HTTP" do
    assert MethodPolicy.timeout_for(@long_method) > @slow_answer_ms

    journey(fn tenant, fleet ->
      Fleet.script(fleet, @long_method, [], {:respond, fn _ -> {:hold, make_ref()} end})
      params = ["0x" <> String.duplicate("ab", 32)]
      started = System.monotonic_time(:millisecond)

      http =
        Task.async(fn ->
          Rpc.call(tenant, @long_method, params, receive_timeout: 2 * @slow_answer_ms)
        end)

      wire = ws_wire(tenant)

      try do
        Rpc.send!(wire, @long_method, params, 1)
        tokens = for _ <- 1..2, do: held(fleet)

        refute_receive {:rpc_frame, _, _},
                       @slow_answer_ms - (System.monotonic_time(:millisecond) - started)

        for token <- tokens, do: :ok = Fleet.release(fleet, token, {:answer, "0x7"})

        assert %{"id" => 1, "result" => "0x7"} = frame(wire)
        assert %{status: 200, body: %{"result" => "0x7"}} = Task.await(http)
      after
        Rpc.close!(wire)
      end
    end)
  end

  test "a method budgeted under ten seconds ends at its own deadline over WebSocket" do
    assert MethodPolicy.timeout_for(@short_method) == @short_budget_ms

    journey(fn tenant, fleet ->
      Fleet.script(fleet, @short_method, [], {:respond, fn _ -> {:hold, make_ref()} end})
      wire = ws_wire(tenant)

      try do
        started = System.monotonic_time(:millisecond)
        Rpc.send!(wire, @short_method, ["0x1", "latest"], 1)
        token = held(fleet)

        assert %{"id" => 1, "error" => %{"code" => -32_007}} = frame(wire)
        elapsed_ms = System.monotonic_time(:millisecond) - started
        :ok = Fleet.release(fleet, token, {:answer, "0x0"})

        assert elapsed_ms >= @short_budget_ms
        assert elapsed_ms < 2 * @short_budget_ms
      after
        Rpc.close!(wire)
      end
    end)
  end

  defp journey(fun) do
    fleet = Fleet.start!(self(), "ws-timeout-#{System.unique_integer([:positive])}")

    try do
      tenant = Tenant.open!([fleet])

      try do
        fun.(tenant, fleet)
      after
        Tenant.close!(tenant)
      end
    after
      Fleet.stop(fleet)
    end
  end

  defp ws_wire(tenant) do
    tenant.rpc_url
    |> String.replace("http://", "ws://")
    |> String.replace("/rpc/", "/ws/rpc/")
    |> Rpc.wire!()
  end

  defp held(fleet) do
    pid = fleet.pid
    assert_receive {:fleet, ^pid, %{action: {:hold, token}}}, 5_000
    token
  end

  defp frame(wire) do
    reference = wire.reference
    assert_receive {:rpc_frame, ^reference, {:text, bytes}}, 5_000
    Jason.decode!(bytes)
  end
end

defmodule Livechain.RPC.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias Livechain.RPC.CircuitBreaker

  test "opens after failure_threshold failures and rejects until recovery timeout" do
    id = "cb_provider"

    {:ok, _pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 2, recovery_timeout: 100, success_threshold: 2}}
      )

    assert {:error, _} = CircuitBreaker.call(id, fn -> raise "boom" end)
    assert {:error, _} = CircuitBreaker.call(id, fn -> raise "boom" end)

    state = CircuitBreaker.get_state(id)
    assert state.state == :open

    # Should reject before recovery timeout elapses
    assert {:error, :circuit_open} = CircuitBreaker.call(id, fn -> :ok end)

    # After timeout, it should attempt half-open
    Process.sleep(120)
    result = CircuitBreaker.call(id, fn -> :ok end)
    assert match?({:ok, :ok}, result)
  end

  test "half-open requires success_threshold successes to close; failure re-opens" do
    id = "cb_provider2"

    {:ok, _pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 1, recovery_timeout: 50, success_threshold: 2}}
      )

    assert {:error, _} = CircuitBreaker.call(id, fn -> raise "boom" end)
    assert CircuitBreaker.get_state(id).state == :open

    Process.sleep(60)
    # First success in half-open
    assert {:ok, :ok} = CircuitBreaker.call(id, fn -> :ok end)
    # Failure should re-open
    assert {:error, :circuit_reopening} = CircuitBreaker.call(id, fn -> raise "oops" end)
    assert CircuitBreaker.get_state(id).state == :open
  end
end

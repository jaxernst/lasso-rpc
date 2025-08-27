defmodule Livechain.RPC.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias Livechain.RPC.CircuitBreaker

  setup_all do
    # Ensure test environment is ready with all services
    TestHelper.ensure_test_environment_ready()
    :ok
  end

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

  test "opens after failure_threshold typed errors and rejects until recovery" do
    id = "cb_provider_typed"

    {:ok, _pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 2, recovery_timeout: 100, success_threshold: 2}}
      )

    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, {:server_error, "500"}} end)
    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, {:server_error, "500"}} end)

    state = CircuitBreaker.get_state(id)
    assert state.state == :open

    # Should reject before recovery timeout elapses
    assert {:error, :circuit_open} = CircuitBreaker.call(id, fn -> {:ok, :ok} end)

    Process.sleep(120)
    # Half-open success path: need two successes to close
    assert {:ok, :ok} = CircuitBreaker.call(id, fn -> {:ok, :ok} end)
    assert CircuitBreaker.get_state(id).state in [:half_open, :closed]
  end

  test "record_failure increments failures and can open the circuit" do
    id = "cb_provider_record"

    {:ok, _pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 2, recovery_timeout: 50, success_threshold: 1}}
      )

    assert {:error, _} = CircuitBreaker.record_failure(id)
    assert CircuitBreaker.get_state(id).state == :closed

    assert {:error, _} = CircuitBreaker.record_failure(id)
    assert CircuitBreaker.get_state(id).state == :open

    # After recovery timeout, half-open then success should close
    Process.sleep(60)
    assert {:ok, :success} = CircuitBreaker.record_success(id)
    assert CircuitBreaker.get_state(id).state == :closed
  end
end

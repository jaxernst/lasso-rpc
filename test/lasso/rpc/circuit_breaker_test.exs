defmodule Lasso.RPC.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.CircuitBreaker

  setup_all do
    # Ensure test environment is ready with all services
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  test "opens after failure_threshold failures and rejects until recovery timeout" do
    id = {"test_chain", "cb_provider", :http}

    {:ok, _pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 2, recovery_timeout: 100, success_threshold: 2}}
      )

    assert {:error, _} = CircuitBreaker.call(id, fn -> raise "boom" end)
    assert {:error, _} = CircuitBreaker.call(id, fn -> raise "boom" end)

    # allow async state update to apply
    Process.sleep(20)
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
    id = {"test_chain", "cb_provider2", :http}

    {:ok, _pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 1, recovery_timeout: 50, success_threshold: 2}}
      )

    assert {:error, _} = CircuitBreaker.call(id, fn -> raise "boom" end)
    Process.sleep(20)
    assert CircuitBreaker.get_state(id).state == :open

    Process.sleep(60)
    # First success in half-open
    assert {:ok, :ok} = CircuitBreaker.call(id, fn -> :ok end)
    # Failure should re-open (caller receives raw error now)
    assert {:error, _} = CircuitBreaker.call(id, fn -> raise "oops" end)
    Process.sleep(20)
    assert CircuitBreaker.get_state(id).state == :open
  end

  test "opens after failure_threshold typed errors and rejects until recovery" do
    id = {"test_chain", "cb_provider_typed", :http}

    {:ok, _pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 2, recovery_timeout: 100, success_threshold: 2}}
      )

    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, {:server_error, "500"}} end)
    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, {:server_error, "500"}} end)

    Process.sleep(20)
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
    id = {"test_chain", "cb_provider_record", :http}

    {:ok, _pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 2, recovery_timeout: 50, success_threshold: 1}}
      )

    assert :ok = CircuitBreaker.record_failure(id)
    Process.sleep(20)
    assert CircuitBreaker.get_state(id).state == :closed

    assert :ok = CircuitBreaker.record_failure(id)
    Process.sleep(20)
    assert CircuitBreaker.get_state(id).state == :open

    # After recovery timeout, half-open then success should close
    Process.sleep(60)
    assert :ok = CircuitBreaker.record_success(id)
    Process.sleep(20)
    assert CircuitBreaker.get_state(id).state == :closed
  end
end

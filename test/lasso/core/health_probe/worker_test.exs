defmodule Lasso.HealthProbe.WorkerTest do
  @moduledoc """
  Unit tests for HealthProbe.Worker.

  Tests the core functionality:
  - Probing healthy/unhealthy providers
  - Recording success/failure to circuit breaker
  - Bypassing circuit breaker for probes
  - Handling various error scenarios
  """

  use ExUnit.Case, async: false

  alias Lasso.HealthProbe.Worker
  alias Lasso.RPC.CircuitBreaker

  setup_all do
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  describe "get_status/2" do
    test "returns error for non-running worker" do
      chain = "nonexistent_chain_#{System.unique_integer([:positive])}"
      provider_id = "nonexistent_provider"

      assert {:error, :not_running} = Worker.get_status(chain, provider_id)
    end
  end

  describe "circuit breaker interaction" do
    test "record_success/record_failure affect circuit breaker state" do
      # Generate unique IDs
      test_id = System.unique_integer([:positive])
      chain = "cb_test_#{test_id}"
      provider_id = "provider_#{test_id}"
      cb_id = {chain, provider_id, :http}

      # Start circuit breaker
      {:ok, _cb_pid} =
        CircuitBreaker.start_link(
          {cb_id, %{failure_threshold: 3, recovery_timeout: 100, success_threshold: 1}}
        )

      # Verify circuit starts closed
      state = CircuitBreaker.get_state(cb_id)
      assert state.state == :closed

      # Record failures (what HealthProbe does when probes fail)
      CircuitBreaker.record_failure(cb_id)
      CircuitBreaker.record_failure(cb_id)
      CircuitBreaker.record_failure(cb_id)

      # Allow async state update
      Process.sleep(50)

      # Circuit should be open now
      state = CircuitBreaker.get_state(cb_id)
      assert state.state == :open

      # Wait for recovery timeout
      Process.sleep(150)

      # Record success (what HealthProbe does when probe succeeds)
      CircuitBreaker.record_success(cb_id)
      Process.sleep(50)

      # Circuit should be closed now
      state = CircuitBreaker.get_state(cb_id)
      assert state.state == :closed
    end

    test "circuit breaker blocks calls when open" do
      test_id = System.unique_integer([:positive])
      chain = "cb_block_test_#{test_id}"
      provider_id = "provider_#{test_id}"
      cb_id = {chain, provider_id, :http}

      {:ok, _cb_pid} =
        CircuitBreaker.start_link(
          {cb_id, %{failure_threshold: 2, recovery_timeout: 100, success_threshold: 1}}
        )

      # Open the circuit
      CircuitBreaker.record_failure(cb_id)
      CircuitBreaker.record_failure(cb_id)
      Process.sleep(50)

      assert CircuitBreaker.get_state(cb_id).state == :open

      # Calls should be blocked
      result = CircuitBreaker.call(cb_id, fn -> {:ok, :should_not_run} end)
      assert result == {:error, :circuit_open}
    end

    test "HealthProbe bypasses circuit by using record_success/failure directly" do
      # This test verifies the design: HealthProbe doesn't go through CB.call,
      # it uses record_success/record_failure directly, which always works
      test_id = System.unique_integer([:positive])
      chain = "bypass_test_#{test_id}"
      provider_id = "provider_#{test_id}"
      cb_id = {chain, provider_id, :http}

      {:ok, _cb_pid} =
        CircuitBreaker.start_link(
          {cb_id, %{failure_threshold: 2, recovery_timeout: 100, success_threshold: 1}}
        )

      # Open the circuit
      CircuitBreaker.record_failure(cb_id)
      CircuitBreaker.record_failure(cb_id)
      Process.sleep(50)
      assert CircuitBreaker.get_state(cb_id).state == :open

      # Even though circuit is open, record_success still works
      # (This is what HealthProbe does)
      Process.sleep(150)  # Wait for recovery timeout
      :ok = CircuitBreaker.record_success(cb_id)
      Process.sleep(50)

      # Circuit should close
      assert CircuitBreaker.get_state(cb_id).state == :closed
    end
  end
end

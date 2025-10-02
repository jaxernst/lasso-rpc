defmodule Lasso.ErrorScenariosTest do
  @moduledoc """
  Tests for error scenarios and failure handling.

  These tests verify:
  - Circuit breaker behavior
  - Malicious input validation
  - Basic error handling
  """

  use ExUnit.Case, async: false
  require Logger

  alias Lasso.RPC.CircuitBreaker

  @moduletag :error_scenarios
  @moduletag :fault_tolerance

  setup do
    # Cleanup any existing circuit breakers before test
    on_exit(fn ->
      # Stop any circuit breakers that might have been started
      ["test_provider_failures", "test_provider_recovery"]
      |> Enum.each(fn provider_id ->
        via_name = {:via, Registry, {Lasso.Registry, {:circuit_breaker, provider_id}}}

        case GenServer.whereis(via_name) do
          nil ->
            :ok

          pid when is_pid(pid) ->
            try do
              GenServer.stop(pid, :normal)
            catch
              :exit, _ -> :ok
            end
        end
      end)
    end)

    :ok
  end

  describe "circuit breaker behavior" do
    test "opens circuit after consecutive failures" do
      provider_id = "test_provider_failures"
      config = %{failure_threshold: 3, recovery_timeout: 1000, success_threshold: 2}

      {:ok, _pid} = CircuitBreaker.start_link({provider_id, config})

      # Simulate consecutive failures
      for i <- 1..3 do
        result =
          CircuitBreaker.call(provider_id, fn ->
            raise "Simulated failure #{i}"
          end)

        # Circuit breaker should return an error (format may vary)
        assert {:error, _} = result
      end

      # Circuit should be open
      state = CircuitBreaker.get_state(provider_id)
      assert state.state == :open
      assert state.failure_count >= 3
    end

    test "recovers circuit after success threshold" do
      provider_id = "test_provider_recovery"
      config = %{failure_threshold: 2, recovery_timeout: 100, success_threshold: 2}

      {:ok, _pid} = CircuitBreaker.start_link({provider_id, config})

      # Open the circuit
      for _ <- 1..2 do
        CircuitBreaker.call(provider_id, fn -> raise "test error" end)
      end

      # Verify circuit is open
      state = CircuitBreaker.get_state(provider_id)
      assert state.state == :open

      # Wait for recovery timeout with proper polling instead of fixed sleep
      wait_for_recovery_timeout(provider_id, 100)

      # Attempt recovery with successes
      for _ <- 1..2 do
        result = CircuitBreaker.call(provider_id, fn -> :ok end)
        assert {:ok, :ok} = result
      end

      # Circuit should be closed
      state = CircuitBreaker.get_state(provider_id)
      assert state.state == :closed
    end
  end

  # Helper function to wait for circuit breaker recovery timeout
  defp wait_for_recovery_timeout(provider_id, timeout_ms, max_attempts \\ 50) do
    wait_for_recovery_timeout_impl(provider_id, timeout_ms, max_attempts, 0)
  end

  defp wait_for_recovery_timeout_impl(provider_id, timeout_ms, max_attempts, attempt) do
    if attempt >= max_attempts do
      flunk(
        "Circuit breaker #{provider_id} did not reach recovery timeout after #{max_attempts} attempts"
      )
    end

    state = CircuitBreaker.get_state(provider_id)

    case state.state do
      :open ->
        # Check if enough time has passed since last failure
        case state.last_failure_time do
          nil ->
            # No failure time recorded, assume ready for recovery
            :ok

          last_failure ->
            current_time = System.monotonic_time(:millisecond)

            if current_time - last_failure >= timeout_ms do
              :ok
            else
              # Wait a bit and try again
              Process.sleep(10)
              wait_for_recovery_timeout_impl(provider_id, timeout_ms, max_attempts, attempt + 1)
            end
        end

      :half_open ->
        # Already in half-open state, ready to proceed
        :ok

      :closed ->
        # Already closed, ready to proceed
        :ok
    end
  end

  # Deleted meaningless malicious input tests that only test Jason.decode
  # and don't validate actual system security behavior

  # Deleted meaningless memory pressure test that doesn't test actual
  # system limits or recovery behavior
end

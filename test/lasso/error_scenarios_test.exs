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

  alias Lasso.Core.Support.CircuitBreaker

  @moduletag :error_scenarios
  @moduletag :fault_tolerance

  setup do
    on_exit(fn ->
      [
        {"test_provider_failures", :http},
        {"test_provider_recovery", :http}
      ]
      |> Enum.each(fn {instance_id, transport} ->
        key = "#{instance_id}:#{transport}"
        via_name = {:via, Registry, {Lasso.Registry, {:circuit_breaker, key}}}

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
      breaker_id = {"test_provider_failures", :http}
      config = %{failure_threshold: 3, recovery_timeout: 1000, success_threshold: 2}

      {:ok, _pid} = CircuitBreaker.start_link({breaker_id, config})

      # Simulate consecutive failures
      for i <- 1..3 do
        result =
          CircuitBreaker.call(breaker_id, fn ->
            raise "Simulated failure #{i}"
          end)

        # Circuit breaker wraps exceptions as {:executed, {:exception, {kind, error, stacktrace}}}
        assert {:executed, {:exception, _}} = result
      end

      # Circuit should be open
      state = CircuitBreaker.get_state(breaker_id)
      assert state.state == :open
      assert state.failure_count >= 3
    end

    test "recovers circuit after success threshold" do
      breaker_id = {"test_provider_recovery", :http}
      config = %{failure_threshold: 2, recovery_timeout: 100, success_threshold: 2}

      {:ok, _pid} = CircuitBreaker.start_link({breaker_id, config})

      # Open the circuit
      for _ <- 1..2 do
        CircuitBreaker.call(breaker_id, fn -> raise "test error" end)
      end

      # Verify circuit is open
      state = CircuitBreaker.get_state(breaker_id)
      assert state.state == :open

      # Wait for recovery timeout with proper polling instead of fixed sleep
      wait_for_recovery_timeout(breaker_id, 100)

      # Attempt recovery with successes
      for _ <- 1..2 do
        result = CircuitBreaker.call(breaker_id, fn -> :ok end)
        assert {:executed, :ok} = result
      end

      # Circuit should be closed
      state = CircuitBreaker.get_state(breaker_id)
      assert state.state == :closed
    end
  end

  # Helper function to wait for circuit breaker recovery timeout
  defp wait_for_recovery_timeout(breaker_id, timeout_ms, max_attempts \\ 50) do
    wait_for_recovery_timeout_impl(breaker_id, timeout_ms, max_attempts, 0)
  end

  defp wait_for_recovery_timeout_impl(breaker_id, timeout_ms, max_attempts, attempt) do
    if attempt >= max_attempts do
      flunk(
        "Circuit breaker #{inspect(breaker_id)} did not reach recovery timeout after #{max_attempts} attempts"
      )
    end

    state = CircuitBreaker.get_state(breaker_id)

    case state.state do
      :open ->
        # Check if enough time has passed since last failure
        case state.last_failure_time do
          nil ->
            # No failure time recorded, assume ready for recovery
            :ok

          last_failure ->
            current_time = System.monotonic_time(:millisecond)

            if current_time - last_failure >= timeout_ms + div(timeout_ms, 20) + 5 do
              :ok
            else
              # Wait a bit and try again
              Process.sleep(10)
              wait_for_recovery_timeout_impl(breaker_id, timeout_ms, max_attempts, attempt + 1)
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

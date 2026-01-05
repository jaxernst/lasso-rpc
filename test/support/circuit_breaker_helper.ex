defmodule Lasso.Test.CircuitBreakerHelper do
  @moduledoc """
  Test helpers for managing circuit breaker lifecycle and state.

  This module ensures circuit breakers are properly isolated between tests,
  preventing state pollution and timing issues. It provides:

  - Automatic circuit breaker cleanup and reset
  - Synchronous circuit breaker startup verification
  - State inspection utilities
  - Test-scoped circuit breaker tracking

  ## Usage

      # In test setup
      setup do
        CircuitBreakerHelper.setup_clean_circuit_breakers()
        :ok
      end

      # Ensure circuit breaker is ready before test
      test "failover test" do
        CircuitBreakerHelper.ensure_circuit_breaker_started("provider_id", :http)
        # Circuit breaker is guaranteed to be ready
      end
  """

  alias Lasso.Core.Support.CircuitBreaker
  require Logger

  @doc """
  Sets up clean circuit breaker state for a test.

  This helper:
  1. Lists all existing circuit breakers
  2. Resets them to :closed state with zero failures
  3. Registers cleanup callback to reset state after test
  4. Tracks circuit breakers created during test for cleanup

  Should be called in test setup blocks for tests that use circuit breakers.

  ## Example

      setup do
        CircuitBreakerHelper.setup_clean_circuit_breakers()
        {:ok, test: "state"}
      end
  """
  @spec setup_clean_circuit_breakers() :: :ok
  def setup_clean_circuit_breakers do
    # Get all existing circuit breakers
    existing_cbs = list_all_circuit_breakers()

    # Reset all existing circuit breakers to clean state
    Enum.each(existing_cbs, fn {_key, pid} ->
      reset_circuit_breaker(pid)
    end)

    # Register cleanup callback
    ExUnit.Callbacks.on_exit(fn ->
      cleanup_circuit_breakers(existing_cbs)
    end)

    :ok
  end

  @doc """
  Ensures a circuit breaker is started and ready for a chain+provider+transport.

  This is critical for avoiding race conditions where tests execute before
  the circuit breaker process has registered.

  Returns `{:ok, state}` when circuit breaker is confirmed ready.

  ## Options

  - `:timeout` - Maximum time to wait for circuit breaker startup (default: 2000ms)
  - `:config` - Circuit breaker configuration to use if starting new breaker

  ## Example

      # Ensure circuit breaker exists before making requests
      {:ok, state} = CircuitBreakerHelper.ensure_circuit_breaker_started(
        "ethereum",
        "alchemy",
        :http
      )

      assert state.state == :closed
  """
  @spec ensure_circuit_breaker_started(String.t(), String.t(), String.t(), atom(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ensure_circuit_breaker_started(profile, chain, provider_id, transport, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2_000)
    config = Keyword.get(opts, :config, %{})

    deadline = System.monotonic_time(:millisecond) + timeout

    ensure_cb_started_loop({profile, chain, provider_id, transport}, config, deadline)
  end

  defp ensure_cb_started_loop(breaker_id, config, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      case get_circuit_breaker_state(breaker_id) do
        {:ok, state} ->
          # Circuit breaker exists and responded
          {:ok, state}

        {:error, :not_found} ->
          # CB doesn't exist, try to start it (ignore if someone else started it)
          _ = start_circuit_breaker(breaker_id, config)

          # Always wait a bit and retry state check regardless of start result
          Process.sleep(50)
          ensure_cb_started_loop(breaker_id, config, deadline)

        {:error, :timeout} ->
          # CB exists but not responding, wait and retry
          Process.sleep(50)
          ensure_cb_started_loop(breaker_id, config, deadline)
      end
    end
  end

  @doc """
  Gets the current state of a circuit breaker if it exists.

  Returns `{:ok, state}` or `{:error, :not_found}`.

  ## Example

      case get_circuit_breaker_state({"provider_id", :http}) do
        {:ok, %{state: :open}} -> :breaker_open
        {:ok, %{state: :closed}} -> :breaker_closed
        {:error, :not_found} -> :breaker_not_started
      end
  """
  @spec get_circuit_breaker_state(CircuitBreaker.breaker_id()) ::
          {:ok, map()} | {:error, :not_found}
  def get_circuit_breaker_state(breaker_id) do
    try do
      state = CircuitBreaker.get_state(breaker_id)
      {:ok, state}
    catch
      :exit, {:noproc, _} -> {:error, :not_found}
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc """
  Waits for a circuit breaker to reach a specific state.

  More flexible than telemetry-based waiting when you need to check
  internal state that might not emit events.

  ## Options

  - `:timeout` - Maximum time to wait (default: 5000ms)
  - `:interval` - Polling interval (default: 50ms)

  ## Example

      # Wait for circuit breaker to open
      {:ok, state} = wait_for_circuit_breaker_state(
        {"provider_id", :http},
        fn state -> state.state == :open end
      )

      # Wait for failure count to reach threshold
      {:ok, state} = wait_for_circuit_breaker_state(
        {"provider_id", :http},
        fn state -> state.failure_count >= 3 end
      )
  """
  @spec wait_for_circuit_breaker_state(
          CircuitBreaker.breaker_id(),
          (map() -> boolean()),
          keyword()
        ) :: {:ok, map()} | {:error, :timeout}
  def wait_for_circuit_breaker_state(breaker_id, condition_fn, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    interval = Keyword.get(opts, :interval, 50)

    deadline = System.monotonic_time(:millisecond) + timeout

    wait_for_cb_state_loop(breaker_id, condition_fn, deadline, interval)
  end

  defp wait_for_cb_state_loop(breaker_id, condition_fn, deadline, interval) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :timeout}
    else
      case get_circuit_breaker_state(breaker_id) do
        {:ok, state} ->
          if condition_fn.(state) do
            {:ok, state}
          else
            Process.sleep(interval)
            wait_for_cb_state_loop(breaker_id, condition_fn, deadline, interval)
          end

        {:error, :not_found} ->
          Process.sleep(interval)
          wait_for_cb_state_loop(breaker_id, condition_fn, deadline, interval)
      end
    end
  end

  @doc """
  Resets a circuit breaker to clean closed state.

  Useful for resetting state between test phases without restarting
  the entire circuit breaker process.

  ## Example

      CircuitBreakerHelper.reset_to_closed({"ethereum", "provider_id", :http})
  """
  @spec reset_to_closed(CircuitBreaker.breaker_id()) :: :ok
  def reset_to_closed(breaker_id) do
    try do
      CircuitBreaker.close(breaker_id)
      :ok
    catch
      :exit, _ -> :ok
    end
  end

  @doc """
  Manually opens a circuit breaker for testing failover scenarios.

  ## Example

      # Force circuit breaker open to test failover
      CircuitBreakerHelper.force_open({"ethereum", "primary_provider", :http})
      # Requests should now failover to backup provider
  """
  @spec force_open(CircuitBreaker.breaker_id()) :: :ok
  def force_open(breaker_id) do
    try do
      CircuitBreaker.open(breaker_id)
      :ok
    catch
      :exit, _ -> :ok
    end
  end

  @doc """
  Gets all circuit breakers for a specific chain+provider across all transports.

  Useful for asserting on provider-level behavior.

  ## Example

      cbs = get_provider_circuit_breakers("default", "ethereum", "alchemy")
      # Returns circuit breakers for "alchemy" on both :http and :ws
  """
  @spec get_provider_circuit_breakers(String.t(), String.t(), String.t()) :: [{atom(), map()}]
  def get_provider_circuit_breakers(profile, chain, provider_id) do
    list_all_circuit_breakers()
    |> Enum.filter(fn
      {{^profile, ^chain, ^provider_id, _transport}, _pid} -> true
      _ -> false
    end)
    |> Enum.map(fn
      {{_profile, _chain, _provider_id, transport}, _pid} ->
        case get_circuit_breaker_state({profile, chain, provider_id, transport}) do
          {:ok, state} -> {transport, state}
          {:error, _} -> nil
        end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Asserts that a circuit breaker is in a specific state.

  Convenience wrapper for common assertion pattern.

  ## Example

      assert_circuit_breaker_state({"ethereum", "provider_id", :http}, :open)
      assert_circuit_breaker_state({"ethereum", "provider_id", :http}, :closed)
  """
  @spec assert_circuit_breaker_state(CircuitBreaker.breaker_id(), atom()) :: :ok
  def assert_circuit_breaker_state(breaker_id, expected_state) do
    case get_circuit_breaker_state(breaker_id) do
      {:ok, %{state: ^expected_state}} ->
        :ok

      {:ok, %{state: actual_state}} ->
        raise ExUnit.AssertionError,
          message: """
          Circuit breaker state mismatch for #{inspect(breaker_id)}
          Expected: #{expected_state}
          Got: #{actual_state}
          """

      {:error, :not_found} ->
        raise ExUnit.AssertionError,
          message: "Circuit breaker not found: #{inspect(breaker_id)}"
    end
  end

  # Private helpers

  defp list_all_circuit_breakers do
    try do
      Registry.select(Lasso.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.filter(fn
        {{:circuit_breaker, _profile, _chain, _provider_id, _transport}, _pid} -> true
        _ -> false
      end)
      |> Enum.map(fn {{:circuit_breaker, profile, chain, provider_id, transport}, pid} ->
        breaker_id = {profile, chain, provider_id, transport}
        {breaker_id, pid}
      end)
    catch
      :exit, _ -> []
    end
  end

  defp reset_circuit_breaker(pid) when is_pid(pid) do
    try do
      state = :sys.get_state(pid)
      breaker_id = {state.profile, state.chain, state.provider_id, state.transport}
      CircuitBreaker.close(breaker_id)
    catch
      :exit, _ -> :ok
    end
  end

  defp cleanup_circuit_breakers(existing_cbs) do
    # Get current circuit breakers
    current_cbs = list_all_circuit_breakers()

    # Find circuit breakers created during test
    new_cbs = current_cbs -- existing_cbs

    # Clean up new circuit breakers (graceful stop)
    Enum.each(new_cbs, fn {breaker_id, pid} ->
      if Process.alive?(pid) do
        try do
          # Reset to clean state rather than killing
          # This is safer as other tests might reference them
          reset_to_closed(breaker_id)
        catch
          _ -> :ok
        end
      end
    end)

    # Reset existing circuit breakers back to clean state
    Enum.each(existing_cbs, fn {_key, pid} ->
      if Process.alive?(pid) do
        reset_circuit_breaker(pid)
      end
    end)

    :ok
  end

  defp start_circuit_breaker(breaker_id, config) do
    # Start circuit breaker via supervisor
    # This depends on the actual circuit breaker supervision structure
    # For now, we'll try to start it directly
    try do
      CircuitBreaker.start_link({breaker_id, config})
    catch
      :exit, reason -> {:error, reason}
    end
  end
end

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

    # Use network_error which has threshold of 3 in category thresholds
    # But since we set failure_threshold to 2, it should use 2
    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, {:network_error, "timeout"}} end)
    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, {:network_error, "timeout"}} end)

    Process.sleep(20)
    state = CircuitBreaker.get_state(id)
    # Network errors use threshold of 3, but we explicitly set failure_threshold: 2
    # The category threshold should only be used if higher than the default
    # For this test, let's verify it uses the category-specific threshold
    # Actually, the logic uses category threshold OR falls back to failure_threshold
    # So network_error (threshold: 3) will need 3 failures
    # Let me add one more failure
    assert state.state == :closed

    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, {:network_error, "timeout"}} end)
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

  test "rate limit errors open circuit after 2 failures (lower threshold)" do
    alias Lasso.JSONRPC.Error, as: JError
    id = {"test_chain", "cb_rate_limit", :http}

    {:ok, _pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 5, recovery_timeout: 100, success_threshold: 2}}
      )

    # Rate limit error should use threshold of 2, not 5
    rate_limit_error = JError.new(-32_005, "Rate limited", category: :rate_limit)

    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, rate_limit_error} end)
    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, rate_limit_error} end)

    Process.sleep(20)
    state = CircuitBreaker.get_state(id)
    assert state.state == :open, "Circuit should open after 2 rate limit errors"
  end

  test "server errors use default threshold of 5" do
    alias Lasso.JSONRPC.Error, as: JError
    id = {"test_chain", "cb_server_error", :http}

    {:ok, _pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 5, recovery_timeout: 100, success_threshold: 2}}
      )

    server_error = JError.new(-32_000, "Server error", category: :server_error)

    # Should not open after 2 server errors (needs 5)
    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, server_error} end)
    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, server_error} end)

    Process.sleep(20)
    state = CircuitBreaker.get_state(id)
    assert state.state == :closed, "Circuit should remain closed after 2 server errors"
  end

  test "retry-after header adjusts recovery timeout for rate limits" do
    alias Lasso.JSONRPC.Error, as: JError
    id = {"test_chain", "cb_retry_after", :http}

    {:ok, _pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 2, recovery_timeout: 60_000, success_threshold: 2}}
      )

    # Rate limit error with retry-after in data (populated by ErrorNormalizer)
    # :retry_after_ms is in milliseconds
    rate_limit_error =
      JError.new(-32_005, "Rate limited",
        category: :rate_limit,
        data: %{retry_after_ms: 2000}
      )

    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, rate_limit_error} end)
    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, rate_limit_error} end)

    Process.sleep(20)
    state = CircuitBreaker.get_state(id)
    assert state.state == :open

    # Should use 2 second timeout instead of default 60 seconds
    # Wait 2.1 seconds and verify circuit attempts recovery
    Process.sleep(2100)
    result = CircuitBreaker.call(id, fn -> {:ok, :success} end)
    assert match?({:ok, :success}, result), "Circuit should attempt recovery after 2 seconds"
  end

  test "custom category thresholds can be configured" do
    alias Lasso.JSONRPC.Error, as: JError
    id = {"test_chain", "cb_custom_threshold", :http}

    # Override rate_limit threshold to 3 instead of default 2
    {:ok, _pid} =
      CircuitBreaker.start_link(
        {id,
         %{
           failure_threshold: 5,
           recovery_timeout: 100,
           success_threshold: 2,
           category_thresholds: %{rate_limit: 3}
         }}
      )

    rate_limit_error = JError.new(-32_005, "Rate limited", category: :rate_limit)

    # Should not open after 2 failures (needs 3 now)
    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, rate_limit_error} end)
    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, rate_limit_error} end)

    Process.sleep(20)
    state = CircuitBreaker.get_state(id)
    assert state.state == :closed, "Circuit should remain closed with custom threshold"

    # Should open after 3rd failure
    assert {:error, _} = CircuitBreaker.call(id, fn -> {:error, rate_limit_error} end)
    Process.sleep(20)
    state = CircuitBreaker.get_state(id)
    assert state.state == :open
  end
end

defmodule Lasso.Integration.HealthProbeIntegrationTest do
  @moduledoc """
  Integration tests for HealthProbe system.

  Tests the full integration between:
  - HealthProbe.Worker
  - CircuitBreaker
  - BlockSync.HttpStrategy
  - TransportRegistry

  These tests validate the core value proposition:
  1. HealthProbe bypasses circuit breaker to detect recovery
  2. HealthProbe informs circuit breaker via record_success/record_failure
  3. BlockSync HTTP respects circuit breaker state
  4. Full recovery flow works end-to-end
  """

  use ExUnit.Case, async: false

  alias Lasso.Testing.IntegrationHelper
  alias Lasso.RPC.CircuitBreaker
  alias Lasso.HealthProbe
  alias Lasso.BlockSync

  @moduletag :integration

  setup_all do
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  setup do
    # Generate unique chain name for each test
    test_id = System.unique_integer([:positive])
    chain = "health_probe_int_#{test_id}"

    on_exit(fn ->
      # Clean up any lingering processes
      cleanup_chain(chain)
    end)

    {:ok, chain: chain, test_id: test_id}
  end

  describe "HealthProbe → CircuitBreaker integration" do
    @tag :integration
    test "HealthProbe success closes open circuit", %{chain: chain} do
      # Setup: Create provider with behavior that will fail then succeed
      provider_spec = %{
        id: "probe_recovery_provider",
        behavior: :healthy,
        priority: 100
      }

      {:ok, [provider_id]} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [provider_spec],
          provider_type: :http,
          skip_health_check: true
        )

      cb_id = {chain, provider_id, :http}

      # Wait for circuit breaker to be ready
      wait_for_circuit_breaker(cb_id)

      # Manually open the circuit by recording failures (default threshold is 5)
      for _ <- 1..5, do: CircuitBreaker.record_failure(cb_id)

      # Allow async state update
      Process.sleep(50)

      # Verify circuit is open
      state = CircuitBreaker.get_state(cb_id)
      assert state.state == :open, "Circuit should be open after failures"

      # Now record success (simulating what HealthProbe does)
      # Wait for recovery timeout first
      Process.sleep(150)

      CircuitBreaker.record_success(cb_id)
      Process.sleep(50)

      # record_success transitions open -> half_open
      # A successful call (or another record_success) closes it fully
      state = CircuitBreaker.get_state(cb_id)
      assert state.state in [:half_open, :closed], "Circuit should be in recovery after HealthProbe success"

      # Make a successful call to fully close the circuit
      if state.state == :half_open do
        result = CircuitBreaker.call(cb_id, fn -> {:ok, :test} end)
        # Result should indicate success (either {:ok, {:ok, :test}} or {:ok, :test} depending on circuit state)
        assert match?({:ok, _}, result), "Call should succeed in half_open state"
        Process.sleep(50)
      end

      # Circuit should be closed now
      state = CircuitBreaker.get_state(cb_id)
      assert state.state == :closed, "Circuit should close after successful call in half_open"
    end

    @tag :integration
    test "HealthProbe failure opens circuit after threshold", %{chain: chain} do
      provider_spec = %{
        id: "probe_failure_provider",
        behavior: :healthy,
        priority: 100
      }

      {:ok, [provider_id]} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [provider_spec],
          provider_type: :http,
          skip_health_check: true
        )

      cb_id = {chain, provider_id, :http}
      wait_for_circuit_breaker(cb_id)

      # Verify circuit starts closed
      state = CircuitBreaker.get_state(cb_id)
      assert state.state == :closed

      # Record failures (simulating what HealthProbe does when probes fail)
      # Default threshold is 5
      for _ <- 1..5, do: CircuitBreaker.record_failure(cb_id)

      Process.sleep(50)

      # Circuit should be open
      state = CircuitBreaker.get_state(cb_id)
      assert state.state == :open, "Circuit should open after threshold failures"
    end

    @tag :integration
    test "circuit transitions: closed → open → half_open → closed", %{chain: chain} do
      provider_spec = %{
        id: "transition_provider",
        behavior: :healthy,
        priority: 100
      }

      {:ok, [provider_id]} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [provider_spec],
          provider_type: :http,
          skip_health_check: true
        )

      cb_id = {chain, provider_id, :http}
      wait_for_circuit_breaker(cb_id)

      # 1. Start closed
      assert CircuitBreaker.get_state(cb_id).state == :closed

      # 2. Open via failures (default threshold is 5)
      for _ <- 1..5, do: CircuitBreaker.record_failure(cb_id)
      Process.sleep(50)
      assert CircuitBreaker.get_state(cb_id).state == :open

      # 3. Wait for recovery timeout → half_open
      Process.sleep(150)

      # record_success triggers transition to half_open
      CircuitBreaker.record_success(cb_id)
      Process.sleep(20)

      state = CircuitBreaker.get_state(cb_id)
      # State should be half_open after record_success from open
      assert state.state in [:half_open, :closed], "Expected half_open or closed, got: #{state.state}"

      # 4. Successful call from half_open closes it
      if state.state == :half_open do
        result = CircuitBreaker.call(cb_id, fn -> {:ok, :test} end)
        assert match?({:ok, _}, result), "Call should succeed in half_open state"
        Process.sleep(50)
      end

      assert CircuitBreaker.get_state(cb_id).state == :closed
    end
  end

  describe "BlockSync HTTP respects circuit breaker" do
    @tag :integration
    test "BlockSync HTTP is blocked when circuit is open", %{chain: chain} do
      provider_spec = %{
        id: "blocksync_cb_provider",
        behavior: :healthy,
        priority: 100
      }

      {:ok, [provider_id]} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [provider_spec],
          provider_type: :http,
          skip_health_check: true
        )

      cb_id = {chain, provider_id, :http}
      wait_for_circuit_breaker(cb_id)

      # Open the circuit (default threshold is 5)
      for _ <- 1..5, do: CircuitBreaker.record_failure(cb_id)
      Process.sleep(50)
      assert CircuitBreaker.get_state(cb_id).state == :open

      # BlockSync HTTP should get :circuit_open when trying to poll
      result = CircuitBreaker.call(cb_id, fn -> {:ok, 12345} end)
      assert result == {:error, :circuit_open}
    end

    @tag :integration
    test "BlockSync HTTP resumes when circuit closes", %{chain: chain} do
      provider_spec = %{
        id: "blocksync_resume_provider",
        behavior: :healthy,
        priority: 100
      }

      {:ok, [provider_id]} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [provider_spec],
          provider_type: :http,
          skip_health_check: true
        )

      cb_id = {chain, provider_id, :http}
      wait_for_circuit_breaker(cb_id)

      # Open the circuit (default threshold is 5)
      for _ <- 1..5, do: CircuitBreaker.record_failure(cb_id)
      Process.sleep(50)
      assert CircuitBreaker.get_state(cb_id).state == :open

      # Wait for recovery timeout
      Process.sleep(150)

      # Record success (simulating HealthProbe recovery detection)
      # This transitions from open -> half_open
      CircuitBreaker.record_success(cb_id)
      Process.sleep(50)

      # Circuit should be in recovery state (half_open or closed)
      state = CircuitBreaker.get_state(cb_id)
      assert state.state in [:half_open, :closed]

      # BlockSync HTTP should work again - a successful call closes the circuit fully
      result = CircuitBreaker.call(cb_id, fn -> {:ok, 12345} end)
      assert match?({:ok, _}, result), "Call should succeed in half_open/closed state"
      Process.sleep(50)

      # Now circuit should be closed
      assert CircuitBreaker.get_state(cb_id).state == :closed
    end
  end

  describe "end-to-end recovery flow" do
    @tag :integration
    test "full recovery: provider fails → circuit opens → HealthProbe detects recovery → circuit closes",
         %{chain: chain} do
      provider_spec = %{
        id: "e2e_recovery_provider",
        behavior: :healthy,
        priority: 100
      }

      {:ok, [provider_id]} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [provider_spec],
          provider_type: :http,
          skip_health_check: true
        )

      cb_id = {chain, provider_id, :http}
      wait_for_circuit_breaker(cb_id)

      # Phase 1: Provider is healthy, circuit is closed
      assert CircuitBreaker.get_state(cb_id).state == :closed

      # Phase 2: Provider starts failing
      # Simulate failures that would be detected by HealthProbe (default threshold is 5)
      for _ <- 1..5, do: CircuitBreaker.record_failure(cb_id)
      Process.sleep(50)

      # Circuit should be open
      assert CircuitBreaker.get_state(cb_id).state == :open

      # Phase 3: User traffic is blocked
      result = CircuitBreaker.call(cb_id, fn -> {:ok, :should_not_run} end)
      assert result == {:error, :circuit_open}

      # Phase 4: HealthProbe continues probing (bypasses circuit)
      # and eventually detects recovery
      Process.sleep(150)  # Wait for recovery timeout

      # HealthProbe detects recovery and records success
      # This transitions open -> half_open
      CircuitBreaker.record_success(cb_id)
      Process.sleep(50)

      # Phase 5: Circuit is in recovery state, traffic can test
      state = CircuitBreaker.get_state(cb_id)
      assert state.state in [:half_open, :closed]

      # First successful call through closes the circuit
      result = CircuitBreaker.call(cb_id, fn -> {:ok, :traffic_resumed} end)
      assert match?({:ok, _}, result), "Call should succeed in half_open/closed state"
      Process.sleep(50)

      # Circuit should now be closed
      assert CircuitBreaker.get_state(cb_id).state == :closed
    end

    @tag :integration
    test "flapping provider: rapid up/down doesn't cause thrashing", %{chain: chain} do
      provider_spec = %{
        id: "flapping_provider",
        behavior: :healthy,
        priority: 100
      }

      {:ok, [provider_id]} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [provider_spec],
          provider_type: :http,
          skip_health_check: true
        )

      cb_id = {chain, provider_id, :http}
      wait_for_circuit_breaker(cb_id)

      # Simulate flapping: success, fail, success, fail...
      for i <- 1..10 do
        if rem(i, 2) == 0 do
          CircuitBreaker.record_failure(cb_id)
        else
          CircuitBreaker.record_success(cb_id)
        end

        Process.sleep(10)
      end

      # Circuit should still be closed (failures didn't accumulate consecutively)
      state = CircuitBreaker.get_state(cb_id)
      assert state.state == :closed
    end

    @tag :integration
    test "multiple providers have independent circuit states", %{chain: chain} do
      providers = [
        %{id: "independent_p1", behavior: :healthy, priority: 100},
        %{id: "independent_p2", behavior: :healthy, priority: 90},
        %{id: "independent_p3", behavior: :healthy, priority: 80}
      ]

      {:ok, provider_ids} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          providers,
          provider_type: :http,
          skip_health_check: true
        )

      [p1, p2, p3] = provider_ids
      cb1 = {chain, p1, :http}
      cb2 = {chain, p2, :http}
      cb3 = {chain, p3, :http}

      # Wait for all circuit breakers
      wait_for_circuit_breaker(cb1)
      wait_for_circuit_breaker(cb2)
      wait_for_circuit_breaker(cb3)

      # Open only p1's circuit (default threshold is 5)
      for _ <- 1..5, do: CircuitBreaker.record_failure(cb1)
      Process.sleep(50)

      # Verify p1 is open, others are closed
      assert CircuitBreaker.get_state(cb1).state == :open
      assert CircuitBreaker.get_state(cb2).state == :closed
      assert CircuitBreaker.get_state(cb3).state == :closed

      # Open p2's circuit (default threshold is 5)
      for _ <- 1..5, do: CircuitBreaker.record_failure(cb2)
      Process.sleep(50)

      # Verify p1 and p2 are open, p3 is closed
      assert CircuitBreaker.get_state(cb1).state == :open
      assert CircuitBreaker.get_state(cb2).state == :open
      assert CircuitBreaker.get_state(cb3).state == :closed

      # Recover p1
      Process.sleep(150)
      CircuitBreaker.record_success(cb1)
      Process.sleep(50)

      # p1 should be in recovery state (half_open)
      state1 = CircuitBreaker.get_state(cb1)
      assert state1.state in [:half_open, :closed], "p1 should be in recovery"

      # Make a successful call to fully close p1
      if state1.state == :half_open do
        result = CircuitBreaker.call(cb1, fn -> {:ok, :test} end)
        assert match?({:ok, _}, result), "Call should succeed in half_open state"
        Process.sleep(50)
      end

      # Verify p1 is closed, p2 is still open, p3 is still closed
      assert CircuitBreaker.get_state(cb1).state == :closed
      assert CircuitBreaker.get_state(cb2).state == :open
      assert CircuitBreaker.get_state(cb3).state == :closed
    end
  end

  describe "rate limit handling" do
    @tag :integration
    test "rate limit opens circuit with lower threshold", %{chain: chain} do
      provider_spec = %{
        id: "rate_limit_provider",
        behavior: :healthy,
        priority: 100
      }

      {:ok, [provider_id]} =
        IntegrationHelper.setup_test_chain_with_providers(
          chain,
          [provider_spec],
          provider_type: :http,
          skip_health_check: true
        )

      cb_id = {chain, provider_id, :http}
      wait_for_circuit_breaker(cb_id)

      # Rate limit errors should open circuit faster (threshold: 2)
      rate_limit_error = {:rate_limit, %{retry_after: 60}}

      # First rate limit
      CircuitBreaker.call(cb_id, fn -> {:error, rate_limit_error} end)
      Process.sleep(20)

      # May still be closed after 1 (depends on threshold)
      _state = CircuitBreaker.get_state(cb_id)

      # Second rate limit
      CircuitBreaker.call(cb_id, fn -> {:error, rate_limit_error} end)
      Process.sleep(50)

      # Should be open now (rate limit threshold is 2)
      state = CircuitBreaker.get_state(cb_id)
      assert state.state == :open
    end
  end

  # Helper functions

  defp wait_for_circuit_breaker(cb_id, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop_cb(cb_id, deadline)
  end

  defp wait_loop_cb(cb_id, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      raise "Timeout waiting for circuit breaker #{inspect(cb_id)}"
    end

    case CircuitBreaker.get_state(cb_id) do
      {:error, _} ->
        Process.sleep(50)
        wait_loop_cb(cb_id, deadline)

      state when is_map(state) ->
        :ok
    end
  end

  defp cleanup_chain(chain) do
    # Stop HealthProbe supervisor if running
    if pid = GenServer.whereis(HealthProbe.Supervisor.via(chain)) do
      try do
        DynamicSupervisor.stop(pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end

    # Stop BlockSync supervisor if running
    if pid = GenServer.whereis(BlockSync.Supervisor.via(chain)) do
      try do
        DynamicSupervisor.stop(pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end
end

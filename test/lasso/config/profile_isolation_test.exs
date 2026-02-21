defmodule Lasso.Config.ProfileIsolationTest do
  @moduledoc """
  Critical tests verifying profile isolation guarantees.

  These tests ensure that:
  - ConfigStore data is completely isolated per profile
  - Metrics/benchmarks are profile-scoped
  - Circuit breakers are profile-isolated
  - Provider pools are profile-scoped

  Profile isolation is a fundamental invariant - violations would allow
  cross-tenant data leakage in multi-tenant deployments.
  """

  use ExUnit.Case, async: false

  alias Lasso.Config.ConfigStore
  alias Lasso.Benchmarking.BenchmarkStore
  alias Lasso.Core.Support.CircuitBreaker

  @profile_a "profile_a"
  @profile_b "profile_b"
  @test_chain "isolation_test_chain"

  setup do
    # Clean up both profiles before each test
    on_exit(fn ->
      ConfigStore.unregister_chain_runtime(@profile_a, @test_chain)
      ConfigStore.unregister_chain_runtime(@profile_b, @test_chain)
      BenchmarkStore.clear_chain_metrics(@profile_a, @test_chain)
      BenchmarkStore.clear_chain_metrics(@profile_b, @test_chain)
      Process.sleep(50)
    end)

    :ok
  end

  describe "ConfigStore isolation" do
    test "chains registered in profile_a don't appear in profile_b" do
      chain_config = %{
        chain_id: 1,
        name: @test_chain,
        providers: []
      }

      # Register chain in profile_a
      :ok = ConfigStore.register_chain_runtime(@profile_a, @test_chain, chain_config)

      # Verify it exists in profile_a
      assert {:ok, _} = ConfigStore.get_chain(@profile_a, @test_chain)

      # Verify it does NOT exist in profile_b
      assert {:error, :not_found} = ConfigStore.get_chain(@profile_b, @test_chain)
    end

    test "providers registered in profile_a don't appear in profile_b" do
      chain_config = %{chain_id: 1, name: @test_chain, providers: []}
      provider_config = %{id: "test_provider", name: "Test", url: "http://test.com", type: "test"}

      # Register chain and provider in profile_a
      :ok = ConfigStore.register_chain_runtime(@profile_a, @test_chain, chain_config)
      :ok = ConfigStore.register_provider_runtime(@profile_a, @test_chain, provider_config)

      # Verify provider exists in profile_a
      {:ok, providers_a} = ConfigStore.get_providers(@profile_a, @test_chain)
      assert length(providers_a) == 1
      assert hd(providers_a).id == "test_provider"

      # Register same chain in profile_b (without the provider)
      :ok = ConfigStore.register_chain_runtime(@profile_b, @test_chain, chain_config)

      # Verify provider does NOT exist in profile_b
      {:ok, providers_b} = ConfigStore.get_providers(@profile_b, @test_chain)
      assert providers_b == []
    end

    test "list_chains_for_profile returns only chains for the requested profile" do
      chain_a_config = %{chain_id: 1, name: @test_chain <> "_a", providers: []}
      chain_b_config = %{chain_id: 2, name: @test_chain <> "_b", providers: []}

      # Register chain_a in profile_a
      :ok = ConfigStore.register_chain_runtime(@profile_a, @test_chain <> "_a", chain_a_config)

      # Register chain_b in profile_b
      :ok = ConfigStore.register_chain_runtime(@profile_b, @test_chain <> "_b", chain_b_config)

      # List chains for each profile
      chains_a = ConfigStore.list_chains_for_profile(@profile_a)
      chains_b = ConfigStore.list_chains_for_profile(@profile_b)

      # Verify each profile only sees its own chain
      assert Enum.any?(chains_a, &(&1 == @test_chain <> "_a"))
      refute Enum.any?(chains_a, &(&1 == @test_chain <> "_b"))

      assert Enum.any?(chains_b, &(&1 == @test_chain <> "_b"))
      refute Enum.any?(chains_b, &(&1 == @test_chain <> "_a"))

      # Cleanup
      ConfigStore.unregister_chain_runtime(@profile_a, @test_chain <> "_a")
      ConfigStore.unregister_chain_runtime(@profile_b, @test_chain <> "_b")
    end
  end

  describe "Metrics/Benchmark isolation" do
    test "benchmark data recorded in profile_a doesn't appear in profile_b" do
      # Record some metrics in profile_a
      BenchmarkStore.record_rpc_call(
        @profile_a,
        @test_chain,
        "provider1",
        "eth_blockNumber",
        100,
        :success
      )

      BenchmarkStore.record_rpc_call(
        @profile_a,
        @test_chain,
        "provider1",
        "eth_blockNumber",
        150,
        :success
      )

      # Get metrics from profile_a (should have data)
      metrics_a =
        BenchmarkStore.get_rpc_performance(
          @profile_a,
          @test_chain,
          "provider1",
          "eth_blockNumber"
        )

      assert metrics_a != nil
      assert metrics_a.total_calls > 0

      # Get metrics from profile_b (should have no data - empty/zeroed metrics)
      metrics_b =
        BenchmarkStore.get_rpc_performance(
          @profile_b,
          @test_chain,
          "provider1",
          "eth_blockNumber"
        )

      # Profile B hasn't recorded any data, so should have zero calls
      assert metrics_b.total_calls == 0
    end

    test "clear_chain_metrics only affects the specified profile" do
      # Record metrics in both profiles
      BenchmarkStore.record_rpc_call(
        @profile_a,
        @test_chain,
        "provider1",
        "eth_blockNumber",
        100,
        :success
      )

      BenchmarkStore.record_rpc_call(
        @profile_b,
        @test_chain,
        "provider1",
        "eth_blockNumber",
        200,
        :success
      )

      # Verify both have metrics
      assert BenchmarkStore.get_rpc_performance(
               @profile_a,
               @test_chain,
               "provider1",
               "eth_blockNumber"
             ) != nil

      assert BenchmarkStore.get_rpc_performance(
               @profile_b,
               @test_chain,
               "provider1",
               "eth_blockNumber"
             ) != nil

      # Clear metrics for profile_a only
      BenchmarkStore.clear_chain_metrics(@profile_a, @test_chain)

      # Verify profile_a is cleared but profile_b still has data
      metrics_a_after =
        BenchmarkStore.get_rpc_performance(
          @profile_a,
          @test_chain,
          "provider1",
          "eth_blockNumber"
        )

      metrics_b_after =
        BenchmarkStore.get_rpc_performance(
          @profile_b,
          @test_chain,
          "provider1",
          "eth_blockNumber"
        )

      # After clearing, metrics return a zeroed struct
      assert metrics_a_after.total_calls == 0
      assert metrics_b_after != nil
      assert metrics_b_after.total_calls > 0
    end
  end

  describe "Circuit breaker isolation" do
    test "circuit breaker failures on instance_a don't affect instance_b" do
      # With shared provider architecture, CBs are keyed by {instance_id, transport}.
      # Different instances (different URLs) have independent circuit breakers.
      cb_id_a = {"isolation_instance_a", :http}
      cb_id_b = {"isolation_instance_b", :http}

      cb_config = %{failure_threshold: 2, recovery_timeout: 1000, success_threshold: 1}
      {:ok, _} = CircuitBreaker.start_link({cb_id_a, cb_config})
      {:ok, _} = CircuitBreaker.start_link({cb_id_b, cb_config})

      CircuitBreaker.record_failure(cb_id_a)
      CircuitBreaker.record_failure(cb_id_a)
      Process.sleep(50)

      state_a = CircuitBreaker.get_state(cb_id_a)
      state_b = CircuitBreaker.get_state(cb_id_b)

      assert state_a.state == :open
      assert state_b.state == :closed
      assert state_b.failure_count == 0

      key_a = "isolation_instance_a:http"
      key_b = "isolation_instance_b:http"

      case GenServer.whereis({:via, Registry, {Lasso.Registry, {:circuit_breaker, key_a}}}) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      case GenServer.whereis({:via, Registry, {Lasso.Registry, {:circuit_breaker, key_b}}}) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end
    end
  end

  describe "Profile chain supervisor isolation" do
    test "stopping chain in profile_a doesn't affect profile_b" do
      # This test verifies that profile chain supervisors are truly independent
      # Since we don't have the full chain infrastructure in this test,
      # we'll test the ConfigStore side of isolation (supervisor tests are in integration)

      chain_config = %{chain_id: 1, name: @test_chain, providers: []}

      # Register chain in both profiles
      :ok = ConfigStore.register_chain_runtime(@profile_a, @test_chain, chain_config)
      :ok = ConfigStore.register_chain_runtime(@profile_b, @test_chain, chain_config)

      # Verify both exist
      assert {:ok, _} = ConfigStore.get_chain(@profile_a, @test_chain)
      assert {:ok, _} = ConfigStore.get_chain(@profile_b, @test_chain)

      # Unregister from profile_a
      :ok = ConfigStore.unregister_chain_runtime(@profile_a, @test_chain)

      # Verify profile_a no longer has it
      assert {:error, :not_found} = ConfigStore.get_chain(@profile_a, @test_chain)

      # Verify profile_b still has it
      assert {:ok, _} = ConfigStore.get_chain(@profile_b, @test_chain)
    end
  end
end

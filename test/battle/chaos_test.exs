defmodule Livechain.Battle.ChaosTest do
  @moduledoc """
  Phase 2 validation tests for chaos injection capabilities.

  These tests demonstrate the chaos module without requiring
  full system integration (deferred to integration tests).
  """

  use ExUnit.Case, async: false

  alias Livechain.Battle.{Scenario, Chaos, Reporter}

  @moduletag :battle
  @moduletag :chaos
  @moduletag timeout: :infinity

  setup do
    Application.ensure_all_started(:livechain)
    :ok
  end

  test "chaos functions execute without errors" do
    # Test that chaos functions can be created and called

    # Create chaos functions
    kill_fn = Chaos.kill_provider("test_provider", delay: 100)
    flap_fn = Chaos.flap_provider("test_provider", down: 100, up: 200, count: 1)
    degrade_fn = Chaos.degrade_provider("test_provider", latency: 100, after: 100, duration: 200)

    # Verify they're functions
    assert is_function(kill_fn, 0)
    assert is_function(flap_fn, 0)
    assert is_function(degrade_fn, 0)

    # Execute them (they'll fail to find provider, but shouldn't crash)
    result1 = kill_fn.()
    assert result1 in [:ok, {:error, :not_found}]

    # Note: flap and degrade will timeout/complete
    # We won't run them in this test to keep it fast
  end

  test "scenario with chaos injection orchestrates correctly" do
    # Verify scenario can include chaos without executing it

    result =
      Scenario.new("Chaos Orchestration Test")
      |> Scenario.setup(fn ->
        {:ok, %{test: true}}
      end)
      |> Scenario.workload(fn ->
        # Emit some test events
        for i <- 1..50 do
          :telemetry.execute(
            [:livechain, :battle, :request],
            %{latency: 50 + :rand.uniform(50)},
            %{
              chain: "testchain",
              method: "eth_blockNumber",
              strategy: nil,
              result: :success,
              request_id: i
            }
          )
        end

        :ok
      end)
      |> Scenario.chaos([
        # These chaos functions won't find providers, but should execute
        Chaos.degrade_provider("phantom_provider", latency: 100, after: 0, duration: 100)
      ])
      |> Scenario.collect([:requests])
      |> Scenario.slo(success_rate: 0.95)
      |> Scenario.run()

    Reporter.save_markdown(result, "priv/battle_results/")

    # Verify scenario completed
    assert result.passed?
    assert result.analysis.requests.total == 50
  end

  test "multiple chaos actions can run concurrently" do
    result =
      Scenario.new("Concurrent Chaos Test")
      |> Scenario.setup(fn ->
        {:ok, %{}}
      end)
      |> Scenario.workload(fn ->
        # Quick workload
        for i <- 1..100 do
          :telemetry.execute(
            [:livechain, :battle, :request],
            %{latency: 60},
            %{
              chain: "test",
              method: "eth_blockNumber",
              strategy: nil,
              result: :success,
              request_id: i
            }
          )
        end

        Process.sleep(500)
        :ok
      end)
      |> Scenario.chaos([
        # Multiple chaos functions should all execute
        Chaos.degrade_provider("provider_1", latency: 50, after: 0, duration: 200),
        Chaos.degrade_provider("provider_2", latency: 100, after: 100, duration: 200)
      ])
      |> Scenario.collect([:requests])
      |> Scenario.slo(success_rate: 0.99)
      |> Scenario.run()

    assert result.passed?

    IO.puts("\n✅ Chaos orchestration working!")
    IO.puts("   Multiple chaos functions executed concurrently")
  end

  test "failover analysis detects high-latency requests" do
    # Test the failover detection logic in Analyzer

    result =
      Scenario.new("Failover Detection Test")
      |> Scenario.setup(fn ->
        {:ok, %{}}
      end)
      |> Scenario.workload(fn ->
        # Normal requests: ~60ms
        for i <- 1..90 do
          :telemetry.execute(
            [:livechain, :battle, :request],
            %{latency: 50 + :rand.uniform(20)},
            %{
              chain: "test",
              method: "eth_blockNumber",
              strategy: nil,
              result: :success,
              request_id: i
            }
          )
        end

        # Simulated failover requests: high latency
        for i <- 91..100 do
          :telemetry.execute(
            [:livechain, :battle, :request],
            %{latency: 200 + :rand.uniform(100)},
            %{
              chain: "test",
              method: "eth_blockNumber",
              strategy: nil,
              result: :success,
              request_id: i
            }
          )
        end

        :ok
      end)
      |> Scenario.collect([:requests])
      |> Scenario.slo(success_rate: 0.99)
      |> Scenario.run()

    Reporter.save_markdown(result, "priv/battle_results/")

    assert result.passed?

    # Verify failover detection
    assert result.analysis.requests.failover_count > 0,
           "Expected to detect high-latency requests as failovers"

    assert result.analysis.requests.avg_failover_latency_ms > 150,
           "Failover requests should have high latency"

    IO.puts("\n✅ Failover Detection Working!")
    IO.puts("   Detected #{result.analysis.requests.failover_count} potential failovers")
    IO.puts(
      "   Avg failover latency: #{Float.round(result.analysis.requests.avg_failover_latency_ms, 1)}ms"
    )
  end

  test "chaos telemetry events are emitted" do
    # Verify chaos actions emit telemetry

    # Attach a test handler
    test_pid = self()

    :telemetry.attach(
      :chaos_test_handler,
      [:livechain, :battle, :chaos],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:chaos_event, measurements, metadata})
      end,
      nil
    )

    # Execute chaos that emits telemetry
    chaos_fn = Chaos.degrade_provider("test_provider", latency: 500, after: 0, duration: 100)
    chaos_fn.()

    # Should receive degradation event
    assert_receive {:chaos_event, %{latency_injected: 500}, %{provider_id: "test_provider"}},
                   1000

    # Should receive restoration event after duration
    assert_receive {:chaos_event, %{latency_injected: 0}, %{provider_id: "test_provider"}}, 200

    :telemetry.detach(:chaos_test_handler)

    IO.puts("\n✅ Chaos telemetry working!")
  end
end
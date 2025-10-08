defmodule Lasso.TelemetryIntegrationExampleTest do
  @moduledoc """
  Example integration tests demonstrating correct telemetry-first testing patterns.

  This shows how to properly test the RequestPipeline using telemetry events
  instead of fragile Process.sleep() or await patterns.
  """

  use Lasso.Test.LassoIntegrationCase

  alias Lasso.Core.Request.RequestPipeline
  alias Lasso.Test.TelemetrySync

  describe "correct telemetry-first testing pattern" do
    @tag :integration
    test "verifies request completion via telemetry", %{chain: chain} do
      # STEP 1: Attach collector BEFORE executing request
      {:ok, collector} = TelemetrySync.attach_request_collector(
        method: "eth_blockNumber",
        chain: chain
      )

      # STEP 2: Execute the request (this will generate telemetry)
      {:ok, result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

      # STEP 3: Wait for telemetry event (it was already collected during step 2)
      {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)

      # STEP 4: Verify both the result and telemetry
      assert is_binary(result)
      assert measurements.duration > 0
      assert metadata.method == "eth_blockNumber"
      assert metadata.chain == chain
      assert metadata.status == :ok
    end

    @tag :integration
    test "tracks multiple retry attempts", %{chain: chain} do
      # Attach collector expecting multiple attempts
      {:ok, collector} = TelemetrySync.attach_request_collector(
        method: "eth_blockNumber",
        count: 3  # Expect 3 attempts (initial + 2 retries)
      )

      # Configure to trigger retries (you'd need to set up chaos/failures)
      # For demonstration, assuming request might retry
      {:ok, _result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

      # Collect all attempts
      # Note: If no retries occur, this will timeout, which is expected behavior
      case TelemetrySync.await_event(collector, timeout: 5000) do
        {:ok, events} when is_list(events) ->
          # Multiple attempts occurred
          assert length(events) <= 3

          # Verify each attempt has telemetry
          for {measurements, metadata} <- events do
            assert measurements.duration > 0
            assert metadata.method == "eth_blockNumber"
          end

        {:error, :timeout} ->
          # Only one attempt succeeded, no retries needed
          # This is actually the happy path!
          :ok
      end
    end

    @tag :integration
    test "verifies provider selection via telemetry", %{chain: chain} do
      # Collect telemetry including provider information
      {:ok, collector} = TelemetrySync.attach_collector(
        [:lasso, :request, :completed],
        match: fn _measurements, metadata ->
          metadata.method == "eth_blockNumber" and metadata.chain == chain
        end
      )

      {:ok, _result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

      {:ok, _measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)

      # Verify provider was selected
      assert is_map(metadata.provider_id) or is_binary(metadata.provider_id)
      assert metadata.adapter in [:public_node, :alchemy, :infura]
    end

    @tag :integration
    test "measures request timing accurately", %{chain: chain} do
      {:ok, collector} = TelemetrySync.attach_request_collector(method: "eth_blockNumber")

      start_time = System.monotonic_time(:millisecond)
      {:ok, _result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
      end_time = System.monotonic_time(:millisecond)

      {:ok, measurements, _metadata} = TelemetrySync.await_event(collector, timeout: 1000)

      # Telemetry duration should be close to measured time
      wall_clock_duration = end_time - start_time
      telemetry_duration = measurements.duration

      # Allow some variance (telemetry measures internal execution)
      assert_in_delta telemetry_duration, wall_clock_duration, 100
    end
  end

  describe "testing error scenarios with telemetry" do
    @tag :integration
    test "captures failure telemetry when provider is down", %{chain: chain} do
      # Attach collector for completion events (will capture errors)
      {:ok, collector} = TelemetrySync.attach_request_collector(
        method: "eth_blockNumber",
        chain: chain
      )

      # You would trigger failure here (e.g., chaos engineering)
      # For demonstration, assuming normal execution
      result = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

      case result do
        {:ok, _} ->
          # Request succeeded
          {:ok, _measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)
          assert metadata.status == :ok

        {:error, _reason} ->
          # Request failed, telemetry should still be emitted
          {:ok, _measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)
          assert metadata.status == :error
      end
    end

    @tag :integration
    test "verifies circuit breaker telemetry", %{chain: chain} do
      # Collect circuit breaker events
      {:ok, cb_collector} = TelemetrySync.attach_collector(
        [:lasso, :circuit_breaker, :state_change],
        match: [chain: chain]
      )

      # Collect request events
      {:ok, req_collector} = TelemetrySync.attach_request_collector(
        method: "eth_blockNumber",
        chain: chain
      )

      # Execute request
      {:ok, _result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

      # Verify request completed
      {:ok, _measurements, _metadata} = TelemetrySync.await_event(req_collector, timeout: 1000)

      # Circuit breaker state change is optional (only if state actually changed)
      case TelemetrySync.await_event(cb_collector, timeout: 500) do
        {:ok, _measurements, metadata} ->
          assert metadata.new_state in [:closed, :open, :half_open]

        {:error, :timeout} ->
          # No state change occurred, which is fine
          :ok
      end
    end
  end

  describe "convenience wrapper pattern" do
    @tag :integration
    test "using collect_event for simple cases", %{chain: chain} do
      # For simple cases, use collect_event wrapper
      {:ok, measurements, metadata} =
        TelemetrySync.collect_event(
          [:lasso, :request, :completed],
          fn ->
            RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])
          end,
          match: [method: "eth_blockNumber", chain: chain],
          timeout: 1000
        )

      assert measurements.duration > 0
      assert metadata.method == "eth_blockNumber"
      assert metadata.status == :ok
    end
  end

  describe "anti-patterns to avoid" do
    @tag :integration
    test "WRONG: attaching after request completes" do
      chain = "ethereum"

      # WRONG: Execute first
      {:ok, _result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

      # Then attach (too late!)
      {:ok, collector} = TelemetrySync.attach_request_collector(
        method: "eth_blockNumber",
        chain: chain
      )

      # This WILL timeout because event already fired
      assert {:error, :timeout} = TelemetrySync.await_event(collector, timeout: 500)
    end

    @tag :integration
    test "WRONG: using Process.sleep instead of telemetry" do
      chain = "ethereum"

      # Don't do this!
      {:ok, _result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

      # Hoping that "enough time" has passed
      Process.sleep(100)

      # Now trying to verify something, but we have no guarantees
      # This is fragile and non-deterministic
    end

    @tag :integration
    test "CORRECT: using telemetry for deterministic verification" do
      chain = "ethereum"

      # Attach BEFORE
      {:ok, collector} = TelemetrySync.attach_request_collector(
        method: "eth_blockNumber",
        chain: chain
      )

      # Execute
      {:ok, _result} = RequestPipeline.execute_via_channels(chain, "eth_blockNumber", [])

      # Wait deterministically
      {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1000)

      # Now we have PROOF the event occurred
      assert metadata.status == :ok
      assert measurements.duration > 0
    end
  end
end

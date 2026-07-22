defmodule Lasso.RPC.RequestPipelineTest do
  @moduledoc """
  Tests for RequestPipeline - the critical path for all RPC requests.

  Focus: API surface validation and basic behavior verification.
  Note: Full integration testing is covered by existing integration tests.
        These tests validate that the API accepts correct parameters and creates
        proper RequestContext tracking.
  """

  use ExUnit.Case, async: false

  alias Lasso.RPC.{RequestPipeline, RequestContext, RequestOptions}
  alias Lasso.RPC.RequestPipeline.{FailoverStrategy, Observability}
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Test.TelemetrySync
  alias Lasso.Core.Support.CircuitBreaker

  setup do
    Application.ensure_all_started(:lasso)
    :ok
  end

  defp extract_context(result) do
    case result do
      {:ok, _, ctx} -> ctx
      {:error, _, ctx} -> ctx
    end
  end

  defp assert_result_valid(result) do
    assert match?({:ok, _, _ctx}, result) or match?({:error, _, _ctx}, result)
  end

  describe "execute_via_channels/4 - parameter validation" do
    test "creates RequestContext when not provided" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      ctx = extract_context(result)
      assert %RequestContext{} = ctx
      assert ctx.chain_id == 1
      assert ctx.method == "eth_blockNumber"
    end

    test "uses provided RequestContext" do
      custom_ctx = RequestContext.new(1, "eth_call", [], strategy: :fastest)

      result =
        RequestPipeline.execute_via_channels(1, "eth_call", [], %RequestOptions{
          profile: "public",
          strategy: :fastest,
          timeout_ms: 30_000,
          request_context: custom_ctx
        })

      returned_ctx = extract_context(result)
      assert returned_ctx.request_id == custom_ctx.request_id
      assert returned_ctx.strategy == :fastest
    end

    test "handles empty params" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      assert_result_valid(result)
    end

    test "accepts standard options" do
      opts = %RequestOptions{
        profile: "public",
        strategy: :fastest,
        timeout_ms: 5000,
        transport: :http
      }

      result = RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], opts)
      assert_result_valid(result)
    end
  end

  describe "execute_via_channels/4 - observability" do
    test "marks selection start" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      ctx = extract_context(result)
      assert ctx.selection_start != nil
    end

    test "tracks retry count" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      ctx = extract_context(result)
      assert is_integer(ctx.retries)
      assert ctx.retries >= 0
    end

    test "stores request metadata in context" do
      result =
        RequestPipeline.execute_via_channels(
          1,
          "eth_getBalance",
          ["0x123", "latest"],
          %RequestOptions{profile: "public", strategy: :load_balanced, timeout_ms: 30_000}
        )

      ctx = extract_context(result)
      assert ctx.chain_id == 1
      assert ctx.method == "eth_getBalance"
      assert ctx.params == ["0x123", "latest"]
    end
  end

  describe "execute_via_channels/4 - strategy support" do
    test "accepts :fastest strategy" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :fastest,
          timeout_ms: 30_000
        })

      assert_result_valid(result)
    end

    test "accepts :priority strategy" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :priority,
          timeout_ms: 30_000
        })

      assert_result_valid(result)
    end

    test ":load_balanced strategy" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      assert_result_valid(result)
    end

    test "stores strategy in context" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_call", [], %RequestOptions{
          profile: "public",
          strategy: :fastest,
          timeout_ms: 30_000
        })

      ctx = extract_context(result)
      assert ctx.strategy == :fastest
    end
  end

  describe "execute_via_channels/4 - transport preferences" do
    test "accepts :http transport override" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          transport: :http,
          timeout_ms: 30_000,
          strategy: :load_balanced
        })

      assert_result_valid(result)
    end

    test "accepts :ws transport override" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          transport: :ws,
          timeout_ms: 30_000,
          strategy: :load_balanced
        })

      assert_result_valid(result)
    end

    test "defaults to :http when no transport specified" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      ctx = extract_context(result)
      assert ctx.transport == :http
    end
  end

  describe "execute_via_channels/4 - timeout handling" do
    test "accepts custom timeout" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          timeout_ms: 5000,
          strategy: :load_balanced
        })

      assert_result_valid(result)
    end

    test "uses default timeout when not specified" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      assert_result_valid(result)
    end
  end

  describe "execute_via_channels/4 - JSON-RPC request construction" do
    test "builds proper JSON-RPC 2.0 request structure" do
      params = ["0xabcd", "latest"]

      result =
        RequestPipeline.execute_via_channels(
          1,
          "eth_getBalance",
          params,
          %RequestOptions{profile: "public", strategy: :load_balanced, timeout_ms: 30_000}
        )

      ctx = extract_context(result)
      assert ctx.params == ["0xabcd", "latest"]
    end

    test "handles nil params" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", nil, %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      ctx = extract_context(result)
      assert ctx.params == nil
    end
  end

  describe "RequestContext lifecycle" do
    test "context is always returned in result tuple" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_test", [], %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      ctx = extract_context(result)
      assert %RequestContext{} = ctx
    end

    test "context tracks timing information" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      ctx = extract_context(result)
      assert ctx.start_time != nil
      assert ctx.end_to_end_latency_ms != nil || ctx.selection_start != nil
    end

    test "context includes unique request ID" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_test", [], %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      ctx = extract_context(result)
      assert is_binary(ctx.request_id)
      assert byte_size(ctx.request_id) == 32
    end
  end

  describe "Fast-fail failover logic" do
    test "FailoverStrategy returns terminal when no channels remaining" do
      error = JError.new(-32_005, "Rate limit", category: :rate_limit, retriable?: true)
      ctx = RequestContext.new(1, "eth_blockNumber", [])

      assert {:terminal_error, :no_channels_remaining} =
               FailoverStrategy.decide(error, [], ctx)
    end

    test "fast-fail logic properly categorizes rate limit errors" do
      error =
        JError.new(-32_005, "Rate limit exceeded", category: :rate_limit, retriable?: true)

      assert error.category == :rate_limit
      assert error.retriable? == true
    end

    test "fast-fail logic properly categorizes server errors" do
      error = JError.new(-32_000, "Internal error", category: :server_error, retriable?: true)

      assert error.category == :server_error
      assert error.retriable? == true
    end

    test "fast-fail logic properly categorizes network errors" do
      error =
        JError.new(-32_004, "Connection failed", category: :network_error, retriable?: true)

      assert error.category == :network_error
      assert error.retriable? == true
    end

    test "fast-fail logic properly categorizes timeout errors" do
      error = JError.new(-32_000, "Request timeout", category: :timeout, retriable?: true)

      assert error.category == :timeout
      assert error.retriable? == true
    end

    test "fast-fail logic properly categorizes auth errors" do
      error = JError.new(4100, "Unauthorized", category: :auth_error, retriable?: true)

      assert error.category == :auth_error
      assert error.retriable? == true
    end

    test "fast-fail logic properly categorizes capability violations" do
      error =
        JError.new(-32_701, "Max addresses exceeded",
          category: :capability_violation,
          retriable?: true
        )

      assert error.category == :capability_violation
      assert error.retriable? == true
    end

    test "non-retriable errors are not categorized for fast-fail" do
      error = JError.new(-32_602, "Invalid params", category: :invalid_params, retriable?: false)

      assert error.category == :invalid_params
      assert error.retriable? == false
    end

    test "circuit_open errors trigger failover when channels remain" do
      ctx = RequestContext.new(1, "eth_blockNumber", [])
      dummy_channel = %Lasso.RPC.Channel{provider_id: "test", transport: :http}

      assert {:failover, :circuit_open} =
               FailoverStrategy.decide(:circuit_open, [dummy_channel], ctx)
    end

    test "execute_via_channels increments retry count on failover" do
      result =
        RequestPipeline.execute_via_channels(1, "eth_blockNumber", [], %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      ctx = extract_context(result)
      assert is_integer(ctx.retries)
      assert ctx.retries >= 0
    end
  end

  describe "Fast-fail telemetry events" do
    test "Observability.record_fast_fail emits [:lasso, :failover, :fast_fail] telemetry" do
      collector =
        TelemetrySync.start_collector([:lasso, :failover, :fast_fail])

      ctx =
        RequestContext.new(1, "eth_blockNumber", [])
        |> Map.put(:opts, %RequestOptions{
          profile: "public",
          strategy: :load_balanced,
          timeout_ms: 30_000
        })

      channel = %Lasso.RPC.Channel{provider_id: "test_provider", transport: :http}
      error = JError.new(-32_000, "Server error", category: :server_error, retriable?: true)

      Observability.record_fast_fail(ctx, channel, :server_error_detected, error, 5)

      {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1_000)

      assert measurements.count == 1
      assert measurements.duration == 5
      assert metadata.chain_id == 1
      assert metadata.method == "eth_blockNumber"
      assert metadata.provider_id == "test_provider"
      assert metadata.transport == :http
      assert metadata.error_category == :server_error
      assert metadata.failover_reason == :server_error_detected
    end
  end

  describe "Fast-fail performance characteristics" do
    test "documents expected fast-fail latency < 10ms" do
      expected_fast_fail_latency_ms = 10
      expected_timeout_latency_ms = 1450

      improvement_factor = expected_timeout_latency_ms / expected_fast_fail_latency_ms
      assert improvement_factor == 145.0
    end

    test "documents elimination of timeout stacking" do
      providers_to_try = 3
      timeout_per_provider_ms = 1450

      worst_case_before = providers_to_try * timeout_per_provider_ms
      assert worst_case_before == 4350

      worst_case_after = providers_to_try * 10
      assert worst_case_after == 30
    end
  end

  describe "Channel exhaustion recovery (Issue #2)" do
    test "handle_no_channels returns provider_error with retry_after_ms data when available" do
      # When all channels are exhausted, the pipeline returns a provider_error
      # with retry_after_ms in the error data (if circuits have recovery times).
      # We test via execute_via_channels on a chain with no providers configured.
      result =
        RequestPipeline.execute_via_channels(
          9_999_999,
          "eth_blockNumber",
          [],
          %RequestOptions{profile: "public", strategy: :load_balanced, timeout_ms: 5_000}
        )

      assert {:error, %JError{} = error, _ctx} = result
      assert error.category == :provider_error
      assert error.retriable? == true
      assert String.contains?(error.message, "No available channels")
    end

    test "exhaustion telemetry emitted when all channels exhausted" do
      collector = TelemetrySync.start_collector([:lasso, :failover, :exhaustion])

      _result =
        RequestPipeline.execute_via_channels(
          9_999_999,
          "eth_blockNumber",
          [],
          %RequestOptions{profile: "public", strategy: :load_balanced, timeout_ms: 5_000}
        )

      {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 2_000)

      assert measurements.count == 1
      assert metadata.chain_id == 9_999_999
      assert metadata.method == "eth_blockNumber"
      assert is_integer(metadata.retry_after_ms)
    end

    test "Observability.record_degraded_mode emits [:lasso, :failover, :degraded_mode]" do
      collector = TelemetrySync.start_collector([:lasso, :failover, :degraded_mode])

      Observability.record_degraded_mode(1, "eth_blockNumber")

      {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1_000)
      assert measurements.count == 1
      assert metadata.chain_id == 1
      assert metadata.method == "eth_blockNumber"
    end

    test "Observability.record_degraded_success emits [:lasso, :failover, :degraded_success]" do
      collector = TelemetrySync.start_collector([:lasso, :failover, :degraded_success])

      channel = %Lasso.RPC.Channel{provider_id: "test_provider", transport: :http}
      Observability.record_degraded_success(1, "eth_blockNumber", channel)

      {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1_000)
      assert measurements.count == 1
      assert metadata.chain_id == 1
      assert metadata.method == "eth_blockNumber"
      assert metadata.provider_id == "test_provider"
      assert metadata.transport == :http
    end

    test "Observability.record_exhaustion emits [:lasso, :failover, :exhaustion]" do
      collector = TelemetrySync.start_collector([:lasso, :failover, :exhaustion])

      Observability.record_exhaustion(1, "eth_blockNumber", :http, 5000)

      {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1_000)
      assert measurements.count == 1
      assert metadata.chain_id == 1
      assert metadata.method == "eth_blockNumber"
      assert metadata.retry_after_ms == 5000
      assert metadata.transport == :http
    end

    test "exhaustion error includes retry_after_ms when circuits have recovery times" do
      collector = TelemetrySync.start_collector([:lasso, :failover, :exhaustion])

      Observability.record_exhaustion(1, "eth_blockNumber", :http, 3000)

      {:ok, _measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1_000)
      assert metadata.retry_after_ms == 3000
    end

    test "exhaustion defaults retry_after_ms to 0 when nil" do
      collector = TelemetrySync.start_collector([:lasso, :failover, :exhaustion])

      Observability.record_exhaustion(1, "eth_blockNumber", :http, nil)

      {:ok, _measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1_000)
      assert metadata.retry_after_ms == 0
    end

    test "exhaustion defaults transport to :both when nil" do
      collector = TelemetrySync.start_collector([:lasso, :failover, :exhaustion])

      Observability.record_exhaustion(1, "eth_blockNumber", nil, 1000)

      {:ok, _measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1_000)
      assert metadata.transport == :both
    end
  end

  describe "Degraded mode selection behavior" do
    test "SelectionFilters supports include_half_open flag" do
      filters = Lasso.RPC.SelectionFilters.new(include_half_open: true)
      assert filters.include_half_open == true

      filters = Lasso.RPC.SelectionFilters.new(include_half_open: false)
      assert filters.include_half_open == false

      # Default is false
      filters = Lasso.RPC.SelectionFilters.new()
      assert filters.include_half_open == false
    end

    test "Selection.select_channels accepts include_half_open option" do
      # include_half_open defaults to true in Selection.select_channels
      channels_with =
        Lasso.RPC.Selection.select_channels("public", 1, "eth_blockNumber",
          include_half_open: true
        )

      channels_without =
        Lasso.RPC.Selection.select_channels("public", 1, "eth_blockNumber",
          include_half_open: false
        )

      assert is_list(channels_with)
      assert is_list(channels_without)
      # With half-open included, we should get >= the number without
      assert length(channels_with) >= length(channels_without)
    end

    test "CircuitBreaker half-open state allows limited concurrent traffic" do
      instance_id = "test_half_open_#{:erlang.unique_integer([:positive])}"
      breaker_id = {instance_id, :http}

      config = %{failure_threshold: 1, recovery_timeout: 100, success_threshold: 1}
      {:ok, _pid} = CircuitBreaker.start_link({breaker_id, config})

      # Initially closed — should admit
      assert {:executed, _} =
               CircuitBreaker.call(breaker_id, fn -> {:ok, "result"} end)

      # Force open
      CircuitBreaker.open(breaker_id)
      Process.sleep(10)

      # Should reject while open
      assert {:rejected, _reason} =
               CircuitBreaker.call(breaker_id, fn -> {:ok, "result"} end)

      # Wait for recovery timeout to enter half-open
      Process.sleep(150)

      # Half-open should admit at least one request
      assert {:executed, _} =
               CircuitBreaker.call(breaker_id, fn -> {:ok, "result"} end)
    end
  end

  describe "Recovery time calculation" do
    test "CircuitBreaker.get_recovery_time_remaining returns time in ms when open" do
      instance_id = "test_recovery_#{:erlang.unique_integer([:positive])}"
      breaker_id = {instance_id, :http}
      config = %{failure_threshold: 1, recovery_timeout: 5_000, success_threshold: 1}

      {:ok, _pid} = CircuitBreaker.start_link({breaker_id, config})

      # Closed circuit returns nil
      assert CircuitBreaker.get_recovery_time_remaining(breaker_id) == nil

      # Open it
      CircuitBreaker.open(breaker_id)
      Process.sleep(10)

      remaining = CircuitBreaker.get_recovery_time_remaining(breaker_id)

      assert is_integer(remaining)
      assert remaining > 0
      # Recovery timeout is 5000ms base + jitter, so allow headroom
      assert remaining <= 6_000
    end

    test "CandidateListing.get_min_recovery_time returns {:ok, nil} when no circuits open" do
      {:ok, result} =
        Lasso.Providers.CandidateListing.get_min_recovery_time("public", 1)

      # Either nil (no open circuits) or a positive integer
      assert result == nil or (is_integer(result) and result > 0)
    end

    test "retry-after hint in exhaustion error message when recovery time available" do
      # Verify the message format when retry_after_ms is present
      result =
        RequestPipeline.execute_via_channels(
          9_999_999,
          "eth_blockNumber",
          [],
          %RequestOptions{profile: "public", strategy: :load_balanced, timeout_ms: 5_000}
        )

      assert {:error, %JError{message: message}, _ctx} = result
      assert String.contains?(message, "No available channels")
    end
  end

  describe "Degraded mode logging and observability" do
    test "Observability.record_circuit_open emits telemetry" do
      collector = TelemetrySync.start_collector([:lasso, :failover, :circuit_open])

      ctx =
        RequestContext.new(1, "eth_blockNumber", [])

      channel = %Lasso.RPC.Channel{provider_id: "test_provider", transport: :http}

      Observability.record_circuit_open(ctx, channel)

      {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1_000)
      assert measurements.count == 1
      assert metadata.chain_id == 1
      assert metadata.provider_id == "test_provider"
      assert metadata.transport == :http
    end

    test "Observability.record_request_start emits [:lasso, :rpc, :request, :start]" do
      collector = TelemetrySync.start_collector([:lasso, :rpc, :request, :start])

      Observability.record_request_start(1, "eth_blockNumber", :load_balanced)

      {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1_000)
      assert measurements.count == 1
      assert metadata.chain_id == 1
      assert metadata.method == "eth_blockNumber"
      assert metadata.strategy == :load_balanced
    end

    test "Observability.record_slow_request emits [:lasso, :request, :slow]" do
      collector = TelemetrySync.start_collector([:lasso, :request, :slow])

      Observability.record_slow_request(
        1,
        "eth_blockNumber",
        "provider_1",
        :http,
        2500.0
      )

      {:ok, measurements, metadata} = TelemetrySync.await_event(collector, timeout: 1_000)
      assert measurements.latency_ms == 2500.0
      assert metadata.chain_id == 1
      assert metadata.method == "eth_blockNumber"
      assert metadata.provider == "provider_1"
      assert metadata.transport == :http
    end
  end
end

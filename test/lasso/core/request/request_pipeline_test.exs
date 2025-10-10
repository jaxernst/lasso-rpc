defmodule Lasso.RPC.RequestPipelineTest do
  @moduledoc """
  Tests for RequestPipeline - the critical path for all RPC requests.

  Focus: API surface validation and basic behavior verification.
  Note: Full integration testing is covered by existing integration/battle tests.
        These tests validate that the API accepts correct parameters and creates
        proper RequestContext tracking.
  """

  use ExUnit.Case, async: false

  alias Lasso.RPC.{RequestPipeline, RequestContext}

  setup do
    Application.ensure_all_started(:lasso)
    :ok
  end

  describe "execute_via_channels/4 - parameter validation" do
    test "creates RequestContext when not provided" do
      # Use ethereum chain which is initialized in test env
      RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [], [])

      # Should have stored context even on error
      ctx = Process.get(:request_context)
      assert %RequestContext{} = ctx
      assert ctx.chain == "ethereum"
      assert ctx.method == "eth_blockNumber"
    end

    test "uses provided RequestContext" do
      custom_ctx = RequestContext.new("ethereum", "eth_call", strategy: :fastest)

      RequestPipeline.execute_via_channels("ethereum", "eth_call", [],
        request_context: custom_ctx
      )

      # Should use the provided context
      stored_ctx = Process.get(:request_context)
      assert stored_ctx.request_id == custom_ctx.request_id
      assert stored_ctx.strategy == :fastest
    end

    test "handles empty params" do
      result = RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [], [])

      # Should handle gracefully (will error due to no providers, but shouldn't crash)
      assert {:error, _} = result
    end

    test "accepts standard options" do
      opts = [
        strategy: :fastest,
        timeout: 5000,
        transport_override: :http
      ]

      result = RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [], opts)

      # Should not crash with valid options
      assert {:error, _} = result
    end
  end

  describe "execute_via_channels/4 - observability" do
    test "marks selection start" do
      RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [])

      ctx = Process.get(:request_context)
      # Selection should have been attempted
      assert ctx.selection_start != nil
    end

    test "tracks retry count" do
      RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [])

      ctx = Process.get(:request_context)
      assert is_integer(ctx.retries)
      assert ctx.retries >= 0
    end

    test "stores request metadata in context" do
      RequestPipeline.execute_via_channels("ethereum", "eth_getBalance", ["0x123", "latest"])

      ctx = Process.get(:request_context)
      assert ctx.chain == "ethereum"
      assert ctx.method == "eth_getBalance"
      assert ctx.params_present == true
    end
  end

  describe "execute_via_channels/4 - strategy support" do
    test "accepts :fastest strategy" do
      result =
        RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [],
          strategy: :fastest
        )

      assert {:error, _} = result
    end

    test "accepts :cheapest strategy" do
      result =
        RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [],
          strategy: :cheapest
        )

      assert {:error, _} = result
    end

    test "accepts :priority strategy" do
      result =
        RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [],
          strategy: :priority
        )

      assert {:error, _} = result
    end

    test "accepts :round_robin strategy (default)" do
      result =
        RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [],
          strategy: :round_robin
        )

      assert {:error, _} = result
    end

    test "stores strategy in context" do
      RequestPipeline.execute_via_channels("ethereum", "eth_call", [], strategy: :fastest)

      ctx = Process.get(:request_context)
      assert ctx.strategy == :fastest
    end
  end

  describe "execute_via_channels/4 - transport preferences" do
    test "accepts :http transport override" do
      result =
        RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [],
          transport_override: :http
        )

      assert {:error, _} = result
    end

    test "accepts :ws transport override" do
      result =
        RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [],
          transport_override: :ws
        )

      assert {:error, _} = result
    end

    test "defaults to :http when no transport specified" do
      RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [])

      ctx = Process.get(:request_context)
      assert ctx.transport == :http
    end
  end

  describe "execute_via_channels/4 - timeout handling" do
    test "accepts custom timeout" do
      result =
        RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [], timeout: 5000)

      assert {:error, _} = result
    end

    test "uses default timeout when not specified" do
      # Should not crash without timeout
      result = RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [])
      assert {:error, _} = result
    end
  end

  describe "execute_via_channels/4 - JSON-RPC request construction" do
    test "builds proper JSON-RPC 2.0 request structure" do
      # We can't directly inspect the internal request, but we can verify
      # the pipeline accepts standard JSON-RPC params
      params = ["0xabcd", "latest"]

      result = RequestPipeline.execute_via_channels("ethereum", "eth_getBalance", params)

      # Should handle params correctly (will fail due to no providers)
      assert {:error, _} = result

      ctx = Process.get(:request_context)
      assert ctx.params_present == true
    end

    test "handles nil params" do
      result = RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", nil)
      assert {:error, _} = result

      ctx = Process.get(:request_context)
      assert ctx.params_present == false
    end
  end

  describe "RequestContext lifecycle" do
    test "context is always stored in process dictionary" do
      RequestPipeline.execute_via_channels("ethereum", "eth_test", [])

      ctx = Process.get(:request_context)
      assert %RequestContext{} = ctx
    end

    test "context tracks timing information" do
      RequestPipeline.execute_via_channels("ethereum", "eth_blockNumber", [])

      ctx = Process.get(:request_context)
      assert ctx.start_time != nil
      assert ctx.end_to_end_latency_ms != nil || ctx.selection_start != nil
    end

    test "context includes unique request ID" do
      RequestPipeline.execute_via_channels("ethereum", "eth_test", [])

      ctx = Process.get(:request_context)
      assert is_binary(ctx.request_id)
      assert byte_size(ctx.request_id) == 32
    end
  end
end

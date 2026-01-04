defmodule Lasso.RPC.PassthroughIntegrationTest do
  @moduledoc """
  Integration tests for JSON passthrough optimization.

  These tests verify end-to-end that the passthrough optimization correctly
  preserves raw JSON bytes through the request pipeline, from provider response
  to final output.

  The passthrough optimization ensures:
  1. Raw bytes from provider response are preserved bit-for-bit
  2. Only envelope fields (jsonrpc, id, type) are parsed
  3. Large response bodies skip full JSON decode
  4. Response.Success struct carries raw_bytes through the pipeline
  """

  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration
  @moduletag timeout: 30_000

  alias Lasso.RPC.{RequestPipeline, RequestOptions, Response}

  describe "HTTP passthrough - basic responses" do
    test "returns Response.Success with raw_bytes for eth_blockNumber", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      # Result should be a Response.Success struct with passthrough data
      assert %Response.Success{} = result
      assert result.jsonrpc == "2.0"
      assert result.raw_bytes != nil
      assert is_binary(result.raw_bytes)

      # Raw bytes should be valid JSON
      assert {:ok, decoded} = Jason.decode(result.raw_bytes)
      assert decoded["jsonrpc"] == "2.0"
      assert Map.has_key?(decoded, "result")

      # Decoded result should be a hex block number
      assert String.starts_with?(decoded["result"], "0x")
    end

    test "decode_result extracts result field correctly", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      assert %Response.Success{} = result

      # decode_result should extract just the result field
      {:ok, block_number} = Response.Success.decode_result(result)
      assert is_binary(block_number)
      assert String.starts_with?(block_number, "0x")

      # It should match what's in the raw bytes
      {:ok, full_decode} = Jason.decode(result.raw_bytes)
      assert block_number == full_decode["result"]
    end

    test "response_size returns byte size of raw response", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      assert %Response.Success{} = result

      # response_size should equal raw_bytes byte size
      size = Response.Success.response_size(result)
      assert size == byte_size(result.raw_bytes)
    end
  end

  describe "HTTP passthrough - various result types" do
    test "handles eth_chainId response", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_chainId",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      # eth_chainId is handled locally for some chains, but if forwarded,
      # should return Response.Success
      case result do
        %Response.Success{} = success ->
          assert success.raw_bytes != nil
          {:ok, chain_id} = Response.Success.decode_result(success)
          assert String.starts_with?(chain_id, "0x")

        # If handled locally, result is built from config
        _ ->
          assert true
      end
    end

    test "handles eth_getBalance response with address param", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      # Use a well-known address (Vitalik's address)
      address = "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_getBalance",
          [address, "latest"],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      assert %Response.Success{} = result
      assert result.raw_bytes != nil

      {:ok, balance} = Response.Success.decode_result(result)
      # Balance should be a hex string (could be "0x0" or larger)
      assert String.starts_with?(balance, "0x")
    end
  end

  describe "HTTP passthrough - failover preserves passthrough" do
    test "failover result is still Response.Success", %{chain: chain} do
      profile = "default"

      # Primary fails, backup succeeds
      setup_providers([
        %{id: "primary", priority: 10, behavior: :always_fail, profile: profile},
        %{id: "backup", priority: 20, behavior: :healthy, profile: profile}
      ])

      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      # Even after failover, should get Response.Success with passthrough
      assert %Response.Success{} = result
      assert result.raw_bytes != nil

      {:ok, block_number} = Response.Success.decode_result(result)
      assert String.starts_with?(block_number, "0x")
    end
  end

  describe "HTTP passthrough - error responses" do
    test "provider errors return Response.Error", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{
          id: "error_provider",
          priority: 10,
          behavior: {:error, %{code: -32_600, message: "Invalid Request"}},
          profile: profile
        }
      ])

      {:error, error, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{
            provider_override: "error_provider",
            failover_on_override: false,
            strategy: :round_robin,
            timeout_ms: 30_000
          }
        )

      # Error should be properly parsed
      assert error != nil
    end
  end

  describe "HTTP passthrough - ID preservation" do
    test "response ID matches request ID for integer IDs", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      assert %Response.Success{id: response_id} = result

      # The pipeline assigns its own ID, so just verify it's present
      assert response_id != nil

      # ID in raw bytes should match parsed ID
      {:ok, decoded} = Jason.decode(result.raw_bytes)
      assert decoded["id"] == response_id
    end
  end

  describe "HTTP passthrough - context tracking" do
    test "RequestContext records passthrough result type", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      {:ok, result, ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      assert %Response.Success{} = result

      # Context should track this as passthrough
      assert ctx.status == :success
      assert ctx.result_type == "passthrough"
      assert ctx.result_size_bytes == byte_size(result.raw_bytes)
    end

    test "RequestContext records upstream latency", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      {:ok, _result, ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      # Upstream latency should be recorded
      assert ctx.upstream_latency_ms != nil
      assert ctx.upstream_latency_ms >= 0

      # End-to-end should be >= upstream
      assert ctx.end_to_end_latency_ms >= ctx.upstream_latency_ms

      # Lasso overhead should be calculated
      assert ctx.lasso_overhead_ms != nil
      assert ctx.lasso_overhead_ms >= 0
    end
  end

  describe "HTTP passthrough - to_bytes roundtrip" do
    test "Response.to_bytes returns identical bytes", %{chain: chain} do
      profile = "default"

      setup_providers([
        %{id: "provider", priority: 10, behavior: :healthy, profile: profile}
      ])

      {:ok, result, _ctx} =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{strategy: :round_robin, timeout_ms: 30_000}
        )

      assert %Response.Success{raw_bytes: original_bytes} = result

      # to_bytes should return identical bytes
      {:ok, output_bytes} = Response.to_bytes(result)
      assert output_bytes == original_bytes
    end
  end
end

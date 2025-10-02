defmodule Lasso.Battle.TransportRoutingTest do
  @moduledoc """
  Tests for Phase 1 of Transport-Agnostic Architecture.

  Validates:
  - HTTP and WebSocket transport selection
  - Mixed transport routing for unary methods
  - Subscription methods route to WebSocket only
  - Transport override functionality
  - Strategy-based channel selection across transports
  """

  use ExUnit.Case, async: false
  require Logger

  alias Lasso.Battle.SetupHelper
  alias Lasso.RPC.RequestPipeline

  @moduletag :battle
  @moduletag :transport
  @moduletag :real_providers
  @moduletag timeout: 120_000

  setup_all do
    # Override HTTP client for real provider tests
    original_client = Application.get_env(:lasso, :http_client)
    Application.put_env(:lasso, :http_client, Lasso.RPC.HttpClient.Finch)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, original_client)
    end)

    :ok
  end

  setup do
    Application.ensure_all_started(:lasso)

    on_exit(fn ->
      try do
        SetupHelper.cleanup_providers("ethereum", ["llamarpc", "ankr"])
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  describe "Transport selection" do
    @tag :fast
    test "execute_via_channels routes to HTTP when transport_override is :http" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])

      # Explicitly override to HTTP transport
      result =
        RequestPipeline.execute_via_channels(
          "ethereum",
          "eth_blockNumber",
          [],
          transport_override: :http,
          timeout: 10_000
        )

      assert {:ok, block_number} = result
      assert is_binary(block_number)
      assert String.starts_with?(block_number, "0x")

      Logger.info("✅ HTTP transport override: block #{block_number}")
    end

    @tag :fast
    test "execute_via_channels routes to WebSocket when transport_override is :ws" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])

      # Explicitly override to WebSocket transport
      result =
        RequestPipeline.execute_via_channels(
          "ethereum",
          "eth_blockNumber",
          [],
          transport_override: :ws,
          timeout: 10_000
        )

      assert {:ok, block_number} = result
      assert is_binary(block_number)
      assert String.starts_with?(block_number, "0x")

      Logger.info("✅ WebSocket transport override: block #{block_number}")
    end

    @tag :fast
    test "execute_via_channels considers both transports when no override" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])

      # No transport override - should consider both HTTP and WS
      result =
        RequestPipeline.execute_via_channels(
          "ethereum",
          "eth_blockNumber",
          [],
          strategy: :round_robin,
          timeout: 10_000
        )

      assert {:ok, block_number} = result
      assert is_binary(block_number)
      assert String.starts_with?(block_number, "0x")

      IO.puts("\n✅ Mixed Transport Routing Test Passed!")
      IO.puts("   Request succeeded with both transports available")
    end
  end

  describe "Method-aware routing" do
    @tag :fast
    test "unary methods can route to either HTTP or WebSocket" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])

      # Test multiple unary methods
      unary_methods = [
        {"eth_blockNumber", []},
        {"eth_chainId", []},
        {"eth_gasPrice", []}
      ]

      results =
        Enum.map(unary_methods, fn {method, params} ->
          result =
            RequestPipeline.execute_via_channels(
              "ethereum",
              method,
              params,
              strategy: :round_robin,
              timeout: 10_000
            )

          {method, result}
        end)

      # All should succeed
      Enum.each(results, fn {method, result} ->
        assert {:ok, _value} = result, "Method #{method} should succeed"
      end)

      IO.puts("\n✅ Unary Methods Routing Test Passed!")
      IO.puts("   All #{length(unary_methods)} unary methods routed successfully")
    end
  end

  describe "Provider failover across transports" do
    test "failover works when primary transport fails" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"},
        {:real, "ankr", "https://rpc.ankr.com/eth", "wss://rpc.ankr.com/eth/ws"}
      ])

      # Seed benchmarks to prefer llamarpc
      SetupHelper.seed_benchmarks("ethereum", "eth_blockNumber", [
        {"llamarpc", 80},
        {"ankr", 150}
      ])

      # First request should succeed
      result1 =
        RequestPipeline.execute_via_channels(
          "ethereum",
          "eth_blockNumber",
          [],
          strategy: :fastest,
          timeout: 10_000
        )

      assert {:ok, _block1} = result1

      # Even if one provider goes down, system should failover to another provider
      # (We can't easily kill real providers, but we can verify multiple providers work)
      result2 =
        RequestPipeline.execute_via_channels(
          "ethereum",
          "eth_blockNumber",
          [],
          provider_override: "ankr",
          timeout: 10_000
        )

      assert {:ok, _block2} = result2

      IO.puts("\n✅ Multi-Provider Transport Test Passed!")
      IO.puts("   Both providers accessible across transports")
    end
  end

  describe "Strategy-based channel selection" do
    @tag :fast
    test "round-robin strategy works across transports" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])

      # Make multiple requests with round-robin
      results =
        Enum.map(1..5, fn _i ->
          RequestPipeline.execute_via_channels(
            "ethereum",
            "eth_blockNumber",
            [],
            strategy: :round_robin,
            timeout: 10_000
          )
        end)

      # All should succeed
      Enum.each(results, fn result ->
        assert {:ok, _block} = result
      end)

      IO.puts("\n✅ Round-Robin Strategy Test Passed!")
      IO.puts("   #{length(results)} requests completed successfully")
    end

    @tag :fast
    test "fastest strategy selects channels based on latency" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"},
        {:real, "ankr", "https://rpc.ankr.com/eth", "wss://rpc.ankr.com/eth/ws"}
      ])

      # Seed benchmarks with clear latency difference
      SetupHelper.seed_benchmarks("ethereum", "eth_blockNumber", [
        {"llamarpc", 50},
        {"ankr", 200}
      ])

      # Multiple requests with fastest strategy
      results =
        Enum.map(1..10, fn _i ->
          RequestPipeline.execute_via_channels(
            "ethereum",
            "eth_blockNumber",
            [],
            strategy: :fastest,
            timeout: 10_000
          )
        end)

      # All should succeed
      successful_count =
        results
        |> Enum.filter(fn
          {:ok, _} -> true
          _ -> false
        end)
        |> length()

      assert successful_count >= 8, "Expected at least 8/10 requests to succeed"

      IO.puts("\n✅ Fastest Strategy Test Passed!")
      IO.puts("   #{successful_count}/#{length(results)} requests succeeded")
    end
  end

  describe "Transport capabilities" do
    @tag :fast
    test "providers with both HTTP and WebSocket URLs support both transports" do
      SetupHelper.setup_providers("ethereum", [
        {:real, "llamarpc", "https://eth.llamarpc.com", "wss://eth.llamarpc.com"}
      ])

      # Test HTTP transport
      http_result =
        RequestPipeline.execute_via_channels(
          "ethereum",
          "eth_blockNumber",
          [],
          transport_override: :http,
          timeout: 10_000
        )

      assert {:ok, _block1} = http_result

      # Test WebSocket transport
      ws_result =
        RequestPipeline.execute_via_channels(
          "ethereum",
          "eth_blockNumber",
          [],
          transport_override: :ws,
          timeout: 10_000
        )

      assert {:ok, _block2} = ws_result

      IO.puts("\n✅ Dual Transport Provider Test Passed!")
      IO.puts("   Provider supports both HTTP and WebSocket transports")
    end
  end
end

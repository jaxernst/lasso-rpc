defmodule Lasso.RPC.RequestAnalysisTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.RequestAnalysis

  describe "analyze/3 for eth_getLogs" do
    test "returns requires_archival: true for earliest block" do
      result = RequestAnalysis.analyze("eth_getLogs", [%{"fromBlock" => "earliest"}])
      assert result.requires_archival
    end

    test "returns requires_archival: false for latest block" do
      result = RequestAnalysis.analyze("eth_getLogs", [%{"fromBlock" => "latest"}])
      refute result.requires_archival
    end

    test "returns requires_archival: false for pending block" do
      result = RequestAnalysis.analyze("eth_getLogs", [%{"fromBlock" => "pending"}])
      refute result.requires_archival
    end

    test "returns requires_archival: false for safe block" do
      result = RequestAnalysis.analyze("eth_getLogs", [%{"fromBlock" => "safe"}])
      refute result.requires_archival
    end

    test "returns requires_archival: false for finalized block" do
      result = RequestAnalysis.analyze("eth_getLogs", [%{"fromBlock" => "finalized"}])
      refute result.requires_archival
    end

    test "returns requires_archival: true for old hex block with consensus height" do
      result =
        RequestAnalysis.analyze(
          "eth_getLogs",
          [%{"fromBlock" => "0x64"}],
          consensus_height: 20_000_000,
          archival_threshold: 1000
        )

      assert result.requires_archival
    end

    test "returns requires_archival: false for recent hex block with consensus height" do
      result =
        RequestAnalysis.analyze(
          "eth_getLogs",
          [%{"fromBlock" => "0xBEBC20"}],
          consensus_height: 12_500_000,
          archival_threshold: 1000
        )

      refute result.requires_archival
    end

    test "returns requires_archival: true for low hex block without consensus height (conservative)" do
      result = RequestAnalysis.analyze("eth_getLogs", [%{"fromBlock" => "0x64"}])
      assert result.requires_archival
    end

    test "returns requires_archival: true for high hex block without consensus height (conservative)" do
      result = RequestAnalysis.analyze("eth_getLogs", [%{"fromBlock" => "0xF4240"}])
      assert result.requires_archival
    end

    test "returns requires_archival: true if either fromBlock or toBlock is archival" do
      result =
        RequestAnalysis.analyze("eth_getLogs", [
          %{"fromBlock" => "earliest", "toBlock" => "latest"}
        ])

      assert result.requires_archival

      result =
        RequestAnalysis.analyze("eth_getLogs", [
          %{"fromBlock" => "latest", "toBlock" => "earliest"}
        ])

      assert result.requires_archival
    end

    test "handles missing fromBlock/toBlock (defaults to latest)" do
      result = RequestAnalysis.analyze("eth_getLogs", [%{}])
      refute result.requires_archival
    end

    test "extracts address count for single address" do
      result = RequestAnalysis.analyze("eth_getLogs", [%{"address" => "0xabc"}])
      assert result.address_count == 1
    end

    test "extracts address count for multiple addresses" do
      result =
        RequestAnalysis.analyze("eth_getLogs", [
          %{"address" => ["0xabc", "0xdef", "0x123"]}
        ])

      assert result.address_count == 3
    end
  end

  describe "analyze/3 for eth_call" do
    test "returns requires_archival: true for old block" do
      result =
        RequestAnalysis.analyze(
          "eth_call",
          [%{}, "0x64"],
          consensus_height: 20_000_000,
          archival_threshold: 1000
        )

      assert result.requires_archival
    end

    test "returns requires_archival: false for latest block" do
      result = RequestAnalysis.analyze("eth_call", [%{}, "latest"])
      refute result.requires_archival
    end

    test "returns requires_archival: false for nil block (defaults to latest)" do
      result = RequestAnalysis.analyze("eth_call", [%{}, nil])
      refute result.requires_archival
    end

    test "handles call without block parameter" do
      result = RequestAnalysis.analyze("eth_call", [%{}])
      refute result.requires_archival
    end
  end

  describe "analyze/3 for eth_getBalance" do
    test "returns requires_archival: true for old block" do
      result =
        RequestAnalysis.analyze(
          "eth_getBalance",
          ["0xabc", "0x64"],
          consensus_height: 20_000_000
        )

      assert result.requires_archival
    end

    test "returns requires_archival: false for latest" do
      result = RequestAnalysis.analyze("eth_getBalance", ["0xabc", "latest"])
      refute result.requires_archival
    end
  end

  describe "analyze/3 for eth_getCode" do
    test "detects archival for old block" do
      result =
        RequestAnalysis.analyze("eth_getCode", ["0xabc", "0x64"], consensus_height: 20_000_000)

      assert result.requires_archival
    end
  end

  describe "analyze/3 for eth_getTransactionCount" do
    test "detects archival for old block" do
      result =
        RequestAnalysis.analyze(
          "eth_getTransactionCount",
          ["0xabc", "0x64"],
          consensus_height: 20_000_000
        )

      assert result.requires_archival
    end
  end

  describe "analyze/3 for eth_getStorageAt" do
    test "detects archival for old block" do
      result =
        RequestAnalysis.analyze(
          "eth_getStorageAt",
          ["0xabc", "0x0", "0x64"],
          consensus_height: 20_000_000
        )

      assert result.requires_archival
    end
  end

  describe "analyze/3 for eth_getBlockByNumber" do
    test "detects archival for old block" do
      result =
        RequestAnalysis.analyze(
          "eth_getBlockByNumber",
          ["0x64", false],
          consensus_height: 20_000_000
        )

      assert result.requires_archival
    end

    test "returns false for latest" do
      result = RequestAnalysis.analyze("eth_getBlockByNumber", ["latest", false])
      refute result.requires_archival
    end
  end

  describe "analyze/3 for non-archival methods" do
    test "eth_blockNumber never requires archival" do
      result = RequestAnalysis.analyze("eth_blockNumber", [])
      refute result.requires_archival
    end

    test "eth_sendRawTransaction never requires archival" do
      result = RequestAnalysis.analyze("eth_sendRawTransaction", ["0xabc"])
      refute result.requires_archival
    end

    test "eth_chainId never requires archival" do
      result = RequestAnalysis.analyze("eth_chainId", [])
      refute result.requires_archival
    end
  end

  describe "archival threshold configuration" do
    test "uses custom archival_threshold when provided" do
      # Block 1100 with threshold 1000 and height 20_000_000
      # Age = 20_000_000 - 1100 = 19_998_900 > 1000 → archival
      result =
        RequestAnalysis.analyze(
          "eth_call",
          [%{}, "0x44C"],
          consensus_height: 20_000_000,
          archival_threshold: 1000
        )

      assert result.requires_archival

      # Same block with threshold 20_000_000
      # Age = 20_000_000 - 1100 = 19_998_900 < 20_000_000 → not archival
      result =
        RequestAnalysis.analyze(
          "eth_call",
          [%{}, "0x44C"],
          consensus_height: 20_000_000,
          archival_threshold: 20_000_000
        )

      refute result.requires_archival
    end

    test "uses default threshold 1000 when not provided" do
      # Block 100 with height 2000
      # Age = 2000 - 100 = 1900 > 1000 (default) → archival
      result =
        RequestAnalysis.analyze(
          "eth_call",
          [%{}, "0x64"],
          consensus_height: 2000
        )

      assert result.requires_archival
    end
  end

  describe "edge cases" do
    test "handles invalid hex block numbers gracefully" do
      result = RequestAnalysis.analyze("eth_call", [%{}, "0xGGG"])
      refute result.requires_archival
    end

    test "handles malformed parameters" do
      result = RequestAnalysis.analyze("eth_getLogs", ["invalid"])
      refute result.requires_archival
    end

    test "handles empty params list" do
      result = RequestAnalysis.analyze("eth_call", [])
      refute result.requires_archival
    end

    test "returns nil for block_range when not eth_getLogs" do
      result = RequestAnalysis.analyze("eth_call", [%{}, "latest"])
      assert result.block_range == nil
    end

    test "returns nil for address_count when not eth_getLogs" do
      result = RequestAnalysis.analyze("eth_call", [%{}, "latest"])
      assert result.address_count == nil
    end
  end
end

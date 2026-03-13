defmodule Lasso.Core.Support.BlockNotFoundClassificationTest do
  @moduledoc """
  Validates how "block not found" / "header not found" errors from various
  Ethereum clients are classified by the error pipeline.

  These errors occur when a provider is asked for a block it hasn't synced yet
  (slightly behind chain head). They should NOT penalize circuit breakers since
  the provider is healthy — it just hasn't seen that block.

  Run: mix test test/lasso/core/support/block_not_found_classification_test.exs
  """
  use ExUnit.Case, async: true

  alias Lasso.Core.Support.ErrorClassification
  alias Lasso.Core.Support.ErrorNormalizer
  alias Lasso.JSONRPC.Error, as: JError

  # ============================================================
  # Realistic provider error responses for "block not found"
  # ============================================================

  @provider_errors [
    %{
      label: "Geth - header not found",
      response: %{"error" => %{"code" => -32_000, "message" => "header not found"}},
      expected_retriable: true,
      expected_breaker_penalty: false
    },
    %{
      label: "Erigon - header not found",
      response: %{"error" => %{"code" => -32_000, "message" => "header not found"}},
      expected_retriable: true,
      expected_breaker_penalty: false
    },
    %{
      label: "Nethermind - block not found",
      response: %{"error" => %{"code" => -32_001, "message" => "block not found"}},
      expected_retriable: true,
      expected_breaker_penalty: false
    },
    %{
      label: "Besu - Block not found",
      response: %{"error" => %{"code" => -39_001, "message" => "Block not found"}},
      expected_retriable: true,
      expected_breaker_penalty: false
    },
    %{
      label: "Reth - header not found",
      response: %{"error" => %{"code" => -32_000, "message" => "header not found"}},
      expected_retriable: true,
      expected_breaker_penalty: false
    },
    %{
      label: "Generic - unknown block",
      response: %{"error" => %{"code" => -32_000, "message" => "unknown block"}},
      expected_retriable: true,
      expected_breaker_penalty: false
    },
    %{
      label: "Generic - block is out of range",
      response: %{"error" => %{"code" => -32_000, "message" => "block is out of range"}},
      expected_retriable: true,
      expected_breaker_penalty: false
    },
    %{
      label: "OnFinality - Unknown block number",
      response: %{"error" => %{"code" => -32_602, "message" => "Unknown block number"}},
      expected_retriable: true,
      expected_breaker_penalty: false
    },
    %{
      label: "Alchemy - header not found",
      response: %{"error" => %{"code" => -32_000, "message" => "header not found"}},
      expected_retriable: true,
      expected_breaker_penalty: false
    },
    %{
      label: "Infura - header not found",
      response: %{"error" => %{"code" => -32_000, "message" => "header not found"}},
      expected_retriable: true,
      expected_breaker_penalty: false
    }
  ]

  describe "ErrorClassification.categorize/2" do
    for %{label: label, response: response} <- @provider_errors do
      @tag_response response
      test "#{label}: classified as :block_not_available" do
        %{"error" => %{"code" => code, "message" => message}} = @tag_response
        assert ErrorClassification.categorize(code, message) == :block_not_available
      end
    end
  end

  describe "full pipeline (ErrorNormalizer)" do
    for %{
          label: label,
          response: response,
          expected_retriable: expected_retriable,
          expected_breaker_penalty: expected_breaker_penalty
        } <- @provider_errors do
      @tag_label label
      @tag_response response
      @tag_expected_retriable expected_retriable
      @tag_expected_breaker_penalty expected_breaker_penalty

      test "#{label}: retriable=#{expected_retriable}, breaker_penalty=#{expected_breaker_penalty}" do
        jerr =
          ErrorNormalizer.normalize(@tag_response,
            provider_id: "test_provider",
            transport: :http
          )

        assert %JError{} = jerr
        assert jerr.category == :block_not_available

        assert jerr.retriable? == @tag_expected_retriable,
               "Expected retriable?=#{@tag_expected_retriable} for #{@tag_label}, got #{jerr.retriable?}"

        assert jerr.breaker_penalty? == @tag_expected_breaker_penalty,
               "Expected breaker_penalty?=#{@tag_expected_breaker_penalty} for #{@tag_label}, got #{jerr.breaker_penalty?}"
      end
    end
  end

  describe "must NOT false-positive on similar messages" do
    test "archival 'missing trie node' stays as capability_violation" do
      assert ErrorClassification.categorize(-32_000, "missing trie node 0xabc123 (path 1234)") ==
               :capability_violation
    end

    test "'block range too large' stays as capability_violation" do
      assert ErrorClassification.categorize(-32_000, "block range too large") ==
               :capability_violation
    end

    test "'unknown blockchain' is NOT classified as block_not_available" do
      refute ErrorClassification.categorize(-32_000, "unknown blockchain") == :block_not_available
    end

    test "'transaction could not be found' is NOT classified as block_not_available" do
      refute ErrorClassification.categorize(-32_000, "transaction could not be found") ==
               :block_not_available
    end

    test "'contract could not be found' is NOT classified as block_not_available" do
      refute ErrorClassification.categorize(-32_000, "contract could not be found") ==
               :block_not_available
    end

    test "unmatched -32000 becomes unclassified_server_error" do
      assert ErrorClassification.categorize(-32_000, "internal server error") ==
               :unclassified_server_error
    end

    test "rate limit with 'not found' stays as rate_limit" do
      assert ErrorClassification.categorize(
               429,
               "Rate limit exceeded - endpoint not found in plan"
             ) ==
               :rate_limit
    end

    test "'blocks are not supported' stays as capability_violation" do
      assert ErrorClassification.categorize(-32_000, "blocks are not supported") ==
               :capability_violation
    end
  end
end

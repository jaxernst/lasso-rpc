defmodule Lasso.Core.Support.RealProviderBlockErrorsTest do
  @moduledoc """
  Tests error classification using REAL error responses captured from live providers
  when requesting a block they don't have (future block).

  Captured via manual curl on 2026-03-03 against default profile providers.

  Run: mix test test/lasso/core/support/real_provider_block_errors_test.exs
  """
  use ExUnit.Case, async: true

  alias Lasso.Core.Support.ErrorClassification
  alias Lasso.Core.Support.ErrorNormalizer

  @real_errors [
    %{
      provider: "dRPC (all chains)",
      method: "eth_getBalance / eth_call",
      code: 26,
      message: "Unknown block"
    },
    %{
      provider: "Merkle, 1RPC, LlamaRPC, Nodies",
      method: "eth_getBalance",
      code: -32_001,
      message: "block not found: 0x1770b2b"
    },
    %{
      provider: "BlockPI, bloXroute, MEVBlocker, PublicNode, Base Official",
      method: "eth_getBalance / eth_call",
      code: -32_000,
      message: "header not found"
    },
    %{
      provider: "OnFinality",
      method: "eth_getBalance",
      code: -32_602,
      message: "Unknown block number"
    },
    %{
      provider: "Lava",
      method: "eth_getBalance",
      code: -32_000,
      message: "24578859 could not be found"
    },
    %{
      provider: "OnFinality",
      method: "eth_call",
      code: -32_001,
      message: "block not found: 0x1770b2b"
    }
  ]

  describe "real provider errors classified as block_not_available" do
    for %{provider: provider, code: code, message: message} <- @real_errors,
        # Lava's "24578859 could not be found" is too broad to match safely
        provider != "Lava" do
      @tag_code code
      @tag_message message

      test "#{provider} (code=#{code}): classified as block_not_available" do
        category = ErrorClassification.categorize(@tag_code, @tag_message)
        retriable = ErrorClassification.retriable?(@tag_code, @tag_message)
        breaker_penalty = ErrorClassification.breaker_penalty?(category)

        assert category == :block_not_available,
               "Expected :block_not_available, got #{category} for code=#{@tag_code} message=#{inspect(@tag_message)}"

        assert retriable == true
        assert breaker_penalty == false
      end
    end
  end

  describe "Lava error falls through to code-based classification" do
    test "Lava '24578859 could not be found' classified as server_error (code -32000)" do
      category = ErrorClassification.categorize(-32_000, "24578859 could not be found")
      assert category == :server_error
      assert ErrorClassification.retriable?(-32_000, "24578859 could not be found") == true
      # CB penalty is acceptable — Lava-specific handling can be added via YAML error_rules
      assert ErrorClassification.breaker_penalty?(category) == true
    end
  end

  describe "full pipeline: dRPC code 26" do
    test "dRPC 'Unknown block' code=26 through ErrorNormalizer" do
      response = %{"error" => %{"code" => 26, "message" => "Unknown block"}}
      jerr = ErrorNormalizer.normalize(response, provider_id: "ethereum_drpc", transport: :http)

      assert jerr.category == :block_not_available
      assert jerr.retriable? == true
      assert jerr.breaker_penalty? == false
    end
  end

  describe "full pipeline: OnFinality -32602" do
    test "OnFinality 'Unknown block number' code=-32602 through ErrorNormalizer" do
      response = %{"error" => %{"code" => -32_602, "message" => "Unknown block number"}}

      jerr =
        ErrorNormalizer.normalize(response, provider_id: "ethereum_onfinality", transport: :http)

      assert jerr.category == :block_not_available
      assert jerr.retriable? == true
      assert jerr.breaker_penalty? == false
    end
  end
end

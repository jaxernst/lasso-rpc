defmodule Lasso.RPC.ErrorClassificationTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.ErrorClassification

  describe "categorize/2" do
    test "classifies LlamaRPC block range error as capability violation" do
      category =
        ErrorClassification.categorize(-32603, "eth_getLogs range is too large, max is 1k blocks")

      assert category == :capability_violation
    end

    test "classifies PublicNode address requirement error as capability violation" do
      message =
        "Please specify an address in your request or, to remove restrictions, order a dedicated full node here: https://www.allnodes.com/eth/host"

      category = ErrorClassification.categorize(-32701, message)
      assert category == :capability_violation
    end

    test "classifies PublicNode error code -32701 as capability violation even without message" do
      category = ErrorClassification.categorize(-32701, nil)
      assert category == :capability_violation
    end

    test "classifies regular internal error as internal error" do
      category = ErrorClassification.categorize(-32603, "Internal server error")
      assert category == :internal_error
    end

    test "classifies rate limit error correctly" do
      category = ErrorClassification.categorize(429, "Rate limit exceeded")
      assert category == :rate_limit
    end
  end

  describe "retriable?/2" do
    test "capability violations are retriable" do
      retriable =
        ErrorClassification.retriable?(-32603, "eth_getLogs range is too large, max is 1k blocks")

      assert retriable == true
    end

    test "PublicNode capability violations are retriable" do
      message =
        "Please specify an address in your request or, to remove restrictions, order a dedicated full node here: https://www.allnodes.com/eth/host"

      retriable = ErrorClassification.retriable?(-32701, message)
      assert retriable == true
    end

    test "PublicNode error code -32701 is retriable even without message" do
      retriable = ErrorClassification.retriable?(-32701, nil)
      assert retriable == true
    end

    test "rate limits are retriable" do
      retriable = ErrorClassification.retriable?(429, "Rate limit exceeded")
      assert retriable == true
    end

    test "invalid params are not retriable" do
      retriable = ErrorClassification.retriable?(-32602, "Invalid parameters")
      assert retriable == false
    end
  end

  describe "breaker_penalty?/1" do
    test "capability violations do not penalize circuit breaker" do
      penalty = ErrorClassification.breaker_penalty?(:capability_violation)
      assert penalty == false
    end

    test "rate limits do penalize circuit breaker" do
      penalty = ErrorClassification.breaker_penalty?(:rate_limit)
      assert penalty == true
    end

    test "server errors do penalize circuit breaker" do
      penalty = ErrorClassification.breaker_penalty?(:server_error)
      assert penalty == true
    end
  end

  describe "integration test with ErrorNormalizer" do
    alias Lasso.RPC.ErrorNormalizer

    test "LlamaRPC error gets proper classification and no breaker penalty" do
      error_response = %{
        "error" => %{
          "code" => -32603,
          "message" => "eth_getLogs range is too large, max is 1k blocks"
        }
      }

      jerror =
        ErrorNormalizer.normalize(error_response,
          provider_id: "ethereum_llamarpc",
          transport: :http
        )

      assert jerror.category == :capability_violation
      assert jerror.retriable? == true
      assert jerror.breaker_penalty? == false
      assert jerror.provider_id == "ethereum_llamarpc"
    end

    test "PublicNode error gets proper classification and no breaker penalty" do
      error_response = %{
        "error" => %{
          "code" => -32701,
          "message" =>
            "Please specify an address in your request or, to remove restrictions, order a dedicated full node here: https://www.allnodes.com/eth/host"
        }
      }

      jerror =
        ErrorNormalizer.normalize(error_response,
          provider_id: "ethereum_publicnode",
          transport: :http
        )

      assert jerror.category == :capability_violation
      assert jerror.retriable? == true
      assert jerror.breaker_penalty? == false
      assert jerror.provider_id == "ethereum_publicnode"
    end
  end
end

defmodule Lasso.RPC.ErrorClassificationTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.ErrorClassification
  alias Lasso.RPC.ErrorClassifier

  describe "categorize/2" do
    test "classifies LlamaRPC block range error as capability violation" do
      category =
        ErrorClassification.categorize(-32_603, "eth_getLogs range is too large, max is 1k blocks")

      assert category == :capability_violation
    end

    test "classifies PublicNode address requirement error as capability violation" do
      message =
        "Please specify an address in your request or, to remove restrictions, order a dedicated full node here: https://www.allnodes.com/eth/host"

      category = ErrorClassification.categorize(-32_701, message)
      assert category == :capability_violation
    end

    test "classifies PublicNode error code -32_701 as capability violation even without message" do
      # Provider-specific code requires ErrorClassifier with provider_id
      %{category: category} = ErrorClassifier.classify(-32_701, nil, provider_id: "ethereum_publicnode")
      assert category == :capability_violation
    end

    test "classifies regular internal error as internal error" do
      category = ErrorClassification.categorize(-32_603, "Internal server error")
      assert category == :internal_error
    end

    test "classifies rate limit error correctly" do
      category = ErrorClassification.categorize(429, "Rate limit exceeded")
      assert category == :rate_limit
    end

    test "classifies result size violation as capability violation (provider-specific limit)" do
      category = ErrorClassification.categorize(-32_005, "query returned more than 10000 results")
      assert category == :capability_violation
    end

    test "classifies 'too many results' as capability violation" do
      category = ErrorClassification.categorize(-32_000, "too many results")
      assert category == :capability_violation
    end

    test "classifies 'result set too large' as capability violation" do
      category = ErrorClassification.categorize(-32_000, "result set too large")
      assert category == :capability_violation
    end

    test "classifies 'too many logs' as capability violation" do
      category = ErrorClassification.categorize(-32_000, "too many logs returned")
      assert category == :capability_violation
    end
  end

  describe "retriable?/2" do
    test "capability violations are retriable" do
      retriable =
        ErrorClassification.retriable?(-32_603, "eth_getLogs range is too large, max is 1k blocks")

      assert retriable == true
    end

    test "PublicNode capability violations are retriable" do
      message =
        "Please specify an address in your request or, to remove restrictions, order a dedicated full node here: https://www.allnodes.com/eth/host"

      retriable = ErrorClassification.retriable?(-32_701, message)
      assert retriable == true
    end

    test "PublicNode error code -32_701 is retriable even without message" do
      # Provider-specific code requires ErrorClassifier with provider_id
      %{retriable?: retriable?} = ErrorClassifier.classify(-32_701, nil, provider_id: "ethereum_publicnode")
      assert retriable? == true
    end

    test "rate limits are retriable" do
      retriable = ErrorClassification.retriable?(429, "Rate limit exceeded")
      assert retriable == true
    end

    test "invalid params are not retriable" do
      retriable = ErrorClassification.retriable?(-32_602, "Invalid parameters")
      assert retriable == false
    end

    test "result size violations ARE retriable (provider-specific limits, smart detection prevents exhaustion)" do
      retriable = ErrorClassification.retriable?(-32_005, "query returned more than 10000 results")
      assert retriable == true
    end

    test "'too many results' errors ARE retriable (premium providers may handle)" do
      retriable = ErrorClassification.retriable?(-32_000, "too many results")
      assert retriable == true
    end

    test "'result set too large' errors ARE retriable (provider capabilities vary)" do
      retriable = ErrorClassification.retriable?(-32_000, "result set too large")
      assert retriable == true
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
          "code" => -32_603,
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
          "code" => -32_701,
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

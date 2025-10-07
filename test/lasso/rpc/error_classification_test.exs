defmodule Lasso.RPC.ErrorClassificationTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.ErrorClassification

  describe "categorize/2 message-based classification" do
    test "rate limit patterns take priority" do
      # Rate limit should be detected even with generic error code
      assert :rate_limit = ErrorClassification.categorize(-32000, "rate limit exceeded")
      assert :rate_limit = ErrorClassification.categorize(-32000, "too many requests")
      assert :rate_limit = ErrorClassification.categorize(-32000, "quota exceeded")
    end

    test "auth errors are detected from message" do
      assert :auth_error = ErrorClassification.categorize(-32000, "unauthorized")
      assert :auth_error = ErrorClassification.categorize(-32000, "invalid api key")
      assert :auth_error = ErrorClassification.categorize(-32000, "forbidden")
    end

    test "capability violations are detected from message" do
      # The critical case from your logs
      assert :capability_violation =
               ErrorClassification.categorize(-32000, "Please, specify less number of addresses")

      assert :capability_violation =
               ErrorClassification.categorize(-32000, "block range too large")

      assert :capability_violation =
               ErrorClassification.categorize(-32000, "archive node required")

      assert :capability_violation =
               ErrorClassification.categorize(-32000, "query returned more than 10000 results")
    end

    test "message classification priority: rate_limit > auth > capability" do
      # If message has multiple patterns, highest priority wins
      # This is regression-prone - ensure ordering is correct

      # Rate limit keyword should win even with auth keyword
      assert :rate_limit =
               ErrorClassification.categorize(-32000, "quota exceeded for this API key")
    end

    test "falls back to code-based classification when no message match" do
      assert :invalid_params = ErrorClassification.categorize(-32602, "some message")
      assert :invalid_params = ErrorClassification.categorize(-32602, nil)
    end
  end

  describe "retriable?/2" do
    test "capability violations are retriable (should failover)" do
      assert ErrorClassification.retriable?(-32000, "block range too large")
      assert ErrorClassification.retriable?(-32000, "max addresses exceeded")
    end

    test "rate limits are retriable" do
      assert ErrorClassification.retriable?(-32005, "rate limit")
      assert ErrorClassification.retriable?(429, nil)
    end

    test "client errors are not retriable" do
      refute ErrorClassification.retriable?(-32600, nil)
      refute ErrorClassification.retriable?(-32602, nil)
      refute ErrorClassification.retriable?(-32601, nil)
    end

    test "server errors are retriable" do
      assert ErrorClassification.retriable?(-32603, nil)
      assert ErrorClassification.retriable?(-32000, nil)
    end
  end

  describe "breaker_penalty?/1" do
    test "capability violations do NOT penalize breaker" do
      # This is the key fix - capability violations should failover but not open CB
      refute ErrorClassification.breaker_penalty?(:capability_violation)
    end

    test "all other categories DO penalize breaker" do
      assert ErrorClassification.breaker_penalty?(:rate_limit)
      assert ErrorClassification.breaker_penalty?(:server_error)
      assert ErrorClassification.breaker_penalty?(:network_error)
      assert ErrorClassification.breaker_penalty?(:auth_error)
      assert ErrorClassification.breaker_penalty?(:client_error)
      assert ErrorClassification.breaker_penalty?(:unknown_error)
    end
  end

  describe "code-based classification edge cases" do
    test "JSON-RPC server error range is categorized correctly" do
      assert :server_error = ErrorClassification.categorize(-32099, nil)
      assert :server_error = ErrorClassification.categorize(-32000, nil)
      assert :server_error = ErrorClassification.categorize(-32050, nil)
    end

    test "HTTP status codes map correctly" do
      assert :rate_limit = ErrorClassification.categorize(429, nil)
      assert :server_error = ErrorClassification.categorize(500, nil)
      assert :client_error = ErrorClassification.categorize(400, nil)
    end

    test "EIP-1193 codes map correctly" do
      assert :auth_error = ErrorClassification.categorize(4100, nil)
      assert :network_error = ErrorClassification.categorize(4901, nil)
    end
  end

  describe "integration: full normalize flow" do
    test "capability violation message overrides generic server error code" do
      # Real-world scenario: provider returns -32603 with capability message
      category = ErrorClassification.categorize(-32603, "max block range exceeded")
      retriable? = ErrorClassification.retriable?(-32603, "max block range exceeded")
      penalty? = ErrorClassification.breaker_penalty?(category)

      assert category == :capability_violation
      assert retriable? == true
      assert penalty? == false
    end
  end
end

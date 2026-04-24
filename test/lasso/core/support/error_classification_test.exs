defmodule Lasso.RPC.ErrorClassificationTest do
  use ExUnit.Case, async: true

  alias Lasso.Core.Support.ErrorClassification
  alias Lasso.Core.Support.ErrorClassifier

  describe "categorize/2" do
    test "classifies LlamaRPC block range error as capability violation" do
      category =
        ErrorClassification.categorize(
          -32_603,
          "eth_getLogs range is too large, max is 1k blocks"
        )

      assert category == :capability_violation
    end

    test "classifies PublicNode address requirement error as capability violation" do
      message =
        "Please specify an address in your request or, to remove restrictions, order a dedicated full node here: https://www.allnodes.com/eth/host"

      category = ErrorClassification.categorize(-32_701, message)
      assert category == :capability_violation
    end

    test "classifies PublicNode error code -32_701 as capability violation even without message" do
      %{category: category} =
        ErrorClassifier.classify(-32_701, nil, provider_id: "ethereum_publicnode")

      assert category == :capability_violation
    end

    test "classifies regular internal error as internal error" do
      category = ErrorClassification.categorize(-32_603, "Internal server error")
      assert category == :internal_error
    end

    test "classifies DRPC unsupported subscription code as server_error" do
      category = ErrorClassification.categorize(23, "Unsupported subscription: newHeads")
      assert category == :server_error
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
        ErrorClassification.retriable?(
          -32_603,
          "eth_getLogs range is too large, max is 1k blocks"
        )

      assert retriable == true
    end

    test "PublicNode capability violations are retriable" do
      message =
        "Please specify an address in your request or, to remove restrictions, order a dedicated full node here: https://www.allnodes.com/eth/host"

      retriable = ErrorClassification.retriable?(-32_701, message)
      assert retriable == true
    end

    test "PublicNode error code -32_701 is retriable even without message" do
      %{retriable?: retriable?} =
        ErrorClassifier.classify(-32_701, nil, provider_id: "ethereum_publicnode")

      assert retriable? == true
    end

    test "rate limits are retriable" do
      retriable = ErrorClassification.retriable?(429, "Rate limit exceeded")
      assert retriable == true
    end

    test "DRPC unsupported subscription code is retriable" do
      retriable = ErrorClassification.retriable?(23, "Unsupported subscription: newHeads")
      assert retriable == true
    end

    test "invalid params are not retriable" do
      retriable = ErrorClassification.retriable?(-32_602, "Invalid parameters")
      assert retriable == false
    end

    test "result size violations ARE retriable (provider-specific limits, smart detection prevents exhaustion)" do
      retriable =
        ErrorClassification.retriable?(-32_005, "query returned more than 10000 results")

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
      assert ErrorClassification.breaker_penalty?(:capability_violation) == false
    end

    test "rate limits do not penalize circuit breaker" do
      assert ErrorClassification.breaker_penalty?(:rate_limit) == false
    end

    test "server errors do penalize circuit breaker" do
      assert ErrorClassification.breaker_penalty?(:server_error) == true
    end

    test "unclassified_server_error does not penalize circuit breaker" do
      assert ErrorClassification.breaker_penalty?(:unclassified_server_error) == false
    end
  end

  describe "execution_revert classification" do
    test "intrinsic gas too low is non-retriable execution_revert" do
      category = ErrorClassification.categorize(-32_000, "intrinsic gas too low")
      assert category == :execution_revert
      assert ErrorClassification.retriable?(-32_000, "intrinsic gas too low") == false
      assert ErrorClassification.breaker_penalty?(:execution_revert) == false
    end

    test "Lava variant: gas limit below intrinsic gas" do
      category = ErrorClassification.categorize(-32_000, "gas limit below intrinsic gas")
      assert category == :execution_revert
      assert ErrorClassification.retriable?(-32_000, "gas limit below intrinsic gas") == false
    end

    test "verbose intrinsic gas message from geth" do
      msg = "err: intrinsic gas too low: have 1, want 21000 (supplied gas 1)"
      assert ErrorClassification.categorize(-32_000, msg) == :execution_revert
      assert ErrorClassification.retriable?(-32_000, msg) == false
    end

    test "execution reverted is non-retriable" do
      assert ErrorClassification.categorize(3, "execution reverted") == :execution_revert
      assert ErrorClassification.retriable?(3, "execution reverted") == false
    end

    test "EVM code 3 without message is execution_revert" do
      assert ErrorClassification.categorize(3, nil) == :execution_revert
      assert ErrorClassification.retriable?(3, nil) == false
    end

    test "out of gas is execution_revert" do
      assert ErrorClassification.categorize(-32_000, "out of gas") == :execution_revert
      assert ErrorClassification.retriable?(-32_000, "out of gas") == false
    end

    test "nonce too low is execution_revert" do
      assert ErrorClassification.categorize(-32_000, "nonce too low") == :execution_revert
      assert ErrorClassification.retriable?(-32_000, "nonce too low") == false
    end

    test "insufficient funds is execution_revert" do
      assert ErrorClassification.categorize(-32_000, "insufficient funds for transfer") ==
               :execution_revert

      assert ErrorClassification.retriable?(-32_000, "insufficient funds for transfer") == false
    end
  end

  describe "invalid_params classification" do
    test "invalid argument is non-retriable invalid_params" do
      msg =
        "invalid argument 0: json: cannot unmarshal hex string of odd length into Go value of type common.Address"

      assert ErrorClassification.categorize(-32_000, msg) == :invalid_params
      assert ErrorClassification.retriable?(-32_000, msg) == false
      assert ErrorClassification.breaker_penalty?(:invalid_params) == false
    end

    test "cannot unmarshal is invalid_params" do
      msg = "cannot unmarshal string into value"
      assert ErrorClassification.categorize(-32_000, msg) == :invalid_params
      assert ErrorClassification.retriable?(-32_000, msg) == false
    end

    test "invalid hex is invalid_params" do
      assert ErrorClassification.categorize(-32_000, "invalid hex string") == :invalid_params
    end

    test "wrong number of arguments is invalid_params" do
      assert ErrorClassification.categorize(-32_000, "wrong number of arguments") ==
               :invalid_params
    end
  end

  describe "standard JSON-RPC code priority" do
    test "-32601 classifies as method_not_found even with 'not available' in message" do
      msg = "The method eth_fooBarBaz does not exist/is not available"
      assert ErrorClassification.categorize(-32_601, msg) == :method_not_found
      assert ErrorClassification.retriable?(-32_601, msg) == false
    end

    test "-32601 with 'not supported' message still classifies as method_not_found" do
      assert ErrorClassification.categorize(-32_601, "method not supported") == :method_not_found
    end

    test "-32600 with misleading message still classifies as invalid_request" do
      assert ErrorClassification.categorize(-32_600, "not available") == :invalid_request
    end

    test "-32700 with misleading message still classifies as parse_error" do
      assert ErrorClassification.categorize(-32_700, "rate limit") == :parse_error
    end

    test "-32602 allows message override (OnFinality uses for block-not-found)" do
      assert ErrorClassification.categorize(-32_602, "Unknown block number") ==
               :block_not_available
    end

    test "-32603 still allows message override (providers reuse for capability violations)" do
      assert ErrorClassification.categorize(-32_603, "range is too large") ==
               :capability_violation
    end

    test "categorize_with_path returns :code_based for unambiguous standard codes" do
      {category, path} =
        ErrorClassification.categorize_with_path(-32_601, "method not available")

      assert category == :method_not_found
      assert path == :code_based
    end
  end

  # Phase 1: Unclassified server error tests
  describe "unclassified_server_error (-32000 inversion)" do
    test "unmatched -32000 message returns :unclassified_server_error" do
      assert ErrorClassification.categorize(-32_000, "some unknown provider message") ==
               :unclassified_server_error
    end

    test "unmatched -32000 is non-retriable" do
      assert ErrorClassification.retriable?(-32_000, "some unknown provider message") == false
    end

    test "-32000 without message returns :unclassified_server_error" do
      assert ErrorClassification.categorize(-32_000, nil) == :unclassified_server_error
    end

    test "-32001 through -32099 still return :server_error (retriable)" do
      assert ErrorClassification.categorize(-32_001, nil) == :server_error
      assert ErrorClassification.categorize(-32_050, nil) == :server_error
      assert ErrorClassification.categorize(-32_099, nil) == :server_error

      assert ErrorClassification.retriable?(-32_001, nil) == true
      assert ErrorClassification.retriable?(-32_050, nil) == true
    end

    test "transient patterns under -32000 still classify as :server_error" do
      assert ErrorClassification.categorize(-32_000, "please retry") == :server_error
      assert ErrorClassification.categorize(-32_000, "try again later") == :server_error

      assert ErrorClassification.categorize(-32_000, "service temporarily unavailable") ==
               :server_error

      assert ErrorClassification.categorize(-32_000, "request timeout") == :server_error
      assert ErrorClassification.categorize(-32_000, "backend timeout") == :server_error
      assert ErrorClassification.categorize(-32_000, "resource unavailable") == :server_error
      assert ErrorClassification.categorize(-32_000, "service overloaded") == :server_error
    end

    test "transient patterns under -32000 are retriable" do
      assert ErrorClassification.retriable?(-32_000, "please retry") == true
      assert ErrorClassification.retriable?(-32_000, "request timeout") == true
    end

    test "unclassified_server_error is non-retriable for category" do
      assert ErrorClassification.retriable_for_category?(:unclassified_server_error) == false
    end

    test "unclassified_server_error does not penalize provider health" do
      assert ErrorClassification.provider_health_failure?(:unclassified_server_error) == false
    end

    test "message matching BOTH transient and execution_revert patterns: transient wins" do
      # transient_error_patterns is checked before execution_revert_patterns in cond
      msg = "execution reverted, please retry"
      # "please retry" matches transient → :server_error
      assert ErrorClassification.categorize(-32_000, msg) == :server_error
    end
  end

  # Phase 2: Data field revert detection tests
  describe "categorize/3 (data field detection)" do
    test "Error(string) selector under -32000 returns :execution_revert" do
      data = "0x08c379a0" <> String.duplicate("00", 64)
      assert ErrorClassification.categorize(-32_000, "server error", data) == :execution_revert
    end

    test "Panic(uint256) selector under -32000 returns :execution_revert" do
      data = "0x4e487b71" <> String.duplicate("00", 32)
      assert ErrorClassification.categorize(-32_000, "server error", data) == :execution_revert
    end

    test "mixed case selector is detected" do
      data = "0x08C379A0" <> String.duplicate("00", 64)
      assert ErrorClassification.categorize(-32_000, "server error", data) == :execution_revert
    end

    test "wrapped data map is detected" do
      inner = "0x08c379a0" <> String.duplicate("00", 64)

      assert ErrorClassification.categorize(-32_000, "server error", %{"data" => inner}) ==
               :execution_revert
    end

    test "data wins over conflicting message" do
      data = "0x08c379a0" <> String.duplicate("00", 64)
      # "rate limit" would normally classify as :rate_limit
      assert ErrorClassification.categorize(-32_000, "rate limit exceeded", data) ==
               :execution_revert
    end

    test "nil data falls through to 2-arg behavior" do
      assert ErrorClassification.categorize(-32_000, "out of gas", nil) == :execution_revert
    end

    test "empty string data falls through to 2-arg behavior" do
      assert ErrorClassification.categorize(-32_000, "out of gas", "") == :execution_revert
    end

    test "short data (< 10 bytes) falls through" do
      assert ErrorClassification.categorize(-32_000, "out of gas", "0x08c3") == :execution_revert
    end

    test "non-revert data falls through to message classification" do
      assert ErrorClassification.categorize(-32_000, "rate limit", "0xdeadbeef00") == :rate_limit
    end

    test "large data binary only downcases prefix" do
      # 10KB of data — should not downcase the whole thing
      data = "0x08c379a0" <> String.duplicate("AB", 5000)
      assert ErrorClassification.categorize(-32_000, "server error", data) == :execution_revert
    end
  end

  describe "retriable?/3 (data field detection)" do
    test "revert data makes error non-retriable" do
      data = "0x08c379a0" <> String.duplicate("00", 64)
      assert ErrorClassification.retriable?(-32_000, "server error", data) == false
    end

    test "non-revert data falls through" do
      data = "0xdeadbeef00"
      assert ErrorClassification.retriable?(-32_000, "rate limit", data) == true
    end

    test "nil data falls through" do
      assert ErrorClassification.retriable?(-32_000, "rate limit", nil) == true
    end
  end

  # Phase 4: Client-specific codes
  describe "client-specific error codes" do
    test "-32010 is execution_revert" do
      assert ErrorClassification.categorize(-32_010, nil) == :execution_revert
      assert ErrorClassification.retriable?(-32_010, nil) == false
    end

    test "-32015 (Nethermind) is execution_revert" do
      assert ErrorClassification.categorize(-32_015, nil) == :execution_revert
      assert ErrorClassification.retriable?(-32_015, nil) == false
    end

    test "-32016 (Besu) is execution_revert" do
      assert ErrorClassification.categorize(-32_016, nil) == :execution_revert
      assert ErrorClassification.retriable?(-32_016, nil) == false
    end

    test "upfront cost exceeds is execution_revert" do
      assert ErrorClassification.categorize(-32_000, "upfront cost exceeds account balance") ==
               :execution_revert
    end

    test "nonce mismatch is execution_revert" do
      assert ErrorClassification.categorize(
               -32_000,
               "does not match sender account nonce"
             ) == :execution_revert
    end

    test "transaction type not supported is execution_revert" do
      assert ErrorClassification.categorize(-32_000, "transaction type not supported") ==
               :execution_revert
    end
  end

  # Phase 5: categorize_with_path
  describe "categorize_with_path/3" do
    test "message pattern returns :message_pattern path" do
      {category, path} = ErrorClassification.categorize_with_path(-32_000, "rate limit exceeded")
      assert category == :rate_limit
      assert path == :message_pattern
    end

    test "code-based returns :code_based path" do
      {category, path} = ErrorClassification.categorize_with_path(-32_602, nil)
      assert category == :invalid_params
      assert path == :code_based
    end

    test "data selector returns :data_selector path" do
      data = "0x08c379a0" <> String.duplicate("00", 64)
      {category, path} = ErrorClassification.categorize_with_path(-32_000, "server error", data)
      assert category == :execution_revert
      assert path == :data_selector
    end

    test "nil data falls through to message/code" do
      {category, path} = ErrorClassification.categorize_with_path(-32_000, "out of gas", nil)
      assert category == :execution_revert
      assert path == :message_pattern
    end

    test "unmatched -32000 returns :unclassified_server_error with :code_based" do
      {category, path} = ErrorClassification.categorize_with_path(-32_000, "something unknown")
      assert category == :unclassified_server_error
      assert path == :code_based
    end
  end

  describe "integration test with ErrorNormalizer" do
    alias Lasso.Core.Support.ErrorNormalizer

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

defmodule Lasso.RPC.Providers.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.Providers.Capabilities

  describe "default_capabilities/0" do
    test "blocks only local_only by default" do
      caps = Capabilities.default_capabilities()
      assert caps.unsupported_categories == [:local_only]
      assert caps.unsupported_methods == []
      assert caps.error_rules == []
      assert caps.limits == %{}
    end
  end

  describe "supports_method?/2" do
    test "nil capabilities uses permissive defaults" do
      assert Capabilities.supports_method?("eth_blockNumber", nil) == :ok
      assert Capabilities.supports_method?("eth_call", nil) == :ok
    end

    test "blocks local_only methods by default" do
      assert {:error, :method_unsupported} =
               Capabilities.supports_method?("eth_accounts", nil)
    end

    test "blocks methods in unsupported_categories" do
      caps = %{unsupported_categories: [:debug, :trace, :local_only]}

      assert {:error, :method_unsupported} =
               Capabilities.supports_method?("debug_traceTransaction", caps)

      assert {:error, :method_unsupported} =
               Capabilities.supports_method?("trace_block", caps)

      assert Capabilities.supports_method?("eth_blockNumber", caps) == :ok
    end

    test "blocks methods in unsupported_methods list" do
      caps = %{
        unsupported_methods: ["eth_getLogs", "eth_newFilter"],
        unsupported_categories: [:local_only]
      }

      assert {:error, :method_unsupported} =
               Capabilities.supports_method?("eth_getLogs", caps)

      assert {:error, :method_unsupported} =
               Capabilities.supports_method?("eth_newFilter", caps)

      assert Capabilities.supports_method?("eth_call", caps) == :ok
    end

    test "allows unknown methods through (fail-open)" do
      caps = %{unsupported_categories: [:local_only], unsupported_methods: []}
      assert Capabilities.supports_method?("some_custom_method", caps) == :ok
    end

    test "rejects debug/trace methods for providers that block them" do
      caps = %{
        unsupported_categories: [:debug, :trace, :filters, :txpool, :mempool, :local_only]
      }

      assert {:error, :method_unsupported} =
               Capabilities.supports_method?("debug_traceCall", caps)

      assert {:error, :method_unsupported} =
               Capabilities.supports_method?("trace_transaction", caps)

      assert Capabilities.supports_method?("eth_blockNumber", caps) == :ok
      assert Capabilities.supports_method?("eth_getBalance", caps) == :ok
      assert Capabilities.supports_method?("eth_call", caps) == :ok
      assert Capabilities.supports_method?("net_version", caps) == :ok
    end
  end

  describe "validate_params/4 - block range" do
    test "nil capabilities always passes" do
      assert :ok = Capabilities.validate_params("eth_getLogs", [%{}], nil, %{})
    end

    test "validates block range for eth_getLogs" do
      caps = %{limits: %{max_block_range: 1000}}
      ctx = %{chain: "ethereum"}

      params = [%{"fromBlock" => "0x1", "toBlock" => "0x3E9"}]
      assert :ok = Capabilities.validate_params("eth_getLogs", params, caps, ctx)

      params = [%{"fromBlock" => "0x1", "toBlock" => "0x3EB"}]

      assert {:error, {:param_limit, msg}} =
               Capabilities.validate_params("eth_getLogs", params, caps, ctx)

      assert msg =~ "max 1000 block range"
    end

    test "uses custom block range from capabilities" do
      caps = %{limits: %{max_block_range: 500}}
      ctx = %{chain: "ethereum"}

      params = [%{"fromBlock" => "0x1", "toBlock" => "0x1F5"}]
      assert :ok = Capabilities.validate_params("eth_getLogs", params, caps, ctx)

      params = [%{"fromBlock" => "0x1", "toBlock" => "0x1F6"}]

      assert {:error, {:param_limit, msg}} =
               Capabilities.validate_params("eth_getLogs", params, caps, ctx)

      assert msg =~ "max 500 block range"
    end

    test "skips validation for non-getLogs methods" do
      caps = %{limits: %{max_block_range: 10}}
      ctx = %{chain: "ethereum"}

      assert :ok =
               Capabilities.validate_params("eth_call", [%{}, "latest"], caps, ctx)
    end

    test "no limits means no validation" do
      caps = %{limits: %{}}
      ctx = %{chain: "ethereum"}

      params = [%{"fromBlock" => "0x1", "toBlock" => "0xFFFFFF"}]
      assert :ok = Capabilities.validate_params("eth_getLogs", params, caps, ctx)
    end
  end

  describe "classify_error/3" do
    test "nil capabilities returns :default" do
      assert :default = Capabilities.classify_error(-32000, "some error", nil)
    end

    test "no error_rules returns :default" do
      caps = %{error_rules: []}
      assert :default = Capabilities.classify_error(-32000, "some error", caps)
    end

    test "matches by code" do
      caps = %{error_rules: [%{code: 35, category: :capability_violation}]}

      assert {:ok, :capability_violation} = Capabilities.classify_error(35, nil, caps)
      assert :default = Capabilities.classify_error(36, nil, caps)
    end

    test "matches by message_contains (string)" do
      caps = %{
        error_rules: [
          %{message_contains: "timeout on the free tier", category: :rate_limit}
        ]
      }

      assert {:ok, :rate_limit} =
               Capabilities.classify_error(30, "Timeout on the Free Tier", caps)

      assert :default = Capabilities.classify_error(30, "other error", caps)
    end

    test "matches by message_contains (array)" do
      caps = %{
        error_rules: [
          %{message_contains: ["compute units", "credits quota"], category: :rate_limit}
        ]
      }

      assert {:ok, :rate_limit} =
               Capabilities.classify_error(-32000, "Compute Units exceeded", caps)

      assert {:ok, :rate_limit} =
               Capabilities.classify_error(-32000, "Credits quota reached", caps)
    end

    test "matches code + message together" do
      caps = %{
        error_rules: [
          %{code: 30, message_contains: "timeout on the free tier", category: :rate_limit},
          %{code: 30, category: :rate_limit}
        ]
      }

      assert {:ok, :rate_limit} =
               Capabilities.classify_error(30, "timeout on the free tier", caps)

      assert {:ok, :rate_limit} = Capabilities.classify_error(30, nil, caps)
      assert {:ok, :rate_limit} = Capabilities.classify_error(30, "other error", caps)
    end

    test "first match wins" do
      caps = %{
        error_rules: [
          %{code: 30, message_contains: "timeout", category: :rate_limit},
          %{code: 30, category: :capability_violation}
        ]
      }

      assert {:ok, :rate_limit} = Capabilities.classify_error(30, "timeout", caps)
      assert {:ok, :capability_violation} = Capabilities.classify_error(30, "other", caps)
    end

    test "nil message doesn't match message_contains rule" do
      caps = %{
        error_rules: [
          %{message_contains: "timeout", category: :rate_limit},
          %{code: 30, category: :capability_violation}
        ]
      }

      assert {:ok, :capability_violation} = Capabilities.classify_error(30, nil, caps)
    end
  end

  describe "validate!/2" do
    test "nil capabilities passes" do
      assert :ok = Capabilities.validate!("test_provider", nil)
    end

    test "valid capabilities passes" do
      caps = %{
        unsupported_categories: [:debug, :trace],
        error_rules: [
          %{code: 35, category: :capability_violation},
          %{message_contains: "timeout", category: :rate_limit}
        ],
        limits: %{max_block_range: 1000}
      }

      assert :ok = Capabilities.validate!("test_provider", caps)
    end

    test "raises on invalid unsupported_category" do
      caps = %{unsupported_categories: [:nonexistent_category]}

      assert_raise RuntimeError, ~r/not a valid method category/, fn ->
        Capabilities.validate!("test_provider", caps)
      end
    end

    test "raises on error rule without code or message_contains" do
      caps = %{error_rules: [%{category: :rate_limit}]}

      assert_raise RuntimeError, ~r/must have at least one/, fn ->
        Capabilities.validate!("test_provider", caps)
      end
    end

    test "raises on error rule without category" do
      caps = %{error_rules: [%{code: 30}]}

      assert_raise RuntimeError, ~r/must have exactly one :category/, fn ->
        Capabilities.validate!("test_provider", caps)
      end
    end

    test "raises on invalid error rule category" do
      caps = %{error_rules: [%{code: 30, category: :bogus_category}]}

      assert_raise RuntimeError, ~r/not a valid category/, fn ->
        Capabilities.validate!("test_provider", caps)
      end
    end

    test "raises on negative block range limit" do
      caps = %{limits: %{max_block_range: -1}}

      assert_raise RuntimeError, ~r/must be a non-negative integer/, fn ->
        Capabilities.validate!("test_provider", caps)
      end
    end

    test "accepts null limits" do
      caps = %{limits: %{max_block_range: nil, max_block_age: nil}}
      assert :ok = Capabilities.validate!("test_provider", caps)
    end

    test "raises on non-string message_contains" do
      caps = %{error_rules: [%{message_contains: 42, category: :rate_limit}]}

      assert_raise RuntimeError, ~r/must be a string or list of strings/, fn ->
        Capabilities.validate!("test_provider", caps)
      end
    end

    test "raises on message_contains list with non-strings" do
      caps = %{error_rules: [%{message_contains: ["valid", 42], category: :rate_limit}]}

      assert_raise RuntimeError, ~r/list must contain only strings/, fn ->
        Capabilities.validate!("test_provider", caps)
      end
    end

    test "accepts message_contains as list of strings" do
      caps = %{
        error_rules: [
          %{message_contains: ["timeout", "pruned"], category: :rate_limit}
        ]
      }

      assert :ok = Capabilities.validate!("test_provider", caps)
    end

    test "raises on non-list block_age_methods" do
      caps = %{limits: %{max_block_age: 1000, block_age_methods: "eth_call"}}

      assert_raise RuntimeError, ~r/must be a list of strings/, fn ->
        Capabilities.validate!("test_provider", caps)
      end
    end

    test "accepts valid block_age_methods" do
      caps = %{
        limits: %{
          max_block_age: 1000,
          block_age_methods: ["eth_call", "eth_getBalance"]
        }
      }

      assert :ok = Capabilities.validate!("test_provider", caps)
    end
  end

  describe "supports_method?/2 - PublicNode-like capabilities" do
    test "blocks filter methods when :filters in unsupported_categories" do
      caps = %{unsupported_categories: [:debug, :trace, :txpool, :eip4844, :filters, :local_only]}

      assert {:error, :method_unsupported} =
               Capabilities.supports_method?("eth_getLogs", caps)

      assert {:error, :method_unsupported} =
               Capabilities.supports_method?("eth_newFilter", caps)

      assert {:error, :method_unsupported} =
               Capabilities.supports_method?("eth_getFilterChanges", caps)

      assert {:error, :method_unsupported} =
               Capabilities.supports_method?("eth_getFilterLogs", caps)

      assert {:error, :method_unsupported} =
               Capabilities.supports_method?("eth_uninstallFilter", caps)

      assert :ok = Capabilities.supports_method?("eth_call", caps)
      assert :ok = Capabilities.supports_method?("eth_getBalance", caps)
      assert :ok = Capabilities.supports_method?("eth_blockNumber", caps)
    end
  end
end

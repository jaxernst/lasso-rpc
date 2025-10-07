defmodule Lasso.RPC.Providers.Adapters.CloudflareTest do
  use ExUnit.Case, async: true

  alias Lasso.RPC.Providers.Adapters.Cloudflare

  describe "supports_method?/3 - unsupported methods" do
    test "rejects eth_getLogs" do
      assert Cloudflare.supports_method?("eth_getLogs", :http, %{}) == {:error, :method_unsupported}
    end

    test "rejects eth_getFilterLogs" do
      assert Cloudflare.supports_method?("eth_getFilterLogs", :http, %{}) ==
               {:error, :method_unsupported}
    end

    test "rejects eth_newFilter" do
      assert Cloudflare.supports_method?("eth_newFilter", :http, %{}) ==
               {:error, :method_unsupported}
    end

    test "rejects eth_newBlockFilter" do
      assert Cloudflare.supports_method?("eth_newBlockFilter", :http, %{}) ==
               {:error, :method_unsupported}
    end

    test "rejects eth_getFilterChanges" do
      assert Cloudflare.supports_method?("eth_getFilterChanges", :http, %{}) ==
               {:error, :method_unsupported}
    end

    test "rejects eth_uninstallFilter" do
      assert Cloudflare.supports_method?("eth_uninstallFilter", :http, %{}) ==
               {:error, :method_unsupported}
    end

    test "rejects debug_* methods" do
      assert Cloudflare.supports_method?("debug_traceTransaction", :http, %{}) ==
               {:error, :method_unsupported}

      assert Cloudflare.supports_method?("debug_traceCall", :http, %{}) ==
               {:error, :method_unsupported}
    end

    test "rejects trace_* methods" do
      assert Cloudflare.supports_method?("trace_transaction", :http, %{}) ==
               {:error, :method_unsupported}

      assert Cloudflare.supports_method?("trace_block", :http, %{}) ==
               {:error, :method_unsupported}
    end
  end

  describe "supports_method?/3 - supported methods" do
    test "supports eth_blockNumber" do
      assert Cloudflare.supports_method?("eth_blockNumber", :http, %{}) == :skip_params
    end

    test "supports eth_getBlockByNumber" do
      assert Cloudflare.supports_method?("eth_getBlockByNumber", :http, %{}) == :skip_params
    end

    test "supports eth_call" do
      assert Cloudflare.supports_method?("eth_call", :http, %{}) == :skip_params
    end

    test "supports eth_estimateGas" do
      assert Cloudflare.supports_method?("eth_estimateGas", :http, %{}) == :skip_params
    end

    test "supports eth_getTransactionReceipt" do
      assert Cloudflare.supports_method?("eth_getTransactionReceipt", :http, %{}) ==
               :skip_params
    end

    test "supports eth_getBalance" do
      assert Cloudflare.supports_method?("eth_getBalance", :http, %{}) == :skip_params
    end

    test "supports eth_chainId" do
      assert Cloudflare.supports_method?("eth_chainId", :http, %{}) == :skip_params
    end

    test "supports net_version" do
      assert Cloudflare.supports_method?("net_version", :http, %{}) == :skip_params
    end
  end

  describe "supports_method?/3 - transport independence" do
    test "method support is transport-independent" do
      # Unsupported method rejected on both transports
      assert Cloudflare.supports_method?("eth_getLogs", :http, %{}) ==
               {:error, :method_unsupported}

      assert Cloudflare.supports_method?("eth_getLogs", :ws, %{}) ==
               {:error, :method_unsupported}

      # Supported method works on both transports
      assert Cloudflare.supports_method?("eth_blockNumber", :http, %{}) == :skip_params
      assert Cloudflare.supports_method?("eth_blockNumber", :ws, %{}) == :skip_params
    end
  end

  describe "validate_params/4" do
    test "returns :ok for any method and params" do
      # Cloudflare has no parameter-level restrictions
      assert Cloudflare.validate_params("eth_call", [%{}, "latest"], :http, %{}) == :ok
      assert Cloudflare.validate_params("eth_getLogs", [%{}], :http, %{}) == :ok
      assert Cloudflare.validate_params("debug_trace", [], :http, %{}) == :ok
    end
  end

  describe "metadata/0" do
    test "returns provider metadata" do
      metadata = Cloudflare.metadata()

      assert metadata.type == :public
      assert metadata.tier == :free
      assert is_binary(metadata.documentation)
      assert is_list(metadata.known_limitations)
      assert length(metadata.known_limitations) > 0
      assert %Date{} = metadata.last_verified
    end

    test "documents known limitations" do
      metadata = Cloudflare.metadata()

      limitations = metadata.known_limitations

      assert Enum.any?(limitations, &String.contains?(&1, "eth_getLogs"))
      assert Enum.any?(limitations, &String.contains?(&1, "filter"))
      assert Enum.any?(limitations, &String.contains?(&1, "debug"))
    end
  end

  describe "normalization delegation to Generic" do
    test "normalize_request delegates to Generic" do
      request = %{"jsonrpc" => "2.0", "method" => "eth_blockNumber", "id" => 1}
      ctx = %{provider_id: "ethereum_cloudflare"}

      # Should not crash - delegates to Generic
      result = Cloudflare.normalize_request(request, ctx)
      assert is_map(result)
    end

    test "headers delegates to Generic" do
      ctx = %{provider_id: "ethereum_cloudflare"}

      # Generic returns empty list
      assert Cloudflare.headers(ctx) == []
    end
  end

  describe "behavior correctness" do
    test "Cloudflare implements ProviderAdapter behaviour" do
      # Verify the module implements the behaviour
      behaviours = Cloudflare.module_info(:attributes)[:behaviour] || []
      assert Lasso.RPC.ProviderAdapter in behaviours
    end

    test "all required callbacks are implemented" do
      # These should not raise
      assert function_exported?(Cloudflare, :supports_method?, 3)
      assert function_exported?(Cloudflare, :validate_params, 4)
      assert function_exported?(Cloudflare, :normalize_request, 2)
      assert function_exported?(Cloudflare, :normalize_response, 2)
      assert function_exported?(Cloudflare, :normalize_error, 2)
      assert function_exported?(Cloudflare, :headers, 1)
      assert function_exported?(Cloudflare, :metadata, 0)
    end
  end
end

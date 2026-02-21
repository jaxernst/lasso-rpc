defmodule Lasso.RPC.RequestPipeline.FailoverStrategyTest do
  use ExUnit.Case, async: true

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.{Channel, RequestContext}
  alias Lasso.RPC.RequestPipeline.FailoverStrategy

  defp make_channel(provider_id \\ "test-provider") do
    %Channel{
      profile: "default",
      chain: "ethereum",
      provider_id: provider_id,
      transport: :http,
      raw_channel: nil,
      transport_module: nil,
      capabilities: nil
    }
  end

  defp make_ctx(opts \\ []) do
    ctx = RequestContext.new("ethereum", "eth_call", [])
    error_categories = Keyword.get(opts, :error_categories, %{})
    %{ctx | repeated_error_categories: error_categories}
  end

  describe "client_error failover" do
    test "failovers once when channels remain and no prior client errors" do
      error = JError.new(-32_000, "Bad Request", category: :client_error, retriable?: false)
      channels = [make_channel("provider-b")]
      ctx = make_ctx()

      assert {:failover, :client_error_failover} = FailoverStrategy.decide(error, channels, ctx)
    end

    test "treats as terminal after threshold reached" do
      error = JError.new(-32_000, "Bad Request", category: :client_error, retriable?: false)
      channels = [make_channel("provider-b")]
      ctx = make_ctx(error_categories: %{client_error: 1})

      assert {:terminal_error, :repeated_client_error} =
               FailoverStrategy.decide(error, channels, ctx)
    end

    test "no channels remaining wins over client_error failover" do
      error = JError.new(-32_000, "Bad Request", category: :client_error, retriable?: false)
      ctx = make_ctx()

      assert {:terminal_error, :no_channels_remaining} = FailoverStrategy.decide(error, [], ctx)
    end
  end

  describe "non-retriable errors" do
    test "invalid_params is terminal" do
      error = JError.new(-32_602, "Invalid params", category: :invalid_params, retriable?: false)
      channels = [make_channel()]
      ctx = make_ctx()

      assert {:terminal_error, :non_retriable_error} =
               FailoverStrategy.decide(error, channels, ctx)
    end

    test "parse_error is terminal" do
      error = JError.new(-32_700, "Parse error", category: :parse_error, retriable?: false)
      channels = [make_channel()]
      ctx = make_ctx()

      assert {:terminal_error, :non_retriable_error} =
               FailoverStrategy.decide(error, channels, ctx)
    end
  end

  describe "capability_violation tracking is independent of client_error" do
    test "capability violation with client_error count does not affect its own threshold" do
      error =
        JError.new(-32_701, "Max results exceeded",
          category: :capability_violation,
          retriable?: true
        )

      channels = [make_channel()]
      ctx = make_ctx(error_categories: %{client_error: 5})

      assert {:failover, :capability_violation_detected} =
               FailoverStrategy.decide(error, channels, ctx)
    end
  end

  describe "method_not_found failover threshold" do
    test "failovers before threshold is reached" do
      error =
        JError.new(-32_601, "method does not exist",
          category: :method_not_found,
          retriable?: true
        )

      channels = [make_channel("provider-b")]
      ctx = make_ctx(error_categories: %{method_not_found: 1})

      assert {:failover, :method_not_found_detected} =
               FailoverStrategy.decide(error, channels, ctx)
    end

    test "becomes terminal after repeated method_not_found errors" do
      error =
        JError.new(-32_601, "method does not exist",
          category: :method_not_found,
          retriable?: true
        )

      channels = [make_channel("provider-b")]
      ctx = make_ctx(error_categories: %{method_not_found: 2})

      assert {:terminal_error, :universal_method_not_found} =
               FailoverStrategy.decide(error, channels, ctx)
    end
  end

  describe "retriable categories still failover (regression)" do
    test "rate_limit → failover" do
      error = JError.new(-32_005, "Rate limited", category: :rate_limit, retriable?: true)
      channels = [make_channel()]
      ctx = make_ctx()

      assert {:failover, :rate_limit_detected} = FailoverStrategy.decide(error, channels, ctx)
    end

    test "server_error → failover" do
      error = JError.new(-32_000, "Internal error", category: :server_error, retriable?: true)
      channels = [make_channel()]
      ctx = make_ctx()

      assert {:failover, :server_error_detected} = FailoverStrategy.decide(error, channels, ctx)
    end

    test "network_error → failover" do
      error =
        JError.new(-32_004, "Connection failed", category: :network_error, retriable?: true)

      channels = [make_channel()]
      ctx = make_ctx()

      assert {:failover, :network_error_detected} = FailoverStrategy.decide(error, channels, ctx)
    end

    test "timeout → failover" do
      error = JError.new(-32_000, "Request timeout", category: :timeout, retriable?: true)
      channels = [make_channel()]
      ctx = make_ctx()

      assert {:failover, :timeout_detected} = FailoverStrategy.decide(error, channels, ctx)
    end

    test "circuit_open → failover" do
      channels = [make_channel()]
      ctx = make_ctx()

      assert {:failover, :circuit_open} = FailoverStrategy.decide(:circuit_open, channels, ctx)
    end
  end
end

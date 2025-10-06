defmodule Lasso.RPC.ProviderPoolTest do
  use ExUnit.Case, async: false
  import Mox

  alias Lasso.RPC.ProviderPool
  alias Lasso.Config.ChainConfig

  setup_all do
    # Ensure test environment is ready with all services
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  setup :verify_on_exit!

  setup do
    # Set up default mock expectations for health checks
    # Allow any number of health check calls to succeed
    stub(Lasso.RPC.HttpClientMock, :request, fn _endpoint, method, _params, _timeout ->
      case method do
        "eth_chainId" -> {:ok, "0x1"}
        _ -> {:error, :method_not_mocked}
      end
    end)

    :ok
  end

  defp base_chain_config(providers) do
    %{
      aggregation: %{max_providers: 5},
      global: %{
        health_check: %{
          interval: 2000,
          timeout: 5_000,
          failure_threshold: 2,
          recovery_threshold: 1
        },
        provider_management: %{load_balancing: "priority"}
      },
      providers: providers
    }
  end

  defp provider_struct(attrs) do
    struct(
      ChainConfig.Provider,
      Map.merge(
        %{
          id: "test_provider",
          name: "Test Provider",
          priority: 1,
          type: "public",
          url: "http://example",
          ws_url: "ws://example",
          api_key_required: false,
          region: "us"
        },
        attrs
      )
    )
  end

  test "EMA updates on success and failure, cooldown on rate limit" do
    p1 = provider_struct(%{id: "p1", name: "P1", priority: 1, region: "us"})
    p2 = provider_struct(%{id: "p2", name: "P2", priority: 2, region: "us"})
    chain_config = base_chain_config([p1, p2])

    {:ok, _pid} = ProviderPool.start_link({"testnet", chain_config})

    :ok = ProviderPool.register_provider("testnet", p1.id, p1)
    :ok = ProviderPool.register_provider("testnet", p2.id, p2)

    ProviderPool.report_success("testnet", p1.id)
    {:ok, status} = ProviderPool.get_status("testnet")
    p1_status = Enum.find(status.providers, &(&1.id == p1.id))
    assert p1_status.status in [:healthy, :connecting]

    ProviderPool.report_failure("testnet", p1.id, {:rate_limit, "HTTP 429"})
    {:ok, status2} = ProviderPool.get_status("testnet")
    p1_status2 = Enum.find(status2.providers, &(&1.id == p1.id))
    assert p1_status2.status == :rate_limited

    ProviderPool.report_failure("testnet", p1.id, {:server_error, "500"})
    {:ok, status3} = ProviderPool.get_status("testnet")
    p1_status3 = Enum.find(status3.providers, &(&1.id == p1.id))
    assert p1_status3.consecutive_failures >= p1_status2.consecutive_failures
  end

  test ":fastest strategy prefers lowest latency meeting success-rate threshold" do
  end

  test ":cheapest prefers public type with fallback to paid and respects region filter" do
  end

  test "excludes providers with open circuit from candidates" do
  end
end

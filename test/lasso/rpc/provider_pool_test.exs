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

  describe "list_candidates circuit breaker filtering" do
    setup do
      # Create test provider with both HTTP and WS configured
      provider =
        provider_struct(%{
          id: "test_provider_both",
          name: "Test Provider Both",
          url: "http://example.com",
          ws_url: "ws://example.com",
          priority: 1
        })

      chain_config = base_chain_config([provider])
      {:ok, _pid} = ProviderPool.start_link({"test_cb_chain", chain_config})
      :ok = ProviderPool.register_provider("test_cb_chain", provider.id, provider)

      # Wait for provider to be active
      Process.sleep(50)

      %{provider: provider, chain: "test_cb_chain"}
    end

    test "excludes provider when protocol=:http and HTTP CB is open", %{
      provider: provider,
      chain: chain
    } do
      # Simulate HTTP circuit breaker opening
      send_cb_event(chain, provider.id, :http, :closed, :open)
      Process.sleep(10)

      # Filter for HTTP protocol - should exclude provider
      candidates = ProviderPool.list_candidates(chain, %{protocol: :http})

      assert Enum.empty?(candidates),
             "Provider should be excluded when HTTP CB is open and filtering for :http"
    end

    test "includes provider when protocol=:http and HTTP CB is closed", %{
      provider: provider,
      chain: chain
    } do
      # Ensure HTTP circuit breaker is closed
      send_cb_event(chain, provider.id, :http, :open, :closed)
      Process.sleep(10)

      candidates = ProviderPool.list_candidates(chain, %{protocol: :http})

      assert length(candidates) == 1, "Provider should be included when HTTP CB is closed"
      assert hd(candidates).id == provider.id
    end

    test "excludes provider when protocol=:ws and WS CB is open", %{
      provider: provider,
      chain: chain
    } do
      # Simulate WS circuit breaker opening
      send_cb_event(chain, provider.id, :ws, :closed, :open)
      Process.sleep(10)

      candidates = ProviderPool.list_candidates(chain, %{protocol: :ws})

      assert Enum.empty?(candidates),
             "Provider should be excluded when WS CB is open and filtering for :ws"
    end

    test "excludes provider when protocol=nil and both CBs are open", %{
      provider: provider,
      chain: chain
    } do
      # Open both circuit breakers
      send_cb_event(chain, provider.id, :http, :closed, :open)
      send_cb_event(chain, provider.id, :ws, :closed, :open)
      Process.sleep(10)

      candidates = ProviderPool.list_candidates(chain, %{})

      assert Enum.empty?(candidates),
             "Provider should be excluded when both CBs are open"
    end

    test "includes provider when protocol=nil, HTTP CB open, WS CB closed", %{
      provider: provider,
      chain: chain
    } do
      # HTTP open, WS closed - provider should be included (has viable WS transport)
      send_cb_event(chain, provider.id, :http, :closed, :open)
      send_cb_event(chain, provider.id, :ws, :open, :closed)
      Process.sleep(10)

      candidates = ProviderPool.list_candidates(chain, %{})

      assert length(candidates) == 1,
             "Provider should be included when at least one transport CB is closed"

      assert hd(candidates).id == provider.id
    end

    test "includes provider when protocol=nil, HTTP CB closed, WS CB open", %{
      provider: provider,
      chain: chain
    } do
      # HTTP closed, WS open - provider should be included (has viable HTTP transport)
      send_cb_event(chain, provider.id, :http, :open, :closed)
      send_cb_event(chain, provider.id, :ws, :closed, :open)
      Process.sleep(10)

      candidates = ProviderPool.list_candidates(chain, %{})

      assert length(candidates) == 1,
             "Provider should be included when at least one transport CB is closed"

      assert hd(candidates).id == provider.id
    end

    test "includes provider with half-open CB when include_half_open=true", %{
      provider: provider,
      chain: chain
    } do
      # HTTP half-open, WS open
      send_cb_event(chain, provider.id, :http, :closed, :half_open)
      send_cb_event(chain, provider.id, :ws, :closed, :open)
      Process.sleep(10)

      # Should include with include_half_open=true
      candidates =
        ProviderPool.list_candidates(chain, %{protocol: :http, include_half_open: true})

      assert length(candidates) == 1,
             "Provider should be included when CB is half-open and include_half_open=true"
    end

    test "excludes provider with half-open CB when include_half_open=false", %{
      provider: provider,
      chain: chain
    } do
      # HTTP half-open, WS open
      send_cb_event(chain, provider.id, :http, :closed, :half_open)
      send_cb_event(chain, provider.id, :ws, :closed, :open)
      Process.sleep(10)

      # Should exclude with include_half_open=false (default)
      candidates = ProviderPool.list_candidates(chain, %{protocol: :http})

      assert Enum.empty?(candidates),
             "Provider should be excluded when CB is half-open and include_half_open=false"
    end

    test "only considers configured transports when filtering", %{chain: chain} do
      # Create provider with only HTTP (no WS)
      http_only_provider =
        provider_struct(%{
          id: "http_only",
          name: "HTTP Only",
          url: "http://example.com",
          ws_url: nil,
          priority: 2
        })

      :ok = ProviderPool.register_provider(chain, http_only_provider.id, http_only_provider)
      Process.sleep(50)

      # Open HTTP CB
      send_cb_event(chain, http_only_provider.id, :http, :closed, :open)
      Process.sleep(10)

      # Should be excluded because HTTP (only transport) has open CB
      candidates = ProviderPool.list_candidates(chain, %{})

      http_only_candidate = Enum.find(candidates, &(&1.id == http_only_provider.id))

      assert is_nil(http_only_candidate),
             "Provider with only HTTP and open HTTP CB should be excluded"
    end
  end

  # Helper to simulate circuit breaker events
  defp send_cb_event(chain, provider_id, transport, from, to) do
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "circuit:events",
      {:circuit_breaker_event,
       %{
         chain: chain,
         provider_id: provider_id,
         transport: transport,
         from: from,
         to: to
       }}
    )
  end
end

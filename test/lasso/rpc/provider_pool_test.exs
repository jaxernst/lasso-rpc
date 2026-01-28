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
          url: "http://example",
          ws_url: "ws://example"
        },
        attrs
      )
    )
  end

  test "EMA updates on success and failure, cooldown on rate limit" do
    p1 = provider_struct(%{id: "p1", name: "P1", priority: 1})
    p2 = provider_struct(%{id: "p2", name: "P2", priority: 2})
    chain_config = base_chain_config([p1, p2])

    {:ok, _pid} = ProviderPool.start_link({"testnet", chain_config})

    :ok = ProviderPool.register_provider("default", "testnet", p1.id, p1)
    :ok = ProviderPool.register_provider("default", "testnet", p2.id, p2)

    ProviderPool.report_success("default", "testnet", p1.id, nil)
    {:ok, status} = ProviderPool.get_status("default", "testnet")
    p1_status = Enum.find(status.providers, &(&1.id == p1.id))
    assert p1_status.status in [:healthy, :connecting]

    ProviderPool.report_failure("default", "testnet", p1.id, {:rate_limit, "HTTP 429"}, nil)
    {:ok, status2} = ProviderPool.get_status("default", "testnet")
    p1_status2 = Enum.find(status2.providers, &(&1.id == p1.id))
    # Rate limits don't change health status - check rate limit state via RateLimitState fields
    assert p1_status2.http_rate_limited == true or p1_status2.is_in_cooldown == true
    # Health status should remain unchanged (healthy or connecting)
    assert p1_status2.status in [:healthy, :connecting]

    ProviderPool.report_failure("default", "testnet", p1.id, {:server_error, "500"}, nil)
    {:ok, status3} = ProviderPool.get_status("default", "testnet")
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
      :ok = ProviderPool.register_provider("default", "test_cb_chain", provider.id, provider)

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
      candidates = ProviderPool.list_candidates("default", chain, %{protocol: :http})

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

      candidates = ProviderPool.list_candidates("default", chain, %{protocol: :http})

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

      candidates = ProviderPool.list_candidates("default", chain, %{protocol: :ws})

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

      candidates = ProviderPool.list_candidates("default", chain, %{})

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

      candidates = ProviderPool.list_candidates("default", chain, %{})

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

      candidates = ProviderPool.list_candidates("default", chain, %{})

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
        ProviderPool.list_candidates("default", chain, %{protocol: :http, include_half_open: true})

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
      candidates = ProviderPool.list_candidates("default", chain, %{protocol: :http})

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

      :ok =
        ProviderPool.register_provider(
          "default",
          chain,
          http_only_provider.id,
          http_only_provider
        )

      Process.sleep(50)

      # Open HTTP CB
      send_cb_event(chain, http_only_provider.id, :http, :closed, :open)
      Process.sleep(10)

      # Should be excluded because HTTP (only transport) has open CB
      candidates = ProviderPool.list_candidates("default", chain, %{})

      http_only_candidate = Enum.find(candidates, &(&1.id == http_only_provider.id))

      assert is_nil(http_only_candidate),
             "Provider with only HTTP and open HTTP CB should be excluded"
    end
  end

  # Helper to simulate circuit breaker events
  defp send_cb_event(chain, provider_id, transport, from, to, profile \\ "default") do
    Phoenix.PubSub.broadcast(
      Lasso.PubSub,
      "circuit:events:#{profile}:#{chain}",
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

  describe "circuit breaker recovery clears rate_limited status" do
    setup do
      provider =
        provider_struct(%{
          id: "rate_limit_test_provider",
          name: "Rate Limit Test Provider",
          url: "http://example.com",
          ws_url: "ws://example.com",
          priority: 1
        })

      chain_config = base_chain_config([provider])
      {:ok, _pid} = ProviderPool.start_link({"rate_limit_chain", chain_config})
      :ok = ProviderPool.register_provider("default", "rate_limit_chain", provider.id, provider)
      Process.sleep(50)

      %{provider: provider, chain: "rate_limit_chain"}
    end

    test "rate limit records to RateLimitState without changing health status", %{
      provider: provider,
      chain: chain
    } do
      # Get initial status - should be healthy/connecting
      {:ok, status_before} = ProviderPool.get_status("default", chain)
      provider_before = Enum.find(status_before.providers, &(&1.id == provider.id))
      initial_http_status = provider_before.http_status

      # Report rate limit - should NOT change health status
      ProviderPool.report_failure("default", chain, provider.id, {:rate_limit, "HTTP 429"}, :http)
      Process.sleep(10)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider_status = Enum.find(status.providers, &(&1.id == provider.id))

      # Health status should NOT change - rate limits are backpressure, not failures
      assert provider_status.http_status == initial_http_status,
             "HTTP health status should not change on rate limit"

      # Rate limit state should be recorded via RateLimitState
      assert provider_status.http_rate_limited == true,
             "http_rate_limited should be true from RateLimitState"

      assert provider_status.is_in_cooldown == true,
             "is_in_cooldown should be true"
    end

    test "rate limit on WS records to RateLimitState without changing health status", %{
      provider: provider,
      chain: chain
    } do
      # Get initial status
      {:ok, status_before} = ProviderPool.get_status("default", chain)
      provider_before = Enum.find(status_before.providers, &(&1.id == provider.id))
      initial_ws_status = provider_before.ws_status

      # Report rate limit - should NOT change health status
      ProviderPool.report_failure("default", chain, provider.id, {:rate_limit, "WS 429"}, :ws)
      Process.sleep(10)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider_status = Enum.find(status.providers, &(&1.id == provider.id))

      # Health status should NOT change
      assert provider_status.ws_status == initial_ws_status,
             "WS health status should not change on rate limit"

      # Rate limit state should be recorded via RateLimitState
      assert provider_status.ws_rate_limited == true,
             "ws_rate_limited should be true from RateLimitState"
    end

    test "rate limits are independent of circuit breaker state", %{
      provider: provider,
      chain: chain
    } do
      # Report rate limit
      ProviderPool.report_failure("default", chain, provider.id, {:rate_limit, "HTTP 429"}, :http)
      Process.sleep(10)

      # Circuit breaker should NOT open from rate limits (breaker_penalty?: false)
      {:ok, status} = ProviderPool.get_status("default", chain)
      provider_status = Enum.find(status.providers, &(&1.id == provider.id))

      # Rate limit should be recorded
      assert provider_status.http_rate_limited == true

      # Circuit should still be closed (rate limits don't trigger circuit breaker)
      assert provider_status.http_cb_state == :closed,
             "Circuit should remain closed - rate limits don't trip circuit breaker"
    end

    test "success clears rate limit state", %{
      provider: provider,
      chain: chain
    } do
      # Report rate limit
      ProviderPool.report_failure("default", chain, provider.id, {:rate_limit, "HTTP 429"}, :http)
      Process.sleep(10)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider_status = Enum.find(status.providers, &(&1.id == provider.id))
      assert provider_status.http_rate_limited == true

      # Report success - should clear rate limit
      ProviderPool.report_success("default", chain, provider.id, :http)
      Process.sleep(10)

      {:ok, status_after} = ProviderPool.get_status("default", chain)
      provider_after = Enum.find(status_after.providers, &(&1.id == provider.id))

      assert provider_after.http_rate_limited == false,
             "Success should clear rate limit state"
    end

    test "aggregate status reflects health not rate limits", %{
      provider: provider,
      chain: chain
    } do
      # Get initial health status
      {:ok, status_before} = ProviderPool.get_status("default", chain)
      provider_before = Enum.find(status_before.providers, &(&1.id == provider.id))
      initial_status = provider_before.status

      # Rate limit both transports - health status should NOT change
      ProviderPool.report_failure("default", chain, provider.id, {:rate_limit, "HTTP 429"}, :http)
      ProviderPool.report_failure("default", chain, provider.id, {:rate_limit, "WS 429"}, :ws)
      Process.sleep(10)

      {:ok, status} = ProviderPool.get_status("default", chain)
      provider_status = Enum.find(status.providers, &(&1.id == provider.id))

      # Health status should remain unchanged - rate limits don't affect it
      assert provider_status.status == initial_status,
             "Aggregate health status should not change on rate limit"

      # But rate limit state should be recorded
      assert provider_status.http_rate_limited == true
      assert provider_status.ws_rate_limited == true
      assert provider_status.is_in_cooldown == true
    end
  end
end

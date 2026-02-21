defmodule Lasso.RPC.TransportFailureReportingIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration
  @moduletag timeout: 10_000

  alias Lasso.RPC.{RequestPipeline, ProviderPool, RequestOptions}
  alias Lasso.Test.{TelemetrySync, CircuitBreakerHelper}

  test "failures are reported with correct transport and gate HTTP only", %{chain: chain} do
    profile = "default"

    # Setup two providers: one failing, one healthy
    setup_providers([
      %{id: "fail_http", priority: 10, behavior: :always_fail, profile: profile},
      %{id: "ok_http", priority: 20, behavior: :healthy, profile: profile}
    ])

    # Ensure circuit breaker exists for HTTP transport
    CircuitBreakerHelper.ensure_circuit_breaker_started(profile, chain, "fail_http", :http)

    # Attach telemetry collector BEFORE triggering failures
    {:ok, cb_open} =
      TelemetrySync.attach_collector(
        [:lasso, :circuit_breaker, :open],
        match: [provider_id: "fail_http"]
      )

    # Trigger multiple failures on HTTP path only (no failover)
    for _ <- 1..5 do
      _ =
        RequestPipeline.execute_via_channels(
          chain,
          "eth_blockNumber",
          [],
          %RequestOptions{
            provider_override: "fail_http",
            failover_on_override: false,
            strategy: :load_balanced,
            timeout_ms: 30_000
          }
        )

      Process.sleep(10)
    end

    # Wait for circuit breaker open telemetry or continue after short grace
    _ = TelemetrySync.await_event(cb_open, timeout: 1500)

    # Verify HTTP circuit breaker is open
    CircuitBreakerHelper.assert_circuit_breaker_state({profile, chain, "fail_http", :http}, :open)

    # ProviderPool should reflect HTTP transport failure without forcing WS changes
    {:ok, status} = ProviderPool.get_status("default", chain)
    p = Enum.find(status.providers, &(&1.id == "fail_http"))
    assert p.http_status in [:unhealthy, :rate_limited, :degraded]

    # HTTP candidate list should exclude the failing provider due to CB open
    http_candidates = ProviderPool.list_candidates("default", chain, %{protocol: :http})
    refute Enum.any?(http_candidates, &(&1.id == "fail_http"))

    # Agnostic (nil) candidates should still include ok_http
    any_candidates = ProviderPool.list_candidates("default", chain, %{protocol: nil})
    assert Enum.any?(any_candidates, &(&1.id == "ok_http"))
  end
end

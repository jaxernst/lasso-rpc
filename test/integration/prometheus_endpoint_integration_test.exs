defmodule Lasso.PrometheusEndpointIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  @moduletag :integration

  alias Lasso.Observability.Prometheus

  test "a real HTTP scrape exposes bounded request and current route evidence", %{chain: chain} do
    setup_providers([%{id: "metrics_probe", profile: "public", behavior: :healthy}])

    :telemetry.execute(
      [:lasso, :rpc, :request, :stop],
      %{duration: 1},
      %{
        chain_id: chain,
        provider_id: "metrics_probe",
        method: "eth_getLogs",
        result: :error
      }
    )

    :telemetry.execute(
      [:lasso, :rpc, :request, :stop],
      %{duration: 1},
      %{
        chain_id: chain,
        provider_id: "metrics_probe",
        method: "unbounded_user_method_#{chain}",
        result: :success
      }
    )

    {:ok, _apps} = Application.ensure_all_started(:inets)
    port = LassoWeb.Endpoint.config(:http)[:port]
    url = String.to_charlist("http://127.0.0.1:#{port}/metrics")

    assert {:ok, {{_version, 200, _reason}, headers, body}} =
             :httpc.request(:get, {url, []}, [], [])

    assert {~c"content-type", content_type} =
             Enum.find(headers, fn {name, _value} -> name == ~c"content-type" end)

    assert to_string(content_type) =~ "text/plain"
    body = to_string(body)

    assert body =~
             ~s(lasso_rpc_requests_total{chain="#{chain}",provider="metrics_probe",method="eth_getLogs",outcome="error"} 1)

    assert body =~
             ~s(lasso_rpc_requests_total{chain="#{chain}",provider="metrics_probe",method="other",outcome="success"} 1)

    assert body =~
             "lasso_circuit_state{profile=\"public\",chain=\"#{chain}\",provider=\"metrics_probe\""

    assert body =~ "# TYPE lasso_provider_head_lag_blocks gauge"
    refute body =~ "unbounded_user_method_#{chain}"
    assert Prometheus.stats().series <= 4_096
  end
end

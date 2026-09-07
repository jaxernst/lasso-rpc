defmodule LassoWeb.MetricsAPITest do
  use Lasso.Test.LassoIntegrationCase

  import Phoenix.ConnTest
  alias Lasso.Benchmarking.BenchmarkStore

  @endpoint LassoWeb.Endpoint
  @moduletag :integration

  test "configured providers are reported before any benchmark observations", %{chain: chain} do
    setup_providers([%{id: "metrics-local", behavior: :healthy}], profile: "public")

    body = build_conn() |> get("/api/metrics/#{chain}") |> json_response(200)
    assert body["chain_performance"]["total_providers"] == 1
    assert body["chain_performance"]["total_calls"] == 0
    assert body["chain_performance"]["success_rate"] == nil
    assert body["chain_performance"]["rpc_calls_per_second"] == nil
    assert body["chain_performance"]["failovers_last_minute"] == nil
  end

  test "chain metrics reflect recorded upstream outcomes", %{chain: chain} do
    setup_providers([%{id: "metrics-local", behavior: :healthy}], profile: "public")

    BenchmarkStore.record_rpc_call(
      "public",
      chain,
      "metrics-local",
      "eth_call@http",
      20,
      :success
    )

    BenchmarkStore.record_rpc_call("public", chain, "metrics-local", "eth_call@http", 80, :error)

    body = build_conn() |> get("/api/metrics/#{chain}") |> json_response(200)
    assert body["chain_performance"]["total_calls"] == 2
    assert body["chain_performance"]["success_rate"] == 50.0
    assert body["chain_performance"]["error_rate_percent"] == 50.0
    assert is_number(body["chain_performance"]["p50_latency"])
    assert [%{"id" => "metrics-local", "total_calls" => 2}] = body["providers"]
  end
end

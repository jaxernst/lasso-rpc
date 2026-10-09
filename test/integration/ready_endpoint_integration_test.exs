defmodule LassoWeb.ReadyEndpointIntegrationTest do
  use Lasso.Test.LassoIntegrationCase

  import Phoenix.ConnTest

  alias Lasso.BlockSync.Registry, as: BlockSyncRegistry
  alias Lasso.Config.ConfigStore
  alias Lasso.Providers.{CandidateListing, Catalog}
  alias Lasso.RPC.SelectionFilters

  @endpoint LassoWeb.Endpoint
  @moduletag :integration

  test "readiness follows eligible upstreams and fresh head evidence", %{chain: chain} do
    path = "/api/ready?profile=public&chain=#{chain}"
    assert %{"status" => "healthy"} = build_conn() |> get("/api/health") |> json_response(200)

    :ok =
      ConfigStore.register_chain_runtime("public", chain, %{
        chain_id: chain,
        providers: []
      })

    :ok = Catalog.build_from_config()

    assert %{"status" => "not_ready", "checks" => [%{"reason" => "no_eligible_upstream"}]} =
             build_conn() |> get(path) |> json_response(503)

    assert Lasso.Observability.Prometheus.scrape() =~
             ~s(lasso_chain_ready{profile="public",chain="#{chain}"} 0)

    setup_providers([%{id: "ready-upstream", profile: "public", behavior: :healthy}])

    Lasso.Test.Eventually.assert_eventually(fn ->
      CandidateListing.list_candidates(
        "public",
        chain,
        SelectionFilters.new(protocol: :http, exclude_rate_limited: true)
      ) != []
    end)

    :ok = BlockSyncRegistry.clear_chain(chain)

    assert %{"status" => "not_ready", "checks" => [%{"reason" => "stale_or_missing_head"}]} =
             build_conn() |> get(path) |> json_response(503)

    instance_id = Catalog.lookup_instance_id("public", chain, "ready-upstream")
    assert is_binary(instance_id)
    :ok = BlockSyncRegistry.put_height(chain, instance_id, 100, :http)

    assert %{"status" => "ready", "checks" => [%{"chain_id" => ^chain, "reason" => nil}]} =
             build_conn() |> get(path) |> json_response(200)

    assert Lasso.Observability.Prometheus.scrape() =~
             ~s(lasso_chain_ready{profile="public",chain="#{chain}"} 1)

    assert Lasso.Observability.Prometheus.scrape() =~
             ~s(lasso_chain_eligible_upstreams{profile="public",chain="#{chain}"} 1)

    :ets.insert(:lasso_instance_state, {
      {:health_block_sync, instance_id},
      %{http_status: :unhealthy, last_health_check: System.system_time(:millisecond)}
    })

    assert %{"status" => "not_ready", "checks" => [%{"reason" => "no_eligible_upstream"}]} =
             build_conn() |> get(path) |> json_response(503)
  end

  test "a dead upstream on one chain leaves the replica ready and the scoped probe not ready",
       %{chain: chain} do
    setup_providers([%{id: "dead-upstream", profile: "public", behavior: :healthy}])
    instance_id = Catalog.lookup_instance_id("public", chain, "dead-upstream")
    assert is_binary(instance_id)

    :ets.insert(:lasso_instance_state, {
      {:health_block_sync, instance_id},
      %{http_status: :unhealthy, last_health_check: System.system_time(:millisecond)}
    })

    assert %{
             "status" => "ready",
             "reason" => nil,
             "checks" => %{"configuration" => true, "catalog" => true, "cluster" => true}
           } = build_conn() |> get("/api/ready") |> json_response(200)

    assert %{
             "status" => "not_ready",
             "checks" => [%{"chain_id" => ^chain, "reason" => "no_eligible_upstream"}]
           } =
             build_conn() |> get("/api/ready?profile=public&chain=#{chain}") |> json_response(503)

    assert %{"status" => "not_ready", "profile" => "public"} =
             build_conn() |> get("/api/ready?profile=public") |> json_response(503)
  end

  test "unknown chain is not ready", %{chain: chain} do
    path = "/api/ready?profile=public&chain=#{chain + 1_000_000}"

    assert %{"status" => "not_ready", "reason" => "profile_or_chain_not_configured"} =
             build_conn() |> get(path) |> json_response(503)
  end
end

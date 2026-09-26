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
  end

  test "unknown chain is not ready", %{chain: chain} do
    path = "/api/ready?profile=public&chain=#{chain + 1_000_000}"

    assert %{"status" => "not_ready", "reason" => "profile_or_chain_not_configured"} =
             build_conn() |> get(path) |> json_response(503)
  end
end

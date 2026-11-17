defmodule LassoWeb.DashboardProfileScopeTest do
  use Lasso.Test.LassoIntegrationCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Lasso.BlockSync.Registry
  alias Lasso.Config.ConfigStore
  alias Lasso.Observations.HeadSnapshot
  alias Lasso.Providers.{Catalog, HeadEvidence}

  @endpoint LassoWeb.Endpoint
  @profile "testnet"
  @other_profile "public"

  setup %{chain: chain} do
    on_exit(fn ->
      ConfigStore.unregister_chain_runtime(@profile, chain)
      ConfigStore.unregister_chain_runtime(@other_profile, chain)
      Catalog.build_from_config()
    end)

    suffix = Integer.to_string(chain)
    own = Enum.map(~w(a b c), &"own-#{&1}-#{suffix}")
    other = Enum.map(~w(a b), &"other-#{&1}-#{suffix}")

    for profile <- [@profile, @other_profile] do
      assert :ok =
               ConfigStore.register_chain_runtime(profile, chain, %{
                 block_time_ms: 1_000,
                 monitoring: %{lag_alert_threshold_blocks: 3},
                 providers: []
               })
    end

    specs = &Enum.map(&1, fn id -> %{id: id, background_observations: false} end)
    setup_providers(specs.(own), profile: @profile)
    setup_providers(specs.(other), profile: @other_profile)

    {:ok, own: own, other: other}
  end

  test "provider sync status compares a provider only with its own profile's head", %{
    chain: chain,
    own: [synced, peer, behind],
    other: other
  } do
    instance = &Catalog.lookup_instance_id(&1, chain, &2)

    for id <- other,
        do: Registry.put_height(chain, instance.(@other_profile, id), 26_000_000, :ws)

    for id <- [synced, peer], do: Registry.put_height(chain, instance.(@profile, id), 100, :ws)

    assert {:ok, %HeadSnapshot{qualification: :qualified} = snapshot} =
             HeadEvidence.snapshot(@profile, chain)

    assert {:ok, reference} = HeadSnapshot.reference(snapshot)
    now_ms = System.system_time(:millisecond)

    Registry.put_height_at(chain, instance.(@profile, behind), 95, now_ms - 300_000, :ws, %{})

    {:ok, view, _html} = live(build_conn(), "/dashboard/#{@profile}")

    stale_html = render_click(view, "select_provider", %{"provider" => behind})
    assert sync_status(stale_html) =~ "Block height data unavailable"
    refute sync_status(stale_html) =~ "95"

    Registry.put_height(chain, instance.(@profile, behind), 80, :http, %{
      poll_references: [%{reference | captured_at_ms: now_ms}]
    })

    synced_html = render_click(view, "select_provider", %{"provider" => synced})
    assert sync_status(synced_html) =~ ~r/Block Height:\s*100\b/
    assert sync_status(synced_html) =~ ~r/Consensus:\s*100\b/
    assert sync_status(synced_html) =~ "Synced"
    refute synced_html =~ "26,000,000"
    refute sync_status(synced_html) =~ ~r/-\d/

    behind_html = render_click(view, "select_provider", %{"provider" => behind})
    assert sync_status(behind_html) =~ ~r/Block Height:\s*80\b/
    assert sync_status(behind_html) =~ ~r/Consensus:\s*100\b/
    assert sync_status(behind_html) =~ " -20 "
    assert behind_html =~ "Lagging"
    assert behind_html =~ "20 blocks behind the profile head"
  end

  test "chain details show the profile's routing decisions and traffic share", %{
    chain: chain,
    own: own
  } do
    {:ok, view, _html} = live(build_conn(), "/dashboard/#{@profile}?chain=#{chain}")

    assert render(view) =~ "No recent decisions"

    for _ <- 1..6 do
      assert {:ok, _, _} =
               RequestPipeline.execute_via_channels(chain, "eth_chainId", [], %RequestOptions{
                 profile: @profile,
                 strategy: :load_balanced,
                 transport: :http,
                 timeout_ms: 2_000
               })
    end

    Lasso.Test.Eventually.assert_eventually(
      fn ->
        html = view |> element("#chain-details-#{chain}") |> render()

        html =~ "eth_chainId" and not (html =~ "No recent decisions") and
          not (html =~ "No traffic recorded recently") and
          Enum.any?(own, &(html =~ "Mock HTTP Provider #{&1}"))
      end,
      timeout: 5_000
    )
  end

  defp sync_status(html) do
    [_, section] = String.split(html, "Sync Status", parts: 2)

    section
    |> String.split("Performance", parts: 2)
    |> hd()
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/\s+/, " ")
  end
end

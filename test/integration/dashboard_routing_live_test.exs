defmodule LassoWeb.DashboardRoutingLiveTest do
  use Lasso.Test.LassoIntegrationCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Lasso.RPC.{RequestOptions, RequestPipeline}
  alias LassoWeb.Dashboard.MetricsHelpers

  @endpoint LassoWeb.Endpoint
  @moduletag :integration
  @moduletag timeout: 10_000

  test "canonical routing decisions propagate through EventStream into LiveView", %{chain: chain} do
    request_id = "dashboard-live-#{System.unique_integer([:positive])}"

    setup_providers([
      %{id: "dashboard-live-provider", priority: 10, behavior: :healthy, profile: "public"}
    ])

    {:ok, view, _html} = live(build_conn(), "/dashboard/public?tab=overview")
    assert has_element?(view, "details#profile-selector")

    assert {:ok, _result, _ctx} =
             RequestPipeline.execute_via_channels(
               chain,
               "eth_blockNumber",
               [],
               %RequestOptions{
                 strategy: :load_balanced,
                 timeout_ms: 30_000,
                 request_id: request_id
               }
             )

    assert %{
             request_id: ^request_id,
             provider_id: "dashboard-live-provider",
             method: "eth_blockNumber",
             transport: :http,
             request_origin: :client,
             result: :success
           } = await_live_routing_event(view, request_id)

    state = :sys.get_state(view.pid)

    assert Enum.any?(state.socket.assigns.routing_events, fn event ->
             event.provider_id == "dashboard-live-provider" and
               event.method == "eth_blockNumber" and event.request_origin == :client and
               event.result == :success
           end)

    assert render(view) =~ "Sampled success ("
    assert MetricsHelpers.routing_sample_count(state.socket.assigns.routing_events) >= 1

    assert Process.alive?(view.pid)
  end

  test "system failures remain visible without lowering client routing success", %{chain: chain} do
    system_request_id = "dashboard-system-#{System.unique_integer([:positive])}"
    client_request_id = "dashboard-client-#{System.unique_integer([:positive])}"

    setup_providers([
      %{id: "dashboard-system-failure", priority: 10, behavior: :always_fail, profile: "public"},
      %{id: "dashboard-client-success", priority: 20, behavior: :healthy, profile: "public"}
    ])

    {:ok, view, _html} = live(build_conn(), "/dashboard/public?tab=overview")

    assert {:error, _error, _ctx} =
             RequestPipeline.execute_via_channels(
               chain,
               "eth_blockNumber",
               [],
               %RequestOptions{
                 provider_override: "dashboard-system-failure",
                 failover_on_override: false,
                 strategy: :priority,
                 timeout_ms: 30_000,
                 request_id: system_request_id,
                 request_origin: :system
               }
             )

    assert {:ok, _result, _ctx} =
             RequestPipeline.execute_via_channels(
               chain,
               "eth_blockNumber",
               [],
               %RequestOptions{
                 provider_override: "dashboard-client-success",
                 failover_on_override: false,
                 strategy: :priority,
                 timeout_ms: 30_000,
                 request_id: client_request_id
               }
             )

    assert %{request_origin: :system, result: :error} =
             await_live_routing_event(view, system_request_id)

    assert %{request_origin: :client, result: :success} =
             await_live_routing_event(view, client_request_id)

    state = :sys.get_state(view.pid)
    assert MetricsHelpers.success_rate_percent(state.socket.assigns.routing_events) == 100.0
  end

  defp await_live_routing_event(view, request_id, attempts \\ 50)

  defp await_live_routing_event(_view, request_id, 0),
    do: flunk("LiveView did not receive routing event #{request_id}")

  defp await_live_routing_event(view, request_id, attempts) do
    _html = render(view)
    state = :sys.get_state(view.pid)

    case Enum.find(state.socket.assigns.events, &(Map.get(&1, :request_id) == request_id)) do
      nil ->
        Process.sleep(20)
        await_live_routing_event(view, request_id, attempts - 1)

      event ->
        event
    end
  end
end

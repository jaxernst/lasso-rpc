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
    profile = "dashboard-live-#{System.unique_integer([:positive])}"

    setup_providers(
      [
        %{id: "dashboard-live-provider", priority: 10, behavior: :healthy}
      ],
      profile: profile
    )

    {:ok, view, _html} = live(build_conn(), "/dashboard/#{profile}?tab=overview")
    assert has_element?(view, "details#profile-selector")

    assert {:ok, _result, _ctx} =
             RequestPipeline.execute_via_channels(
               chain,
               "eth_blockNumber",
               [],
               %RequestOptions{
                 profile: profile,
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

    state = await_exact_traffic(view, 1)

    assert Enum.any?(state.socket.assigns.routing_events, fn event ->
             event.provider_id == "dashboard-live-provider" and
               event.method == "eth_blockNumber" and event.request_origin == :client and
               event.result == :success
           end)

    html = render(view)
    assert html =~ "Success (1)"
    refute html =~ "Sampled success"
    assert MetricsHelpers.routing_sample_count(state.socket.assigns.routing_events) >= 1

    assert is_binary(render_click(view, "select_chain", %{"chain" => to_string(chain)}))

    assert %{socket: %{assigns: %{selected_chain: selected_chain}}} = :sys.get_state(view.pid)
    assert selected_chain == to_string(chain)
    assert Process.alive?(view.pid)
  end

  test "system failures remain visible without lowering client routing success", %{chain: chain} do
    system_request_id = "dashboard-system-#{System.unique_integer([:positive])}"
    client_request_id = "dashboard-client-#{System.unique_integer([:positive])}"
    profile = "dashboard-origin-#{System.unique_integer([:positive])}"

    setup_providers(
      [
        %{id: "dashboard-system-failure", priority: 10, behavior: :always_fail},
        %{id: "dashboard-client-success", priority: 20, behavior: :healthy}
      ],
      profile: profile
    )

    {:ok, view, _html} = live(build_conn(), "/dashboard/#{profile}?tab=overview")

    assert {:error, _error, _ctx} =
             RequestPipeline.execute_via_channels(
               chain,
               "eth_blockNumber",
               [],
               %RequestOptions{
                 profile: profile,
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
                 profile: profile,
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

    state = await_exact_traffic(view, 1)
    assert MetricsHelpers.success_rate_percent(state.socket.assigns.routing_events) == 100.0
    assert state.socket.assigns.traffic_metrics.count == 1
    assert state.socket.assigns.traffic_metrics.successes == 1
    assert state.socket.assigns.traffic_metrics.errors == 0

    html = render(view)
    assert html =~ "Success (1)"
    assert html =~ "SYSTEM"
    assert html =~ ~s(data-request-origin="system")
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

  defp await_exact_traffic(view, count, attempts \\ 60)

  defp await_exact_traffic(_view, count, 0),
    do: flunk("LiveView did not receive exact traffic count #{count}")

  defp await_exact_traffic(view, count, attempts) do
    _html = render(view)
    state = :sys.get_state(view.pid)

    if get_in(state.socket.assigns, [:traffic_metrics, :count]) == count do
      state
    else
      Process.sleep(50)
      await_exact_traffic(view, count, attempts - 1)
    end
  end
end

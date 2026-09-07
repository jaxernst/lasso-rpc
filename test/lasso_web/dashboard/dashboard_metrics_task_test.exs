defmodule LassoWeb.Dashboard.MetricsTaskTest do
  use ExUnit.Case, async: true

  alias LassoWeb.Dashboard

  defp socket(task) do
    Phoenix.Component.assign(%Phoenix.LiveView.Socket{},
      selected_profile: "current",
      metrics_selected_chain: 1,
      metrics_task: task,
      metrics_loading: true,
      provider_metrics: [:current]
    )
  end

  test "cache completion during a fetch causes another refresh after settlement" do
    ref = make_ref()
    socket = socket(%Task{ref: ref, owner: self(), pid: self(), mfa: {__MODULE__, :test, 0}})

    {:noreply, socket} =
      Dashboard.handle_info({:cache_warmed, {:bulk_method_perf, "current", 1}}, socket)

    assert socket.assigns.metrics_refresh_needed

    data = %{
      provider_metrics: [],
      method_metrics: [],
      coverage: %{responding: 1, total: 1},
      stale: false,
      cache_warming: true
    }

    {:noreply, socket} = Dashboard.handle_info({ref, {"current", 1, data}}, socket)
    assert socket.assigns.metrics_loading
    assert_received :refresh_cluster_metrics
  end

  test "an old profile's task result cannot replace current metrics" do
    ref = make_ref()

    {:noreply, socket} =
      Dashboard.handle_info(
        {ref, {"old", 1, %{}}},
        socket(%Task{ref: ref, owner: self(), pid: self(), mfa: {__MODULE__, :test, 0}})
      )

    assert socket.assigns.provider_metrics == [:current]
    assert socket.assigns.metrics_task == nil
    assert_received :refresh_cluster_metrics
  end

  test "unrelated cache completions do not trigger queries" do
    original = socket(nil)

    assert {:noreply, ^original} =
             Dashboard.handle_info({:cache_warmed, {:bulk_method_perf, "other", 1}}, original)

    refute_received :refresh_cluster_metrics
  end

  test "metrics chain controls keep configured numeric identities" do
    original = Phoenix.Component.assign(socket(nil), :profile_chains, [1, 10])
    {:noreply, selected} = Dashboard.handle_info({:metrics_chain_selected, "10"}, original)
    assert selected.assigns.metrics_selected_chain == 10
    assert selected.assigns.metrics_loading
    assert_received :refresh_cluster_metrics

    assert {:noreply, ^original} =
             Dashboard.handle_info({:metrics_chain_selected, "unknown"}, original)

    refute_received :refresh_cluster_metrics
  end

  test "empty profiles settle loading without spawning a task" do
    socket = Phoenix.Component.assign(socket(nil), :metrics_selected_chain, nil)
    {:noreply, socket} = Dashboard.handle_info(:refresh_cluster_metrics, socket)
    refute socket.assigns.metrics_loading
    assert socket.assigns.metrics_task == nil
  end
end

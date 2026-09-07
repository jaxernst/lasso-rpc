defmodule LassoWeb.Dashboard.SimulatorControlsTest do
  use ExUnit.Case, async: true

  alias LassoWeb.Dashboard.Components.SimulatorControls

  defp socket do
    {:ok, socket} =
      SimulatorControls.update(
        %{selected_profile: "local", available_chains: [%{name: 1}], rps_limit: 2},
        %Phoenix.LiveView.Socket{}
      )

    socket
  end

  test "quick runs use the selected profile's chains, duration, and tester limit" do
    {:noreply, socket} =
      SimulatorControls.handle_event("update_duration", %{"duration" => "10"}, socket())

    {:ok, socket} = SimulatorControls.update(%{}, socket)
    assert socket.assigns.quick_run_config.profile == "local"
    assert socket.assigns.quick_run_config.chains == [1]
    assert socket.assigns.quick_run_config.duration == 10_000
    assert socket.assigns.quick_run_config.http.rps == 2
    refute Map.has_key?(socket.assigns.quick_run_config, :api_key)
  end

  test "chain selections use configured identities and reset when the profile changes" do
    {:noreply, socket} =
      SimulatorControls.handle_event("toggle_chain_selection", %{"chain" => "1"}, socket())

    assert socket.assigns.selected_chains == [1]

    {:noreply, socket} =
      SimulatorControls.handle_event("toggle_chain_selection", %{"chain" => "999"}, socket)

    assert socket.assigns.selected_chains == [1]

    {:ok, socket} =
      SimulatorControls.update(
        %{selected_profile: "other", available_chains: [%{name: 10}]},
        socket
      )

    assert socket.assigns.selected_chains == []
    assert socket.assigns.quick_run_config.chains == [10]
  end

  test "an empty profile cannot start requests" do
    {:ok, socket} = SimulatorControls.update(%{available_chains: []}, socket())

    for event <- ["quick_start", "start_simulator_run"] do
      assert {:noreply, ^socket} = SimulatorControls.handle_event(event, %{}, socket)
    end
  end

  test "custom runs and profile changes clamp the tester rate" do
    initial = socket()
    assert initial.assigns.request_rate == 2
    {:noreply, selected} = SimulatorControls.handle_event("set_rate", %{"rate" => "30"}, initial)
    assert selected.assigns.request_rate == 2
    {:ok, reduced} = SimulatorControls.update(%{rps_limit: 1}, selected)
    assert reduced.assigns.request_rate == 1
    {:noreply, running} = SimulatorControls.handle_event("start_simulator_run", %{}, reduced)
    [["start_simulator_run", config] | _] = Phoenix.LiveView.Utils.get_push_events(running)
    assert config.http.rps == 1
  end

  test "malformed control events leave the selection intact" do
    initial = socket()

    for {event, params} <- [
          {"set_rate", %{"rate" => "bad"}},
          {"set_rate", %{"rate" => "-1"}},
          {"update_duration", %{"duration" => "0"}},
          {"select_strategy", %{"strategy" => "invented"}}
        ] do
      assert {:noreply, ^initial} = SimulatorControls.handle_event(event, params, initial)
    end
  end
end

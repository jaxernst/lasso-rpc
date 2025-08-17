defmodule Livechain.Simulator do
  @moduledoc """
  WebSocket Connection Simulator for real-time dashboard demonstration.

  This module provides convenient access to the simulator functionality
  organized under the Livechain.Simulator namespace.
  """

  # Add child_spec to delegate to the actual implementation
  def child_spec(opts) do
    Livechain.Simulator.Simulator.child_spec(opts)
  end

  # Delegate main simulator functions to the actual implementation
  defdelegate start_link(opts \\ []), to: Livechain.Simulator.Simulator
  defdelegate start_simulation(), to: Livechain.Simulator.Simulator
  defdelegate stop_simulation(), to: Livechain.Simulator.Simulator
  defdelegate get_stats(), to: Livechain.Simulator.Simulator
  defdelegate get_mode(), to: Livechain.Simulator.Simulator
  defdelegate switch_mode(mode), to: Livechain.Simulator.Simulator
  defdelegate update_config(config), to: Livechain.Simulator.Simulator
  defdelegate start_all_mock_connections(), to: Livechain.Simulator.Simulator
  defdelegate stop_all_mock_connections(), to: Livechain.Simulator.Simulator
end

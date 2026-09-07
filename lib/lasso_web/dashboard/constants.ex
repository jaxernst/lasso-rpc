defmodule LassoWeb.Dashboard.Constants do
  @moduledoc "Shared display windows and history limits for the dashboard."

  def metrics_window_5min, do: 300_000
  def vm_metrics_interval, do: 1_000
  def event_history_size, do: 200
  def recent_blocks_limit, do: 20
  def routing_events_limit, do: 200
  def provider_events_limit, do: 200
end

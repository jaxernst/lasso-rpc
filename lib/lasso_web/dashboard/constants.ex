defmodule LassoWeb.Dashboard.Constants do
  @moduledoc """
  Centralized configuration constants for dashboard UI.
  All magic numbers and thresholds in one place.
  """

  # Time windows (milliseconds)
  def metrics_window_5min, do: 300_000
  def metrics_window_1hour, do: 3_600_000
  def vm_metrics_interval, do: 1_000
  def metrics_refresh_interval, do: 30_000
  def latency_refresh_interval, do: 30_000

  # Event buffer configuration
  def default_batch_interval, do: get_config(:batch_interval, 100)
  def max_buffer_size, do: get_config(:max_buffer_size, 50)
  def event_history_size, do: 200

  # Mailbox pressure thresholds
  def mailbox_throttle_threshold do
    get_config(:mailbox_thresholds, %{})
    |> Map.get(:throttle, 500)
  end

  def mailbox_drop_threshold do
    get_config(:mailbox_thresholds, %{})
    |> Map.get(:drop, 1000)
  end

  # Block configuration
  def default_block_time_ms, do: 12_000
  def recent_blocks_limit, do: 20

  # Provider list limits
  def routing_events_limit, do: 200
  def provider_events_limit, do: 200

  # Performance thresholds
  def consistency_excellent, do: 2.0
  def consistency_good, do: 5.0
  # Above 5.0 is considered poor

  # Memory conversion
  def bytes_per_mb, do: 1_048_576

  defp get_config(key, default) do
    Application.get_env(:lasso, :dashboard, [])
    |> Keyword.get(key, default)
  end
end

defmodule LassoWeb.Dashboard.Status do
  @moduledoc """
  Single source of truth for provider status determination and styling.
  All status-related colors and logic in one place.
  """

  @type status :: :connected | :connecting | :disconnected | :failed | :degraded

  @doc """
  Get text color class for a given status.

  ## Examples

      iex> Status.text_color(:connected)
      "text-emerald-400"

      iex> Status.text_color(:failed)
      "text-rose-400"
  """
  def text_color(:connected), do: "text-emerald-400"
  def text_color(:connecting), do: "text-yellow-400"
  def text_color(:disconnected), do: "text-red-400"
  def text_color(:failed), do: "text-rose-400"
  def text_color(:degraded), do: "text-orange-400"
  def text_color(_), do: "text-gray-400"

  @doc """
  Get background color class for a given status.
  """
  def bg_color(:connected), do: "bg-emerald-500/20"
  def bg_color(:connecting), do: "bg-yellow-500/20"
  def bg_color(:disconnected), do: "bg-red-500/20"
  def bg_color(:failed), do: "bg-rose-500/20"
  def bg_color(:degraded), do: "bg-orange-500/20"
  def bg_color(_), do: "bg-gray-500/20"

  @doc """
  Get color class for consistency ratio.
  Lower is better (more consistent).

  ## Examples

      iex> Status.consistency_color(1.5)
      "text-emerald-400"

      iex> Status.consistency_color(3.0)
      "text-yellow-400"

      iex> Status.consistency_color(6.0)
      "text-red-400"
  """
  def consistency_color(ratio) when ratio < 2.0, do: "text-emerald-400"
  def consistency_color(ratio) when ratio < 5.0, do: "text-yellow-400"
  def consistency_color(_), do: "text-red-400"

  @doc """
  Get indicator dot classes for status (full opacity).
  """
  def indicator_class(status) do
    [
      "h-2 w-2 rounded-full",
      case status do
        :connected -> "bg-emerald-500"
        :connecting -> "bg-yellow-500"
        :disconnected -> "bg-red-500"
        :failed -> "bg-rose-500"
        :degraded -> "bg-orange-500"
        _ -> "bg-gray-500"
      end
    ]
  end

  @doc """
  Get human-readable status message.
  """
  def message(:connected), do: "Connected"
  def message(:connecting), do: "Connecting..."
  def message(:disconnected), do: "Disconnected"
  def message(:failed), do: "Failed"
  def message(:degraded), do: "Degraded Performance"
  def message(_), do: "Unknown"

  @doc """
  Determine provider status based on connection info and metrics.
  """
  def determine_status(%{status: :connected, metrics: metrics}) when is_map(metrics) do
    cond do
      failing?(metrics) -> :failed
      degraded?(metrics) -> :degraded
      true -> :connected
    end
  end

  def determine_status(%{status: status}) when status in [:connecting, :disconnected, :failed] do
    status
  end

  def determine_status(_), do: :disconnected

  # Private helpers

  defp degraded?(metrics) do
    success_rate = Map.get(metrics, :success_rate, 100)
    p95_latency = Map.get(metrics, :p95_latency, 0)

    success_rate < 95 or (p95_latency && p95_latency > 1000)
  end

  defp failing?(metrics) do
    success_rate = Map.get(metrics, :success_rate, 100)
    success_rate < 50
  end
end

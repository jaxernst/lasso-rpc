defmodule LassoWeb.Dashboard.Formatting do
  @moduledoc """
  Formatting and calculation helpers for the Dashboard UI.
  Provides number formatting, rounding, and visualization calculations.
  """

  @doc """
  Calculate bar width percentage for comparison visualization.

  ## Examples

      iex> providers = [%{avg_latency: 100}, %{avg_latency: 200}]
      iex> Formatting.calculate_bar_width(100, providers, :avg_latency)
      50.0
  """
  def calculate_bar_width(value, all_items, field) do
    max_value =
      all_items
      |> Enum.map(&Map.get(&1, field))
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> 1 end)

    if max_value > 0 do
      min(100, value / max_value * 100)
    else
      0
    end
  end

  @doc """
  Calculate bar width for method performance metrics.

  ## Examples

      iex> stats = [%{avg_latency: 50}, %{avg_latency: 100}]
      iex> Formatting.calculate_method_bar_width(50, stats)
      50.0
  """
  def calculate_method_bar_width(value, provider_stats) do
    max_value =
      provider_stats
      |> Enum.map(& &1.avg_latency)
      |> Enum.max(fn -> 1 end)

    if max_value > 0 do
      min(100, value / max_value * 100)
    else
      0
    end
  end

  @doc """
  Format numbers with comma separators for readability.

  ## Examples

      iex> Formatting.format_number(1000)
      "1,000"

      iex> Formatting.format_number(1234567)
      "1,234,567"
  """
  def format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def format_number(number), do: to_string(number)

  @doc """
  Safely round values handling integers, floats, and nil.

  ## Examples

      iex> Formatting.safe_round(1.567, 2)
      1.57

      iex> Formatting.safe_round(42, 2)
      42

      iex> Formatting.safe_round(nil, 2)
      nil
  """
  def safe_round(value, _precision) when is_integer(value), do: value
  def safe_round(value, precision) when is_float(value), do: Float.round(value, precision)
  def safe_round(nil, _precision), do: nil

  def format_latency(nil), do: "—"
  def format_latency(ms) when is_float(ms), do: "#{round(ms)}ms"
  def format_latency(ms), do: "#{ms}ms"

  def format_rps(rps) when rps == 0 or rps == 0.0, do: "0"
  def format_rps(rps), do: "#{rps}"

  def success_rate_color(nil), do: "text-gray-500"
  def success_rate_color(rate) when rate >= 99.0, do: "text-emerald-400"
  def success_rate_color(rate) when rate >= 95.0, do: "text-yellow-400"
  def success_rate_color(_), do: "text-red-400"
end

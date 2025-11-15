defmodule LassoWeb.Dashboard.Metrics.Calculations do
  @moduledoc """
  Pure statistical calculation functions for dashboard metrics.
  No side effects, easy to test.
  """

  @doc """
  Calculate 50th and 95th percentiles from a list of values.

  ## Examples

      iex> Calculations.percentile_pair([1, 2, 3, 4, 5])
      {3, 5}

      iex> Calculations.percentile_pair([])
      {nil, nil}
  """
  def percentile_pair([]), do: {nil, nil}

  def percentile_pair(values) when is_list(values) do
    sorted = Enum.sort(values)
    {percentile(sorted, 50), percentile(sorted, 95)}
  end

  @doc """
  Calculate a specific percentile from sorted values.

  ## Examples

      iex> Calculations.percentile([1, 2, 3, 4, 5], 50)
      3

      iex> Calculations.percentile([1, 2, 3, 4, 5], 95)
      5
  """
  def percentile([], _percentile), do: nil

  def percentile(sorted_values, percentile) when percentile >= 0 and percentile <= 100 do
    count = length(sorted_values)
    index = ceil(count * percentile / 100) - 1
    index = max(0, min(index, count - 1))
    Enum.at(sorted_values, index)
  end

  @doc """
  Calculate success rate as a percentage.

  ## Examples

      iex> events = [%{result: :success}, %{result: :error}, %{result: :success}]
      iex> Calculations.success_rate(events)
      66.7
  """
  def success_rate([]), do: nil

  def success_rate(events) when is_list(events) do
    successes = Enum.count(events, fn e -> e[:result] == :success end)
    Float.round(successes * 100.0 / length(events), 1)
  end

  @doc """
  Calculate coefficient of variation (measure of consistency).
  Lower values indicate more consistent performance.

  ## Examples

      iex> Calculations.coefficient_of_variation([10, 12, 11, 13, 9])
      0.14
  """
  def coefficient_of_variation([]), do: nil
  def coefficient_of_variation(values) when length(values) < 2, do: nil

  def coefficient_of_variation(values) when is_list(values) do
    mean = Enum.sum(values) / length(values)

    if mean == 0 do
      0.0
    else
      variance =
        values
        |> Enum.map(fn v -> :math.pow(v - mean, 2) end)
        |> Enum.sum()
        |> Kernel./(length(values))

      std_dev = :math.sqrt(variance)
      Float.round(std_dev / mean, 2)
    end
  end

  @doc """
  Calculate average of values.

  ## Examples

      iex> Calculations.average([1, 2, 3, 4, 5])
      3.0
  """
  def average([]), do: nil

  def average(values) when is_list(values) do
    Float.round(Enum.sum(values) / length(values), 2)
  end

  @doc """
  Calculate median of values.

  ## Examples

      iex> Calculations.median([1, 2, 3, 4, 5])
      3

      iex> Calculations.median([1, 2, 3, 4])
      2.5
  """
  def median([]), do: nil

  def median(values) when is_list(values) do
    sorted = Enum.sort(values)
    mid = div(length(sorted), 2)

    if rem(length(sorted), 2) == 0 do
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    else
      Enum.at(sorted, mid)
    end
  end
end

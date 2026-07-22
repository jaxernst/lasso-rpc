defmodule Lasso.RPC.StrategyContext do
  @moduledoc """
  Typed context passed to selection strategies after preparation.

  Contains common, strategy-agnostic fields. Individual strategies can
  populate optional fields during their `prepare_context/1` implementation.
  """

  alias Lasso.Core.Benchmarking.Metrics

  # Fallback latency when no provider data exists
  @default_fallback_latency_ms 500.0
  @max_fallback_latency_ms 10_000.0

  @enforce_keys [:chain_id, :now_ms, :timeout]
  defstruct [
    :chain_id,
    :now_ms,
    :timeout,
    # Optional fields populated by strategies
    :total_requests,
    :freshness_cutoff_ms,
    :min_calls,
    :min_success_rate,
    :cold_start_baseline
  ]

  @type t :: %__MODULE__{
          chain_id: pos_integer(),
          now_ms: integer(),
          timeout: non_neg_integer(),
          total_requests: non_neg_integer() | nil,
          freshness_cutoff_ms: non_neg_integer() | nil,
          min_calls: non_neg_integer() | nil,
          min_success_rate: float() | nil,
          cold_start_baseline: float() | nil
        }

  @doc """
  Builds the base strategy context.
  """
  @spec new(pos_integer(), non_neg_integer()) :: t()
  def new(chain_id, timeout) when is_integer(chain_id) and chain_id > 0 and is_integer(timeout) do
    %__MODULE__{
      chain_id: chain_id,
      now_ms: System.monotonic_time(:millisecond),
      timeout: timeout
    }
  end

  @doc """
  Calculates fallback latency for providers with no performance data.

  Returns the median latency of known providers for the method, or a default
  if no providers have data. This provides context-aware penalties rather than
  using a fixed value for all methods.
  """
  @spec calculate_fallback_latency(String.t(), pos_integer(), String.t()) :: float()
  def calculate_fallback_latency(profile, chain_id, method) do
    case get_valid_latencies(profile, chain_id, method) do
      [] -> @default_fallback_latency_ms
      latencies -> min(median(latencies), @max_fallback_latency_ms)
    end
  end

  # Private functions

  defp get_valid_latencies(profile, chain_id, method) do
    profile
    |> Metrics.get_method_performance(chain_id, method)
    |> Enum.map(& &1.performance.latency_ms)
    |> Enum.filter(&(is_number(&1) and &1 > 0))
    |> Enum.sort()
  end

  defp median(sorted_list) do
    mid = div(length(sorted_list), 2)

    if rem(length(sorted_list), 2) == 0 do
      (Enum.at(sorted_list, mid - 1) + Enum.at(sorted_list, mid)) / 2
    else
      Enum.at(sorted_list, mid)
    end
  end
end

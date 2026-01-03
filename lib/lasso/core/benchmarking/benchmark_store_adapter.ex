defmodule Lasso.RPC.Metrics.BenchmarkStore do
  @moduledoc """
  BenchmarkStore adapter implementing the Metrics behavior.

  Provides a bridge between the metrics abstraction and the existing
  BenchmarkStore implementation. All read operations are profile-scoped
  to ensure metrics isolation across routing profiles.
  """

  @behaviour Lasso.RPC.Metrics

  alias Lasso.Benchmarking.BenchmarkStore

  @impl true
  def get_provider_performance(profile, chain, provider_id, method) do
    case BenchmarkStore.get_rpc_performance(profile, chain, provider_id, method) do
      %{total_calls: 0} ->
        nil

      %{avg_latency: latency, success_rate: success_rate, total_calls: total_calls} ->
        confidence_score = calculate_confidence_score(total_calls, success_rate)

        %{
          latency_ms: latency,
          success_rate: success_rate,
          total_calls: total_calls,
          confidence_score: confidence_score
        }

      _ ->
        nil
    end
  end

  @impl true
  def get_method_performance(profile, chain, method) do
    case BenchmarkStore.get_rpc_method_performance(profile, chain, method) do
      %{providers: providers} when is_list(providers) ->
        providers
        |> Enum.filter(fn provider -> provider.total_calls > 0 end)
        |> Enum.map(fn provider ->
          confidence_score =
            calculate_confidence_score(provider.total_calls, provider.success_rate)

          %{
            provider_id: provider.provider_id,
            performance: %{
              latency_ms: provider.avg_duration_ms,
              success_rate: provider.success_rate,
              total_calls: provider.total_calls,
              confidence_score: confidence_score
            }
          }
        end)
        |> Enum.sort_by(fn %{performance: perf} ->
          # Sort by confidence-weighted performance score
          latency_score = if perf.latency_ms > 0, do: 1000 / perf.latency_ms, else: 0
          {-perf.confidence_score, -perf.success_rate, -latency_score}
        end)

      _ ->
        []
    end
  end

  @impl true
  def record_request(profile, chain, provider_id, method, duration_ms, result, opts) do
    transport = Keyword.get(opts, :transport, :http)

    method_key = "#{method}@#{transport}"

    # Timestamps are captured automatically inside record_rpc_call
    BenchmarkStore.record_rpc_call(
      profile,
      chain,
      provider_id,
      method_key,
      duration_ms,
      result
    )

    :ok
  end

  @impl true
  def get_provider_transport_performance(profile, chain, provider_id, method, transport) do
    method_key = "#{method}@#{transport}"

    case BenchmarkStore.get_rpc_performance(profile, chain, provider_id, method_key) do
      %{total_calls: 0} ->
        nil

      %{avg_latency: latency, success_rate: success_rate, total_calls: total_calls} ->
        %{
          latency_ms: latency,
          success_rate: success_rate,
          total_calls: total_calls,
          confidence_score: calculate_confidence_score(total_calls, success_rate)
        }

      _ ->
        nil
    end
  end

  @impl true
  def get_method_transport_performance(profile, chain, provider_id, method, transport) do
    # Get performance for the specific provider and transport
    case get_provider_transport_performance(profile, chain, provider_id, method, transport) do
      nil ->
        []

      perf ->
        [%{provider_id: provider_id, transport: transport, performance: perf}]
    end
  end

  # Private functions

  defp calculate_confidence_score(total_calls, success_rate) when total_calls > 0 do
    # Calculate confidence based on sample size and success rate
    # More calls = higher confidence, higher success rate = higher confidence
    # Log scale, max at 1000 calls
    sample_confidence = :math.log10(max(total_calls, 1)) / 3.0
    success_confidence = success_rate

    # Weighted average with slightly more weight on sample size
    (sample_confidence * 0.6 + success_confidence * 0.4)
    |> min(1.0)
    |> max(0.0)
  end

  defp calculate_confidence_score(0, _success_rate), do: 0.0
end

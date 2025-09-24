defmodule Livechain.RPC.Metrics do
  @moduledoc """
  Unified metrics abstraction for provider performance data.

  Provides clean producer/consumer interface that decouples strategy
  implementations from specific metrics storage backends. Supports
  async metrics recording to avoid impacting request path performance.
  """

  @type chain :: String.t()
  @type provider_id :: String.t()
  @type method :: String.t()
  @type result :: :success | :error

  @type performance_data :: %{
          latency_ms: float(),
          success_rate: float(),
          total_calls: non_neg_integer(),
          confidence_score: float()
        }

  @type recording_opts :: [
          timestamp: integer(),
          async: boolean()
        ]

  @doc """
  Gets performance data for a specific provider and method.

  Returns aggregated performance metrics with confidence scoring
  to help strategies make informed routing decisions.
  """
  @callback get_provider_performance(chain, provider_id, method) ::
              performance_data() | nil

  @doc """
  Gets performance comparison data for all providers supporting a method.

  Returns a list of performance data sorted by the backend's ranking algorithm.
  """
  @callback get_method_performance(chain, method) ::
              [%{provider_id: provider_id, performance: performance_data()}]

  @doc """
  Records a request performance metric asynchronously.

  This should not block the calling process and should handle
  any storage failures gracefully.
  """
  @callback record_request(chain, provider_id, method, non_neg_integer(), result, recording_opts) :: :ok

  @doc """
  Gets performance data using the configured metrics backend.
  """
  @spec get_provider_performance(chain, provider_id, method) :: performance_data() | nil
  def get_provider_performance(chain, provider_id, method) do
    backend().get_provider_performance(chain, provider_id, method)
  end

  @doc """
  Gets method performance comparison using the configured metrics backend.
  """
  @spec get_method_performance(chain, method) :: [%{provider_id: provider_id, performance: performance_data()}]
  def get_method_performance(chain, method) do
    backend().get_method_performance(chain, method)
  end

  @doc """
  Records a request metric asynchronously using the configured backend.

  Options:
  - `:async` - If false, records synchronously (default: true)
  - `:timestamp` - Custom timestamp (default: current time)
  """
  @spec record_request(chain, provider_id, method, non_neg_integer(), result, recording_opts) :: :ok
  def record_request(chain, provider_id, method, duration_ms, result, opts \\ []) do
    backend().record_request(chain, provider_id, method, duration_ms, result, opts)
  end

  @doc """
  Convenience function to record a successful request.
  """
  @spec record_success(chain, provider_id, method, non_neg_integer(), recording_opts) :: :ok
  def record_success(chain, provider_id, method, duration_ms, opts \\ []) do
    record_request(chain, provider_id, method, duration_ms, :success, opts)
  end

  @doc """
  Convenience function to record a failed request.
  """
  @spec record_failure(chain, provider_id, method, non_neg_integer(), recording_opts) :: :ok
  def record_failure(chain, provider_id, method, duration_ms, opts \\ []) do
    record_request(chain, provider_id, method, duration_ms, :error, opts)
  end

  # Private functions

  defp backend do
    Application.get_env(:livechain, :metrics_backend, Livechain.RPC.Metrics.BenchmarkStore)
  end
end
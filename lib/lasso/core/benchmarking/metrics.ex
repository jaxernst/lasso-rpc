defmodule Lasso.RPC.Metrics do
  @moduledoc """
  Unified metrics abstraction for provider performance data.

  Provides clean producer/consumer interface that decouples strategy
  implementations from specific metrics storage backends. Supports
  async metrics recording to avoid impacting request path performance.

  All read operations require a profile parameter to ensure metrics
  are scoped to the appropriate routing profile context.
  """

  @type profile :: String.t()
  @type chain :: String.t()
  @type provider_id :: String.t()
  @type method :: String.t()
  @type result :: :success | :error

  @type performance_data :: %{
          latency_ms: float(),
          success_rate: float(),
          total_calls: non_neg_integer(),
          confidence_score: float(),
          last_updated_ms: integer()
        }

  @type recording_opts :: [
          timestamp: integer(),
          async: boolean(),
          transport: :http | :ws | nil
        ]

  @doc """
  Gets performance data for a specific provider and method.

  Returns aggregated performance metrics with confidence scoring
  to help strategies make informed routing decisions.
  """
  @callback get_provider_performance(profile, chain, provider_id, method) ::
              performance_data() | nil

  @doc """
  Gets performance data for a specific provider and method and transport.

  Returns aggregated performance metrics with confidence scoring
  to help strategies make informed routing decisions.
  """
  @callback get_provider_transport_performance(profile, chain, provider_id, method, :http | :ws) ::
              performance_data() | nil

  @doc """
  Gets performance comparison data for all providers supporting a method.

  Returns a list of performance data sorted by the backend's ranking algorithm.
  """
  @callback get_method_performance(profile, chain, method) ::
              [%{provider_id: provider_id, performance: performance_data()}]

  @doc """
  Gets performance data for a specific method and transport.

  Returns a list of performance data sorted by the backend's ranking algorithm.
  """
  @callback get_method_transport_performance(profile, chain, provider_id, method, :http | :ws) ::
              [
                %{
                  provider_id: provider_id,
                  transport: :http | :ws,
                  performance: performance_data()
                }
              ]

  @doc """
  Records a request performance metric asynchronously.

  This should not block the calling process and should handle
  any storage failures gracefully.
  """
  @callback record_request(String.t(), chain, provider_id, method, non_neg_integer(), result, recording_opts) ::
              :ok

  @doc """
  Batch fetches performance data for multiple provider/method/transport combinations.

  This is an optimized path that can fetch multiple metrics in a single operation,
  avoiding N sequential calls. Returns a map keyed by the request tuple.
  """
  @callback batch_get_transport_performance(profile, chain, [{provider_id, method, :http | :ws}]) ::
              %{{provider_id, method, :http | :ws} => performance_data() | nil}

  @doc """
  Gets performance data using the configured metrics backend.
  """
  @spec get_provider_performance(profile, chain, provider_id, method) :: performance_data() | nil
  def get_provider_performance(profile, chain, provider_id, method) do
    backend().get_provider_performance(profile, chain, provider_id, method)
  end

  @doc """
  Gets performance data for a specific provider, method, and transport.
  """
  @spec get_provider_transport_performance(profile, chain, provider_id, method, :http | :ws) ::
          performance_data() | nil
  def get_provider_transport_performance(profile, chain, provider_id, method, transport) do
    backend().get_provider_transport_performance(profile, chain, provider_id, method, transport)
  end

  @doc """
  Gets method performance comparison using the configured metrics backend.
  """
  @spec get_method_performance(profile, chain, method) :: [
          %{provider_id: provider_id, performance: performance_data()}
        ]
  def get_method_performance(profile, chain, method) do
    backend().get_method_performance(profile, chain, method)
  end

  @doc """
  Gets method performance comparison across all transports.

  Returns performance data with transport dimension included.
  """
  @spec get_method_transport_performance(profile, chain, provider_id, method, :http | :ws) :: [
          %{provider_id: provider_id, transport: :http | :ws, performance: performance_data()}
        ]
  def get_method_transport_performance(profile, chain, provider_id, method, transport) do
    backend().get_method_transport_performance(profile, chain, provider_id, method, transport)
  end

  @doc """
  Records a request metric asynchronously using the configured backend.

  Options:
  - `:async` - If false, records synchronously (default: true)
  - `:timestamp` - Custom timestamp (default: current time)
  """
  @spec record_request(String.t(), chain, provider_id, method, non_neg_integer(), result, recording_opts) ::
          :ok
  def record_request(profile, chain, provider_id, method, duration_ms, result, opts \\ []) do
    backend().record_request(profile, chain, provider_id, method, duration_ms, result, opts)
  end

  @doc """
  Convenience function to record a successful request.
  """
  @spec record_success(String.t(), chain, provider_id, method, non_neg_integer(), recording_opts) :: :ok
  def record_success(profile, chain, provider_id, method, duration_ms, opts \\ []) do
    record_request(profile, chain, provider_id, method, duration_ms, :success, opts)
  end

  @doc """
  Convenience function to record a failed request.
  """
  @spec record_failure(String.t(), chain, provider_id, method, non_neg_integer(), recording_opts) :: :ok
  def record_failure(profile, chain, provider_id, method, duration_ms, opts \\ []) do
    record_request(profile, chain, provider_id, method, duration_ms, :error, opts)
  end

  @doc """
  Batch fetches performance data for multiple provider/method/transport combinations.

  Returns a map keyed by {provider_id, method, transport} tuples.
  """
  @spec batch_get_transport_performance(profile, chain, [{provider_id, method, :http | :ws}]) ::
          %{{provider_id, method, :http | :ws} => performance_data() | nil}
  def batch_get_transport_performance(profile, chain, requests) do
    backend().batch_get_transport_performance(profile, chain, requests)
  end

  # Private functions

  defp backend do
    Application.get_env(:lasso, :metrics_backend, Lasso.RPC.Metrics.BenchmarkStore)
  end
end

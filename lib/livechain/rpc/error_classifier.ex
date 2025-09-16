defmodule Livechain.RPC.ErrorClassifier do
  @moduledoc """
  Centralizes error classification logic for RPC operations.

  Distinguishes between:
  - Infrastructure/provider failures (should trigger circuit breaker & failover)
  - User/client errors (should not affect provider health)

  Used by both CircuitBreaker and Failover modules to ensure consistent behavior.
  """

  @doc """
  Classifies an error reason as either infrastructure failure or user error.

  ## Examples

      iex> ErrorClassifier.classify_error({:server_error, "500 Internal Server Error"})
      :infrastructure_failure

      iex> ErrorClassifier.classify_error({:client_error, "400 Bad Request"})
      :user_error

      iex> ErrorClassifier.classify_error(:circuit_open)
      :infrastructure_failure
  """
  @spec classify_error(any()) :: :infrastructure_failure | :user_error
  def classify_error(reason) do
    case reason do
      %Livechain.JSONRPC.Error{retriable?: true} ->
        :infrastructure_failure

      %Livechain.JSONRPC.Error{retriable?: false} ->
        :user_error

      # === HTTP Client Errors (from Livechain.RPC.HttpClient.Finch) ===
      {:rate_limit, _} ->
        :infrastructure_failure

      {:server_error, _} ->
        :infrastructure_failure

      {:network_error, _} ->
        :infrastructure_failure

      # 4xx errors are user errors
      {:client_error, _} ->
        :user_error

      # JSON parse errors are user errors
      {:decode_error, _} ->
        :user_error

      # === Circuit Breaker States ===
      :circuit_open ->
        :infrastructure_failure

      :circuit_opening ->
        :infrastructure_failure

      :circuit_reopening ->
        :infrastructure_failure

      {:circuit_breaker, _} ->
        :infrastructure_failure

      # === Common Network/Connection Errors ===
      :timeout ->
        :infrastructure_failure

      :econnrefused ->
        :infrastructure_failure

      :nxdomain ->
        :infrastructure_failure

      {:timeout, _} ->
        :infrastructure_failure

      {:connection_error, _} ->
        :infrastructure_failure

      # === Circuit Breaker Internal Errors ===
      # Used by record_failure/1
      :failure ->
        :infrastructure_failure

      # === JSON-RPC Error Responses ===
      %{"code" => code} when is_integer(code) ->
        classify_jsonrpc_error(code)

      # === Fallback: Unknown errors are treated as infrastructure failures ===
      # This is the safe default - better to fail over than leave a bad provider active
      _ ->
        :infrastructure_failure
    end
  end

  @doc """
  Checks if an error should trigger failover (same as infrastructure failure).
  Provided for API compatibility with existing Failover module.
  """
  @spec should_failover?(any()) :: boolean()
  def should_failover?(reason) do
    classify_error(reason) == :infrastructure_failure
  end

  # JSON-RPC 2.0 error codes classification
  defp classify_jsonrpc_error(code) do
    case code do
      # Standard JSON-RPC 2.0 errors are user errors
      code when code in [-32700, -32600, -32601, -32602, -32603] -> :user_error
      # Provider rate limiting patterns - infrastructure failures
      code when code in [-32005, -32429] -> :infrastructure_failure
      # Conservative default: treat unknown JSON-RPC codes as user errors
      # Providers should use HTTP status codes for infrastructure issues
      _ -> :user_error
    end
  end
end

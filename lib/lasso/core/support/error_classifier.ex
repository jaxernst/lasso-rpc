defmodule Lasso.RPC.ErrorClassifier do
  @moduledoc """
  Unified error classification and normalization for RPC operations.

  Provides consistent error categorization and JError normalization across
  all transport layers and components. Single source of truth for error
  classification used by CircuitBreaker, HealthPolicy, and Failover.
  """

  alias Lasso.JSONRPC.Error, as: JError

  @type context :: %{
          optional(:transport) => :http | :ws,
          optional(:provider_id) => String.t(),
          optional(:method) => String.t()
        }

  @doc """
  Normalizes any error into a properly categorized JError.

  Delegates to the centralized ErrorNormalizer for consistency.
  """
  @spec normalize_error(any(), context()) :: JError.t()
  def normalize_error(error, context \\ %{}) do
    # Convert context map to keyword list for ErrorNormalizer
    opts =
      context
      |> Map.take([:provider_id, :transport, :method])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Keyword.new()
      |> Keyword.put(:context, context)

    Lasso.RPC.ErrorNormalizer.normalize(error, opts)
  end

  @doc """
  Legacy classification function for backwards compatibility.

  Use normalize_error/2 for new code.
  """
  @spec classify_error(any()) :: :infrastructure_failure | :user_error
  def classify_error(reason) do
    case reason do
      %Lasso.JSONRPC.Error{retriable?: true} ->
        :infrastructure_failure

      %Lasso.JSONRPC.Error{retriable?: false} ->
        :user_error

      # === HTTP Client Errors (from Lasso.RPC.HttpClient.Finch) ===
      {:rate_limit, _} ->
        :infrastructure_failure

      {:server_error, _} ->
        :infrastructure_failure

      {:network_error, _} ->
        :infrastructure_failure

      # 4xx errors are user errors
      {:client_error, _} ->
        :user_error

      # Response decode errors indicate provider/infra problems
      {:response_decode_error, _} ->
        :infrastructure_failure

      # Request encode errors are user/client-side
      {:encode_error, _} ->
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
      # Standard JSON-RPC 2.0 errors
      # -32700 (parse), -32600, -32601, -32602 are client-side/user errors
      code when code in [-32700, -32600, -32601, -32602] -> :user_error
      # -32603 (internal error) is a server-side retriable/infrastructure failure
      -32603 -> :infrastructure_failure
      # Provider rate limiting patterns - infrastructure failures
      code when code in [-32005, -32429] -> :infrastructure_failure
      # Conservative default: treat unknown JSON-RPC codes as user errors
      # Providers should use HTTP status codes for infrastructure issues
      _ -> :user_error
    end
  end
end

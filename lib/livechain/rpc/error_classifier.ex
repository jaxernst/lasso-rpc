defmodule Livechain.RPC.ErrorClassifier do
  @moduledoc """
  Unified error classification and normalization for RPC operations.

  Provides consistent error categorization and JError normalization across
  all transport layers and components. Single source of truth for error
  classification used by CircuitBreaker, HealthPolicy, and Failover.
  """

  alias Livechain.JSONRPC.Error, as: JError

  @type context :: %{
          optional(:transport) => :http | :ws,
          optional(:provider_id) => String.t(),
          optional(:method) => String.t()
        }

  @doc """
  Normalizes any error into a properly categorized JError.

  This is the single entry point for all error normalization across
  transport layers, ensuring consistent categorization and retriability.
  """
  @spec normalize_error(any(), context()) :: JError.t()
  def normalize_error(error, context \\ %{})

  def normalize_error(%JError{} = error, _context), do: error

  def normalize_error(error, context) do
    classification = classify_error(error)
    provider_id = Map.get(context, :provider_id, "unknown")
    transport = Map.get(context, :transport)

    case error do
      {:rate_limit, payload} ->
        JError.new(-32001, "Rate limited by provider",
          data: payload,
          provider_id: provider_id,
          source: :transport,
          transport: transport,
          category: :rate_limit,
          retriable?: true
        )

      {:server_error, payload} ->
        JError.new(-32002, "Server error",
          data: payload,
          provider_id: provider_id,
          source: :transport,
          transport: transport,
          category: :server_error,
          retriable?: true
        )

      {:client_error, payload} ->
        JError.new(-32003, "Client error",
          data: payload,
          provider_id: provider_id,
          source: :transport,
          transport: transport,
          category: :client_error,
          retriable?: false
        )

      {:network_error, reason} ->
        JError.new(-32004, "Network error: #{reason}",
          provider_id: provider_id,
          source: :transport,
          transport: transport,
          category: :network_error,
          retriable?: true
        )

      :circuit_open ->
        JError.new(-32010, "Circuit breaker open",
          provider_id: provider_id,
          source: :infrastructure,
          transport: transport,
          category: :circuit_open,
          retriable?: true
        )

      :timeout ->
        JError.new(-32011, "Request timeout",
          provider_id: provider_id,
          source: :infrastructure,
          transport: transport,
          category: :timeout,
          retriable?: true
        )

      other ->
        retriable? = classification == :infrastructure_failure
        category = if retriable?, do: :infrastructure_error, else: :user_error

        JError.new(-32000, "Unclassified error: #{inspect(other)}",
          data: other,
          provider_id: provider_id,
          source: :infrastructure,
          transport: transport,
          category: category,
          retriable?: retriable?
        )
    end
  end

  @doc """
  Legacy classification function for backwards compatibility.

  Use normalize_error/2 for new code.
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

defmodule Lasso.RPC.ErrorClassification do
  @moduledoc """
  Pure functions for error categorization, retriability assessment, and penalty determination.

  This module encapsulates all business rules for classifying errors from various sources
  (JSON-RPC responses, transport layers, providers). Used by ErrorNormalizer to populate
  JError struct fields.

  ## Classification Strategy

  1. Message-based patterns (highest priority) - detects rate limits, auth, capabilities
  2. Code-based classification (fallback) - standard JSON-RPC, HTTP, EIP-1193 codes
  """

  # ===========================================================================
  # JSON-RPC 2.0 Standard Error Codes
  # ===========================================================================

  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  # Server error range: -32_000 to -32_099 (reserved by spec)

  # ===========================================================================
  # Lasso Custom Error Codes (within server error range)
  # ===========================================================================

  @generic_server_error -32_000
  @rate_limit_error -32_005
  @network_error_code -32_004
  @client_error_code -32_003
  @server_error_code -32_002

  # ===========================================================================
  # Provider-Specific Error Codes
  # ===========================================================================

  # PublicNode uses -32_701 for capability violations (e.g., address requirements)
  @publicnode_capability_violation -32_701

  # ===========================================================================
  # EIP-1193 Provider Error Codes
  # ===========================================================================

  @user_rejected 4001
  @unauthorized 4100
  @unsupported_method 4200
  @unsupported_chain 4900
  @chain_disconnected 4901

  # ===========================================================================
  # Message Pattern Matching
  # ===========================================================================

  @rate_limit_patterns [
    "rate limit",
    "too many requests",
    "throttled",
    "quota exceeded",
    "capacity exceeded",
    "request count exceeded",
    "maximum requests",
    "credits quota",
    "requests per second",
    # Cloudflare capacity/rate limiting (-32046)
    "cannot fulfill request"
  ]

  @auth_patterns [
    "unauthorized",
    "authentication",
    "authenticate",
    "api key",
    "forbidden",
    "access denied",
    "permission denied"
  ]

  @capability_violation_patterns [
    "free tier",
    # Address/query limits
    "specify less number of addresses",
    "less number of addresses",
    "maximum number of addresses",
    "max addresses",
    "too many addresses",
    "specify an address",
    # Block range constraints
    "max block range",
    "block range too large",
    "range too large",
    "exceeds maximum block range",
    "invalid block range",
    "max is 1k blocks",
    "range is too large",
    # Archival/historical data
    "archive node required",
    "requires archival",
    "archival data not available",
    "historical data not supported",
    # Feature availability
    "tracing not enabled",
    "debug not available",
    "trace not supported",
    "method not available",
    # Result size limits
    "unsupported parameter range",
    "unsupported param range",
    "limit exceeded for this method",
    "result set too large",
    "query returned more than",
    "too many results",
    "exceeds limit",
    "limit reached",
    # Provider-specific limitations
    "dedicated full node",
    "remove restrictions",
    "order a dedicated",
    "upgrade",
    "premium plan",
    "paid plan"
  ]

  # ===========================================================================
  # Public API
  # ===========================================================================

  @doc """
  Categorizes an error into a semantic category.

  Message-based classification takes priority over code-based classification,
  allowing detection of capability violations, rate limits, and auth errors
  that providers encode inconsistently.

  ## Examples

      iex> categorize(-32_000, "block range too large")
      :capability_violation

      iex> categorize(-32_602, nil)
      :invalid_params

      iex> categorize(429, "rate limit exceeded")
      :rate_limit
  """
  @spec categorize(integer(), String.t() | nil) :: atom()
  def categorize(code, message)

  def categorize(code, message) when is_binary(message) do
    message
    |> String.downcase()
    |> classify_by_message()
    |> case do
      nil -> classify_by_code(code)
      category -> category
    end
  end

  def categorize(code, _message), do: classify_by_code(code)

  @doc """
  Determines if an error should trigger failover to another provider.

  Retriable errors include:
  - Rate limits (temporary backpressure)
  - Network errors (transient connectivity)
  - Server errors (provider-side issues)
  - Capability violations (try a different provider)

  Non-retriable errors include:
  - Invalid requests (bad client input)
  - Method not found (API mismatch)
  - Invalid params (client error)
  """
  @spec retriable?(integer(), String.t() | nil) :: boolean()
  def retriable?(code, message)

  def retriable?(code, message) when is_binary(message) do
    message
    |> String.downcase()
    |> classify_by_message()
    |> case do
      nil -> retriable_by_code?(code)
      :rate_limit -> true
      :auth_error -> true
      :capability_violation -> true
    end
  end

  def retriable?(code, _message), do: retriable_by_code?(code)

  @doc """
  Determines if an error should count against circuit breaker failure threshold.

  Capability violations are retriable but should NOT penalize the provider's
  circuit breaker, as they represent permanent constraints, not transient failures.
  """
  @spec breaker_penalty?(atom()) :: boolean()
  def breaker_penalty?(:capability_violation), do: false
  def breaker_penalty?(_category), do: true

  # ===========================================================================
  # Private: Message-Based Classification
  # ===========================================================================

  defp classify_by_message(message_lower) do
    cond do
      contains_any?(message_lower, @rate_limit_patterns) -> :rate_limit
      contains_any?(message_lower, @auth_patterns) -> :auth_error
      contains_any?(message_lower, @capability_violation_patterns) -> :capability_violation
      true -> nil
    end
  end

  defp contains_any?(message, patterns) do
    Enum.any?(patterns, &String.contains?(message, &1))
  end

  # ===========================================================================
  # Private: Code-Based Classification
  # ===========================================================================

  defp classify_by_code(code) do
    cond do
      # Standard JSON-RPC 2.0 errors
      code == @parse_error -> :parse_error
      code == @invalid_request -> :invalid_request
      code == @method_not_found -> :method_not_found
      code == @invalid_params -> :invalid_params
      code == @internal_error -> :internal_error
      # Lasso custom error codes
      code == @rate_limit_error -> :rate_limit
      code == @network_error_code -> :network_error
      code == @client_error_code -> :client_error
      code == @server_error_code -> :server_error
      code == @generic_server_error -> :server_error
      # Provider-specific error codes (check before general server error range)
      code == @publicnode_capability_violation -> :capability_violation
      # JSON-RPC server error range
      code >= -32_099 and code <= -32_000 -> :server_error
      # EIP-1193 provider errors
      code == @user_rejected -> :user_error
      code == @unauthorized -> :auth_error
      code == @unsupported_method -> :method_error
      code == @unsupported_chain -> :chain_error
      code == @chain_disconnected -> :network_error
      # HTTP status codes
      code == 429 -> :rate_limit
      code >= 500 and code <= 599 -> :server_error
      code >= 400 and code <= 499 -> :client_error
      # Unknown codes
      true -> :unknown_error
    end
  end

  defp retriable_by_code?(code) do
    cond do
      # Non-retriable: client/user errors (bad input)
      code in [@invalid_request, @method_not_found, @invalid_params] -> false
      code in [@user_rejected, @unauthorized] -> false
      # Retriable: server/network/transient errors (check before 4xx range)
      code in [@parse_error, @internal_error, @rate_limit_error] -> true
      code in [@chain_disconnected, @network_error_code] -> true
      # Retriable: provider-specific capability violations
      code == @publicnode_capability_violation -> true
      code >= -32_099 and code <= -32_000 -> true
      code == 429 -> true
      code >= 500 -> true
      # Non-retriable 4xx range (after checking 429)
      code >= 400 and code < 500 -> false
      # Conservative default: non-retriable
      true -> false
    end
  end
end

defmodule Lasso.Core.Support.ErrorClassification do
  @moduledoc """
  Pure functions for error categorization, retriability assessment, and penalty determination.

  This module encapsulates all business rules for classifying errors from various sources
  (JSON-RPC responses, transport layers, providers). Used by ErrorNormalizer to populate
  JError struct fields.

  ## Classification Strategy

  1. Message-based patterns (highest priority) - detects rate limits, auth, capabilities
  2. Code-based classification (fallback) - standard JSON-RPC, HTTP, EIP-1193 codes

  ## Error Categories

  The following categories are used throughout the system. Each category determines
  both retriability (failover behavior) and circuit breaker penalty semantics.

  **Retriable categories** (trigger failover to another provider):
  - `:rate_limit` - Provider rate limiting / quota exceeded (temporary backpressure)
  - `:network_error` - Network/connectivity issues (transient failures)
  - `:server_error` - Provider-side server errors (5xx, provider crashes)
  - `:capability_violation` - Provider lacks capability for this request (try different provider)
  - `:method_not_found` - Method not supported by this provider (try different provider)
  - `:method_error` - Method-level error that another provider might handle
  - `:auth_error` - Authentication/authorization failure (credentials may work on different provider)
  - `:internal_error` - Provider internal error (JSON-RPC -32603)
  - `:chain_error` - Chain-level error (e.g., unsupported chain)

  **Non-retriable categories** (user/client errors, no failover):
  - `:invalid_request` - Malformed JSON-RPC request
  - `:invalid_params` - Invalid method parameters
  - `:parse_error` - JSON parsing failure
  - `:user_error` - User rejected transaction (EIP-1193)
  - `:client_error` - Generic client error (4xx)

  **Special categories**:
  - `:provider_error` - Infrastructure-level provider unavailability (no channels, pool errors)
  - `:timeout` - Request timeout
  - `:unknown_error` - Unclassified error (fallback category)

  **Circuit breaker penalty**:
  - All categories count against circuit breaker EXCEPT `:capability_violation`
  - Capability violations represent permanent constraints, not transient failures
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
    "requests per second"
  ]

  # Patterns indicating transient/retriable server errors
  # These are provider-specific errors that should trigger failover
  @transient_error_patterns [
    # DRPC error code 19: "Temporary internal error. Please retry"
    "please retry",
    "temporary internal error",
    "try again",
    "service temporarily unavailable",
    "temporarily unavailable"
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

  @result_size_violation_patterns [
    # Provider-specific result size limits (retriable on premium providers)
    "query returned more than",
    "result set too large",
    "result limit exceeded",
    "too many results",
    "too many logs"
  ]

  @capability_violation_patterns [
    "free tier",
    # Address/query limits
    "maximum number of addresses",
    "max addresses",
    "too many addresses",
    # PublicNode
    "specify less number of addresses",
    # PublicNode
    "specify an address",
    # Block range constraints
    "block range exceeded",
    "max block range",
    "block range too large",
    "range too large",
    "range not supported",
    # PublicNode
    "this range of parameters is not supported",
    "exceeds maximum block range",
    "invalid block range",
    "max is 1k blocks",
    "range is too large",
    "blocks are not supported",
    # DRPC
    "ranges over",
    # 1RPC
    "is limited to",
    # Archival/historical data
    "archive node required",
    "requires archival",
    "archival data not available",
    "archival not available",
    "historical data not supported",
    "pruned",
    # Geth pruned data
    "missing trie node",
    # Feature availability
    "tracing not enabled",
    "debug not available",
    "trace not supported",
    "method not available",
    "method unavailable",
    "not supported",
    "not available",
    "not enabled",
    "does not support",
    # Parameter range limits (provider-specific)
    "unsupported parameter range",
    "unsupported param range",
    "limit exceeded for this method",
    "exceeds limit",
    "exceeds maximum",
    "limit reached",
    # Tier/plan restrictions
    "dedicated full node",
    "remove restrictions",
    "order a dedicated",
    "upgrade",
    "upgrade your plan",
    "upgrade your tier",
    "premium plan",
    "paid plan",
    "paid tier",
    # DRPC
    "timeout on the free tier",
    "feature not enabled"
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
      category -> retriable_for_category?(category)
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

  @doc """
  Determines if an error category should trigger failover to another provider.

  Retriable errors include:
  - Rate limits (temporary backpressure)
  - Network errors (transient connectivity)
  - Server errors (provider-side issues)
  - Capability violations (try a provider with different capabilities)
  - Method not found (try a provider that supports the method)
  - Auth errors (this provider's credentials failed, another might work)
  - Internal errors (provider-side crashes)

  Non-retriable errors include:
  - Invalid requests (bad client input)
  - Invalid params (malformed parameters)
  - Parse errors (malformed JSON)
  - User errors (user rejected transaction in wallet)
  - Client errors (generic 4xx errors indicating client fault)

  ## Examples

      iex> retriable_for_category?(:rate_limit)
      true

      iex> retriable_for_category?(:invalid_params)
      false

      iex> retriable_for_category?(:method_not_found)
      true  # Another provider might support this method
  """
  @spec retriable_for_category?(atom()) :: boolean()
  def retriable_for_category?(:rate_limit), do: true
  def retriable_for_category?(:network_error), do: true
  def retriable_for_category?(:server_error), do: true
  def retriable_for_category?(:auth_error), do: true
  def retriable_for_category?(:capability_violation), do: true
  def retriable_for_category?(:method_not_found), do: true
  def retriable_for_category?(:method_error), do: true
  def retriable_for_category?(:internal_error), do: true
  def retriable_for_category?(:chain_error), do: true
  def retriable_for_category?(:invalid_request), do: false
  def retriable_for_category?(:invalid_params), do: false
  def retriable_for_category?(:parse_error), do: false
  def retriable_for_category?(:user_error), do: false
  def retriable_for_category?(:client_error), do: false
  def retriable_for_category?(_category), do: false

  # ===========================================================================
  # Private: Message-Based Classification
  # ===========================================================================

  defp classify_by_message(message_lower) do
    cond do
      # Rate limits checked first (highest priority)
      contains_any?(message_lower, @rate_limit_patterns) -> :rate_limit
      # Auth errors
      contains_any?(message_lower, @auth_patterns) -> :auth_error
      # Transient/retriable server errors (check before capability violations)
      # Patterns like "please retry" indicate the provider wants a retry
      contains_any?(message_lower, @transient_error_patterns) -> :server_error
      # Result size violations are provider-specific capabilities, not client errors
      # Different providers have different limits (10k free tier, 100k+ premium)
      contains_any?(message_lower, @result_size_violation_patterns) -> :capability_violation
      # Other capability constraints
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

  # Group related codes for efficient compile-time matching
  @jsonrpc_standard_codes [@parse_error, @invalid_request, @method_not_found,
                            @invalid_params, @internal_error]
  @lasso_custom_codes [@rate_limit_error, @network_error_code, @client_error_code,
                       @server_error_code, @generic_server_error]
  @eip1193_codes [@user_rejected, @unauthorized, @unsupported_method,
                  @unsupported_chain, @chain_disconnected]

  defp classify_by_code(code) do
    cond do
      code in @jsonrpc_standard_codes -> classify_jsonrpc_standard(code)
      code in @lasso_custom_codes -> classify_lasso_error(code)
      code in @eip1193_codes -> classify_eip1193_error(code)
      jsonrpc_server_range?(code) -> :server_error
      http_status_code?(code) -> classify_http_status(code)
      true -> :unknown_error
    end
  end

  defp jsonrpc_server_range?(code), do: code >= -32_099 and code <= -32_000
  defp http_status_code?(code), do: code >= 400 and code <= 599

  defp classify_jsonrpc_standard(code) do
    case code do
      @parse_error -> :parse_error
      @invalid_request -> :invalid_request
      @method_not_found -> :method_not_found
      @invalid_params -> :invalid_params
      @internal_error -> :internal_error
    end
  end

  defp classify_lasso_error(code) do
    case code do
      @rate_limit_error -> :rate_limit
      @network_error_code -> :network_error
      @client_error_code -> :client_error
      @server_error_code -> :server_error
      @generic_server_error -> :server_error
    end
  end

  defp classify_eip1193_error(code) do
    case code do
      @user_rejected -> :user_error
      @unauthorized -> :auth_error
      @unsupported_method -> :method_error
      @unsupported_chain -> :chain_error
      @chain_disconnected -> :network_error
    end
  end

  defp classify_http_status(code) do
    cond do
      code == 429 -> :rate_limit
      code >= 500 -> :server_error
      true -> :client_error
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

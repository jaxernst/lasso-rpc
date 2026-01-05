defmodule Lasso.Core.Support.ErrorNormalizer do
  @moduledoc """
  Centralized error normalization for consistent error handling across the system.

  Provides a single entry point to normalize errors from different sources (transport,
  providers, health checks) into standardized JError structures with consistent
  categorization and retry semantics.

  All categorization logic is delegated to ErrorClassification for maintainability.
  """

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Core.Support.ErrorClassifier

  @type context :: :health_check | :live_traffic | :transport | :jsonrpc
  @type transport :: :http | :ws | nil

  @doc """
  Normalizes any error into a standardized JError structure.

  ## Parameters
    - `error`: The error to normalize (can be any term)
    - `opts`: Options including :provider_id, :context, :transport

  ## Examples

      iex> normalize({:rate_limit, %{}}, provider_id: "test", context: :transport)
      %JError{category: :rate_limit, retriable?: true, breaker_penalty?: false}

      iex> normalize(%{"error" => %{"code" => -32_000, "message" => "block range too large"}}, provider_id: "test")
      %JError{category: :capability_violation, retriable?: true, breaker_penalty?: false}
  """
  @spec normalize(any(), keyword()) :: JError.t()
  def normalize(error, opts \\ [])

  # Already normalized JError - just add missing context if needed
  def normalize(%JError{} = jerr, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    transport = Keyword.get(opts, :transport)

    jerr
    |> maybe_add_provider_id(provider_id)
    |> maybe_add_transport(transport)
  end

  # JSON-RPC error response - most common case
  def normalize(%{"error" => error} = _response, opts) when is_map(error) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :jsonrpc)
    transport = Keyword.get(opts, :transport)

    raw_code = Map.get(error, "code", -32_000)
    message = Map.get(error, "message", "Unknown error")
    raw_data = Map.get(error, "data")

    # Normalize HTTP status codes to JSON-RPC error codes
    code = normalize_code(raw_code)

    # Unified classification with adapter priority
    %{category: category, retriable?: retriable?, breaker_penalty?: breaker_penalty?} =
      ErrorClassifier.classify(code, message, provider_id: provider_id)

    # Extract retry-after hint if this is a rate limit error
    data =
      if category == :rate_limit do
        add_retry_after(raw_data, error)
      else
        raw_data
      end

    JError.new(code, message,
      data: data,
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: category,
      retriable?: retriable?,
      breaker_penalty?: breaker_penalty?,
      original_code: raw_code
    )
  end

  # Rate limiting errors
  def normalize({:rate_limit, payload}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    # Extract retry-after hint from payload and add to data
    data = add_retry_after(payload, payload)

    JError.new(-32_005, "Rate limited by provider",
      data: data,
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :rate_limit,
      retriable?: true,
      # Rate limits are temporary backpressure, not failures - don't trip circuit breaker
      breaker_penalty?: false
    )
  end

  # Network errors
  def normalize({:network_error, reason}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    JError.new(-32_004, "Network error: #{inspect(reason)}",
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :network_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  # Server errors (5xx HTTP, provider issues)
  def normalize({:server_error, payload}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    # Try to extract nested JSON-RPC error from response body for better classification
    {code, message} = extract_nested_error(payload, -32_002, "Server error")

    # Unified classification with adapter priority
    %{category: category, retriable?: retriable?, breaker_penalty?: breaker_penalty?} =
      ErrorClassifier.classify(code, message, provider_id: provider_id)

    # Extract retry-after hint if this is a rate limit error
    data =
      if category == :rate_limit do
        add_retry_after(payload, payload)
      else
        payload
      end

    JError.new(code, message,
      data: data,
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: category,
      retriable?: retriable?,
      breaker_penalty?: breaker_penalty?,
      original_code: code
    )
  end

  # Client errors (4xx HTTP, bad requests)
  def normalize({:client_error, payload}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    # Try to extract nested JSON-RPC error from response body for better classification
    {code, message} = extract_nested_error(payload, -32_003, "Client error")

    # Unified classification with adapter priority
    %{category: category, retriable?: retriable?, breaker_penalty?: breaker_penalty?} =
      ErrorClassifier.classify(code, message, provider_id: provider_id)

    # Extract retry-after hint if this is a rate limit error (e.g., 429)
    data =
      if category == :rate_limit do
        add_retry_after(payload, payload)
      else
        payload
      end

    JError.new(code, message,
      data: data,
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: category,
      retriable?: retriable?,
      breaker_penalty?: breaker_penalty?,
      original_code: code
    )
  end

  # Timeout errors
  def normalize(:timeout, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    JError.new(-32_007, "Request timeout",
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :network_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  # WebSocket specific errors
  def normalize(:not_connected, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(-32_000, "WebSocket not connected",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :network_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  def normalize(:connection_closed, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    # Use -32_004 (network error code) to match the :network_error category
    # Previously used -32_005 (rate limit code) which was inconsistent
    JError.new(-32_004, "WebSocket connection closed",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :network_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  def normalize(:connection_failed, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(-32_006, "WebSocket connection failed",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :network_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  # WebSockex connection errors
  def normalize(%WebSockex.RequestError{code: 429} = _err, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(429, "Rate limited",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :rate_limit,
      retriable?: true,
      # Rate limits are temporary backpressure, not failures - don't trip circuit breaker
      breaker_penalty?: false
    )
  end

  def normalize(%WebSockex.RequestError{code: 408, message: msg} = _err, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(-32_000, msg || "Upstream timeout",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :network_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  def normalize(%WebSockex.RequestError{code: code, message: msg} = _err, opts)
      when is_integer(code) and code >= 500 and code <= 599 do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(code, msg || "Upstream server error",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :server_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  def normalize(%WebSockex.RequestError{code: code, message: msg} = _err, opts)
      when is_integer(code) and code >= 400 and code <= 499 do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(code, msg || "Client error",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :client_error,
      retriable?: false,
      breaker_penalty?: true
    )
  end

  def normalize(%WebSockex.RequestError{} = err, opts) do
    normalize({:network_error, {:request_error, err}}, Keyword.put(opts, :transport, :ws))
  end

  def normalize(%WebSockex.NotConnectedError{connection_state: state}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)

    JError.new(-32_000, "WebSocket not connected (state: #{state})",
      provider_id: provider_id,
      source: context,
      transport: :ws,
      category: :network_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  # WebSocket close codes (RFC 6455)
  def normalize({:ws_close, code, reason}, opts) when is_integer(code) do
    provider_id = Keyword.get(opts, :provider_id)

    case code do
      1000 ->
        # Normal closure
        JError.new(-32_000, "WebSocket normal closure",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :network_error,
          retriable?: true,
          breaker_penalty?: true
        )

      1001 ->
        # Going away
        JError.new(-32_000, "WebSocket going away",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :network_error,
          retriable?: true,
          breaker_penalty?: true
        )

      1002 ->
        # Protocol error
        JError.new(-32_000, "WebSocket protocol error",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :server_error,
          retriable?: true,
          breaker_penalty?: true
        )

      1003 ->
        # Unsupported data
        JError.new(-32_600, "WebSocket unsupported data",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :client_error,
          retriable?: false,
          breaker_penalty?: true
        )

      1006 ->
        # Abnormal closure
        JError.new(-32_000, "WebSocket abnormal closure",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :network_error,
          retriable?: true,
          breaker_penalty?: true
        )

      1008 ->
        # Policy violation
        JError.new(-32_600, "WebSocket policy violation",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :client_error,
          retriable?: false,
          breaker_penalty?: true
        )

      1009 ->
        # Message too big
        JError.new(-32_602, "WebSocket message too big",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :client_error,
          retriable?: false,
          breaker_penalty?: true
        )

      1011 ->
        # Internal server error
        JError.new(-32_000, "WebSocket server error",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :server_error,
          retriable?: true,
          breaker_penalty?: true
        )

      1012 ->
        # Service restart
        JError.new(-32_000, "WebSocket service restart",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :server_error,
          retriable?: true,
          breaker_penalty?: true
        )

      1013 ->
        JError.new(-32_000, "WebSocket try again later",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :server_error,
          retriable?: true,
          breaker_penalty?: true
        )

      1014 ->
        # Bad gateway
        JError.new(-32_000, "WebSocket bad gateway",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :network_error,
          retriable?: true,
          breaker_penalty?: true
        )

      1015 ->
        # TLS handshake failure
        JError.new(-32_000, "WebSocket TLS handshake failure",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :network_error,
          retriable?: true,
          breaker_penalty?: true
        )

      _ ->
        # Unknown/abnormal - treat as network/transient
        JError.new(-32_000, "WebSocket close (code #{code}): #{inspect(reason)}",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :network_error,
          retriable?: true,
          breaker_penalty?: true
        )
    end
  end

  # WebSocket disconnect with remote close code
  def normalize({:ws_disconnect, {:remote, code, msg}}, opts) when is_integer(code) do
    # Delegate to ws_close handler which has proper categorization for all codes
    normalize({:ws_close, code, msg}, opts)
  end

  # Generic WebSocket disconnect
  def normalize({:ws_disconnect, reason}, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(-32_000, "WebSocket disconnected: #{inspect(reason)}",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :network_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  # Health check context wrapper
  def normalize({:health_check, error}, opts) do
    opts
    |> Keyword.put(:context, :health_check)
    |> then(&normalize(error, &1))
  end

  # No channels available - all providers unavailable or filtered out
  def normalize(:no_channels_available, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :infrastructure)
    transport = Keyword.get(opts, :transport)

    JError.new(-32_603, "Service temporarily unavailable - no providers available",
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :provider_error,
      retriable?: true,
      breaker_penalty?: false
    )
  end

  # Generic fallback
  def normalize(other, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :unknown)
    transport = Keyword.get(opts, :transport)

    JError.new(-32_000, "Unknown error: #{inspect(other)}",
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :unknown_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # Extract retry-after hint from provider error responses
  # This handles both standard Retry-After headers and provider-specific message formats
  defp extract_retry_after(error_data) when is_map(error_data) do
    cond do
      # Standard Retry-After header (atom key)
      Map.has_key?(error_data, :retry_after) ->
        parse_retry_after_value(error_data[:retry_after])

      # Standard Retry-After header (string key)
      Map.has_key?(error_data, "retry_after") ->
        parse_retry_after_value(error_data["retry_after"])

      # Provider-specific message parsing (e.g., "Try again in 60 seconds")
      is_binary(Map.get(error_data, :body)) ->
        parse_retry_from_message(error_data[:body])

      is_binary(Map.get(error_data, "body")) ->
        parse_retry_from_message(error_data["body"])

      true ->
        nil
    end
  end

  defp extract_retry_after(_), do: nil

  # Parse retry-after value from header (seconds → milliseconds)
  defp parse_retry_after_value(value) when is_integer(value), do: value * 1000

  defp parse_retry_after_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, _} -> seconds * 1000
      :error -> nil
    end
  end

  defp parse_retry_after_value(_), do: nil

  # Extract retry-after from provider-specific error messages
  # Examples: "Try again in 60 seconds", "Try again in 5 minutes"
  defp parse_retry_from_message(message) when is_binary(message) do
    cond do
      # Match "X seconds" pattern (supports decimal seconds like "3.2 seconds")
      match = Regex.run(~r/try again in (\d+(?:\.\d+)?) second/i, message) ->
        case match do
          [_, seconds_str] ->
            case Float.parse(seconds_str) do
              {seconds, _} -> trunc(seconds * 1000)
              :error -> nil
            end

          _ ->
            nil
        end

      # Match "X minutes" pattern
      match = Regex.run(~r/try again in (\d+) minute/i, message) ->
        case match do
          [_, minutes_str] ->
            case Integer.parse(minutes_str) do
              {minutes, _} -> minutes * 60 * 1000
              :error -> nil
            end

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  defp parse_retry_from_message(_), do: nil

  # Add retry-after hint to data map if present
  defp add_retry_after(data, payload) do
    case extract_retry_after(payload) do
      nil ->
        data

      retry_ms ->
        base = if is_map(data), do: data, else: %{}
        Map.put(base, :retry_after_ms, retry_ms)
    end
  end

  # Normalize HTTP status codes embedded in JSON-RPC responses to standard JSON-RPC codes
  # Rate limit
  defp normalize_code(429), do: -32_005
  # Server error
  defp normalize_code(code) when code >= 500 and code <= 599, do: -32_000
  # Client error
  defp normalize_code(code) when code >= 400 and code <= 499, do: -32_600
  # JSON-RPC codes pass through
  defp normalize_code(code), do: code

  defp maybe_add_provider_id(%JError{provider_id: nil} = jerr, provider_id)
       when is_binary(provider_id),
       do: %{jerr | provider_id: provider_id}

  defp maybe_add_provider_id(jerr, _provider_id), do: jerr

  defp maybe_add_transport(%JError{transport: nil} = jerr, transport)
       when not is_nil(transport),
       do: %{jerr | transport: transport}

  defp maybe_add_transport(jerr, _transport), do: jerr

  # Extract nested JSON-RPC error from HTTP error payload (e.g., 4xx/5xx with JSON body)
  defp extract_nested_error(%{body: body} = _payload, fallback_code, fallback_message)
       when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code, "message" => message}}} when is_integer(code) ->
        {code, message}

      {:ok, %{"error" => %{"message" => message}}} ->
        # Error without code - use fallback code but preserve message
        {fallback_code, message}

      _ ->
        # Not a JSON-RPC error or invalid JSON - use fallback
        {fallback_code, fallback_message}
    end
  end

  defp extract_nested_error(_payload, fallback_code, fallback_message) do
    # No body or non-map payload - use fallback
    {fallback_code, fallback_message}
  end
end

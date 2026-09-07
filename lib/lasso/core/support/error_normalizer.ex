defmodule Lasso.Core.Support.ErrorNormalizer do
  @moduledoc """
  Centralized error normalization for consistent error handling across the system.

  Provides a single entry point to normalize errors from different sources (transport,
  providers, health checks) into standardized JError structures with consistent
  categorization and retry semantics.

  All categorization logic is delegated to ErrorClassification for maintainability.
  """

  require Logger

  alias Lasso.Core.Support.ErrorClassifier
  alias Lasso.JSONRPC.Error, as: JError

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

    code = raw_code

    # Unified classification with adapter priority
    %{category: category, retriable?: retriable?, breaker_penalty?: breaker_penalty?} =
      ErrorClassifier.classify(code, message, Keyword.put(classifier_opts(opts), :data, raw_data))

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

    case extract_nested_error(payload, -32_005, "Rate limited by provider") do
      {:json_rpc, code, message, data} ->
        normalized_json_rpc_error(code, message, data, payload, opts)

      {:raw, _code, _message} ->
        data = payload |> public_transport_data() |> add_retry_after(payload)

        JError.new(-32_005, "Rate limited by provider",
          data: data,
          provider_id: provider_id,
          source: context,
          transport: transport,
          category: :rate_limit,
          retriable?: true,
          breaker_penalty?: false,
          http_status: transport_status(payload)
        )
    end
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

  def normalize({:local_capacity_rejection, reason}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    JError.new(-32_008, "Local transport capacity unavailable",
      data: %{reason: reason},
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :local_capacity_rejection,
      retriable?: true,
      breaker_penalty?: false
    )
  end

  def normalize({:encode_error, reason}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    JError.new(-32_600, "JSON-RPC request could not be encoded",
      data: %{reason: reason},
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :invalid_params,
      retriable?: false,
      breaker_penalty?: false
    )
  end

  def normalize({:request_build_error, reason}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    JError.new(-32_600, "HTTP request configuration is invalid",
      data: %{reason: reason},
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :client_error,
      retriable?: false,
      breaker_penalty?: false
    )
  end

  # Server errors (5xx HTTP, provider issues)
  def normalize({:server_error, payload}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    # Try to extract nested JSON-RPC error from response body for better classification
    case extract_nested_error(payload, -32_002, "Server error") do
      {:json_rpc, code, message, data} ->
        normalized_json_rpc_error(code, message, data, payload, opts)

      {:raw, code, message} ->
        JError.new(code, message,
          data: payload,
          provider_id: provider_id,
          source: context,
          transport: transport,
          category: :server_error,
          retriable?: true,
          breaker_penalty?: true,
          original_code: code,
          http_status: transport_status(payload)
        )
    end
  end

  # Client errors (4xx HTTP, bad requests)
  def normalize({:client_error, payload}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    case extract_nested_error(payload, -32_003, "Client error") do
      {:json_rpc, code, message, data} ->
        # Body is a valid JSON-RPC error envelope — classify normally
        normalized_json_rpc_error(code, message, data, payload, opts)

      {:raw, _code, _message} ->
        # Body is NOT a JSON-RPC error envelope (e.g. gateway/proxy/CDN rejection).
        # A compliant JSON-RPC provider would return errors in JSON-RPC format.
        # Non-JSON-RPC 4xx means the RPC handler never processed the request.
        status = Map.get(payload, :status, "4xx")

        Logger.warning("Reclassifying non-JSON-RPC 4xx as server_error",
          provider_id: provider_id,
          status: status
        )

        JError.new(-32_002, "Provider infrastructure error (HTTP #{status})",
          data: payload,
          provider_id: provider_id,
          source: context,
          transport: transport,
          category: :server_error,
          retriable?: true,
          breaker_penalty?: true,
          original_code: -32_003,
          http_status: transport_status(payload)
        )
    end
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
      category: :timeout,
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
      category: :local_capacity_rejection,
      retriable?: true,
      breaker_penalty?: false
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

  def normalize({:ws_upgrade_error, 429, headers}, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(-32_005, "Rate limited",
      data: websocket_retry_after_data(headers),
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :rate_limit,
      retriable?: true,
      # Rate limits are temporary backpressure, not failures - don't trip circuit breaker
      breaker_penalty?: false,
      original_code: 429
    )
  end

  def normalize({:ws_upgrade_error, 408, _headers}, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(-32_000, "Upstream timeout",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :network_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  def normalize({:ws_upgrade_error, code, _headers}, opts)
      when is_integer(code) and code >= 500 and code <= 599 do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(code, "Upstream server error",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :server_error,
      retriable?: true,
      breaker_penalty?: true
    )
  end

  def normalize({:ws_upgrade_error, code, _headers}, opts)
      when is_integer(code) and code >= 400 and code <= 499 do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(code, "Client error",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :client_error,
      retriable?: false,
      breaker_penalty?: true
    )
  end

  def normalize({:ws_upgrade_error, code, _headers}, opts) do
    normalize({:network_error, {:upgrade_failed, code}}, Keyword.put(opts, :transport, :ws))
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

  # WebSocket process exited (via :EXIT message from linked process)
  def normalize({:ws_exit, reason}, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(-32_000, "WebSocket process exited: #{inspect(reason)}",
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

  defp websocket_retry_after_data(headers) when is_list(headers) do
    retry_after =
      Enum.find_value(headers, fn
        {name, value} when is_binary(name) ->
          if String.downcase(name) == "retry-after", do: parse_retry_after_value(value)

        _other ->
          nil
      end)

    if is_integer(retry_after), do: %{retry_after_ms: retry_after}, else: nil
  end

  defp websocket_retry_after_data(_headers), do: nil

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

  defp public_transport_data(payload) when is_map(payload) do
    payload
    |> Map.delete(:body)
    |> Map.delete("body")
  end

  defp public_transport_data(payload), do: payload

  defp normalized_json_rpc_error(code, message, data, payload, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :jsonrpc)
    transport = Keyword.get(opts, :transport)

    %{category: category, retriable?: retriable?, breaker_penalty?: breaker_penalty?} =
      ErrorClassifier.classify(code, message, Keyword.put(classifier_opts(opts), :data, data))

    JError.new(code, message,
      data: data,
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: category,
      retriable?: retriable?,
      breaker_penalty?: breaker_penalty?,
      original_code: code,
      http_status: transport_status(payload)
    )
  end

  defp transport_status(payload) when is_map(payload),
    do: Map.get(payload, :status) || Map.get(payload, "status")

  defp transport_status(_payload), do: nil

  defp maybe_add_provider_id(%JError{provider_id: nil} = jerr, provider_id)
       when is_binary(provider_id),
       do: %{jerr | provider_id: provider_id}

  defp maybe_add_provider_id(jerr, _provider_id), do: jerr

  defp maybe_add_transport(%JError{transport: nil} = jerr, transport)
       when not is_nil(transport),
       do: %{jerr | transport: transport}

  defp maybe_add_transport(jerr, _transport), do: jerr

  defp classifier_opts(opts) do
    Keyword.take(opts, [
      :provider_id,
      :profile,
      :chain_id,
      :chain,
      :provider_capabilities,
      :shared_instance?
    ])
  end

  # Extract nested JSON-RPC error from HTTP error payload (e.g., 4xx/5xx with JSON body).
  #
  # Returns a tagged tuple:
  #   {:json_rpc, code, message, data} — body contained a JSON-RPC error envelope
  #   {:raw, code, message}      — body was not JSON-RPC; code/message are fallbacks
  defp extract_nested_error(%{body: body} = _payload, fallback_code, fallback_message)
       when is_binary(body) do
    case Jason.decode(body) do
      {:ok,
       %{
         "jsonrpc" => "2.0",
         "id" => _id,
         "error" => %{"code" => code, "message" => message} = error
       }}
      when is_integer(code) and is_binary(message) ->
        {:json_rpc, code, message, Map.get(error, "data")}

      _ ->
        {:raw, fallback_code, fallback_message}
    end
  end

  defp extract_nested_error(_payload, fallback_code, fallback_message) do
    {:raw, fallback_code, fallback_message}
  end
end

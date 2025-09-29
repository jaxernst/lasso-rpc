defmodule Livechain.RPC.ErrorNormalizer do
  @moduledoc """
  Centralized error normalization for consistent error handling across the system.

  Provides a single point to normalize errors from different sources (transport,
  providers, health checks) into standardized JError structures with consistent
  categorization and retry semantics.
  """

  alias Livechain.JSONRPC.Error, as: JError

  @type context :: :health_check | :live_traffic | :transport | :jsonrpc
  @type transport :: :http | :ws | nil

  @doc """
  Normalizes any error into a standardized JError structure.

  ## Parameters
    - `error`: The error to normalize (can be any term)
    - `opts`: Options including :provider_id, :context, :transport

  ## Examples

      iex> normalize({:rate_limit, %{}}, provider_id: "test", context: :transport)
      %JError{category: :rate_limit, retriable?: true}

      iex> normalize(%{"error" => %{"code" => -32000}}, provider_id: "test", context: :jsonrpc)
      %JError{code: -32000, category: :server_error}
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

  # JSON-RPC error response
  def normalize(%{"error" => error} = _response, opts) when is_map(error) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :jsonrpc)
    transport = Keyword.get(opts, :transport)

    code = Map.get(error, "code", -32000)
    message = Map.get(error, "message", "Unknown error")
    data = Map.get(error, "data")

    JError.new(code, message,
      data: data,
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: categorize_jsonrpc_error(code),
      retriable?: retriable_jsonrpc_error?(code)
    )
  end

  # Rate limiting errors
  def normalize({:rate_limit, payload}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    JError.new(-32001, "Rate limited by provider",
      data: payload,
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :rate_limit,
      retriable?: true
    )
  end

  # Network errors
  def normalize({:network_error, reason}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    JError.new(-32004, "Network error: #{inspect(reason)}",
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :network_error,
      retriable?: true
    )
  end

  # Server errors (5xx HTTP, provider issues)
  def normalize({:server_error, payload}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    JError.new(-32002, "Server error",
      data: payload,
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :server_error,
      retriable?: true
    )
  end

  # Client errors (4xx HTTP, bad requests)
  def normalize({:client_error, payload}, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    JError.new(-32003, "Client error",
      data: payload,
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :client_error,
      retriable?: false
    )
  end

  # Timeout errors
  def normalize(:timeout, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :transport)
    transport = Keyword.get(opts, :transport)

    JError.new(-32007, "Request timeout",
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :network_error,
      retriable?: true
    )
  end

  # WebSocket specific errors
  def normalize(:not_connected, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(-32000, "WebSocket not connected",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :network_error,
      retriable?: true
    )
  end

  def normalize(:connection_closed, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(-32005, "WebSocket connection closed",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :network_error,
      retriable?: true
    )
  end

  def normalize(:connection_failed, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(-32006, "WebSocket connection failed",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :network_error,
      retriable?: true
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
      retriable?: true
    )
  end

  def normalize(%WebSockex.RequestError{code: 408, message: msg} = _err, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(-32000, msg || "Upstream timeout",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :network_error,
      retriable?: true
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
      retriable?: true
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
      retriable?: false
    )
  end

  def normalize(%WebSockex.RequestError{} = err, opts) do
    normalize({:network_error, {:request_error, err}}, Keyword.put(opts, :transport, :ws))
  end

  # WebSocket close codes (RFC 6455)
  def normalize({:ws_close, code, reason}, opts) when is_integer(code) do
    provider_id = Keyword.get(opts, :provider_id)

    case code do
      1000 ->
        # Normal closure - allow reconnect (transient)
        JError.new(-32000, "WebSocket normal closure",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :network_error,
          retriable?: true
        )

      1001 ->
        # Going away - treat as network/transient
        JError.new(-32000, "WebSocket going away",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :network_error,
          retriable?: true
        )

      1002 ->
        # Protocol error - server-side
        JError.new(-32000, "WebSocket protocol error",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :server_error,
          retriable?: true
        )

      1003 ->
        # Unsupported data - client-side, non-retriable
        JError.new(-32600, "WebSocket unsupported data",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :client_error,
          retriable?: false
        )

      1006 ->
        # Abnormal closure - network/transient
        JError.new(-32000, "WebSocket abnormal closure",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :network_error,
          retriable?: true
        )

      1008 ->
        # Policy violation - client-side
        JError.new(-32600, "WebSocket policy violation",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :client_error,
          retriable?: false
        )

      1009 ->
        # Message too big - client-side
        JError.new(-32602, "WebSocket message too big",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :client_error,
          retriable?: false
        )

      1011 ->
        # Internal server error - retriable
        JError.new(-32000, "WebSocket server error",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :server_error,
          retriable?: true
        )

      1012 ->
        # Service restart - retriable
        JError.new(-32000, "WebSocket service restart",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :server_error,
          retriable?: true
        )

      1013 ->
        # Try again later / overload - map to 429 (retriable)
        JError.new(429, "WebSocket try again later",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :rate_limit,
          retriable?: true
        )

      1014 ->
        # Bad gateway - retriable
        JError.new(-32000, "WebSocket bad gateway",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :network_error,
          retriable?: true
        )

      1015 ->
        # TLS handshake failure - network/transient
        JError.new(-32000, "WebSocket TLS handshake failure",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :network_error,
          retriable?: true
        )

      _ ->
        # Unknown/abnormal - treat as network/transient by default
        JError.new(-32000, "WebSocket close (code #{code}): #{inspect(reason)}",
          provider_id: provider_id,
          source: :transport,
          transport: :ws,
          category: :network_error,
          retriable?: true
        )
    end
  end

  # WebSocket disconnect with remote close code
  def normalize({:ws_disconnect, {:remote, code, msg}}, opts) when is_integer(code) do
    # Handle close code 1013 specially (backpressure/rate limit)
    if code == 1013 do
      provider_id = Keyword.get(opts, :provider_id)

      JError.new(429, msg || "WebSocket backpressure",
        provider_id: provider_id,
        source: :transport,
        transport: :ws,
        category: :rate_limit,
        retriable?: true
      )
    else
      normalize({:ws_close, code, msg}, opts)
    end
  end

  # Generic WebSocket disconnect
  def normalize({:ws_disconnect, reason}, opts) do
    provider_id = Keyword.get(opts, :provider_id)

    JError.new(-32000, "WebSocket disconnected: #{inspect(reason)}",
      provider_id: provider_id,
      source: :transport,
      transport: :ws,
      category: :network_error,
      retriable?: true
    )
  end

  # Health check context wrapper
  def normalize({:health_check, error}, opts) do
    opts = Keyword.put(opts, :context, :health_check)
    normalize(error, opts)
  end

  # Generic fallback
  def normalize(other, opts) do
    provider_id = Keyword.get(opts, :provider_id)
    context = Keyword.get(opts, :context, :unknown)
    transport = Keyword.get(opts, :transport)

    JError.new(-32000, "Unknown error: #{inspect(other)}",
      provider_id: provider_id,
      source: context,
      transport: transport,
      category: :unknown_error,
      retriable?: true
    )
  end

  # Private functions

  defp maybe_add_provider_id(%JError{provider_id: nil} = jerr, provider_id)
       when is_binary(provider_id) do
    %{jerr | provider_id: provider_id}
  end

  defp maybe_add_provider_id(jerr, _), do: jerr

  defp maybe_add_transport(%JError{transport: nil} = jerr, transport)
       when not is_nil(transport) do
    %{jerr | transport: transport}
  end

  defp maybe_add_transport(jerr, _), do: jerr

  defp categorize_jsonrpc_error(code) when code >= -32099 and code <= -32000, do: :server_error
  defp categorize_jsonrpc_error(-32700), do: :parse_error
  defp categorize_jsonrpc_error(-32600), do: :invalid_request
  defp categorize_jsonrpc_error(-32601), do: :method_not_found
  defp categorize_jsonrpc_error(-32602), do: :invalid_params
  defp categorize_jsonrpc_error(-32603), do: :internal_error
  defp categorize_jsonrpc_error(code) when code >= -32001 and code <= -32099, do: :server_error
  defp categorize_jsonrpc_error(_), do: :application_error

  # Parse error
  defp retriable_jsonrpc_error?(-32700), do: false
  # Invalid request
  defp retriable_jsonrpc_error?(-32600), do: false
  # Method not found
  defp retriable_jsonrpc_error?(-32601), do: false
  # Invalid params
  defp retriable_jsonrpc_error?(-32602), do: false
  # Server errors
  defp retriable_jsonrpc_error?(code) when code >= -32099 and code <= -32000, do: true
  # Application errors - usually retriable
  defp retriable_jsonrpc_error?(_), do: true
end

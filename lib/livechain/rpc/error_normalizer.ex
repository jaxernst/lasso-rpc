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

  defp maybe_add_provider_id(%JError{provider_id: nil} = jerr, provider_id) when is_binary(provider_id) do
    %{jerr | provider_id: provider_id}
  end

  defp maybe_add_provider_id(jerr, _), do: jerr

  defp maybe_add_transport(%JError{transport: nil} = jerr, transport) when not is_nil(transport) do
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

  defp retriable_jsonrpc_error?(-32700), do: false  # Parse error
  defp retriable_jsonrpc_error?(-32600), do: false  # Invalid request
  defp retriable_jsonrpc_error?(-32601), do: false  # Method not found
  defp retriable_jsonrpc_error?(-32602), do: false  # Invalid params
  defp retriable_jsonrpc_error?(code) when code >= -32099 and code <= -32000, do: true  # Server errors
  defp retriable_jsonrpc_error?(_), do: true  # Application errors - usually retriable
end
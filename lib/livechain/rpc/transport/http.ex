defmodule Livechain.RPC.Transport.HTTP do
  @moduledoc """
  HTTP transport implementation for RPC requests.

  Handles HTTP-based JSON-RPC requests with proper error normalization
  and provider-specific configuration handling.
  """

  @behaviour Livechain.RPC.Transport

  require Logger
  alias Livechain.RPC.HttpClient
  alias Livechain.JSONRPC.Error, as: JError

  @impl true
  def forward_request(provider_config, method, params, opts) do
    provider_id = Keyword.get(opts, :provider_id, "unknown")
    timeout_ms = Keyword.get(opts, :timeout, 30_000)

    case get_http_url(provider_config) do
      nil ->
        {:error, JError.new(-32000, "No HTTP URL configured for provider",
                           provider_id: provider_id, retriable?: false)}

      url ->
        http_config = Map.put(provider_config, :url, url)

        Logger.debug("Forwarding HTTP request",
                     provider: provider_id, method: method, url: url)

        case HttpClient.request(http_config, method, params, timeout_ms) do
          {:ok, response} ->
            normalize_http_response(response, provider_id)

          {:error, reason} ->
            {:error, normalize_http_error(reason, provider_id)}
        end
    end
  end

  @impl true
  def supports_protocol?(provider_config, :http), do: has_http_url?(provider_config)
  def supports_protocol?(provider_config, :both), do: has_http_url?(provider_config)
  def supports_protocol?(_provider_config, :ws), do: false

  @impl true
  def get_transport_type(_provider_config), do: :http

  # Private functions

  defp get_http_url(provider_config) do
    Map.get(provider_config, :url) || Map.get(provider_config, :http_url)
  end

  defp has_http_url?(provider_config) do
    is_binary(get_http_url(provider_config))
  end

  defp normalize_http_response(%{"error" => error} = _response, provider_id)
       when is_map(error) do
    # JSON-RPC error response
    code = Map.get(error, "code", -32000)
    message = Map.get(error, "message", "Unknown error")
    data = Map.get(error, "data")

    jerr = JError.new(code, message, data: data, provider_id: provider_id,
                     source: :jsonrpc, transport: :http)
    {:error, jerr}
  end

  defp normalize_http_response(%{"result" => result}, _provider_id) do
    {:ok, result}
  end

  defp normalize_http_response(other, provider_id) do
    {:error, JError.new(-32700, "Invalid JSON-RPC response format",
                       data: other, provider_id: provider_id,
                       source: :transport, transport: :http, retriable?: false)}
  end

  defp normalize_http_error({:rate_limit, payload}, provider_id) do
    JError.new(-32001, "Rate limited by provider",
               data: payload, provider_id: provider_id,
               source: :transport, transport: :http,
               category: :rate_limit, retriable?: true)
  end

  defp normalize_http_error({:server_error, payload}, provider_id) do
    JError.new(-32002, "Server error",
               data: payload, provider_id: provider_id,
               source: :transport, transport: :http,
               category: :server_error, retriable?: true)
  end

  defp normalize_http_error({:client_error, payload}, provider_id) do
    JError.new(-32003, "Client error",
               data: payload, provider_id: provider_id,
               source: :transport, transport: :http,
               category: :client_error, retriable?: false)
  end

  defp normalize_http_error({:network_error, reason}, provider_id) do
    JError.new(-32004, "Network error: #{reason}",
               provider_id: provider_id,
               source: :transport, transport: :http,
               category: :network_error, retriable?: true)
  end

  defp normalize_http_error({:encode_error, reason}, provider_id) do
    JError.new(-32700, "JSON encoding error: #{reason}",
               provider_id: provider_id,
               source: :transport, transport: :http,
               category: :client_error, retriable?: false)
  end

  defp normalize_http_error({:response_decode_error, reason}, provider_id) do
    JError.new(-32700, "Response decode error: #{reason}",
               provider_id: provider_id,
               source: :transport, transport: :http,
               category: :server_error, retriable?: true)
  end

  defp normalize_http_error(other, provider_id) do
    JError.new(-32000, "Unknown HTTP transport error: #{inspect(other)}",
               provider_id: provider_id,
               source: :transport, transport: :http,
               category: :network_error, retriable?: true)
  end
end
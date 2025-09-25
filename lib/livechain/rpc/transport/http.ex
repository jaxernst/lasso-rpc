defmodule Livechain.RPC.Transport.HTTP do
  @moduledoc """
  HTTP transport implementation for RPC requests.

  Handles HTTP-based JSON-RPC requests with proper error normalization
  and provider-specific configuration handling.
  """

  @behaviour Livechain.RPC.Transport

  require Logger
  alias Livechain.RPC.HttpClient
  alias Livechain.RPC.ErrorNormalizer
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
          {:ok, %{"error" => _error} = response} ->
            # JSON-RPC error response - normalize using centralized logic
            jerr = ErrorNormalizer.normalize(response,
                     provider_id: provider_id, context: :jsonrpc, transport: :http)
            {:error, jerr}

          {:ok, %{"result" => result}} ->
            {:ok, result}

          {:ok, invalid_response} ->
            {:error, JError.new(-32700, "Invalid JSON-RPC response format",
                               data: invalid_response, provider_id: provider_id,
                               source: :transport, transport: :http, retriable?: false)}

          {:error, reason} ->
            {:error, ErrorNormalizer.normalize(reason,
                       provider_id: provider_id, context: :transport, transport: :http)}
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

end
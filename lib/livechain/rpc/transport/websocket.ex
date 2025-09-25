defmodule Livechain.RPC.Transport.WebSocket do
  @moduledoc """
  WebSocket transport implementation for RPC requests.

  Handles WebSocket-based JSON-RPC requests including subscriptions
  with proper connection management and error normalization.
  """

  @behaviour Livechain.RPC.Transport

  require Logger
  alias Livechain.RPC.ChainSupervisor
  alias Livechain.RPC.ErrorNormalizer
  alias Livechain.JSONRPC.Error, as: JError

  @impl true
  def forward_request(provider_config, method, params, opts) do
    provider_id = Keyword.get(opts, :provider_id, "unknown")
    request_id = Keyword.get(opts, :request_id) || Livechain.RPC.Transport.generate_request_id()
    chain_name = Map.get(provider_config, :chain)

    case get_ws_url(provider_config) do
      nil ->
        {:error, JError.new(-32000, "No WebSocket URL configured for provider",
                           provider_id: provider_id, retriable?: false)}

      _ws_url ->
        message = %{
          "jsonrpc" => "2.0",
          "method" => method,
          "params" => params,
          "id" => request_id
        }

        Logger.debug("Forwarding WebSocket request",
                     provider: provider_id, method: method, id: request_id)

        case ChainSupervisor.forward_ws_message(chain_name, provider_id, message) do
          {:ok, result} ->
            {:ok, result}

          {:error, reason} ->
            {:error, ErrorNormalizer.normalize(reason,
                       provider_id: provider_id, context: :transport, transport: :ws)}
        end
    end
  end

  @impl true
  def supports_protocol?(provider_config, :ws), do: has_ws_url?(provider_config)
  def supports_protocol?(provider_config, :both), do: has_ws_url?(provider_config)
  def supports_protocol?(_provider_config, :http), do: false

  @impl true
  def get_transport_type(_provider_config), do: :ws

  # Private functions

  defp get_ws_url(provider_config) do
    Map.get(provider_config, :ws_url)
  end

  defp has_ws_url?(provider_config) do
    is_binary(get_ws_url(provider_config))
  end

end
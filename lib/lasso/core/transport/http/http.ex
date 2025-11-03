defmodule Lasso.RPC.Transports.HTTP do
  @moduledoc """
  HTTP transport implementation for RPC requests.

  Handles HTTP-based JSON-RPC requests with proper error normalization
  and provider-specific configuration handling. Implements the new Transport
  behaviour for transport-agnostic request routing.
  """

  @behaviour Lasso.RPC.Transport

  require Logger
  alias Lasso.RPC.HttpClient
  alias Lasso.RPC.ErrorNormalizer
  alias Lasso.JSONRPC.Error, as: JError

  # Channel is the provider configuration for HTTP (stateless)
  @type channel :: %{url: String.t(), provider_id: String.t(), config: map()}

  # New Transport behaviour implementation

  @impl true
  def open(provider_config, opts \\ []) do
    provider_id = Keyword.get(opts, :provider_id, Map.get(provider_config, :id, "unknown"))

    case get_http_url(provider_config) do
      nil ->
        {:error,
         JError.new(-32_000, "No HTTP URL configured for provider",
           provider_id: provider_id,
           retriable?: false
         )}

      url ->
        channel = %{
          url: url,
          provider_id: provider_id,
          config: provider_config
        }

        {:ok, channel}
    end
  end

  @impl true
  def healthy?(%{url: url}) when is_binary(url), do: true
  def healthy?(_), do: false

  @impl true
  def capabilities(_channel) do
    %{
      unary?: true,
      subscriptions?: false,
      # HTTP supports all methods by default
      methods: :all
    }
  end

  @impl true
  def request(channel, rpc_request, timeout \\ 30_000) do
    %{provider_id: provider_id, config: provider_config} = channel

    method = Map.get(rpc_request, "method")
    params = Map.get(rpc_request, "params", [])
    request_id = Map.get(rpc_request, "id")

    io_start_us = System.monotonic_time(:microsecond)

    result =
      case HttpClient.request(provider_config, method, params,
             request_id: request_id,
             timeout: timeout
           ) do
        {:ok, %{"error" => _error} = response} ->
          jerr =
            ErrorNormalizer.normalize(response,
              provider_id: provider_id,
              context: :jsonrpc,
              transport: :http
            )

          {:error, jerr}

        {:ok, %{"result" => result}} ->
          {:ok, result}

        {:ok, invalid_response} ->
          {:error,
           JError.new(-32_700, "Invalid JSON-RPC response format",
             data: invalid_response,
             provider_id: provider_id,
             source: :transport,
             transport: :http,
             retriable?: false
           )}

        {:error, reason} ->
          {:error,
           ErrorNormalizer.normalize(reason,
             provider_id: provider_id,
             context: :transport,
             transport: :http
           )}
      end

    # Calculate I/O latency
    io_ms = div(System.monotonic_time(:microsecond) - io_start_us, 1000)

    # Emit telemetry
    :telemetry.execute(
      [:lasso, :http, :request, :io],
      %{io_ms: io_ms},
      %{provider_id: provider_id, method: method}
    )

    # Return latency as third tuple element for both success and error
    case result do
      {:ok, response} ->
        {:ok, response, io_ms}

      {:error, reason} ->
        Logger.warning("HTTP request failed",
          provider: provider_id,
          method: method,
          rpc_id: request_id,
          io_latency_ms: io_ms,
          error: inspect(reason, limit: 500, printable_limit: 1000)
        )

        {:error, reason, io_ms}
    end
  end

  @impl true
  def subscribe(_channel, _rpc_request, _handler_pid) do
    # HTTP doesn't support subscriptions
    {:error, :unsupported_method}
  end

  @impl true
  def unsubscribe(_channel, _subscription_ref) do
    # HTTP doesn't support subscriptions
    {:error, :unsupported_method}
  end

  @impl true
  def close(_channel) do
    # HTTP channels are stateless
    :ok
  end

  # Private functions

  defp get_http_url(provider_config) do
    Map.get(provider_config, :url) || Map.get(provider_config, :http_url)
  end
end

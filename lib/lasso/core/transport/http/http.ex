defmodule Lasso.RPC.Transports.HTTP do
  @moduledoc """
  HTTP transport implementation for RPC requests.

  Handles HTTP-based JSON-RPC requests with proper error normalization
  and provider-specific configuration handling. Implements the new Transport
  behaviour for transport-agnostic request routing.
  """

  @behaviour Lasso.RPC.Transport

  alias Lasso.Core.Support.{ErrorClassifier, ErrorNormalizer}
  alias Lasso.Core.Transport.{AttemptProtocol, UpstreamResponse}
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.PreparedRequest
  alias Lasso.RPC.Transport.HTTP.Client, as: HttpClient

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
          config: provider_config,
          request_config: HttpClient.prepare_provider(provider_config)
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
  def deferred_dispatch?, do: HttpClient.deferred_dispatch?()

  @impl true
  def request(channel, rpc_request, timeout \\ 30_000) do
    method = Map.get(rpc_request, "method")
    params = Map.get(rpc_request, "params", [])
    request_id = Map.get(rpc_request, "id")

    perform_request(channel, request_id, request_id, timeout, fn provider_config, options ->
      HttpClient.request(provider_config, method, params, options)
    end)
  end

  @impl true
  def request_prepared(channel, %PreparedRequest{} = prepared, timeout) do
    perform_request(
      channel,
      prepared.transport_id,
      prepared.client_id,
      timeout,
      fn provider_config, options ->
        HttpClient.request_prepared(provider_config, prepared, options)
      end
    )
  end

  defp perform_request(
         %{provider_id: provider_id, config: provider_config} = channel,
         upstream_id,
         client_id,
         timeout,
         request_fun
       ) do
    io_start_us = System.monotonic_time(:microsecond)
    dispatch_context = AttemptProtocol.context()
    deadline_us = request_deadline_us(io_start_us, timeout, AttemptProtocol.deadline_us())

    request_config = Map.get(channel, :request_config, provider_config)

    result =
      case request_fun.(request_config,
             request_id: upstream_id,
             timeout: timeout,
             deadline_us: deadline_us,
             attempt_dispatch: dispatch_context
           ) do
        {:ok, {:raw, raw_bytes}} ->
          received_at_us = System.monotonic_time(:microsecond)
          validation = UpstreamResponse.validate_unary(raw_bytes, upstream_id, client_id)
          validated_at_us = System.monotonic_time(:microsecond)

          settle_raw_response(%{
            validation: validation,
            raw_bytes: raw_bytes,
            provider_id: provider_id,
            dispatch_context: dispatch_context,
            deadline_us: deadline_us,
            io_duration_us: max(received_at_us - io_start_us, 0),
            validated_at_us: validated_at_us
          })

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

    # Return latency as third tuple element for both success and error
    case result do
      {:ok, response} ->
        {:ok, response, io_ms}

      {:error, reason} ->
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

  defp request_deadline_us(started_at_us, timeout, decision_deadline_us)
       when is_integer(timeout) and timeout >= 0 and is_integer(decision_deadline_us),
       do: min(decision_deadline_us, started_at_us + timeout * 1_000)

  defp request_deadline_us(started_at_us, timeout, nil)
       when is_integer(timeout) and timeout >= 0,
       do: started_at_us + timeout * 1_000

  defp settle_raw_response(%{validated_at_us: validated_at_us, deadline_us: deadline_us} = input)
       when validated_at_us >= deadline_us do
    AttemptProtocol.terminal_at(
      input.dispatch_context,
      :transport_failure,
      %{reason: :timeout, certainty: :dispatched},
      validated_at_us
    )

    {:error,
     ErrorNormalizer.normalize(:timeout,
       provider_id: input.provider_id,
       context: :transport,
       transport: :http
     )}
  end

  defp settle_raw_response(%{validation: {:ok, response}} = input) do
    AttemptProtocol.terminal_at(
      input.dispatch_context,
      :response,
      %{response_kind: :success, io_duration_us: input.io_duration_us},
      input.validated_at_us
    )

    {:ok, response}
  end

  defp settle_raw_response(%{validation: {:error, %JError{} = jerr}} = input) do
    %{category: category, retriable?: retriable?, breaker_penalty?: breaker_penalty?} =
      ErrorClassifier.classify(jerr.code, jerr.message,
        data: jerr.data,
        provider_id: input.provider_id
      )

    AttemptProtocol.terminal_at(
      input.dispatch_context,
      :response,
      %{
        response_kind: :error,
        error_code: jerr.code,
        error_category: category,
        io_duration_us: input.io_duration_us
      },
      input.validated_at_us
    )

    {:error,
     %{
       jerr
       | provider_id: input.provider_id,
         source: :jsonrpc,
         transport: :http,
         category: category,
         retriable?: retriable?,
         breaker_penalty?: breaker_penalty?
     }}
  end

  defp settle_raw_response(%{validation: {:invalid, parse_reason}} = input) do
    AttemptProtocol.terminal_at(
      input.dispatch_context,
      :invalid_response,
      %{reason: parse_reason, io_duration_us: input.io_duration_us},
      input.validated_at_us
    )

    {:error,
     JError.new(-32_700, "Invalid JSON-RPC response format",
       data: %{reason: parse_reason, raw_bytes_size: byte_size(input.raw_bytes)},
       provider_id: input.provider_id,
       source: :transport,
       transport: :http,
       category: :server_error,
       retriable?: true,
       breaker_penalty?: true
     )}
  end
end

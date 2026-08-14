defmodule Lasso.RPC.Transports.WebSocket do
  @moduledoc """
  WebSocket transport implementation for RPC requests and subscriptions.

  Handles WebSocket-based JSON-RPC requests including both unary requests
  (single request/response) and streaming subscriptions with proper connection
  management and error normalization. Implements the new Transport behaviour
  for transport-agnostic request routing.

  Outbound frames use a one-way WebSockex cast guarded by the connection
  generation, absolute decision cutoff, and a shared cancellation latch. Direct
  `WebSockex.send_frame/2` is not used because its queued `GenServer.call` may
  send after the waiting task has been cancelled or its deadline has expired.
  Cast acceptance opens an indeterminate send phase. A same-process
  acknowledgement after WebSockex completes its socket write proves dispatch;
  a correlated response remains independently sufficient proof.
  """

  @behaviour Lasso.RPC.Transport

  require Logger
  alias Lasso.Core.Support.{ErrorClassifier, ErrorNormalizer}
  alias Lasso.Core.Transport.{AttemptProtocol, UpstreamResponse}
  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.Providers.Catalog
  alias Lasso.RPC.Response
  alias Lasso.RPC.Transport.WebSocket.Connection, as: WSConnection

  # Channel represents a WebSocket connection
  @type channel :: %{
          profile: String.t(),
          chain: String.t(),
          ws_url: String.t(),
          provider_id: String.t(),
          connection_pid: pid(),
          config: map()
        }

  # New Transport behaviour implementation

  @impl true
  def open(provider_config, opts \\ []) do
    provider_id = Keyword.get(opts, :provider_id, Map.get(provider_config, :id, "unknown"))
    profile = Keyword.get(opts, :profile, Map.get(provider_config, :profile))
    chain_id = Keyword.get(opts, :chain_id, Map.get(provider_config, :chain_id))

    case get_ws_url(provider_config) do
      nil ->
        {:error,
         JError.new(-32_000, "No WebSocket URL configured for provider",
           provider_id: provider_id,
           retriable?: false
         )}

      ws_url ->
        instance_id =
          Keyword.get_lazy(opts, :instance_id, fn ->
            resolve_instance_id(profile, chain_id, provider_id)
          end)

        connection_pid =
          GenServer.whereis(WSConnection.via_instance_name(instance_id))

        case connection_pid do
          nil ->
            {:error,
             JError.new(-32_000, "WebSocket connection not available",
               provider_id: provider_id,
               retriable?: true
             )}

          connection_pid when is_pid(connection_pid) ->
            channel = %{
              profile: profile,
              chain_id: chain_id,
              ws_url: ws_url,
              provider_id: provider_id,
              instance_id: instance_id,
              connection_pid: connection_pid,
              config: provider_config
            }

            {:ok, channel}
        end
    end
  end

  @impl true
  def healthy?(%{connection_pid: pid}) when is_pid(pid) do
    Process.alive?(pid)
  end

  def healthy?(_), do: false

  @impl true
  def capabilities(_channel) do
    %{
      unary?: true,
      subscriptions?: true,
      # WebSocket supports all methods by default
      methods: :all
    }
  end

  @impl true
  def deferred_dispatch?, do: true

  @impl true
  def request(channel, rpc_request, timeout \\ 30_000) do
    %{instance_id: instance_id, provider_id: provider_id} = channel

    method = Map.get(rpc_request, "method")
    params = Map.get(rpc_request, "params", [])
    request_id = Map.get(rpc_request, "id")

    io_start_us = System.monotonic_time(:microsecond)

    context = AttemptProtocol.context()

    transport_deadline_us = io_start_us + timeout * 1_000

    deadline_us =
      case AttemptProtocol.deadline_us() do
        nil -> transport_deadline_us
        lifecycle_deadline_us -> min(lifecycle_deadline_us, transport_deadline_us)
      end

    result =
      transport_request(
        instance_id,
        provider_id,
        method,
        params,
        request_id,
        context,
        deadline_us
      )

    io_ms = div(System.monotonic_time(:microsecond) - io_start_us, 1000)

    case result do
      {:ok, response} -> {:ok, response, io_ms}
      {:error, reason} -> {:error, reason, io_ms}
    end
  end

  defp transport_request(
         instance_id,
         provider_id,
         method,
         params,
         client_id,
         context,
         deadline_us
       ) do
    transport_id = generate_transport_id()

    case Jason.encode(%{
           "jsonrpc" => "2.0",
           "id" => transport_id,
           "method" => method,
           "params" => params || []
         }) do
      {:ok, encoded} ->
        authorize_transport_request(%{
          instance_id: instance_id,
          provider_id: provider_id,
          transport_id: transport_id,
          encoded: encoded,
          client_id: client_id,
          context: context,
          deadline_us: deadline_us
        })

      {:error, reason} ->
        AttemptProtocol.predispatch_failure(context, :encode_error)
        {:error, normalize_ws_error(reason, provider_id)}
    end
  end

  defp authorize_transport_request(%{
         instance_id: instance_id,
         provider_id: provider_id,
         transport_id: transport_id,
         encoded: encoded,
         client_id: client_id,
         context: context,
         deadline_us: deadline_us
       }) do
    with :ok <- AttemptProtocol.send_started(context),
         send_started_us = System.monotonic_time(:microsecond),
         true <- send_started_us < deadline_us,
         {:ok, {connection, generation, token}} <-
           WSConnection.authorize_transport(
             instance_id,
             transport_id,
             self(),
             deadline_us,
             encoded,
             call_timeout_ms(deadline_us)
           ) do
      await_transport_response(%{
        token: token,
        generation: generation,
        transport_id: transport_id,
        client_id: client_id,
        provider_id: provider_id,
        context: context,
        deadline_us: deadline_us,
        started_us: send_started_us,
        connection: connection,
        certainty: :indeterminate
      })
    else
      false ->
        record_send_failure(context, :deadline)
        {:error, normalize_start_error(:deadline, provider_id)}

      {:error, :deadline_expired} ->
        record_send_failure(context, :deadline)
        {:error, normalize_start_error(:deadline, provider_id)}

      {:error, :owner_down} ->
        record_send_failure(context, :owner_down)
        {:error, normalize_start_error(:owner_down, provider_id)}

      {:error, reason} ->
        record_send_failure(context, reason)
        {:error, normalize_start_error(reason, provider_id)}
    end
  end

  defp normalize_start_error(:owner_down, provider_id) do
    JError.new(-32_000, "WebSocket attempt owner ended before send",
      provider_id: provider_id,
      transport: :ws,
      category: :cancelled,
      retriable?: false,
      breaker_penalty?: false
    )
  end

  defp normalize_start_error(reason, provider_id), do: normalize_ws_error(reason, provider_id)

  defp await_transport_response(%{
         token: token,
         generation: generation,
         transport_id: transport_id,
         client_id: client_id,
         provider_id: provider_id,
         context: context,
         deadline_us: deadline_us,
         started_us: started_us,
         connection: connection,
         certainty: certainty
       }) do
    receive do
      {:ws_transport_send_accepted, ^token, ^generation, accepted_at_us} ->
        await_transport_response(%{
          token: token,
          generation: generation,
          transport_id: transport_id,
          client_id: client_id,
          provider_id: provider_id,
          context: context,
          deadline_us: deadline_us,
          started_us: accepted_at_us,
          connection: connection,
          certainty: certainty
        })

      {:ws_transport_send_confirmed, ^token, ^generation, written_at_us} ->
        AttemptProtocol.observe_at(context, :send_confirmed, written_at_us, %{})

        await_transport_response(%{
          token: token,
          generation: generation,
          transport_id: transport_id,
          client_id: client_id,
          provider_id: provider_id,
          context: context,
          deadline_us: deadline_us,
          started_us: started_us,
          connection: connection,
          certainty: :dispatched
        })

      {:ws_transport_send_rejected, ^token, ^generation, reason} ->
        record_send_failure(context, reason)
        {:error, normalize_start_error(reason, provider_id)}

      {:ws_transport_response, ^token, ^generation, ^connection, validation, raw_bytes,
       received_at_us, validated_at_us}
      when validated_at_us < deadline_us ->
        io_duration_us = max(received_at_us - started_us, 0)

        settle_validated_response(%{
          validation: validation,
          raw_bytes: raw_bytes,
          transport_id: transport_id,
          client_id: client_id,
          context: context,
          provider_id: provider_id,
          io_duration_us: io_duration_us,
          validated_at_us: validated_at_us
        })

      {:ws_transport_response, ^token, ^generation, ^connection, _validation, _raw_bytes,
       _received_at_us, _validated_at_us} ->
        AttemptProtocol.terminal(context, :transport_failure, %{
          reason: :timeout,
          certainty: :dispatched
        })

        {:error, normalize_ws_error(:timeout, provider_id)}

      {:ws_transport_timeout, ^token, ^generation} ->
        AttemptProtocol.terminal(context, :transport_failure, %{
          reason: :timeout,
          certainty: certainty
        })

        {:error, normalize_ws_error(:timeout, provider_id)}

      {:ws_transport_disconnected, ^token, ^generation, reason} ->
        AttemptProtocol.terminal(context, :transport_failure, %{
          reason: :connection_error,
          certainty: certainty
        })

        {:error, normalize_ws_error(reason, provider_id)}
    end
  end

  defp settle_validated_response(%{
         validation: validation,
         raw_bytes: raw_bytes,
         transport_id: transport_id,
         client_id: client_id,
         context: context,
         provider_id: provider_id,
         io_duration_us: io_duration_us,
         validated_at_us: validated_at_us
       }) do
    finalized =
      case validation do
        {:ok, validated} ->
          UpstreamResponse.finalize_unary(validated, raw_bytes, transport_id, client_id)

        {:invalid, reason} ->
          {:invalid, reason}
      end

    case finalized do
      {:ok, response} ->
        AttemptProtocol.terminal_at(
          context,
          :response,
          %{response_kind: :success, io_duration_us: io_duration_us},
          validated_at_us
        )

        {:ok, response}

      {:error, %JError{} = error} ->
        %{category: category, retriable?: retriable?, breaker_penalty?: breaker_penalty?} =
          ErrorClassifier.classify(error.code, error.message,
            data: error.data,
            provider_id: provider_id
          )

        AttemptProtocol.terminal_at(
          context,
          :response,
          %{
            response_kind: :error,
            error_code: error.code,
            error_category: category,
            io_duration_us: io_duration_us
          },
          validated_at_us
        )

        {:error,
         %{
           error
           | provider_id: provider_id,
             transport: :ws,
             category: category,
             retriable?: retriable?,
             breaker_penalty?: breaker_penalty?
         }}

      {:invalid, reason} ->
        AttemptProtocol.terminal_at(
          context,
          :invalid_response,
          %{reason: reason, io_duration_us: io_duration_us},
          validated_at_us
        )

        {:error,
         JError.new(-32_700, "Invalid JSON-RPC response",
           provider_id: provider_id,
           transport: :ws,
           category: :server_error,
           retriable?: true,
           breaker_penalty?: true,
           data: %{reason: reason}
         )}
    end
  end

  defp send_error_certainty(:deadline), do: :not_dispatched
  defp send_error_certainty(:owner_down), do: :not_dispatched
  defp send_error_certainty(:cancelled), do: :not_dispatched
  defp send_error_certainty(:stale_generation), do: :not_dispatched
  defp send_error_certainty(:stale_connection), do: :not_dispatched
  defp send_error_certainty(:invalid_latch), do: :not_dispatched
  defp send_error_certainty(:capacity), do: :not_dispatched
  defp send_error_certainty(:not_connected), do: :not_dispatched
  defp send_error_certainty(:duplicate_transport_id), do: :not_dispatched
  defp send_error_certainty(:invalid_transport_id), do: :not_dispatched
  defp send_error_certainty(_reason), do: :indeterminate

  defp ws_reason(:deadline), do: :deadline
  defp ws_reason(:owner_down), do: :cancelled
  defp ws_reason(:cancelled), do: :cancelled
  defp ws_reason(:stale_generation), do: :stale_connection
  defp ws_reason(:stale_connection), do: :stale_connection
  defp ws_reason(:not_connected), do: :not_connected
  defp ws_reason(_reason), do: :send_error

  defp record_send_failure(context, reason) do
    case send_error_certainty(reason) do
      :not_dispatched ->
        AttemptProtocol.predispatch_failure(context, ws_reason(reason))

      certainty ->
        AttemptProtocol.terminal(context, :transport_failure, %{
          reason: ws_reason(reason),
          certainty: certainty
        })
    end
  end

  defp normalize_ws_error(:capacity, provider_id) do
    JError.new(-32_008, "WebSocket transport admission unavailable",
      provider_id: provider_id,
      transport: :ws,
      category: :local_capacity_rejection,
      retriable?: true,
      breaker_penalty?: false,
      data: %{reason: :capacity}
    )
  end

  defp normalize_ws_error(:deadline, provider_id),
    do:
      ErrorNormalizer.normalize(:timeout,
        provider_id: provider_id,
        context: :transport,
        transport: :ws
      )

  defp normalize_ws_error(reason, provider_id) do
    ErrorNormalizer.normalize(reason,
      provider_id: provider_id,
      context: :transport,
      transport: :ws
    )
  end

  defp call_timeout_ms(deadline_us) do
    case remaining_us(deadline_us) do
      0 -> 0
      remaining_us -> div(remaining_us + 999, 1_000)
    end
  end

  defp remaining_us(deadline_us),
    do: max(deadline_us - System.monotonic_time(:microsecond), 0)

  defp generate_transport_id do
    sequence = System.unique_integer([:positive, :monotonic])
    "lasso-#{sequence}"
  end

  @impl true
  def subscribe(channel, rpc_request, handler_pid) when is_pid(handler_pid) do
    %{instance_id: instance_id, provider_id: provider_id} = channel

    method = Map.get(rpc_request, "method")
    params = Map.get(rpc_request, "params", [])

    case method do
      "eth_subscribe" ->
        case WSConnection.request(
               instance_id,
               method,
               params,
               30_000
             ) do
          {:ok, %Response.Success{} = response} ->
            case Response.Success.decode_result(response) do
              {:ok, subscription_id} ->
                # Return a subscription reference with the upstream subscription ID
                {:ok, {provider_id, subscription_id, handler_pid}}

              {:error, reason} ->
                {:error, {:decode_failed, reason}}
            end

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :unsupported_method}
    end
  end

  @impl true
  def unsubscribe(_channel, {provider_id, topic, _handler_pid}) do
    # In a full implementation, we'd send an eth_unsubscribe message
    # For now, we'll just return ok since the existing system
    # doesn't have explicit unsubscribe support
    Logger.debug("WebSocket unsubscribe", provider: provider_id, topic: topic)
    :ok
  end

  def unsubscribe(_channel, _subscription_ref) do
    {:error, :invalid_subscription_ref}
  end

  @impl true
  def close(channel) do
    %{connection_pid: connection_pid} = channel
    # We don't actually close the connection since it might be shared
    # In a full implementation with connection pools, we'd decrement reference count
    Logger.debug("WebSocket channel close requested", connection: inspect(connection_pid))
    :ok
  end

  # Private functions

  defp resolve_instance_id(profile, chain, provider_id) do
    Catalog.lookup_instance_id(profile, chain, provider_id) || "#{chain}:#{provider_id}"
  end

  defp get_ws_url(provider_config) do
    Map.get(provider_config, :ws_url)
  end
end

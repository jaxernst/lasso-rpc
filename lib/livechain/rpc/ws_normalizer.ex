defmodule Livechain.RPC.WSNormalizer do
  @moduledoc """
  WebSocket-specific error normalization to %Livechain.JSONRPC.Error{}.

  Goals:
  - Provide a single, transport-agnostic error shape for policy decisions
  - Encode retriability via JSON-RPC error categories
  - Keep WS error semantics consistent with HTTP path
  """

  alias Livechain.JSONRPC.Error, as: JError

  @doc """
  Normalize an error returned by `WebSockex.start_link/3`.
  """
  @spec normalize_connect_error(any(), String.t() | nil) :: JError.t()
  def normalize_connect_error(%WebSockex.RequestError{code: 429}, provider_id),
    do: JError.new(429, "Rate limited", provider_id: provider_id)

  # Some intermediaries may return 408 on handshake; treat as retriable infra failure
  def normalize_connect_error(%WebSockex.RequestError{code: 408, message: msg}, provider_id),
    do: JError.new(-32000, msg || "Upstream timeout", provider_id: provider_id)

  def normalize_connect_error(%WebSockex.RequestError{code: code, message: msg}, provider_id)
      when is_integer(code) and code >= 500 and code <= 599,
      do: JError.new(code, msg || "Upstream server error", provider_id: provider_id)

  def normalize_connect_error(%WebSockex.RequestError{code: code, message: msg}, provider_id)
      when is_integer(code) and code >= 400 and code <= 499,
      do: JError.new(code, msg || "Client error", provider_id: provider_id)

  def normalize_connect_error(%WebSockex.RequestError{} = err, provider_id),
    do: JError.from({:network_error, {:request_error, err}}, provider_id: provider_id)

  def normalize_connect_error(other, provider_id),
    do: JError.from({:network_error, other}, provider_id: provider_id)

  @doc """
  Normalize a send-frame error from `WebSockex.send_frame/2`.
  """
  @spec normalize_send_error(any(), String.t() | nil) :: JError.t()
  def normalize_send_error(%WebSockex.RequestError{} = e, provider_id),
    do: normalize_connect_error(e, provider_id)

  def normalize_send_error(other, provider_id),
    do: JError.from({:network_error, other}, provider_id: provider_id)

  @doc """
  Normalize a WebSocket close event (RFC 6455 close codes).
  """
  @spec normalize_close(integer(), any(), String.t() | nil) :: JError.t()
  def normalize_close(code, reason, provider_id) do
    case code do
      1000 ->
        # Normal closure - allow reconnect (transient)
        JError.new(-32000, "WebSocket normal closure", provider_id: provider_id)

      1001 ->
        # Going away - treat as network/transient
        JError.from({:network_error, {:close, code, reason}}, provider_id: provider_id)

      1002 ->
        # Protocol error - server-side
        JError.new(-32000, "WebSocket protocol error", provider_id: provider_id)

      1003 ->
        # Unsupported data - client-side, non-retriable
        JError.new(-32600, "WebSocket unsupported data", provider_id: provider_id)

      1008 ->
        # Policy violation - client-side
        JError.new(-32600, "WebSocket policy violation", provider_id: provider_id)

      1009 ->
        # Message too big - client-side
        JError.new(-32602, "WebSocket message too big", provider_id: provider_id)

      1011 ->
        # Internal server error - retriable
        JError.new(-32000, "WebSocket server error", provider_id: provider_id)

      1013 ->
        # Try again later / overload - map to 429 (retriable)
        JError.new(429, "WebSocket try again later", provider_id: provider_id)

      1006 ->
        # Abnormal closure - network/transient
        JError.from({:network_error, {:close, code, reason}}, provider_id: provider_id)

      1012 ->
        # Service restart - retriable
        JError.new(-32000, "WebSocket service restart", provider_id: provider_id)

      1014 ->
        # Bad gateway - retriable
        JError.new(-32000, "WebSocket bad gateway", provider_id: provider_id)

      1015 ->
        # TLS handshake failure - network/transient
        JError.from({:network_error, {:close, code, reason}}, provider_id: provider_id)

      _ ->
        # Unknown/abnormal - treat as network/transient by default
        JError.from({:network_error, {:close, code, reason}}, provider_id: provider_id)
    end
  end

  @doc """
  Normalize a disconnect reason from `WebSockex`.
  """
  @spec normalize_disconnect(any(), String.t() | nil) :: JError.t()
  def normalize_disconnect({:remote, 1013, msg}, provider_id),
    do: JError.new(429, msg || "WebSocket backpressure", provider_id: provider_id)

  def normalize_disconnect({:remote, code, msg}, provider_id) when is_integer(code),
    do: normalize_close(code, msg, provider_id)

  def normalize_disconnect(other, provider_id),
    do: JError.from({:network_error, other}, provider_id: provider_id)
end

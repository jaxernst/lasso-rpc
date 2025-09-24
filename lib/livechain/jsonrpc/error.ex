defmodule Livechain.JSONRPC.Error do
  @moduledoc """
  Typed representation of a JSON-RPC 2.0 error with comprehensive metadata
  for routing, retries, analytics, and Ethereum-specific error handling.

  This struct provides:
  - Standard JSON-RPC 2.0 error codes
  - Ethereum-specific error code mapping
  - Semantic categorization for routing decisions
  - Retriability assessment for failover logic
  - Provider context for debugging

  At the boundary, this serializes to standard JSON-RPC error maps.
  """

  @enforce_keys [:code, :message]
  defstruct [
    :code,
    :message,
    :data,
    :category,
    :provider_id,
    :http_status,
    :retriable?,
    :original_code
  ]

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: map() | nil,
          category: atom() | nil,
          provider_id: String.t() | nil,
          http_status: integer() | nil,
          retriable?: boolean() | nil,
          original_code: integer() | nil
        }

  # JSON-RPC 2.0 standard error codes
  @parse_error -32700
  @invalid_request -32600
  @method_not_found -32601
  @invalid_params -32602
  @internal_error -32603

  # Server error codes (reserved range: -32000 to -32099)
  @generic_server_error -32000
  @rate_limit_error -32005

  # Ethereum-specific error codes (EIP-1193)
  @user_rejected 4001
  @unauthorized 4100
  @unsupported_method 4200
  @unsupported_chain 4900
  @chain_disconnected 4901

  @doc """
  Creates a new JSON-RPC error with automatic categorization and retriability assessment.
  """
  @spec new(integer(), String.t(), keyword()) :: t()
  def new(code, message, opts \\ []) do
    normalized_code = normalize_error_code(code)

    %__MODULE__{
      code: normalized_code,
      message: message,
      data: Keyword.get(opts, :data),
      category: categorize_error(normalized_code),
      provider_id: Keyword.get(opts, :provider_id),
      http_status: Keyword.get(opts, :http_status),
      retriable?: assess_retriability(normalized_code),
      original_code: code
    }
  end

  @doc """
  Converts this error to a standard JSON-RPC error map for serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    base = %{"code" => error.code, "message" => error.message}

    case error.data do
      nil -> base
      data -> Map.put(base, "data", data)
    end
  end

  @doc """
  Converts this error to a full JSON-RPC response with id.
  """
  @spec to_response(t(), any()) :: map()
  def to_response(%__MODULE__{} = error, id) do
    %{
      "jsonrpc" => "2.0",
      "error" => to_map(error),
      "id" => id
    }
  end

  @doc """
  Coerces any error shape into a %#{__MODULE__}{}.

  Accepts:
  - Existing %#{__MODULE__}{}
  - Provider-style maps with code/message (binary or atom keys)
  - Nested {"error": %{...}} envelopes
  - Internal tuple errors like {:rate_limit, msg}
  - Circuit breaker atoms/tuples
  - Any other value → internal error with details in data

  Optional opts:
  - :provider_id (string)
  """
  @spec from(any(), keyword()) :: t()
  def from(error, opts \\ [])

  def from(%__MODULE__{} = error, _opts), do: error

  # Nested provider envelope
  def from(%{"error" => inner} = _wrapped, opts) when is_map(inner), do: from(inner, opts)
  def from(%{error: inner} = _wrapped, opts) when is_map(inner), do: from(inner, opts)

  # Provider error maps
  def from(%{"code" => code, "message" => message} = err, opts)
      when is_integer(code) and is_binary(message) do
    new(code, message,
      data: Map.get(err, "data"),
      provider_id: Keyword.get(opts, :provider_id),
      http_status: Map.get(err, "http_status")
    )
  end

  def from(%{code: code, message: message} = err, opts)
      when is_integer(code) and is_binary(message) do
    new(code, message,
      data: Map.get(err, :data),
      provider_id: Keyword.get(opts, :provider_id),
      http_status: Map.get(err, :http_status)
    )
  end

  # Internal tuple errors
  def from({:rate_limit, msg}, _opts), do: new(429, msg || "Rate limit exceeded")

  def from({:client_error, payload}, _opts) do
    {message, http_status} = extract_message_and_status(payload)
    new(-32602, message || "Invalid request", http_status: http_status)
  end

  def from({:server_error, payload}, _opts) do
    {message, http_status} = extract_message_and_status(payload)
    new(-32000, message || "Upstream server error", http_status: http_status)
  end

  def from({:network_error, payload}, _opts) do
    {message, http_status} = extract_message_and_status(payload)
    new(-32000, message || "Network error", http_status: http_status)
  end

  def from({:encode_error, msg}, _opts), do: new(-32600, msg || "Failed to encode request")

  def from({:response_decode_error, msg}, _opts),
    do: new(-32000, msg || "Failed to decode response")

  # Circuit breaker
  def from(:circuit_open, _opts), do: new(-32000, "Circuit breaker open")
  def from(:circuit_opening, _opts), do: new(-32000, "Circuit breaker opening")
  def from(:circuit_reopening, _opts), do: new(-32000, "Circuit breaker reopening")
  def from({:circuit_open, _details}, _opts), do: new(-32000, "Circuit breaker open")
  def from({:circuit_opening, _details}, _opts), do: new(-32000, "Circuit breaker opening")
  def from({:circuit_reopening, _details}, _opts), do: new(-32000, "Circuit breaker reopening")

  # Atom errors fall back to internal error
  def from(atom, _opts) when is_atom(atom), do: new(-32603, to_string(atom))

  # Fallback
  def from(other, _opts), do: new(-32603, "Internal error", data: %{details: inspect(other)})

  defp extract_message_and_status(%{status: status, body: body}) when is_integer(status) do
    {format_http_message(status, body), status}
  end

  defp extract_message_and_status(other) when is_binary(other), do: {other, nil}
  defp extract_message_and_status(other), do: {inspect(other), nil}

  defp format_http_message(status, body) do
    "HTTP #{status}: #{truncate_body(body)}"
  end

  defp truncate_body(body) when is_binary(body) do
    if String.length(body) > 300, do: String.slice(body, 0, 300) <> "...", else: body
  end

  defp truncate_body(other), do: inspect(other)

  # Private helper functions

  defp normalize_error_code(code) when is_integer(code) do
    cond do
      # Standard JSON-RPC errors - pass through
      code in [
        @parse_error,
        @invalid_request,
        @method_not_found,
        @invalid_params,
        @internal_error
      ] ->
        code

      # Server error range - pass through
      code >= -32099 and code <= -32000 ->
        code

      # Ethereum-specific mappings
      code == @user_rejected ->
        @invalid_request

      code == @unauthorized ->
        @invalid_request

      code == @unsupported_method ->
        @method_not_found

      code == @unsupported_chain ->
        @generic_server_error

      code == @chain_disconnected ->
        @generic_server_error

      # HTTP status codes
      code == 429 ->
        @rate_limit_error

      code >= 400 and code < 500 ->
        @invalid_request

      code >= 500 ->
        @generic_server_error

      # Default mapping
      true ->
        @internal_error
    end
  end

  defp categorize_error(code) do
    cond do
      code == @parse_error -> :decode_error
      code == @invalid_request -> :client_error
      code == @method_not_found -> :method_error
      code == @invalid_params -> :client_error
      code == @internal_error -> :server_error
      code == @rate_limit_error -> :rate_limit
      code >= -32099 and code <= -32000 -> :server_error
      code == @user_rejected -> :user_error
      code == @unauthorized -> :auth_error
      code == @unsupported_method -> :method_error
      code == @unsupported_chain -> :chain_error
      code == @chain_disconnected -> :network_error
      code == 429 -> :rate_limit
      code >= 400 and code < 500 -> :client_error
      code >= 500 -> :server_error
      true -> :unknown_error
    end
  end

  defp assess_retriability(code) do
    cond do
      # Non-retriable errors
      code in [
        @invalid_request,
        @method_not_found,
        @invalid_params,
        @user_rejected,
        @unauthorized
      ] ->
        false

      # Retriable errors
      code in [@parse_error, @internal_error, @rate_limit_error, @chain_disconnected] ->
        true

      # Server errors are generally retriable
      code >= -32099 and code <= -32000 ->
        true

      # HTTP errors
      code == 429 ->
        true

      code >= 500 ->
        true

      code >= 400 and code < 500 ->
        false

      # Default to non-retriable for safety
      true ->
        false
    end
  end
end

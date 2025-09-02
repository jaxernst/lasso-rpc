defmodule Livechain.RPC.Error do
  @moduledoc """
  Provides comprehensive JSON-RPC 2.0 error normalization for the RPC aggregator.
  
  Ensures consistent error responses across:
  - HTTP and WebSocket protocols
  - Different provider error formats
  - Various error conditions (rate limits, network errors, etc.)
  
  All errors follow the JSON-RPC 2.0 specification:
  ```json
  {
    "jsonrpc": "2.0",
    "error": {
      "code": -32600,
      "message": "Invalid Request",
      "data": "Additional error information (optional)"
    },
    "id": 1
  }
  ```
  """

  @type typed_error ::
          {:rate_limit, String.t()}
          | {:server_error, String.t()}
          | {:client_error, String.t()}
          | {:network_error, String.t()}
          | {:decode_error, String.t()}
          | {:circuit_open, any()}
          | {:circuit_opening, any()}
          | {:circuit_reopening, any()}

  @type json_rpc_error :: %{
          required(:code) => integer(),
          required(:message) => String.t(),
          optional(:data) => any()
        }

  @type json_rpc_response :: %{
          required(:jsonrpc) => String.t(),
          required(:error) => json_rpc_error(),
          required(:id) => any()
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

  @doc """
  Normalizes any error into a JSON-RPC 2.0 compliant error structure.
  
  This is the main entry point for error normalization. It handles:
  - Typed errors from internal systems
  - Provider error responses
  - Map-based errors with code/message
  - Unknown error formats
  """
  @spec normalize(any(), any()) :: json_rpc_response()
  def normalize(error, request_id \\ nil) do
    %{
      "jsonrpc" => "2.0",
      "error" => normalize_error(error),
      "id" => request_id
    }
  end

  @doc """
  Normalizes an error to just the error object (without the JSON-RPC wrapper).
  
  Returns a map with `code`, `message`, and optionally `data` fields.
  """
  @spec normalize_error(any()) :: json_rpc_error()
  def normalize_error(error) do
    case error do
      # Already normalized JSON-RPC error
      %{"code" => code, "message" => message} = err when is_integer(code) and is_binary(message) ->
        sanitize_error_object(err)
      
      %{code: code, message: message} = err when is_integer(code) and is_binary(message) ->
        sanitize_error_object(err)
      
      # Provider error responses (nested error object)
      %{"error" => inner_error} when is_map(inner_error) ->
        normalize_error(inner_error)
      
      %{error: inner_error} when is_map(inner_error) ->
        normalize_error(inner_error)
      
      # Typed internal errors
      {:rate_limit, msg} ->
        create_error(@rate_limit_error, msg || "Rate limit exceeded", %{category: :rate_limit})
      
      {:server_error, msg} ->
        create_error(@generic_server_error, msg || "Upstream server error", %{category: :server_error})
      
      {:client_error, msg} ->
        create_error(@invalid_params, msg || "Invalid request", %{category: :client_error})
      
      {:network_error, msg} ->
        create_error(@generic_server_error, msg || "Network error", %{category: :network_error})
      
      {:decode_error, msg} ->
        create_error(@parse_error, msg || "Parse error", %{category: :decode_error})
      
      {:circuit_open, details} ->
        create_error(@generic_server_error, "Circuit breaker open", %{category: :circuit_breaker, details: inspect(details)})
      
      {:circuit_opening, details} ->
        create_error(@generic_server_error, "Circuit breaker opening", %{category: :circuit_breaker, details: inspect(details)})
      
      {:circuit_reopening, details} ->
        create_error(@generic_server_error, "Circuit breaker reopening", %{category: :circuit_breaker, details: inspect(details)})
      
      # String errors
      msg when is_binary(msg) ->
        create_error(@internal_error, msg, nil)
      
      # Atom errors
      atom when is_atom(atom) ->
        create_error(@internal_error, to_string(atom), nil)
      
      # Any other error format
      other ->
        create_error(@internal_error, "Internal error", %{details: inspect(other)})
    end
  end

  @doc """
  Maps provider-specific error codes to standard JSON-RPC error codes.
  
  Different providers may return different error codes for similar conditions.
  This function normalizes them to standard JSON-RPC 2.0 codes.
  """
  @spec map_provider_error_code(integer() | String.t()) :: integer()
  def map_provider_error_code(code) when is_binary(code) do
    case Integer.parse(code) do
      {int_code, _} -> map_provider_error_code(int_code)
      _ -> @internal_error
    end
  end

  def map_provider_error_code(code) when is_integer(code) do
    cond do
      # Standard JSON-RPC errors - pass through
      code in [@parse_error, @invalid_request, @method_not_found, @invalid_params, @internal_error] ->
        code
      
      # Server error range - pass through
      code >= -32099 and code <= -32000 ->
        code
      
      # Common provider-specific codes
      code == 429 -> @rate_limit_error  # HTTP 429 status
      code == -32005 -> @rate_limit_error  # Explicit rate limit
      code == 4001 -> @invalid_request  # user rejection
      code == 4100 -> @invalid_request  # Unauthorized
      code == 4200 -> @method_not_found  # Unsupported method
      code == 4900 -> @generic_server_error  # Provider disconnected
      code == 4901 -> @generic_server_error  # Chain disconnected
      
      # Default mapping
      true -> @internal_error
    end
  end

  @doc """
  Backward compatibility function for existing code.
  Converts typed errors to JSON-RPC error format.
  """
  @spec to_json_rpc(typed_error() | any()) :: json_rpc_error()
  def to_json_rpc(error) do
    normalize_error(error)
  end

  # Private helper functions

  defp create_error(code, message, nil) do
    %{"code" => code, "message" => message}
  end

  defp create_error(code, message, data) do
    %{"code" => code, "message" => message, "data" => data}
  end

  defp sanitize_error_object(error) do
    base = %{
      "code" => get_error_code(error),
      "message" => get_error_message(error)
    }
    
    case get_error_data(error) do
      nil -> base
      data -> Map.put(base, "data", data)
    end
  end

  defp get_error_code(%{"code" => code}) when is_integer(code), do: code
  defp get_error_code(%{code: code}) when is_integer(code), do: code
  defp get_error_code(%{"code" => code}) when is_binary(code), do: map_provider_error_code(code)
  defp get_error_code(%{code: code}) when is_binary(code), do: map_provider_error_code(code)
  defp get_error_code(_), do: @internal_error

  defp get_error_message(%{"message" => msg}) when is_binary(msg), do: msg
  defp get_error_message(%{message: msg}) when is_binary(msg), do: msg
  defp get_error_message(_), do: "Internal error"

  defp get_error_data(%{"data" => data}), do: data
  defp get_error_data(%{data: data}), do: data
  defp get_error_data(_), do: nil
end

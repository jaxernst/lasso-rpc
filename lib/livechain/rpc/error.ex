defmodule Livechain.RPC.Error do
  @moduledoc """
  Normalizes internal/HTTP client typed errors into JSON-RPC error shapes.
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

  @spec to_json_rpc(typed_error) :: %{code: integer(), message: String.t(), data: map()}
  def to_json_rpc({:rate_limit, msg}) do
    %{code: -32005, message: msg || "Rate limit exceeded", data: %{category: :rate_limit}}
  end

  def to_json_rpc({:server_error, msg}) do
    %{code: -32000, message: msg || "Upstream server error", data: %{category: :server_error}}
  end

  def to_json_rpc({:client_error, msg}) do
    %{code: -32602, message: msg || "Invalid request", data: %{category: :client_error}}
  end

  def to_json_rpc({:network_error, msg}) do
    %{code: -32000, message: msg || "Network error", data: %{category: :network_error}}
  end

  def to_json_rpc({:decode_error, msg}) do
    %{code: -32700, message: msg || "Decode error", data: %{category: :decode_error}}
  end

  def to_json_rpc({:circuit_open, _}) do
    %{code: -32000, message: "Circuit open", data: %{category: :circuit_breaker}}
  end

  def to_json_rpc({:circuit_opening, _}) do
    %{code: -32000, message: "Circuit opening", data: %{category: :circuit_breaker}}
  end

  def to_json_rpc({:circuit_reopening, _}) do
    %{code: -32000, message: "Circuit reopening", data: %{category: :circuit_breaker}}
  end

  def to_json_rpc(other) do
    %{
      code: -32603,
      message: "Internal error",
      data: %{category: :unknown, detail: inspect(other)}
    }
  end
end

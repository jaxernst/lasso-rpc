defmodule Livechain.RPC.Adapters.Generic do
  @moduledoc """
  Default provider adapter that assumes standard JSON-RPC 2.0 behavior and
  performs minimal normalization.
  """

  @behaviour Livechain.RPC.ProviderAdapter

  alias Livechain.JSONRPC.Error, as: JError

  @impl true
  def normalize_request(request, _ctx), do: request

  @impl true
  def normalize_response(%{"error" => err} = _resp, ctx) when is_map(err) do
    {:error, normalize_error(err, ctx)}
  end

  def normalize_response(%{"result" => result}, _ctx), do: {:ok, result}

  def normalize_response(other, _ctx), do: {:ok, other}

  @impl true
  def normalize_error(%{"code" => code, "message" => message} = err, ctx)
      when is_integer(code) and is_binary(message) do
    %JError{
      code: code,
      message: message,
      data: Map.get(err, "data"),
      category: map_category(code),
      provider_id: Map.get(ctx, :provider_id),
      retriable?: retriable?(code)
    }
  end

  def normalize_error(%{code: code, message: message} = err, ctx)
      when is_integer(code) and is_binary(message) do
    %JError{
      code: code,
      message: message,
      data: Map.get(err, :data),
      category: map_category(code),
      provider_id: Map.get(ctx, :provider_id),
      retriable?: retriable?(code)
    }
  end

  def normalize_error(other, ctx) do
    %JError{
      code: -32603,
      message: "Internal error",
      data: %{details: inspect(other)},
      category: :server_error,
      provider_id: Map.get(ctx, :provider_id),
      retriable?: true
    }
  end

  @impl true
  def headers(_ctx), do: []

  # Helpers

  defp map_category(code) when code == -32700, do: :decode_error
  defp map_category(code) when code == -32600, do: :invalid_request
  defp map_category(code) when code == -32601, do: :method_not_found
  defp map_category(code) when code == -32602, do: :invalid_params
  defp map_category(code) when code == -32603, do: :server_error
  defp map_category(code) when code >= -32099 and code <= -32000, do: :server_error
  defp map_category(429), do: :rate_limit
  defp map_category(_), do: :server_error

  defp retriable?(code) when code in [-32700], do: true
  defp retriable?(code) when code == 429, do: true
  defp retriable?(code) when code >= -32099 and code <= -32000, do: true
  defp retriable?(_), do: false
end


defmodule Lasso.RPC.Providers.Generic do
  @moduledoc """
  Standard JSON-RPC 2.0 normalization.

  Provides envelope parsing, error construction, and response normalization
  for all providers.
  """

  alias Lasso.JSONRPC.Error, as: JError

  @spec normalize_request(map(), map()) :: map()
  def normalize_request(request, _ctx), do: request

  @spec normalize_response(map(), map()) :: {:ok, any()} | {:error, JError.t()}
  def normalize_response(%{"error" => err} = _resp, ctx) when is_map(err) do
    {:error, normalize_error(err, ctx)}
  end

  def normalize_response(%{"result" => result}, _ctx), do: {:ok, result}

  def normalize_response(other, _ctx), do: {:ok, other}

  @spec normalize_error(map() | any(), map()) :: JError.t()
  def normalize_error(%{"code" => code, "message" => message} = err, ctx)
      when is_integer(code) and is_binary(message) do
    JError.new(code, message,
      data: Map.get(err, "data"),
      provider_id: Map.get(ctx, :provider_id),
      http_status: Map.get(err, "http_status")
    )
  end

  def normalize_error(%{code: code, message: message} = err, ctx)
      when is_integer(code) and is_binary(message) do
    JError.new(code, message,
      data: Map.get(err, :data),
      provider_id: Map.get(ctx, :provider_id),
      http_status: Map.get(err, :http_status)
    )
  end

  def normalize_error(other, ctx) do
    JError.new(-32_603, "Internal error",
      data: %{details: inspect(other)},
      provider_id: Map.get(ctx, :provider_id)
    )
  end
end

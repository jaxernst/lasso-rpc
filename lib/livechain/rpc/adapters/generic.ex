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
    JError.new(-32603, "Internal error",
      data: %{details: inspect(other)},
      provider_id: Map.get(ctx, :provider_id)
    )
  end

  @impl true
  def headers(_ctx), do: []
end

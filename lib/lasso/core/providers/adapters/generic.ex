defmodule Lasso.RPC.Providers.Generic do
  @moduledoc """
  Default provider adapter that assumes standard JSON-RPC 2.0 behavior and
  performs minimal normalization.

  This adapter provides:
  - Permissive capability validation (assumes all methods supported)
  - Standard JSON-RPC 2.0 normalization
  - No provider-specific headers

  Used as the fallback adapter for providers without custom adapters.

  Note: This module does NOT use `use Lasso.RPC.ProviderAdapter` because it IS
  the base implementation that other adapters delegate to.
  """

  @behaviour Lasso.RPC.ProviderAdapter

  alias Lasso.JSONRPC.Error, as: JError

  import Lasso.RPC.Providers.AdapterHelpers

  # Capability Validation (Permissive - assumes all methods supported)

  @impl true
  def supports_method?(_method, _transport, _ctx), do: :ok

  @impl true
  def validate_params("eth_getLogs", params, _transport, ctx) do
    case get_adapter_config(ctx, :max_block_range, nil) do
      nil -> :ok
      limit -> validate_block_range(params, ctx, limit)
    end
  end

  def validate_params(_method, _params, _transport, _ctx), do: :ok

  # Normalization (Standard JSON-RPC 2.0)

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
    JError.new(-32_603, "Internal error",
      data: %{details: inspect(other)},
      provider_id: Map.get(ctx, :provider_id)
    )
  end

  @impl true
  def headers(_ctx), do: []

  @impl true
  def metadata do
    %{
      type: :default,
      tier: :unknown,
      known_limitations: [],
      unsupported_categories: [],
      unsupported_methods: [],
      conditional_support: %{},
      last_verified: ~D[2025-01-17]
    }
  end

  @impl true
  def classify_error(_code, _message), do: :default
end

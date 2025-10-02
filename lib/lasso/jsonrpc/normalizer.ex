defmodule Lasso.RPC.Normalizer do
  @moduledoc """
  Central normalization pipeline: provider-aware envelope handling, error
  construction, and optional method result casting.
  """

  alias Lasso.JSONRPC.Error, as: JError

  @type response_map :: map()

  @doc """
  Normalize a decoded JSON-RPC response from an upstream provider.

  Options:
  - :cast (boolean) – if true, attempt method-specific casting when available (default: false)
  - :adapter (module) – provider adapter module (default: Generic)
  - :provider_id (string) – for context/telemetry
  """
  @spec run(String.t(), String.t(), response_map, keyword()) ::
          {:ok, any()} | {:error, JError.t()}
  def run(provider_id, method, response, opts \\ [])

  def run(provider_id, method, response, opts) when is_map(response) do
    adapter = Keyword.get(opts, :adapter, Lasso.RPC.Providers.Generic)
    ctx = %{provider_id: provider_id, method: method}

    case adapter.normalize_response(response, ctx) do
      {:ok, result} ->
        emit_result_telemetry(provider_id, method, :ok)
        maybe_cast_result(method, result, ctx, opts)

      {:error, err} ->
        jerr = adapter.normalize_error(err, ctx)
        emit_error_telemetry(provider_id, method, jerr)
        {:error, jerr}
    end
  end

  def run(provider_id, method, other, opts) do
    # Non-map responses: treat as internal error
    adapter = Keyword.get(opts, :adapter, Lasso.RPC.Providers.Generic)
    ctx = %{provider_id: provider_id, method: method}
    {:error, adapter.normalize_error(other, ctx)}
  end

  defp maybe_cast_result(_method, result, _ctx, opts) do
    case Keyword.get(opts, :cast, false) do
      true ->
        # No method normalizers yet
        {:ok, result}

      _ ->
        {:ok, result}
    end
  end

  # In the future, dispatch to method normalizers here
  # defp cast_with_method_normalizer(result, opts), do: ...

  defp emit_result_telemetry(provider_id, method, status) do
    :telemetry.execute([:lasso, :normalize, :result], %{count: 1}, %{
      provider_id: provider_id,
      method: method,
      status: status
    })
  end

  defp emit_error_telemetry(provider_id, method, %JError{} = jerr) do
    :telemetry.execute([:lasso, :normalize, :error], %{count: 1}, %{
      provider_id: provider_id,
      method: method,
      code: jerr.code,
      category: jerr.category,
      retriable?: jerr.retriable?
    })
  end
end

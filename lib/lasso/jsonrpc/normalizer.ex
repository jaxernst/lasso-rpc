defmodule Lasso.RPC.Normalizer do
  @moduledoc """
  Central normalization pipeline: provider-aware envelope handling, error
  construction, and optional method result casting.

  ## Adapter Resolution

  The normalizer automatically resolves the appropriate adapter for each provider
  using the AdapterRegistry. If a provider doesn't have a custom adapter, it falls
  back to the Generic adapter.

  ## Default Implementations

  All adapters that `use Lasso.RPC.ProviderAdapter` automatically inherit default
  normalization behavior from the Generic adapter. This means we can call
  normalization callbacks directly without checking if they exist - they're
  guaranteed to be implemented (either custom or default).
  """

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.Providers.AdapterRegistry

  @type response_map :: map()

  @doc """
  Normalize a decoded JSON-RPC response from an upstream provider.

  The adapter is automatically resolved from the provider_id using AdapterRegistry.

  Options:
  - :cast (boolean) – if true, attempt method-specific casting when available (default: false)
  - :adapter (module) – provider adapter module (optional, auto-resolved from provider_id)
  """
  @spec run(String.t(), String.t(), response_map, keyword()) ::
          {:ok, any()} | {:error, JError.t()}
  def run(provider_id, method, response, opts \\ [])

  def run(provider_id, method, response, opts) when is_map(response) do
    adapter = resolve_adapter(provider_id, opts)
    ctx = %{provider_id: provider_id, method: method}

    # All adapters implement normalize_response (via behaviour or __using__ macro)
    # No need for function_exported? checks
    case adapter.normalize_response(response, ctx) do
      {:ok, result} ->
        emit_result_telemetry(provider_id, method, :ok)
        maybe_cast_result(method, result, ctx, opts)

      {:error, err} ->
        # All adapters implement normalize_error (via behaviour or __using__ macro)
        jerr = adapter.normalize_error(err, ctx)
        emit_error_telemetry(provider_id, method, jerr)
        {:error, jerr}
    end
  end

  def run(provider_id, method, other, opts) do
    # Non-map responses: treat as internal error
    adapter = resolve_adapter(provider_id, opts)
    ctx = %{provider_id: provider_id, method: method}
    {:error, adapter.normalize_error(other, ctx)}
  end

  # Private: Resolve adapter from provider_id or opts
  defp resolve_adapter(provider_id, opts) do
    case Keyword.get(opts, :adapter) do
      nil -> AdapterRegistry.adapter_for(provider_id)
      adapter_module -> adapter_module
    end
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

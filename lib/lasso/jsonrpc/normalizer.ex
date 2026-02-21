defmodule Lasso.RPC.Normalizer do
  @moduledoc """
  Central normalization pipeline: envelope handling, error construction,
  and telemetry emission for upstream JSON-RPC responses.
  """

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.Providers.Generic

  @type response_map :: map()

  @doc """
  Normalize a decoded JSON-RPC response from an upstream provider.
  """
  @spec run(String.t(), String.t(), response_map) :: {:ok, any()} | {:error, JError.t()}
  def run(provider_id, method, response) when is_map(response) do
    ctx = %{provider_id: provider_id, method: method}

    case Generic.normalize_response(response, ctx) do
      {:ok, result} ->
        emit_result_telemetry(provider_id, method, :ok)
        {:ok, result}

      {:error, err} ->
        jerr = Generic.normalize_error(err, ctx)
        emit_error_telemetry(provider_id, method, jerr)
        {:error, jerr}
    end
  end

  def run(provider_id, method, other) do
    ctx = %{provider_id: provider_id, method: method}
    {:error, Generic.normalize_error(other, ctx)}
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

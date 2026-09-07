defmodule Lasso.RPC.Observability do
  @moduledoc "Builds opt-in client metadata and enforces the encoded header size limit."

  alias Lasso.RPC.RequestContext

  @doc """
  Builds client-visible metadata (subset of log event).

  Returns a map suitable for inclusion in HTTP headers or JSON-RPC response body.
  Respects size limits and redaction rules.
  """
  def build_client_metadata(%RequestContext{} = ctx) do
    metadata = %{
      version: "1.0",
      request_id: ctx.request_id,
      strategy: to_string(ctx.strategy),
      chain_id: ctx.chain_id,
      transport: to_string(ctx.transport),
      candidate_providers: format_candidate_providers(ctx.candidate_providers),
      selected_provider: ctx.selected_provider,
      selection_latency_ms: ctx.selection_latency_ms,
      upstream_latency_ms: ctx.upstream_latency_ms,
      end_to_end_latency_ms: ctx.end_to_end_latency_ms,
      lasso_overhead_ms: ctx.lasso_overhead_ms,
      retries: ctx.retries,
      circuit_breaker_state: to_string(ctx.circuit_breaker_state || :unknown)
    }

    # Filter out nil values
    metadata
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc """
  Encodes client metadata as base64url for header transmission.
  Returns {:ok, encoded_string} or {:error, :too_large}.
  """
  def encode_metadata_for_header(metadata) when is_map(metadata) do
    json = Jason.encode!(metadata)
    encoded = Base.url_encode64(json, padding: false)
    max_bytes = get_config(:max_meta_header_bytes, 4096)

    if byte_size(encoded) > max_bytes do
      {:error, :too_large}
    else
      {:ok, encoded}
    end
  end

  defp format_candidate_providers(providers) when is_list(providers), do: providers
  defp format_candidate_providers(_), do: []

  defp get_config(key, default) do
    Application.get_env(:lasso, :observability, []) |> Keyword.get(key, default)
  end
end

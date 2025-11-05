defmodule LassoWeb.Plugs.ObservabilityPlug do
  @moduledoc """
  Plug to handle observability metadata opt-in for HTTP requests.

  Parses the `include_meta` option from query params or headers and
  stores the preference in conn.assigns for later injection of metadata
  into the response.

  ## Options

  Query parameter:
  - `include_meta=headers` - Include metadata in X-Lasso-* response headers
  - `include_meta=body` - Include metadata inline in JSON-RPC response body

  Header:
  - `X-Lasso-Include-Meta: headers|body`

  ## Usage

      plug LassoWeb.Plugs.ObservabilityPlug
  """

  import Plug.Conn

  alias Lasso.RPC.RequestContext

  def init(opts), do: opts

  def call(conn, _opts) do
    include_meta_option = parse_include_meta_option(conn)

    conn
    |> assign(:include_meta, include_meta_option)
    |> assign(:observability_enabled, include_meta_option != :none)
  end

  @doc """
  Injects metadata into the response based on include_meta preference.

  Called after the request has been processed and context is complete.
  """
  def inject_metadata(conn, request_context) do
    case conn.assigns[:include_meta] do
      :headers ->
        inject_metadata_headers(conn, request_context)

      :body ->
        # Body injection happens in the controller/response serialization
        # We just store the context for later access
        assign(conn, :lasso_meta, build_metadata(request_context))

      _ ->
        conn
    end
  end

  @doc """
  Enriches a JSON-RPC response map with lasso_meta field.

  Used when include_meta=body is requested.
  """
  def enrich_response_body(response_map, nil), do: response_map

  def enrich_response_body(response_map, %RequestContext{} = request_context) do
    metadata = build_metadata(request_context)
    Map.put(response_map, "lasso_meta", metadata)
  end

  # Private helpers

  defp parse_include_meta_option(conn) do
    # Check query parameter first
    query_option = conn.query_params["include_meta"]

    # Fall back to header
    header_option =
      case get_req_header(conn, "x-lasso-include-meta") do
        [value | _] -> value
        _ -> nil
      end

    option = query_option || header_option

    case option do
      "headers" -> :headers
      "body" -> :body
      "none" -> :none
      nil -> :none
      _ -> :none
    end
  end

  defp inject_metadata_headers(conn, request_context) do
    # Always include request ID
    conn = put_resp_header(conn, "x-lasso-request-id", request_context.request_id)

    # Try to encode full metadata
    metadata = build_metadata(request_context)

    case Lasso.RPC.Observability.encode_metadata_for_header(metadata) do
      {:ok, encoded} ->
        put_resp_header(conn, "x-lasso-meta", encoded)

      {:error, :too_large} ->
        # Metadata too large, just include request_id
        conn
    end
  end

  defp build_metadata(request_context) do
    Lasso.RPC.Observability.build_client_metadata(request_context)
  end
end

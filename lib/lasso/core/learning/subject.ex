defmodule Lasso.RPC.Learning.Subject do
  @moduledoc """
  Opaque identity for one configured transport and its authorized sharing scope.

  The other transport and the provider display name do not participate. Endpoint
  credentials are hashed as part of the normalized URL; no URL is exposed by the ID.

  Header identity is read from `provider.identity_config` when present, falling
  back to `provider` itself. This lets the digest depend only on the operator's
  configured credentials (api_key, authorization and other configured headers),
  never on transport defaults such as `accept` or `content-type` that a runtime
  channel config may carry alongside them. Any caller holding the operator's
  declared provider configuration, or a runtime config that preserves it under
  `identity_config`, derives the same subject.
  """

  alias Lasso.Providers.ProviderHeaders

  @enforce_keys [:id, :chain_id, :transport, :sharing_scope]
  defstruct @enforce_keys

  @type sharing_scope :: :curated | {:account, binary()} | {:profile, binary()}
  @type t :: %__MODULE__{
          id: binary(),
          chain_id: pos_integer(),
          transport: :http | :ws,
          sharing_scope: sharing_scope()
        }

  @spec new(pos_integer(), :http | :ws, map(), sharing_scope()) :: t() | nil
  def new(chain_id, transport, provider, scope)
      when is_integer(chain_id) and chain_id > 0 and transport in [:http, :ws] do
    identity = Map.get(provider, :identity_config, provider)

    url =
      if transport == :http,
        do: Map.get(identity, :url) || Map.get(identity, :http_url),
        else: Map.get(identity, :ws_url)

    if is_binary(url) and url != "" do
      normalized = normalize_endpoint(url)
      auth = ProviderHeaders.identity_headers(identity)

      digest =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary({1, chain_id, transport, normalized, auth, scope})
        )

      %__MODULE__{
        id: "ls1_" <> Base.url_encode64(digest, padding: false),
        chain_id: chain_id,
        transport: transport,
        sharing_scope: scope
      }
    end
  end

  @spec current?(t(), map(), sharing_scope()) :: boolean()
  def current?(%__MODULE__{} = subject, provider, scope) do
    subject == new(subject.chain_id, subject.transport, provider, scope)
  end

  @doc "Normalizes only scheme, host and default port; opaque path and query stay exact."
  @spec normalize_endpoint(binary()) :: binary()
  def normalize_endpoint(url) when is_binary(url) do
    uri = URI.parse(url)
    scheme = String.downcase(uri.scheme || "")

    port =
      case {scheme, uri.port} do
        {"http", 80} -> nil
        {"https", 443} -> nil
        {"ws", 80} -> nil
        {"wss", 443} -> nil
        {_, value} -> value
      end

    %{
      uri
      | scheme: scheme,
        host: String.downcase(uri.host || ""),
        port: port,
        path: uri.path || "/"
    }
    |> URI.to_string()
  end
end

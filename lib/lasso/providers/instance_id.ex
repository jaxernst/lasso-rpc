defmodule Lasso.Providers.InstanceId do
  @moduledoc """
  Deterministic identity derivation for physical upstream connections.

  A `provider_instance_id` uniquely identifies a physical upstream connection.
  Identity is keyed by `(chain_id, normalized_url, normalized_ws_url, auth)`.
  The optional `:isolated` sharing mode additionally salts the identity with a
  profile ID; otherwise matching authenticated endpoints are shared across
  profiles.

  Format: `"chain_id:host_hint:hash_12"` (e.g., `"1:drpc:a3f2b1c4e5d6"`).

  HTTP and WebSocket endpoint URLs are both identity-relevant, so profiles with
  the same HTTP endpoint but different WebSocket configuration do not share an
  instance.
  """

  alias Lasso.Config.ChainConfig.Provider

  @type sharing_mode :: :auto | :isolated

  @doc """
  Derives a deterministic instance_id for a provider.

  Same `(chain_id, URL, WS URL, auth)` tuple → same instance ID → shared worker.

  ## Options
    * `:profile_id` or `:profile` — deterministic profile scope used when
      `sharing_mode: :isolated` is set.
    * `:sharing_mode` — `:auto` shares by transport identity; `:isolated`
      salts the hash with the profile id and forces per-profile isolation.
  """
  @spec derive(pos_integer(), Provider.t(), keyword()) :: String.t()
  def derive(chain_id, provider_config, opts \\ []) when is_integer(chain_id) and chain_id > 0 do
    sharing_mode = Keyword.get(opts, :sharing_mode, :auto)
    profile_id = Keyword.get(opts, :profile_id) || Keyword.get(opts, :profile)

    url = normalize_url(provider_config.url)
    ws_url = optional_normalize_url(Map.get(provider_config, :ws_url))
    auth = auth_fingerprint(provider_config)

    hash_input =
      cond do
        sharing_mode == :isolated and is_binary(profile_id) ->
          :erlang.term_to_binary({chain_id, url, ws_url, auth, {:profile, profile_id}})

        sharing_mode == :isolated ->
          raise ArgumentError, "sharing_mode :isolated requires :profile_id or :profile"

        true ->
          :erlang.term_to_binary({chain_id, url, ws_url, auth})
      end

    hash_suffix =
      :crypto.hash(:sha256, hash_input)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    host_hint = extract_host_hint(provider_config.url)

    "#{chain_id}:#{host_hint}:#{hash_suffix}"
  end

  @doc """
  Returns a stable fingerprint for credentials that affect upstream access.

  The fingerprint intentionally contains no profile or account identity. It is
  only used to prevent health, circuit, rate-limit, and WebSocket state from
  being shared by providers configured with different authentication.
  """
  @spec auth_fingerprint(Provider.t() | map()) :: String.t() | nil
  def auth_fingerprint(provider_config) when is_map(provider_config) do
    auth =
      provider_config
      |> Map.take([:api_key, :credentials, :headers, :auth_headers, :authorization])
      |> Map.merge(%{
        api_key: Map.get(provider_config, :api_key) || Map.get(provider_config, "api_key"),
        credentials:
          Map.get(provider_config, :credentials) || Map.get(provider_config, "credentials"),
        headers: Map.get(provider_config, :headers) || Map.get(provider_config, "headers"),
        auth_headers:
          Map.get(provider_config, :auth_headers) || Map.get(provider_config, "auth_headers"),
        authorization:
          Map.get(provider_config, :authorization) || Map.get(provider_config, "authorization")
      })
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.map(fn {key, value} -> {key, canonical_auth_value(value)} end)
      |> Enum.sort()

    case auth do
      [] -> nil
      _ -> :crypto.hash(:sha256, :erlang.term_to_binary(auth)) |> Base.encode16(case: :lower)
    end
  end

  @doc """
  Normalizes a URL to a canonical form for identity comparison.

  Rules:
  - Lowercase scheme and host
  - Strip default ports (80 for HTTP, 443 for HTTPS)
  - Strip trailing slash (except root "/")
  - Sort query parameters
  """
  @spec normalize_url(String.t()) :: String.t()
  def normalize_url(url) do
    uri = URI.parse(url)
    scheme = String.downcase(uri.scheme || "https")

    %{
      uri
      | scheme: scheme,
        host: String.downcase(uri.host || ""),
        port: normalize_port(scheme, uri.port),
        path: strip_trailing_slash(uri.path || "/"),
        query: normalize_query(uri.query)
    }
    |> URI.to_string()
  end

  @doc """
  Normalizes an optional URL to canonical form for identity comparison.

  Returns `nil` for nil, non-binary, or blank values.
  """
  @spec optional_normalize_url(term()) :: String.t() | nil
  def optional_normalize_url(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed -> normalize_url(trimmed)
    end
  end

  def optional_normalize_url(_), do: nil

  # Private helpers

  defp canonical_auth_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical_auth_value(nested)} end)
    |> Enum.sort()
  end

  defp canonical_auth_value(value) when is_list(value) do
    value
    |> Enum.map(fn
      {key, nested} -> {to_string(key), canonical_auth_value(nested)}
      nested -> canonical_auth_value(nested)
    end)
    |> Enum.sort()
  end

  defp canonical_auth_value(value), do: value

  defp normalize_port("https", 443), do: nil
  defp normalize_port("https", nil), do: nil
  defp normalize_port("http", 80), do: nil
  defp normalize_port("http", nil), do: nil
  defp normalize_port("wss", 443), do: nil
  defp normalize_port("wss", nil), do: nil
  defp normalize_port("ws", 80), do: nil
  defp normalize_port("ws", nil), do: nil
  defp normalize_port(_scheme, port), do: port

  defp strip_trailing_slash("/"), do: "/"
  defp strip_trailing_slash(path), do: String.trim_trailing(path, "/")

  defp normalize_query(nil), do: nil

  defp normalize_query(query) do
    query |> URI.decode_query() |> Enum.sort() |> URI.encode_query()
  end

  defp extract_host_hint(url) do
    case URI.parse(url).host do
      nil ->
        "unknown"

      host ->
        host
        |> String.downcase()
        |> String.split(".")
        |> Enum.at(-2, "unknown")
    end
  end
end

defmodule Lasso.Providers.InstanceId do
  @moduledoc """
  Deterministic identity derivation for physical upstream connections.

  A `provider_instance_id` uniquely identifies a physical upstream connection.
  Two profiles using the same URL with the same credentials produce the same
  instance_id and will share infrastructure in later phases.

  Format: `"chain:host_hint:hash_12"` (e.g., `"ethereum:drpc:a3f2b1c4e5d6"`)
  """

  alias Lasso.Config.ChainConfig.Provider

  @type sharing_mode :: :auto | :isolated

  @doc """
  Derives a deterministic instance_id for a provider.

  Same URL + same auth + same chain = same instance_id.
  With `sharing_mode: :isolated`, the profile slug is salted in to force uniqueness.

  ## Options
    * `:profile` - Profile slug (required when `sharing_mode` is `:isolated`)
    * `:sharing_mode` - `:auto` (default) or `:isolated`
  """
  @spec derive(String.t(), Provider.t(), keyword()) :: String.t()
  def derive(chain, provider_config, opts \\ []) do
    sharing_mode = Keyword.get(opts, :sharing_mode, :auto)
    profile = Keyword.get(opts, :profile)

    if sharing_mode == :isolated and not is_binary(profile) do
      raise ArgumentError, "profile is required when sharing_mode is :isolated"
    end

    url = normalize_url(provider_config.url)
    auth_fp = auth_fingerprint(provider_config)

    hash_input =
      case sharing_mode do
        :isolated ->
          :erlang.term_to_binary({chain, url, auth_fp, profile})

        _ ->
          :erlang.term_to_binary({chain, url, auth_fp})
      end

    hash_suffix =
      :crypto.hash(:sha256, hash_input)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)

    host_hint = extract_host_hint(provider_config.url)

    "#{chain}:#{host_hint}:#{hash_suffix}"
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
  Computes a 12-character hex fingerprint of provider auth configuration.

  Returns `nil` when no explicit auth is configured.
  Does NOT extract keys from URLs (the URL itself differentiates key-in-path providers).
  """
  @spec auth_fingerprint(Provider.t()) :: String.t() | nil
  def auth_fingerprint(%{api_key: key}) when is_binary(key) and key != "" do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 12)
  end

  def auth_fingerprint(%{auth_headers: headers})
      when is_map(headers) and map_size(headers) > 0 do
    headers
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  def auth_fingerprint(_), do: nil

  # Private helpers

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

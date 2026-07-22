defmodule Lasso.URLMask do
  @moduledoc """
  URL credential masking shared across leak surfaces.

  Provider URLs frequently embed credentials in the path
  (`https://eth-mainnet.g.alchemy.com/v2/<KEY>`,
  `https://mainnet.infura.io/v3/<KEY>`) or as query params. Anywhere a
  URL might end up in a log line, a Sentry event, a YAML export, or a
  rendered template, it should be threaded through `mask/1` first.

  The mask preserves the scheme + host (operationally useful for
  diagnosis) and elides any path segment or query value that looks
  high-entropy. Idempotent — masking an already-masked URL is a no-op.
  """

  @doc """
  Returns the URL with high-entropy path segments and long query values
  replaced by a 4-char prefix + `***`.

  Returns `nil` for `nil` and the original value for non-binary input
  so callers can pass arbitrary values defensively.
  """
  @spec mask(any()) :: any()
  def mask(nil), do: nil

  def mask(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: nil} ->
        url

      %URI{} = uri ->
        uri
        |> Map.put(:path, mask_path(uri.path))
        |> Map.put(:query, mask_query(uri.query))
        |> URI.to_string()
    end
  rescue
    # Any URI parse oddity → return as-is rather than risk crashing the
    # caller (typically a logging or Sentry path that must not raise).
    _ -> url
  end

  def mask(other), do: other

  @doc """
  Scans a freeform string for embedded `http(s)://` and `ws(s)://` URLs and
  replaces each with its masked form via `mask/1`.

  Use this on exception messages, log lines, and other text where a URL may
  appear inline among other content. Returns the input unchanged when it
  contains no recognizable URL.
  """
  @url_pattern ~r{(?:https?|wss?)://[^\s\"\'<>\)\]\}]+}

  @spec mask_in_string(any()) :: any()
  def mask_in_string(string) when is_binary(string) do
    Regex.replace(@url_pattern, string, fn matched -> mask(matched) end)
  end

  def mask_in_string(other), do: other

  @doc """
  Extracts just the host portion of a URL — returning a fallback when
  the input isn't parseable.

  Use this anywhere a URL is rendered to the user (UI, logs, headers,
  telemetry) and you only want the host. Falling back to the raw URL
  on parse failure (a common ad-hoc pattern) leaks credentials when
  the URL is malformed; this helper falls back to a safe placeholder
  instead.
  """
  @spec host(any(), String.t() | nil) :: String.t() | nil
  def host(url, fallback \\ nil)

  def host(url, fallback) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: h} when is_binary(h) and h != "" -> h
      _ -> fallback
    end
  end

  def host(_, fallback), do: fallback

  defp mask_path(nil), do: nil

  defp mask_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn segment ->
      if maskable_path_segment?(segment) do
        String.slice(segment, 0, 4) <> "***"
      else
        segment
      end
    end)
  end

  # Lowered from >20 to >8: real provider keys often live in shorter
  # path slots (QuickNode `/8-char/32-char/`, Tenderly node ids ≤20,
  # Ankr `/<key>` directly under host). Keep the no-dot guard so we
  # don't elide hostnames or filename-like segments accidentally
  # matched by a routing-style URL.
  defp maskable_path_segment?(segment) when is_binary(segment) do
    len = String.length(segment)

    len > 8 and
      not String.contains?(segment, ".") and
      Regex.match?(~r/^[A-Za-z0-9_-]+$/, segment)
  end

  defp mask_query(nil), do: nil

  defp mask_query(query) do
    query
    |> URI.decode_query()
    |> Enum.map(fn {k, v} ->
      if maskable_query_value?(k, v) do
        {k, String.slice(v, 0, 4) <> "***"}
      else
        {k, v}
      end
    end)
    |> URI.encode_query()
  end

  # Names that almost always carry a credential — mask regardless of
  # length so `?key=foo` doesn't slip through. Also still mask any
  # value > 4 chars defensively (was 10).
  @credential_param_names ~w(
    key apikey api_key apiKey api-key access_token accessToken
    auth authorization token secret pass password
  )

  defp maskable_query_value?(_, ""), do: false

  defp maskable_query_value?(name, value) when is_binary(name) and is_binary(value) do
    String.downcase(name) in @credential_param_names or String.length(value) > 4
  end

  defp maskable_query_value?(_, _), do: false
end

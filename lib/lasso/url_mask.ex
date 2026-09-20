defmodule Lasso.URLMask do
  @moduledoc """
  URL projections for diagnostic output and legacy endpoint heuristics.

  Use `redact/1` for a URL known to contain secrets and `mask_in_string/1`
  for diagnostic text. These retain only the origin: credentials can occupy
  any path segment or query value, regardless of length or punctuation.

  `mask/1` is a legacy shape heuristic, not a security boundary. It retains
  credential prefixes and some entire values. Do not use it for output or to
  determine endpoint ownership or authorization.
  """

  @doc """
  Projects an HTTP or WebSocket URL to its scheme, host and port.

  User information, the entire path, query and fragment are omitted. Invalid
  or unsupported inputs become a safe placeholder; nil remains nil. Hostnames
  remain visible for diagnosis, so credentials must not be embedded in hosts.
  """
  @spec redact(any()) :: String.t() | nil
  def redact(nil), do: nil

  def redact(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https", "ws", "wss"] and is_binary(host) and host != "" ->
        %{uri | userinfo: nil, path: nil, query: nil, fragment: nil}
        |> URI.to_string()

      _ ->
        "[FILTERED_URL]"
    end
  rescue
    _ -> "[FILTERED_URL]"
  end

  def redact(_), do: "[FILTERED_URL]"

  @doc """
  Legacy endpoint-shape heuristic that preserves short values and prefixes.
  This is not credential redaction; use `redact/1` for diagnostic output.
  """
  @spec mask(any()) :: any()
  def mask(nil), do: nil

  def mask(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: nil} ->
        url

      %URI{} = uri ->
        uri
        |> Map.put(:userinfo, nil)
        |> Map.put(:path, mask_path(uri.path))
        |> Map.put(:query, mask_query(uri.query))
        |> Map.put(:fragment, nil)
        |> URI.to_string()
    end
  rescue
    # Keep malformed URL handling conservative for legacy callers.
    _ -> if url_shaped?(url), do: "[FILTERED_URL]", else: url
  end

  def mask(other), do: other

  @doc """
  Scans a freeform string for embedded `http(s)://` and `ws(s)://` URLs and
  replaces each with its origin via `redact/1`.

  Use this on exception messages, log lines, and other text where a URL may
  appear inline among other content. Returns the input unchanged when it
  contains no recognizable URL.
  """
  @url_pattern ~r{(?:https?|wss?)://[^\s<>]+}i

  @spec mask_in_string(any()) :: any()
  def mask_in_string(string) when is_binary(string) do
    Regex.replace(@url_pattern, string, fn matched -> redact(matched) end)
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

  defp url_shaped?(url) do
    String.starts_with?(url, ["http://", "https://", "ws://", "wss://"])
  end

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

  # Token-shaped paths are retained only as a legacy endpoint-shape heuristic.
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

  # Legacy shape detection retains prefixes even for short credential values.
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

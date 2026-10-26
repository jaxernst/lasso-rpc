defmodule Lasso.Providers.ProviderHeaders do
  @moduledoc false

  @forbidden_headers ~w[
    connection content-length host keep-alive proxy-connection te trailer
    transfer-encoding upgrade
    sec-websocket-accept sec-websocket-extensions sec-websocket-key
    sec-websocket-protocol sec-websocket-version
  ]
  @max_headers 32
  @max_header_name_bytes 64
  @max_header_value_bytes 8_192
  @header_name ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/

  @spec build(map()) :: [{String.t(), String.t()}]
  def build(provider) when is_map(provider) do
    defaults = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    merge(defaults, identity_headers(provider))
  end

  @doc "Canonical configured headers defining the upstream learning identity."
  @spec identity_headers(map()) :: [{String.t(), String.t()}]
  def identity_headers(provider) when is_map(provider) do
    api_key_headers =
      case fetch(provider, :api_key) do
        api_key when is_binary(api_key) and byte_size(api_key) > 0 ->
          [{"authorization", "Bearer #{api_key}"}]

        _ ->
          []
      end

    api_key_headers
    |> merge(normalize(fetch(provider, :headers)))
    |> merge(normalize(fetch(provider, :auth_headers)))
    |> Enum.sort()
  end

  @doc "Validates credential and configured HTTP/WebSocket headers before publication."
  @spec validate(map()) :: :ok | {:error, :invalid_provider_headers}
  def validate(provider) when is_map(provider) do
    api_key = fetch(provider, :api_key)
    headers = fetch(provider, :headers)
    auth_headers = fetch(provider, :auth_headers)

    if valid_api_key?(api_key) and valid_headers?(headers) and
         valid_headers?(auth_headers) and
         header_count(headers) + header_count(auth_headers) <= @max_headers,
       do: :ok,
       else: {:error, :invalid_provider_headers}
  end

  defp normalize(headers) when is_map(headers), do: normalize(Map.to_list(headers))

  defp normalize(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {key, value} when (is_binary(key) or is_atom(key)) and is_binary(value) ->
        key = key |> to_string() |> String.downcase()
        if valid_header_name?(key) and valid_header_value?(value), do: [{key, value}], else: []

      _ ->
        []
    end)
  end

  defp normalize(_headers), do: []

  defp fetch(provider, key) do
    case Map.fetch(provider, key) do
      {:ok, value} -> value
      :error -> Map.get(provider, Atom.to_string(key))
    end
  end

  defp valid_api_key?(nil), do: true
  defp valid_api_key?(value) when is_binary(value), do: valid_header_value?(value)
  defp valid_api_key?(_value), do: false

  defp valid_headers?(nil), do: true
  defp valid_headers?(headers) when is_map(headers), do: valid_headers?(Map.to_list(headers))

  defp valid_headers?(headers) when is_list(headers) do
    Enum.all?(headers, fn
      {key, value} when (is_binary(key) or is_atom(key)) and is_binary(value) ->
        key = key |> to_string() |> String.downcase()
        valid_header_name?(key) and valid_header_value?(value)

      _ ->
        false
    end)
  end

  defp valid_headers?(_), do: false

  defp header_count(nil), do: 0
  defp header_count(headers) when is_map(headers), do: map_size(headers)
  defp header_count(headers) when is_list(headers), do: length(headers)
  defp header_count(_), do: @max_headers + 1

  defp valid_header_name?(name) do
    byte_size(name) in 1..@max_header_name_bytes and
      Regex.match?(@header_name, name) and
      name not in @forbidden_headers
  end

  defp valid_header_value?(value) do
    byte_size(value) <= @max_header_value_bytes and
      not String.contains?(value, ["\r", "\n", <<0>>])
  end

  defp merge(existing, additions) do
    Enum.reduce(additions, existing, fn {key, value}, headers ->
      key = String.downcase(key)

      [
        {key, value}
        | Enum.reject(headers, fn {current, _} -> String.downcase(current) == key end)
      ]
    end)
    |> Enum.reverse()
  end
end

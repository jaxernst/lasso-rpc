defmodule Lasso.Providers.ProviderHeaders do
  @moduledoc false

  @spec build(map()) :: [{String.t(), String.t()}]
  def build(provider) when is_map(provider) do
    defaults = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    api_key_headers =
      case Map.get(provider, :api_key) || Map.get(provider, "api_key") do
        api_key when is_binary(api_key) and byte_size(api_key) > 0 ->
          [{"authorization", "Bearer #{api_key}"}]

        _ ->
          []
      end

    defaults
    |> merge(api_key_headers)
    |> merge(normalize(Map.get(provider, :headers) || Map.get(provider, "headers")))
    |> merge(normalize(Map.get(provider, :auth_headers) || Map.get(provider, "auth_headers")))
  end

  defp normalize(headers) when is_map(headers), do: normalize(Map.to_list(headers))

  defp normalize(headers) when is_list(headers) do
    Enum.flat_map(headers, fn
      {key, value} when (is_binary(key) or is_atom(key)) and not is_nil(value) ->
        [{key |> to_string() |> String.downcase(), to_string(value)}]

      _ ->
        []
    end)
  end

  defp normalize(_headers), do: []

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

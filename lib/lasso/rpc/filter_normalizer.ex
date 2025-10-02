defmodule Lasso.RPC.FilterNormalizer do
  @moduledoc """
  Deterministic canonicalization for log filters used as pooling keys.
  - Lowercase hex and ensure 0x prefix where appropriate
  - Sort addresses and topics
  - Remove nil/empty values
  """

  def normalize(%{} = filter) do
    filter
    |> prune_nil()
    |> normalize_addresses()
    |> normalize_topics()
    |> normalize_hex_fields(["fromBlock", "toBlock"])
  end

  defp prune_nil(map) do
    for {k, v} <- map, v != nil, into: %{} do
      {k, v}
    end
  end

  defp normalize_addresses(map) do
    case Map.get(map, "address") do
      nil ->
        map

      addr when is_binary(addr) ->
        Map.put(map, "address", normalize_hex(addr))

      list when is_list(list) ->
        Map.put(map, "address", Enum.map(list, &normalize_hex/1) |> Enum.sort())

      other ->
        Map.put(map, "address", other)
    end
  end

  defp normalize_topics(map) do
    case Map.get(map, "topics") do
      nil -> map
      topics when is_list(topics) -> Map.put(map, "topics", Enum.map(topics, &normalize_topic/1))
      other -> Map.put(map, "topics", other)
    end
  end

  defp normalize_topic(nil), do: nil

  defp normalize_topic(topic) when is_binary(topic), do: normalize_hex(topic)

  defp normalize_topic(list) when is_list(list) do
    list
    |> Enum.map(&normalize_topic/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
  end

  defp normalize_hex_fields(map, fields) do
    Enum.reduce(fields, map, fn field, acc ->
      case Map.get(acc, field) do
        nil -> acc
        val when is_binary(val) -> Map.put(acc, field, normalize_hex(val))
        other -> Map.put(acc, field, other)
      end
    end)
  end

  defp normalize_hex(<<"0x", rest::binary>>), do: "0x" <> String.downcase(rest)

  defp normalize_hex(str) when is_binary(str) do
    lower = String.downcase(str)
    if String.starts_with?(lower, "0x"), do: lower, else: "0x" <> lower
  end
end

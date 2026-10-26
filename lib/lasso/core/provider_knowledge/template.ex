defmodule Lasso.RPC.ProviderKnowledge.Template do
  @moduledoc "Masks bounded provider error wording before interpretation."

  alias Lasso.Providers.ProviderHeaders

  @max_source_bytes 48 * 1_024
  @max_text_bytes 8 * 1_024
  @max_context_nodes 256
  @max_request_echo_spans 64
  @max_quantity_slots 32
  @quantity_pattern ~r/(?<![[:alnum:]_])0[xX][0-9a-fA-F]+(?![[:alnum:]_])|\b[0-9]+\b/u

  @markers %{
    credential: "[credential]",
    url_auth: "[url_auth]",
    contact: "[contact]",
    url: "[url]",
    provider_name: "[provider]",
    known_value: "[request_echo]",
    control: "[control]"
  }

  @spec max_source_bytes() :: pos_integer()
  def max_source_bytes, do: @max_source_bytes

  @spec max_text_bytes() :: pos_integer()
  def max_text_bytes, do: @max_text_bytes

  @spec mask(binary(), term(), map() | nil) :: {:ok, map()} | {:error, atom()}
  def mask(message, params \\ [], provider_config \\ nil)

  def mask(message, params, provider_config) when is_binary(message) do
    cond do
      byte_size(message) > @max_source_bytes -> {:error, :inspection_limit}
      not String.valid?(message) -> {:error, :invalid_utf8}
      true -> mask_bounded(message, params, provider_config)
    end
  end

  @spec prepare(binary(), term(), map() | nil) :: {:ok, map()} | {:error, atom()}
  def prepare(message, params \\ [], provider_config \\ nil) do
    with {:ok, masked} <- mask(message, params, provider_config),
         false <- masked.truncated,
         {:ok, template, slots} <- type_quantities(masked.text) do
      {:ok,
       %{
         template: template,
         fingerprint:
           template |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false),
         quantity_slots: slots,
         redaction_counts: masked.redaction_counts
       }}
    else
      true -> {:error, :truncated}
      error -> error
    end
  end

  defp type_quantities(text) do
    matches = Regex.scan(@quantity_pattern, text, return: :index) |> List.flatten()

    if length(matches) > @max_quantity_slots do
      {:error, :too_many_quantities}
    else
      {parts, offset, slots} =
        Enum.reduce(matches, {[], 0, []}, fn {first, size}, {parts, offset, slots} ->
          raw = binary_part(text, first, size)
          {marker, slot} = typed_quantity(raw, length(slots))
          prefix = binary_part(text, offset, first - offset)
          {[parts, prefix, marker], first + size, if(slot, do: slots ++ [slot], else: slots)}
        end)

      template = IO.iodata_to_binary([parts, binary_part(text, offset, byte_size(text) - offset)])
      {:ok, template, slots}
    end
  end

  defp typed_quantity(<<"0", x, hex::binary>>, ordinal) when x in [?x, ?X] do
    case byte_size(hex) do
      40 ->
        {"[address]", nil}

      64 ->
        {"[hash]", nil}

      size when size in 1..16 ->
        {value, ""} = Integer.parse(hex, 16)

        if value <= 9_223_372_036_854_775_807,
          do: {"[hex_quantity:#{ordinal}]", %{kind: :hex_quantity, value: value}},
          else: {"[hex]", nil}

      _ ->
        {"[hex]", nil}
    end
  end

  defp typed_quantity(raw, ordinal) do
    case Integer.parse(raw) do
      {value, ""} when value <= 9_223_372_036_854_775_807 ->
        {"[quantity:#{ordinal}]", %{kind: :decimal, value: value}}

      _ ->
        {"[quantity]", nil}
    end
  end

  defp mask_bounded(message, params, provider_config) do
    case contextual_ranges(message, params, provider_config) do
      {:ok, contextual} ->
        ranges = merge_ranges(pattern_ranges(message) ++ contextual)

        {parts, offset, counts} =
          Enum.reduce(ranges, {[], 0, %{}}, fn {first, last, kind}, {parts, offset, counts} ->
            prefix = binary_part(message, offset, first - offset)

            {[parts, prefix, Map.fetch!(@markers, kind)], last,
             Map.update(counts, kind, 1, &(&1 + 1))}
          end)

        redacted =
          IO.iodata_to_binary([parts, binary_part(message, offset, byte_size(message) - offset)])

        text = utf8_prefix(redacted, min(byte_size(redacted), @max_text_bytes))

        {:ok,
         %{
           text: text,
           source_bytes: byte_size(message),
           truncated: byte_size(redacted) > byte_size(text),
           redaction_counts: counts
         }}

      :overflow ->
        {:error, :invalid_context}
    end
  end

  defp contextual_ranges(message, params, provider_config) do
    case scan_request_value(params, message, {MapSet.new(), 0}) do
      {:ok, {request_ranges, _nodes}} ->
        case credential_values(provider_config) do
          :overflow ->
            :overflow

          credentials ->
            with {:ok, credential_ranges} <-
                   scan_context_values(credentials, message, request_ranges, :credential),
                 {:ok, name_ranges} <-
                   provider_config
                   |> provider_name_values()
                   |> scan_context_values(message, credential_ranges, :provider_name) do
              {:ok, name_ranges |> MapSet.to_list() |> Enum.sort()}
            end
        end

      :overflow ->
        :overflow
    end
  end

  defp scan_context_values(values, message, ranges, kind) do
    Enum.reduce_while(values, {:ok, ranges}, fn value, {:ok, acc} ->
      matches =
        message
        |> :binary.matches(value)
        |> Enum.filter(&(byte_size(value) >= 4 or complete_token?(message, &1)))

      case add_matches(acc, matches, kind) do
        {:ok, next} -> {:cont, {:ok, next}}
        :overflow -> {:halt, :overflow}
      end
    end)
    |> case do
      {:ok, ranges} -> {:ok, ranges}
      :overflow -> :overflow
    end
  end

  defp provider_name_values(provider_config) when is_map(provider_config) do
    [fetch(provider_config, :name), fetch(provider_config, :id)]
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) in 1..128))
    |> Enum.uniq()
  end

  defp provider_name_values(_), do: []

  defp scan_request_value(_value, _message, {_ranges, nodes})
       when nodes >= @max_context_nodes,
       do: :overflow

  defp scan_request_value(value, message, {ranges, nodes}) when is_binary(value) do
    matches =
      case request_echo_candidate(value) do
        :ordinary when byte_size(value) <= byte_size(message) ->
          :binary.matches(message, value)

        :token when byte_size(value) <= byte_size(message) ->
          message
          |> :binary.matches(value)
          |> Enum.filter(&complete_token?(message, &1))

        _ ->
          []
      end

    add_matches(ranges, matches, :known_value)
    |> case do
      {:ok, ranges} -> {:ok, {ranges, nodes + 1}}
      :overflow -> :overflow
    end
  end

  defp scan_request_value(value, message, state) when is_list(value),
    do: scan_enumerable(value, message, increment_nodes(state))

  defp scan_request_value(value, message, state) when is_map(value) do
    Enum.reduce_while(value, {:ok, increment_nodes(state)}, fn {key, item}, {:ok, acc} ->
      with {:ok, acc} <- scan_request_value(key, message, acc),
           {:ok, acc} <- scan_request_value(item, message, acc) do
        {:cont, {:ok, acc}}
      else
        :overflow -> {:halt, :overflow}
      end
    end)
  end

  defp scan_request_value(_value, _message, {ranges, nodes}),
    do: {:ok, {ranges, nodes + 1}}

  defp scan_enumerable(value, message, state) do
    Enum.reduce_while(value, {:ok, state}, fn item, {:ok, acc} ->
      case scan_request_value(item, message, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        :overflow -> {:halt, :overflow}
      end
    end)
  end

  defp increment_nodes({ranges, nodes}), do: {ranges, nodes + 1}

  defp request_echo_candidate("0x" <> hex) when byte_size(hex) in 1..5,
    do: if(String.match?(hex, ~r/\A[0-9a-f]+\z/i), do: :token, else: false)

  defp request_echo_candidate(value) when byte_size(value) >= 8, do: :ordinary
  defp request_echo_candidate(value) when byte_size(value) > 0, do: :token

  defp request_echo_candidate(_), do: false

  defp complete_token?(message, {offset, size}) do
    token_boundary?(message, offset - 1) and token_boundary?(message, offset + size)
  end

  defp token_boundary?(_message, index) when index < 0, do: true
  defp token_boundary?(message, index) when index >= byte_size(message), do: true

  defp token_boundary?(message, index) do
    byte = :binary.at(message, index)

    not (byte in ?0..?9 or byte in ?a..?z or byte in ?A..?Z or byte == ?_)
  end

  defp add_matches(ranges, matches, kind) do
    Enum.reduce_while(matches, {:ok, ranges}, fn {offset, size}, {:ok, acc} ->
      acc = put_context_range(acc, {offset, offset + size, kind})

      if MapSet.size(acc) > @max_request_echo_spans,
        do: {:halt, :overflow},
        else: {:cont, {:ok, acc}}
    end)
  end

  defp put_context_range(ranges, {first, last, kind} = range) do
    existing = Enum.find(ranges, fn {left, right, _kind} -> left == first and right == last end)

    case {existing, kind} do
      {nil, _} ->
        MapSet.put(ranges, range)

      {{_, _, :known_value} = previous, :credential} ->
        ranges |> MapSet.delete(previous) |> MapSet.put(range)

      {_previous, _} ->
        ranges
    end
  end

  defp credential_values(provider_config) when is_map(provider_config) do
    if ProviderHeaders.validate(provider_config) != :ok,
      do: raise(ArgumentError, "invalid provider headers")

    api_key = fetch(provider_config, :api_key)
    url = fetch(provider_config, :url)
    http_url = fetch(provider_config, :http_url)
    ws_url = fetch(provider_config, :ws_url)

    header_values =
      provider_config
      |> ProviderHeaders.identity_headers()
      |> Enum.flat_map(fn {_name, value} ->
        [value, strip_auth_scheme(value)]
      end)

    [api_key | header_values]
    |> Kernel.++(url_credential_values(url))
    |> Kernel.++(url_credential_values(http_url))
    |> Kernel.++(url_credential_values(ws_url))
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) in 1..8_192))
    |> Enum.uniq()
  rescue
    _error -> :overflow
  end

  defp credential_values(_), do: []

  defp url_credential_values(url) when is_binary(url) do
    uri = URI.parse(url)

    userinfo =
      case uri.userinfo do
        value when is_binary(value) ->
          decoded = URI.decode(value)
          [value, decoded] ++ String.split(value, ":") ++ String.split(decoded, ":")

        _ ->
          []
      end

    path =
      uri.path
      |> string_parts("/")
      |> Enum.flat_map(fn raw ->
        decoded = URI.decode(raw)
        [raw, decoded | string_parts(decoded, "/")]
      end)

    query =
      uri.query
      |> string_parts("&")
      |> Enum.flat_map(fn pair ->
        case String.split(pair, "=", parts: 2) do
          [_name, value] ->
            [value, decode_url_part(value)]

          _ ->
            []
        end
      end)

    [uri.host] ++ userinfo ++ path ++ query
  end

  defp url_credential_values(_), do: []

  defp string_parts(value, separator) when is_binary(value),
    do: String.split(value, separator, trim: true)

  defp string_parts(_, _), do: []

  defp decode_url_part(value) do
    URI.decode_www_form(value)
  rescue
    _error -> value
  end

  defp strip_auth_scheme(value) do
    case String.split(value, ~r/\s+/, parts: 2, trim: true) do
      [_scheme, credential] -> credential
      _ -> value
    end
  end

  defp fetch(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp pattern_ranges(message) do
    Enum.flat_map(patterns(), fn {kind, pattern} ->
      Regex.scan(pattern, message, return: :index, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reject(fn {offset, size} ->
        size == 0 or binary_part(message, offset, size) in Map.values(@markers)
      end)
      |> Enum.map(fn {offset, size} -> {offset, offset + size, kind} end)
    end)
  end

  defp patterns do
    [
      {:credential, ~r/\bauthorization\s*[:=]\s*["']?(?:bearer|basic)\s+([a-z0-9._~+\/=:-]+)/iu},
      {:credential, ~r/\bbearer\s+((?=[a-z0-9._~+\/=:-]*[0-9._~+\/=:-])[a-z0-9._~+\/=:-]{8,})/iu},
      {:credential,
       ~r/["']?\b(?:api[ _-]?key|password|passwd|secret|access[_-]?token|refresh[_-]?token|session[_-]?token|cookie|set-cookie)["']?\s*[:=]\s*("(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|(?:bearer|basic)\s+[a-z0-9._~+\/=:-]+|[^\s,;&<>\[\]"']+)/iu},
      {:credential,
       ~r/\btoken\s*=\s*("(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|(?:bearer|basic)\s+[a-z0-9._~+\/=:-]+|[^\s,;&<>\[\]"']+)/iu},
      {:credential,
       ~r/["'](?:token|authorization)["']\s*:\s*("(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*')/iu},
      {:credential,
       ~r/["']?\b(?:api[ _-]?key|password|passwd|secret|token|access[_-]?token|refresh[_-]?token|session[_-]?token|cookie|set-cookie)["']?\s*[:=]\s*(["'][^"'\r\n,;]{0,49152})(?=[,;\r\n]|$)/iu},
      {:url_auth, ~r/\b[a-z][a-z0-9+.-]*:\/\/([^\s\/?#@]+)@/iu},
      {:url, ~r{(\b(?:https?|wss?)://[^\s"'<>]+)}iu},
      {:provider_name,
       ~r/\b((?:dRPC|PublicNode|MEV\s*Blocker|Alchemy|Infura|Ankr|QuickNode|Premium\s+[A-Za-z]+\s+[0-9]+))\b/iu},
      {:known_value,
       ~r/\b(?:account|tenant|customer|organization|project)(?:[ _-]?(?:id|name))?\s*[:=]?\s+([a-z0-9][a-z0-9._:-]{2,127})\b/iu},
      {:contact, ~r/(?<![a-z0-9._%+:\/-])([a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,})/iu},
      {:control, ~r/([\x00-\x08\x0b\x0c\x0e-\x1f\x7f])/u}
    ]
  end

  defp merge_ranges(ranges) do
    ranges
    |> Enum.sort()
    |> Enum.reduce([], fn
      {first, last, _kind}, [{previous, finish, kind} | rest] when first < finish ->
        [{previous, max(last, finish), kind} | rest]

      range, acc ->
        [range | acc]
    end)
    |> Enum.reverse()
  end

  defp utf8_prefix(text, size) do
    prefix = binary_part(text, 0, size)
    if String.valid?(prefix), do: :binary.copy(prefix), else: utf8_prefix(text, size - 1)
  end
end

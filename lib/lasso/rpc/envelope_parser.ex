defmodule Lasso.RPC.EnvelopeParser do
  @moduledoc """
  Fast JSON-RPC envelope parser that extracts metadata without parsing the result value.

  This module enables pass-through optimization for large responses by:
  1. Extracting `jsonrpc`, `id`, and detecting `result` vs `error`
  2. Fully parsing error objects (they're small)
  3. NOT parsing result values (they can be 100MB+)

  ## Key Ordering

  JSON objects are unordered. This parser handles any key order:
  - `{"jsonrpc":"2.0","id":1,"result":[...]}`
  - `{"result":[...],"id":1,"jsonrpc":"2.0"}`
  - `{"id":1,"result":[...],"jsonrpc":"2.0"}`

  ## Usage

      case EnvelopeParser.parse(response_bytes) do
        {:ok, %{type: :result, id: id, raw_bytes: bytes}} ->
          # Pass through raw bytes directly to client
          send_resp(conn, 200, bytes)

        {:ok, %{type: :error, id: id, error: error}} ->
          # Error already parsed, handle normally
          handle_error(error)

        {:error, reason} ->
          # Fall back to full Jason.decode
          Jason.decode(response_bytes)
      end

  ## Performance

  - Envelope parsing: ~0.003ms (constant, regardless of payload size)
  - Full JSON decode: 1-850ms (scales with payload size)
  - Speedup: 600-40,000x for large payloads
  """

  @type envelope :: %{
          jsonrpc: String.t(),
          id: integer() | String.t() | nil,
          type: :result | :error,
          error: map() | nil,
          result_offset: non_neg_integer() | nil,
          raw_bytes: binary()
        }

  @type parse_result :: {:ok, envelope()} | {:error, atom()}

  # Scan first 2000 bytes for envelope keys (handles any key order)
  # Supports IDs up to ~1500 chars before result/error key
  @scan_limit 2000

  # Max nesting depth for error objects (prevents stack overflow)
  @max_object_depth 100

  # Max batch items (prevents stack overflow on malicious input)
  @max_batch_items 10_000

  @doc """
  Parse JSON-RPC envelope without parsing the result value.

  Returns envelope metadata including the byte offset where the result value starts,
  allowing the raw bytes to be passed through without re-encoding.
  """
  @spec parse(binary()) :: parse_result()
  def parse(json_bytes) when is_binary(json_bytes) do
    scan_range = min(@scan_limit, byte_size(json_bytes))
    chunk = binary_part(json_bytes, 0, scan_range)

    with {:ok, type, value_offset} <- find_result_or_error(chunk),
         {:ok, id} <- extract_id(chunk),
         {:ok, jsonrpc} <- extract_jsonrpc(chunk) do
      build_envelope(type, value_offset, id, jsonrpc, json_bytes)
    end
  end

  def parse(_), do: {:error, :invalid_input}

  @doc """
  Parse JSON-RPC batch response without parsing individual result values.

  Returns a list of envelope metadata for each item in the batch array.
  Uses zero-copy slicing to extract items without duplicating the original binary.

  ## Examples

      iex> batch = ~s([{"jsonrpc":"2.0","id":1,"result":[1,2,3]},{"jsonrpc":"2.0","id":2,"result":null}])
      iex> {:ok, envelopes} = EnvelopeParser.parse_batch(batch)
      iex> length(envelopes)
      2
      iex> [first, second] = envelopes
      iex> first.id
      1
      iex> second.id
      2

  """
  @spec parse_batch(binary()) :: {:ok, [envelope()]} | {:error, atom()}
  def parse_batch(json_bytes) when is_binary(json_bytes) do
    case split_batch_items(json_bytes) do
      {:ok, item_slices} ->
        # Parse each item slice
        results =
          Enum.map(item_slices, fn slice ->
            parse(slice)
          end)

        # Check if all succeeded
        if Enum.all?(results, fn result -> match?({:ok, _}, result) end) do
          envelopes = Enum.map(results, fn {:ok, env} -> env end)
          {:ok, envelopes}
        else
          # Find first error
          case Enum.find(results, fn result -> match?({:error, _}, result) end) do
            {:error, reason} -> {:error, reason}
            nil -> {:error, :batch_parse_failed}
          end
        end

      {:error, _} = err ->
        err
    end
  end

  def parse_batch(_), do: {:error, :invalid_input}

  defp build_envelope(:result, value_offset, id, jsonrpc, json_bytes) do
    {:ok,
     %{
       jsonrpc: jsonrpc,
       id: id,
       type: :result,
       error: nil,
       result_offset: value_offset,
       raw_bytes: json_bytes
     }}
  end

  defp build_envelope(:error, value_offset, id, jsonrpc, json_bytes) do
    # Parse the error object (it's small, and we need code/message)
    case extract_error_object(json_bytes, value_offset) do
      {:ok, error_map} ->
        {:ok,
         %{
           jsonrpc: jsonrpc,
           id: id,
           type: :error,
           error: error_map,
           result_offset: nil,
           raw_bytes: json_bytes
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Check if response is eligible for pass-through based on envelope parse.

  A response is eligible if:
  - It's a success response (has result, not error)
  - The ID matches the expected ID (optional verification)
  """
  @spec passthrough_eligible?(envelope(), integer() | String.t() | nil) :: boolean()
  def passthrough_eligible?(%{type: :result, id: response_id}, expected_id) do
    is_nil(expected_id) or response_id == expected_id
  end

  def passthrough_eligible?(_, _), do: false

  # --- Private: Batch Splitting ---

  # Split a batch array into individual item slices (zero-copy)
  # Returns byte slices for each item (references to original binary)
  defp split_batch_items(json_bytes) do
    # Skip leading whitespace, find opening '['
    case skip_whitespace_to_char(json_bytes, 0, ?[) do
      {:ok, open_bracket_pos} ->
        # Start scanning after the '['
        scan_batch_items(json_bytes, open_bracket_pos + 1, open_bracket_pos + 1, 0, false, [])

      :error ->
        {:error, :not_a_batch_array}
    end
  end

  # Scan batch items and split on top-level commas
  # depth: brace/bracket nesting level (split on commas at depth 0)
  # item_start: byte position where current item began
  # in_string: whether inside a quoted string
  # acc: accumulated list of item byte slices
  defp scan_batch_items(_json_bytes, _pos, _item_start, _depth, _in_string, acc)
       when length(acc) >= @max_batch_items do
    # Guard against excessive batch sizes
    {:error, :batch_too_large}
  end

  defp scan_batch_items(json_bytes, pos, _item_start, _depth, _in_string, _acc)
       when pos >= byte_size(json_bytes) do
    # Reached end without finding ']'
    {:error, :unterminated_batch}
  end

  # Handle escape sequences in strings - fix bounds check
  defp scan_batch_items(json_bytes, pos, item_start, depth, true, acc) do
    len = byte_size(json_bytes)

    case binary_at_safe(json_bytes, pos) do
      {:ok, ?\\} when pos + 1 < len ->
        # Skip the backslash and next character (bounds checked)
        scan_batch_items(json_bytes, pos + 2, item_start, depth, true, acc)

      {:ok, ?\\} ->
        # Backslash at end of string - malformed
        {:error, :unterminated_string}

      {:ok, ?"} ->
        # End of string
        scan_batch_items(json_bytes, pos + 1, item_start, depth, false, acc)

      {:ok, _} ->
        # Any other character in string
        scan_batch_items(json_bytes, pos + 1, item_start, depth, true, acc)

      :error ->
        {:error, :invalid_batch}
    end
  end

  # String delimiter (not in string)
  defp scan_batch_items(json_bytes, pos, item_start, depth, false, acc) do
    case binary_at_safe(json_bytes, pos) do
      {:ok, ?"} ->
        # Enter string
        scan_batch_items(json_bytes, pos + 1, item_start, depth, true, acc)

      {:ok, ?{} ->
        # Opening brace - increase depth
        scan_batch_items(json_bytes, pos + 1, item_start, depth + 1, false, acc)

      {:ok, ?}} when depth > 0 ->
        # Closing brace - decrease depth
        scan_batch_items(json_bytes, pos + 1, item_start, depth - 1, false, acc)

      {:ok, ?[} ->
        # Opening bracket - increase depth
        scan_batch_items(json_bytes, pos + 1, item_start, depth + 1, false, acc)

      {:ok, ?]} when depth > 0 ->
        # Closing bracket - decrease depth
        scan_batch_items(json_bytes, pos + 1, item_start, depth - 1, false, acc)

      {:ok, ?]} when depth == 0 ->
        # End of batch array at depth 0
        # Extract final item if there's content
        item = extract_item_if_not_empty(json_bytes, item_start, pos)

        case item do
          nil -> {:ok, Enum.reverse(acc)}
          slice -> {:ok, Enum.reverse([slice | acc])}
        end

      {:ok, ?,} when depth == 0 ->
        # Comma at depth 0 - split point
        # Extract item (skip if empty due to trailing comma)
        item = extract_item_if_not_empty(json_bytes, item_start, pos)

        case item do
          nil ->
            # Empty item (e.g., trailing comma) - skip it
            scan_batch_items(json_bytes, pos + 1, pos + 1, depth, false, acc)

          slice ->
            # Valid item - add to accumulator
            scan_batch_items(json_bytes, pos + 1, pos + 1, depth, false, [slice | acc])
        end

      {:ok, ws} when ws in ~c[ \t\n\r] ->
        # Whitespace - skip
        scan_batch_items(json_bytes, pos + 1, item_start, depth, false, acc)

      {:ok, _} ->
        # Any other character
        scan_batch_items(json_bytes, pos + 1, item_start, depth, false, acc)

      :error ->
        {:error, :invalid_batch}
    end
  end

  # Extract item slice, trimming whitespace, return nil if empty
  defp extract_item_if_not_empty(json_bytes, start_pos, end_pos) when start_pos < end_pos do
    # Trim leading whitespace
    trimmed_start = skip_leading_whitespace(json_bytes, start_pos, end_pos)

    # Trim trailing whitespace
    trimmed_end = skip_trailing_whitespace(json_bytes, trimmed_start, end_pos)

    if trimmed_start < trimmed_end do
      len = trimmed_end - trimmed_start

      if len > 0 do
        binary_part(json_bytes, trimmed_start, len)
      else
        nil
      end
    else
      nil
    end
  end

  defp extract_item_if_not_empty(_json_bytes, _start_pos, _end_pos), do: nil

  # Skip leading whitespace
  defp skip_leading_whitespace(json_bytes, pos, end_pos) when pos < end_pos do
    case binary_at_safe(json_bytes, pos) do
      {:ok, ws} when ws in ~c[ \t\n\r] ->
        skip_leading_whitespace(json_bytes, pos + 1, end_pos)

      _ ->
        pos
    end
  end

  defp skip_leading_whitespace(_json_bytes, pos, _end_pos), do: pos

  # Skip trailing whitespace (scan backwards)
  defp skip_trailing_whitespace(json_bytes, start_pos, pos) when pos > start_pos do
    case binary_at_safe(json_bytes, pos - 1) do
      {:ok, ws} when ws in ~c[ \t\n\r] ->
        skip_trailing_whitespace(json_bytes, start_pos, pos - 1)

      _ ->
        pos
    end
  end

  defp skip_trailing_whitespace(_json_bytes, _start_pos, pos), do: pos

  # Skip whitespace until finding a specific character
  defp skip_whitespace_to_char(json_bytes, pos, target_char) when pos < byte_size(json_bytes) do
    case binary_at_safe(json_bytes, pos) do
      {:ok, ^target_char} ->
        {:ok, pos}

      {:ok, ws} when ws in ~c[ \t\n\r] ->
        skip_whitespace_to_char(json_bytes, pos + 1, target_char)

      {:ok, _} ->
        :error

      :error ->
        :error
    end
  end

  defp skip_whitespace_to_char(_json_bytes, _pos, _target_char), do: :error

  # Safe binary access helper with bounds check
  defp binary_at_safe(binary, pos) when pos >= 0 and pos < byte_size(binary) do
    {:ok, :binary.at(binary, pos)}
  end

  defp binary_at_safe(_binary, _pos), do: :error

  # --- Private: Key Detection ---

  # Find "result": or "error": key in the envelope (handles any key order)
  # Rejects notifications (messages with "method" key) since they are not responses.
  # Per JSON-RPC 2.0 spec: responses have result/error, notifications have method.
  defp find_result_or_error(chunk) do
    # Check for "method" key first - if present, this is a notification, not a response.
    # Subscription notifications have format: {"method":"eth_subscription","params":{"result":...}}
    # The nested "result" inside params would otherwise be incorrectly matched.
    case find_key_value_start(chunk, "\"method\"") do
      {:ok, _offset} ->
        {:error, :not_a_response}

      :nomatch ->
        find_result_or_error_key(chunk)
    end
  end

  defp find_result_or_error_key(chunk) do
    result_match = find_key_value_start(chunk, "\"result\"")
    error_match = find_key_value_start(chunk, "\"error\"")

    case {result_match, error_match} do
      {{:ok, offset}, :nomatch} ->
        {:ok, :result, offset}

      {:nomatch, {:ok, offset}} ->
        {:ok, :error, offset}

      {{:ok, _r_offset}, {:ok, e_offset}} ->
        # Both found (spec violation, seen in Nethermind) - always prefer error
        {:ok, :error, e_offset}

      {:nomatch, :nomatch} ->
        {:error, :no_result_or_error}
    end
  end

  # Find a JSON key and return the byte offset where its value starts
  # String-aware to avoid matching keys inside quoted strings
  defp find_key_value_start(chunk, key_pattern) do
    # Use binary.matches to get all occurrences
    case :binary.matches(chunk, key_pattern) do
      [] ->
        :nomatch

      matches ->
        # Check each match to see if it's inside a string or valid
        find_valid_key_match(chunk, matches)
    end
  end

  defp find_valid_key_match(_chunk, []), do: :nomatch

  defp find_valid_key_match(chunk, [{match_pos, match_len} | rest_matches]) do
    # Check if this match is inside a quoted string
    if inside_string?(chunk, match_pos) do
      # Skip this match, try next
      find_valid_key_match(chunk, rest_matches)
    else
      # Check if followed by colon (valid key)
      rest_start = match_pos + match_len
      rest = binary_part(chunk, rest_start, byte_size(chunk) - rest_start)

      case skip_to_value(rest, 0) do
        {:ok, offset} ->
          {:ok, rest_start + offset}

        :error ->
          # Not followed by colon, try next match
          find_valid_key_match(chunk, rest_matches)
      end
    end
  end

  # Check if a byte position is inside a quoted string by counting quotes before it
  defp inside_string?(chunk, pos) do
    prefix = binary_part(chunk, 0, pos)
    # Count unescaped quotes before this position
    quote_count = count_unescaped_quotes(prefix, 0)
    # Odd number of quotes = inside string
    rem(quote_count, 2) == 1
  end

  defp count_unescaped_quotes(<<>>, count), do: count

  # Skip escaped characters
  defp count_unescaped_quotes(<<"\\", _, rest::binary>>, count) do
    count_unescaped_quotes(rest, count)
  end

  # Count quote
  defp count_unescaped_quotes(<<?", rest::binary>>, count) do
    count_unescaped_quotes(rest, count + 1)
  end

  # Skip other characters
  defp count_unescaped_quotes(<<_, rest::binary>>, count) do
    count_unescaped_quotes(rest, count)
  end

  # Skip optional whitespace, colon, optional whitespace -> return value start offset
  defp skip_to_value(<<ws, rest::binary>>, offset) when ws in ~c[ \t\n\r] do
    skip_to_value(rest, offset + 1)
  end

  defp skip_to_value(<<?:, rest::binary>>, offset) do
    skip_whitespace(rest, offset + 1)
  end

  defp skip_to_value(_, _), do: :error

  defp skip_whitespace(<<ws, rest::binary>>, offset) when ws in ~c[ \t\n\r] do
    skip_whitespace(rest, offset + 1)
  end

  defp skip_whitespace(<<_char, _::binary>>, offset), do: {:ok, offset}
  defp skip_whitespace(<<>>, _), do: :error

  # --- Private: Field Extraction ---

  defp extract_id(chunk) do
    case find_key_value_start(chunk, "\"id\"") do
      {:ok, offset} ->
        value_bytes = binary_part(chunk, offset, byte_size(chunk) - offset)
        parse_simple_value(value_bytes)

      :nomatch ->
        {:ok, nil}
    end
  end

  defp extract_jsonrpc(chunk) do
    case find_key_value_start(chunk, "\"jsonrpc\"") do
      {:ok, offset} ->
        value_bytes = binary_part(chunk, offset, byte_size(chunk) - offset)

        case parse_simple_value(value_bytes) do
          {:ok, version} when is_binary(version) -> {:ok, version}
          _ -> {:ok, "unknown"}
        end

      :nomatch ->
        {:ok, "unknown"}
    end
  end

  # Parse simple JSON values: string, number, null
  defp parse_simple_value(<<?", rest::binary>>), do: extract_string(rest, <<>>)
  defp parse_simple_value(<<"null", _::binary>>), do: {:ok, nil}

  defp parse_simple_value(<<c, _::binary>> = bin) when c in ?0..?9 or c == ?- do
    extract_integer(bin, <<>>)
  end

  defp parse_simple_value(_), do: {:error, :invalid_value}

  # Standard JSON escape sequences
  defp extract_string(<<"\\\"", rest::binary>>, acc),
    do: extract_string(rest, <<acc::binary, ?">>)

  defp extract_string(<<"\\\\", rest::binary>>, acc),
    do: extract_string(rest, <<acc::binary, ?\\>>)

  defp extract_string(<<"\\n", rest::binary>>, acc),
    do: extract_string(rest, <<acc::binary, ?\n>>)

  defp extract_string(<<"\\r", rest::binary>>, acc),
    do: extract_string(rest, <<acc::binary, ?\r>>)

  defp extract_string(<<"\\t", rest::binary>>, acc),
    do: extract_string(rest, <<acc::binary, ?\t>>)

  defp extract_string(<<"\\b", rest::binary>>, acc),
    do: extract_string(rest, <<acc::binary, ?\b>>)

  defp extract_string(<<"\\f", rest::binary>>, acc),
    do: extract_string(rest, <<acc::binary, ?\f>>)

  defp extract_string(<<"\\/", rest::binary>>, acc),
    do: extract_string(rest, <<acc::binary, ?/>>)

  # Unicode escape sequence \uXXXX
  defp extract_string(<<"\\u", h1, h2, h3, h4, rest::binary>>, acc) do
    case parse_hex_digits([h1, h2, h3, h4]) do
      {:ok, codepoint} ->
        # Convert codepoint to UTF-8
        extract_string(rest, <<acc::binary, codepoint::utf8>>)

      :error ->
        # Invalid hex - keep literal (lenient)
        extract_string(rest, <<acc::binary, "\\u", h1, h2, h3, h4>>)
    end
  end

  # Unknown escape sequence - keep the character (lenient)
  defp extract_string(<<"\\", c, rest::binary>>, acc),
    do: extract_string(rest, <<acc::binary, c>>)

  defp extract_string(<<?", _::binary>>, acc), do: {:ok, acc}
  defp extract_string(<<c, rest::binary>>, acc), do: extract_string(rest, <<acc::binary, c>>)
  defp extract_string(<<>>, _), do: {:error, :unterminated_string}

  # Allow minus only at the start (empty accumulator)
  defp extract_integer(<<c, rest::binary>>, acc) when c == ?- and byte_size(acc) == 0 do
    extract_integer(rest, <<acc::binary, c>>)
  end

  # Allow digits anywhere
  defp extract_integer(<<c, rest::binary>>, acc) when c in ?0..?9 do
    extract_integer(rest, <<acc::binary, c>>)
  end

  # Stop at non-digit (valid end of number)
  defp extract_integer(_, acc) when byte_size(acc) > 1 do
    {:ok, String.to_integer(acc)}
  end

  # Single character that's not a complete number (e.g., just "-")
  defp extract_integer(_, <<c>>) when c == ?- do
    {:error, :invalid_number}
  end

  # Single digit or valid negative number
  defp extract_integer(_, acc) when byte_size(acc) > 0 do
    {:ok, String.to_integer(acc)}
  end

  defp extract_integer(_, _), do: {:error, :invalid_number}

  # Parse four hex digits into a codepoint
  defp parse_hex_digits(digits) do
    digits
    |> Enum.reduce_while({:ok, 0}, fn digit, {:ok, acc} ->
      case hex_to_int(digit) do
        {:ok, val} -> {:cont, {:ok, acc * 16 + val}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp hex_to_int(c) when c in ?0..?9, do: {:ok, c - ?0}
  defp hex_to_int(c) when c in ?a..?f, do: {:ok, c - ?a + 10}
  defp hex_to_int(c) when c in ?A..?F, do: {:ok, c - ?A + 10}
  defp hex_to_int(_), do: :error

  # --- Private: Error Object Extraction ---

  # Extract the error object using balanced brace matching, then parse with Jason
  defp extract_error_object(json_bytes, value_offset) do
    rest = binary_part(json_bytes, value_offset, byte_size(json_bytes) - value_offset)

    case find_balanced_object_end(rest, 0, 0, false) do
      {:ok, end_pos} ->
        error_json = binary_part(rest, 0, end_pos)

        case Jason.decode(error_json) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> {:error, :invalid_error_object}
        end

      :error ->
        {:error, :malformed_error_object}
    end
  end

  # Find the end position of a balanced JSON object
  # Tracks brace depth and handles strings (to ignore braces inside strings)
  defp find_balanced_object_end(<<>>, _, _, _), do: :error

  # Depth limit guard - prevent stack overflow on malicious input
  defp find_balanced_object_end(_, depth, _, _) when depth > @max_object_depth, do: :error

  # Handle escape sequences in strings - with bounds check
  defp find_balanced_object_end(<<"\\", _::binary>> = bin, depth, pos, true)
       when byte_size(bin) >= 2 do
    <<_, _, rest::binary>> = bin
    find_balanced_object_end(rest, depth, pos + 2, true)
  end

  # Backslash at end - malformed
  defp find_balanced_object_end(<<"\\">>, _depth, _pos, true), do: :error

  # String delimiter
  defp find_balanced_object_end(<<?", rest::binary>>, depth, pos, in_string) do
    find_balanced_object_end(rest, depth, pos + 1, not in_string)
  end

  # Opening brace (not in string)
  defp find_balanced_object_end(<<?{, rest::binary>>, depth, pos, false) do
    find_balanced_object_end(rest, depth + 1, pos + 1, false)
  end

  # Closing brace at depth 1 = found the end
  defp find_balanced_object_end(<<?}, _::binary>>, 1, pos, false), do: {:ok, pos + 1}

  # Closing brace at deeper level
  defp find_balanced_object_end(<<?}, rest::binary>>, depth, pos, false) when depth > 1 do
    find_balanced_object_end(rest, depth - 1, pos + 1, false)
  end

  # Any other character
  defp find_balanced_object_end(<<_, rest::binary>>, depth, pos, in_string) when depth > 0 do
    find_balanced_object_end(rest, depth, pos + 1, in_string)
  end

  defp find_balanced_object_end(_, 0, _, _), do: :error
end

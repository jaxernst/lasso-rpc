defmodule Lasso.Core.Transport.UpstreamResponse do
  @moduledoc false

  alias Lasso.JSONRPC.Error, as: JError
  alias Lasso.RPC.Response

  @max_transport_id_bytes 128
  @string_specials ["\"", "\\"]
  @scalar_delimiters [" ", "\t", "\r", "\n", ",", "}", "]"]
  @container_specials ["\"", "{", "[", "}", "]"]
  @linear_scan_threshold 256
  @mode_scan_bytes 512
  @discarded_error_data :lasso_discarded_error_data

  defmodule Validated do
    @moduledoc false

    @enforce_keys [:kind, :id]
    defstruct [:kind, :id, :error_code, :error_message, :error_data, :id_span]

    @type t :: %__MODULE__{
            kind: :result | :error,
            id: integer() | binary() | nil,
            error_code: integer() | nil,
            error_message: binary() | nil,
            error_data: term(),
            id_span: {non_neg_integer(), non_neg_integer()} | nil
          }
  end

  @type invalid_reason ::
          :invalid_json
          | :invalid_envelope
          | :unsupported_version
          | :id_mismatch
          | :unexpected_notification
          | :unexpected_batch

  @type parsed ::
          {:ok, Validated.t()}
          | {:invalid, invalid_reason(), integer() | binary() | nil}
          | {:legacy, :notification | :connection_error}

  @spec parse_unary(binary()) :: parsed()
  def parse_unary(raw_bytes) when is_binary(raw_bytes) do
    case response_mode(raw_bytes) do
      {:found, mode, id_span} ->
        raw_bytes
        |> decode_response(mode)
        |> attach_known_id_span(id_span)

      :unknown ->
        raw_bytes
        |> decode_response(:discard)
        |> retain_error_data(raw_bytes)
        |> attach_id_span(raw_bytes)
    end
  end

  def parse_unary(_raw_bytes), do: {:invalid, :invalid_json, nil}

  defp decode_response(raw_bytes, mode) do
    case decode(raw_bytes, mode) do
      {{:container, :object}, {:root, fields}, rest} ->
        if only_json_whitespace?(rest) do
          classify_fields(fields)
        else
          {:invalid, :invalid_json, candidate_id(fields)}
        end

      {{:container, :array}, _accumulator, rest} ->
        if only_json_whitespace?(rest),
          do: {:invalid, :unexpected_batch, nil},
          else: {:invalid, :invalid_json, nil}

      {_value, _accumulator, _rest} ->
        {:invalid, :invalid_envelope, nil}

      :invalid_json ->
        {:invalid, :invalid_json, nil}
    end
  end

  defp retain_error_data(
         {:ok, %Validated{kind: :error, error_data: @discarded_error_data}},
         raw_bytes
       ),
       do: decode_response(raw_bytes, :retain_error)

  defp retain_error_data(parsed, _raw_bytes), do: parsed

  defp attach_id_span({:ok, %Validated{} = validated}, raw_bytes) do
    case top_level_id_span(raw_bytes) do
      {:ok, id_span} -> {:ok, %{validated | id_span: id_span}}
      :error -> {:ok, validated}
    end
  end

  defp attach_id_span(parsed, _raw_bytes), do: parsed

  defp attach_known_id_span({:ok, %Validated{} = validated}, id_span),
    do: {:ok, %{validated | id_span: id_span}}

  defp attach_known_id_span(parsed, _id_span), do: parsed

  @spec parse_ws_frame(binary()) ::
          {:transport, Validated.t()}
          | {:transport_invalid, String.t(), invalid_reason()}
          | :legacy
          | {:unattributable, invalid_reason() | :ambiguous_id_location}
  def parse_ws_frame(raw_bytes) when is_binary(raw_bytes) do
    case parse_unary(raw_bytes) do
      {:ok, %Validated{id: transport_id} = validated} ->
        if transport_id?(transport_id) do
          case locate_id(validated, raw_bytes) do
            {:ok, located} -> {:transport, located}
            {:error, reason} -> {:unattributable, reason}
          end
        else
          :legacy
        end

      {:invalid, reason, transport_id} when is_binary(transport_id) ->
        if transport_id?(transport_id),
          do: {:transport_invalid, transport_id, reason},
          else: {:unattributable, reason}

      {:invalid, reason, _candidate_id} ->
        {:unattributable, reason}

      {:legacy, _kind} ->
        :legacy
    end
  end

  @spec finalize_unary(Validated.t(), binary(), term(), term()) ::
          {:ok, Response.Success.t()} | {:error, JError.t()} | {:invalid, invalid_reason()}
  def finalize_unary(
        %Validated{id: upstream_id} = validated,
        raw_bytes,
        upstream_id,
        client_id
      )
      when is_binary(raw_bytes) do
    case restore_id(validated, raw_bytes, client_id) do
      {:ok, restored_bytes} -> build_response(validated, client_id, restored_bytes)
      {:error, _reason} -> {:invalid, :invalid_envelope}
    end
  end

  def finalize_unary(%Validated{}, _raw_bytes, _upstream_id, _client_id),
    do: {:invalid, :id_mismatch}

  @spec validate_unary(binary(), term(), term()) ::
          {:ok, Response.Success.t()} | {:error, JError.t()} | {:invalid, invalid_reason()}
  def validate_unary(raw_bytes, upstream_id, client_id) when is_binary(raw_bytes) do
    case parse_unary(raw_bytes) do
      {:ok, validated} -> finalize_unary(validated, raw_bytes, upstream_id, client_id)
      {:invalid, reason, _candidate_id} -> {:invalid, reason}
      {:legacy, _kind} -> {:invalid, :unexpected_notification}
    end
  end

  @doc false
  @spec extract_transport_ids(binary()) :: {:ok, [String.t()]} | {:error, :unattributable}
  def extract_transport_ids(raw_bytes) when is_binary(raw_bytes) do
    case parse_unary(raw_bytes) do
      {:ok, %Validated{id: transport_id}} when is_binary(transport_id) ->
        if transport_id?(transport_id), do: {:ok, [transport_id]}, else: {:ok, []}

      {:invalid, _reason, transport_id} when is_binary(transport_id) ->
        if transport_id?(transport_id), do: {:ok, [transport_id]}, else: {:ok, []}

      {:legacy, _kind} ->
        {:ok, []}

      _other ->
        {:error, :unattributable}
    end
  end

  @doc false
  @spec correlation(binary()) ::
          {:transport_id, String.t()} | :legacy | {:unattributable, atom()}
  def correlation(raw_bytes) when is_binary(raw_bytes) do
    case parse_ws_frame(raw_bytes) do
      {:transport, %Validated{id: transport_id}} -> {:transport_id, transport_id}
      {:transport_invalid, transport_id, _reason} -> {:transport_id, transport_id}
      :legacy -> :legacy
      {:unattributable, reason} -> {:unattributable, reason}
    end
  end

  @spec transport_id?(term()) :: boolean()
  def transport_id?(transport_id) when is_binary(transport_id) do
    byte_size(transport_id) <= @max_transport_id_bytes and
      String.starts_with?(transport_id, "lasso-")
  end

  def transport_id?(_transport_id), do: false

  defp decoders(mode) do
    %{
      array_start: &array_start(&1, mode),
      array_push: &array_push/2,
      array_finish: &array_finish/2,
      object_start: &object_start(&1, mode),
      object_push: &object_push/3,
      object_finish: &object_finish/2,
      integer: &decode_integer/1,
      float: float_decoder(mode),
      string: &Function.identity/1,
      null: nil
    }
  end

  defp float_decoder(:discard), do: fn _token -> :float end
  defp float_decoder(:retain_error), do: &:erlang.binary_to_float/1

  defp decode(raw_bytes, mode) do
    :json.decode(raw_bytes, {:root, nil}, decoders(mode))
  rescue
    _error -> :invalid_json
  catch
    _kind, _reason -> :invalid_json
  end

  defp initial_fields do
    %{
      jsonrpc: :missing,
      jsonrpc_count: 0,
      id: :missing,
      id_count: 0,
      result_count: 0,
      error: :missing,
      error_count: 0,
      method_count: 0
    }
  end

  defp initial_error_fields do
    %{code: :missing, code_count: 0, message: :missing, message_count: 0, data_seen?: false}
  end

  defp object_start({:root, _fields}, _mode), do: {:object, 0, initial_fields()}

  defp object_start(old_accumulator, :discard) do
    depth = accumulator_depth(old_accumulator) + 1
    fields = if depth == 1, do: initial_error_fields(), else: nil
    {:object, depth, fields}
  end

  defp object_start(old_accumulator, :retain_error) do
    depth = accumulator_depth(old_accumulator) + 1
    fields = if depth == 1, do: initial_error_fields(), else: nil
    {:retained_object, depth, [], fields}
  end

  defp object_push(key, value, {:object, 0, fields}) do
    {:object, 0, capture_response_field(fields, key, value)}
  end

  defp object_push(key, value, {:object, 1, fields}) do
    {:object, 1, capture_error_field(fields, key, value)}
  end

  defp object_push(key, value, {:retained_object, 1, pairs, fields}) do
    {:retained_object, 1, [{key, value} | pairs], capture_error_field(fields, key, value)}
  end

  defp object_push(key, value, {:retained_object, depth, pairs, fields}) do
    {:retained_object, depth, [{key, value} | pairs], fields}
  end

  defp object_push(_key, _value, accumulator), do: accumulator

  defp object_finish({:object, 0, fields}, {:root, _old_fields}) do
    {{:container, :object}, {:root, fields}}
  end

  defp object_finish({:object, 1, fields}, old_accumulator) do
    {{:container, :object, fields}, old_accumulator}
  end

  defp object_finish({:object, _depth, _fields}, old_accumulator) do
    {{:container, :object}, old_accumulator}
  end

  defp object_finish({:retained_object, 1, pairs, fields}, old_accumulator) do
    value = pairs |> Enum.reverse() |> Map.new()
    {{:container, :object, %{fields: fields, value: value}}, old_accumulator}
  end

  defp object_finish({:retained_object, _depth, pairs, _fields}, old_accumulator) do
    {pairs |> Enum.reverse() |> Map.new(), old_accumulator}
  end

  defp array_start({:root, _fields}, _mode), do: {:array, 0, nil}

  defp array_start(old_accumulator, :discard),
    do: {:array, accumulator_depth(old_accumulator) + 1, nil}

  defp array_start(old_accumulator, :retain_error),
    do: {:retained_array, accumulator_depth(old_accumulator) + 1, []}

  defp array_push(value, {:retained_array, depth, values}),
    do: {:retained_array, depth, [value | values]}

  defp array_push(_value, accumulator), do: accumulator

  defp array_finish({:array, 0, _fields}, {:root, _old_fields}) do
    {{:container, :array}, {:root, :top_level_array}}
  end

  defp array_finish({:array, _depth, _fields}, old_accumulator) do
    {{:container, :array}, old_accumulator}
  end

  defp array_finish({:retained_array, _depth, values}, old_accumulator) do
    {Enum.reverse(values), old_accumulator}
  end

  defp accumulator_depth({:object, depth, _fields}), do: depth
  defp accumulator_depth({:array, depth, _fields}), do: depth
  defp accumulator_depth({:retained_object, depth, _pairs, _fields}), do: depth
  defp accumulator_depth({:retained_array, depth, _values}), do: depth

  defp capture_response_field(fields, "jsonrpc", value) do
    %{fields | jsonrpc: value, jsonrpc_count: fields.jsonrpc_count + 1}
  end

  defp capture_response_field(fields, "id", value) do
    %{fields | id: normalize_id(value), id_count: fields.id_count + 1}
  end

  defp capture_response_field(fields, "result", _value) do
    %{fields | result_count: fields.result_count + 1}
  end

  defp capture_response_field(fields, "error", value) do
    %{fields | error: value, error_count: fields.error_count + 1}
  end

  defp capture_response_field(fields, "method", _value) do
    %{fields | method_count: fields.method_count + 1}
  end

  defp capture_response_field(fields, _key, _value), do: fields

  defp capture_error_field(fields, "code", value) do
    %{fields | code: normalize_error_code(value), code_count: fields.code_count + 1}
  end

  defp capture_error_field(fields, "message", value) do
    message = if is_binary(value), do: value, else: :invalid
    %{fields | message: message, message_count: fields.message_count + 1}
  end

  defp capture_error_field(fields, "data", _value), do: %{fields | data_seen?: true}

  defp capture_error_field(fields, _key, _value), do: fields

  defp decode_integer(token), do: :erlang.binary_to_integer(token)

  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(value) when is_integer(value), do: value
  defp normalize_id(nil), do: nil
  defp normalize_id(_value), do: :invalid

  defp normalize_error_code(value) when is_integer(value), do: value
  defp normalize_error_code(_value), do: :invalid

  defp classify_fields(fields) do
    candidate_id = candidate_id(fields)

    cond do
      fields.jsonrpc_count != 1 ->
        {:invalid, :invalid_envelope, candidate_id}

      fields.jsonrpc != "2.0" ->
        {:invalid, :unsupported_version, candidate_id}

      fields.id_count == 0 and legacy_frame?(fields) ->
        {:legacy, legacy_kind(fields)}

      fields.id_count != 1 ->
        {:invalid, :invalid_envelope, nil}

      fields.id == :invalid ->
        {:invalid, :invalid_envelope, nil}

      fields.method_count > 0 ->
        {:invalid, :unexpected_notification, candidate_id}

      fields.result_count == 1 and fields.error_count == 0 ->
        {:ok, %Validated{kind: :result, id: fields.id}}

      fields.result_count == 0 and fields.error_count == 1 ->
        validate_error(fields.error, fields.id)

      true ->
        {:invalid, :invalid_envelope, candidate_id}
    end
  end

  defp legacy_frame?(fields),
    do: fields.method_count > 0 or fields.error_count == 1

  defp legacy_kind(%{method_count: count}) when count > 0, do: :notification
  defp legacy_kind(_fields), do: :connection_error

  defp validate_error(
         {:container, :object,
          %{
            fields: %{code: code, code_count: 1, message: message, message_count: 1},
            value: value
          }},
         id
       )
       when is_integer(code) and is_binary(message) and is_map(value) do
    {:ok,
     %Validated{
       kind: :error,
       id: id,
       error_code: code,
       error_message: message,
       error_data: Map.get(value, "data")
     }}
  end

  defp validate_error(
         {:container, :object,
          %{code: code, code_count: 1, message: message, message_count: 1} = fields},
         id
       )
       when is_integer(code) and is_binary(message) do
    {:ok,
     %Validated{
       kind: :error,
       id: id,
       error_code: code,
       error_message: message,
       error_data: discarded_error_data(fields)
     }}
  end

  defp validate_error(_error, id), do: {:invalid, :invalid_envelope, id}

  defp discarded_error_data(%{data_seen?: true}), do: @discarded_error_data
  defp discarded_error_data(_fields), do: nil

  defp candidate_id(%{id_count: 1, id: id}) when id != :invalid, do: id
  defp candidate_id(_fields), do: nil

  defp locate_id(%Validated{id: id} = validated, raw_bytes) do
    case Jason.encode(id) do
      {:ok, encoded_id} -> locate_encoded_id(validated, raw_bytes, encoded_id)
      {:error, _reason} -> {:error, :ambiguous_id_location}
    end
  end

  defp locate_encoded_id(validated, raw_bytes, encoded_id) do
    case :binary.matches(raw_bytes, encoded_id) do
      [{start_pos, length}] = matches ->
        locate_verified_id(validated, raw_bytes, matches, {start_pos, length})

      _none_or_ambiguous ->
        locate_top_level_id(validated, raw_bytes)
    end
  end

  defp locate_verified_id(validated, raw_bytes, _matches, canonical_span) do
    case top_level_id_span(raw_bytes) do
      {:ok, ^canonical_span} -> {:ok, %{validated | id_span: canonical_span}}
      {:ok, actual_span} -> {:ok, %{validated | id_span: actual_span}}
      :error -> {:error, :ambiguous_id_location}
    end
  end

  defp locate_top_level_id(validated, raw_bytes) do
    case top_level_id_span(raw_bytes) do
      {:ok, span} -> {:ok, %{validated | id_span: span}}
      :error -> {:error, :ambiguous_id_location}
    end
  end

  defp response_mode(raw_bytes) do
    prefix_size = min(byte_size(raw_bytes), @mode_scan_bytes)
    prefix = binary_part(raw_bytes, 0, prefix_size)
    start = skip_whitespace(prefix, 0)

    if byte_at(prefix, start) == ?{ do
      scan_response_mode(prefix, skip_whitespace(prefix, start + 1), nil)
    else
      :unknown
    end
  end

  defp scan_response_mode(raw_bytes, index, id_span) do
    with ?" <- byte_at(raw_bytes, index),
         {:ok, key_end} <- skip_string(raw_bytes, index),
         {:ok, key} <- decode_key(raw_bytes, index, key_end) do
      colon_index = skip_whitespace(raw_bytes, key_end)

      if byte_at(raw_bytes, colon_index) == ?: do
        value_start = skip_whitespace(raw_bytes, colon_index + 1)

        case key do
          "error" -> {:found, :retain_error, id_span}
          "result" -> {:found, :discard, id_span}
          "id" -> continue_response_mode(raw_bytes, value_start, value_start)
          _other -> continue_response_mode(raw_bytes, value_start, id_span)
        end
      else
        :unknown
      end
    else
      _invalid -> :unknown
    end
  end

  defp continue_response_mode(raw_bytes, value_start, id_start_or_span) do
    case skip_value(raw_bytes, value_start) do
      {:ok, value_end} ->
        id_span =
          if is_integer(id_start_or_span),
            do: {id_start_or_span, value_end - id_start_or_span},
            else: id_start_or_span

        next = skip_whitespace(raw_bytes, value_end)

        if byte_at(raw_bytes, next) == ?, do
          scan_response_mode(raw_bytes, skip_whitespace(raw_bytes, next + 1), id_span)
        else
          :unknown
        end

      :error ->
        :unknown
    end
  end

  defp top_level_id_span(raw_bytes) do
    start = skip_whitespace(raw_bytes, 0)

    if byte_at(raw_bytes, start) == ?{ do
      scan_top_level_members(raw_bytes, skip_whitespace(raw_bytes, start + 1))
    else
      :error
    end
  end

  defp scan_top_level_members(raw_bytes, index) do
    case byte_at(raw_bytes, index) do
      ?} ->
        :error

      ?" ->
        with {:ok, key_end} <- skip_string(raw_bytes, index),
             {:ok, key} <- decode_key(raw_bytes, index, key_end),
             colon_index = skip_whitespace(raw_bytes, key_end),
             ?: <- byte_at(raw_bytes, colon_index),
             value_start = skip_whitespace(raw_bytes, colon_index + 1),
             {:ok, value_end} <- skip_value(raw_bytes, value_start) do
          if key == "id" do
            {:ok, {value_start, value_end - value_start}}
          else
            continue_top_level_members(raw_bytes, value_end)
          end
        else
          _invalid -> :error
        end

      _other ->
        :error
    end
  end

  defp continue_top_level_members(raw_bytes, value_end) do
    next = skip_whitespace(raw_bytes, value_end)

    case byte_at(raw_bytes, next) do
      ?, -> scan_top_level_members(raw_bytes, skip_whitespace(raw_bytes, next + 1))
      ?} -> :error
      _other -> :error
    end
  end

  defp decode_key(raw_bytes, start, finish) do
    case binary_part(raw_bytes, start, finish - start) do
      ~s("id") -> {:ok, "id"}
      ~s("jsonrpc") -> {:ok, "jsonrpc"}
      ~s("result") -> {:ok, "result"}
      ~s("error") -> {:ok, "error"}
      ~s("method") -> {:ok, "method"}
      token -> {:ok, :json.decode(token)}
    end
  rescue
    _error -> :error
  end

  defp skip_value(raw_bytes, index) do
    case byte_at(raw_bytes, index) do
      ?" ->
        skip_string(raw_bytes, index)

      ?{ ->
        skip_container(raw_bytes, index + 1, [?}])

      ?[ ->
        skip_container(raw_bytes, index + 1, [?]])

      byte when byte in [?-, ?0, ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?t, ?f, ?n] ->
        skip_scalar(raw_bytes, index)

      _other ->
        :error
    end
  end

  defp skip_container(raw_bytes, index, [expected | rest] = stack) do
    if byte_size(raw_bytes) - index <= @linear_scan_threshold do
      skip_container_linear(raw_bytes, index, stack)
    else
      skip_container_matched(raw_bytes, index, expected, rest, stack)
    end
  end

  defp skip_container_matched(raw_bytes, index, expected, rest, stack) do
    case binary_match_from(raw_bytes, @container_specials, index) do
      :nomatch ->
        :error

      {special_index, _length} ->
        case byte_at(raw_bytes, special_index) do
          ?" ->
            case skip_string(raw_bytes, special_index) do
              {:ok, next} -> skip_container(raw_bytes, next, stack)
              :error -> :error
            end

          ?{ ->
            skip_container(raw_bytes, special_index + 1, [?} | stack])

          ?[ ->
            skip_container(raw_bytes, special_index + 1, [?] | stack])

          ^expected when rest == [] ->
            {:ok, special_index + 1}

          ^expected ->
            skip_container(raw_bytes, special_index + 1, rest)

          _other_closer ->
            skip_container(raw_bytes, special_index + 1, stack)
        end
    end
  end

  defp skip_container_linear(raw_bytes, index, [expected | rest] = stack) do
    case byte_at(raw_bytes, index) do
      nil ->
        :error

      ?" ->
        case skip_string(raw_bytes, index) do
          {:ok, next} -> skip_container_linear(raw_bytes, next, stack)
          :error -> :error
        end

      ?{ ->
        skip_container_linear(raw_bytes, index + 1, [?} | stack])

      ?[ ->
        skip_container_linear(raw_bytes, index + 1, [?] | stack])

      ^expected when rest == [] ->
        {:ok, index + 1}

      ^expected ->
        skip_container_linear(raw_bytes, index + 1, rest)

      _byte ->
        skip_container_linear(raw_bytes, index + 1, stack)
    end
  end

  defp skip_string(raw_bytes, index), do: do_skip_string(raw_bytes, index + 1)

  defp do_skip_string(raw_bytes, index) do
    if byte_size(raw_bytes) - index <= @linear_scan_threshold do
      do_skip_string_linear(raw_bytes, index)
    else
      do_skip_string_matched(raw_bytes, index)
    end
  end

  defp do_skip_string_matched(raw_bytes, index) do
    case binary_match_from(raw_bytes, @string_specials, index) do
      :nomatch ->
        :error

      {special_index, _length} ->
        case byte_at(raw_bytes, special_index) do
          ?" -> {:ok, special_index + 1}
          ?\\ -> skip_escape(raw_bytes, special_index)
        end
    end
  end

  defp do_skip_string_linear(raw_bytes, index) do
    case byte_at(raw_bytes, index) do
      nil -> :error
      ?" -> {:ok, index + 1}
      ?\\ -> skip_escape(raw_bytes, index)
      _byte -> do_skip_string_linear(raw_bytes, index + 1)
    end
  end

  defp skip_escape(raw_bytes, index) do
    next_index = if byte_at(raw_bytes, index + 1) == ?u, do: index + 6, else: index + 2

    if next_index <= byte_size(raw_bytes),
      do: do_skip_string(raw_bytes, next_index),
      else: :error
  end

  defp skip_scalar(raw_bytes, index) do
    if byte_size(raw_bytes) - index <= @linear_scan_threshold do
      skip_scalar_linear(raw_bytes, index)
    else
      case binary_match_from(raw_bytes, @scalar_delimiters, index) do
        :nomatch -> {:ok, byte_size(raw_bytes)}
        {delimiter_index, _length} -> {:ok, delimiter_index}
      end
    end
  end

  defp skip_scalar_linear(raw_bytes, index) do
    case byte_at(raw_bytes, index) do
      byte when byte in [nil, ?\s, ?\t, ?\r, ?\n, ?,, ?}, ?]] -> {:ok, index}
      _byte -> skip_scalar_linear(raw_bytes, index + 1)
    end
  end

  defp binary_match_from(raw_bytes, pattern, index) when index < byte_size(raw_bytes) do
    :binary.match(raw_bytes, pattern, scope: {index, byte_size(raw_bytes) - index})
  end

  defp binary_match_from(_raw_bytes, _pattern, _index), do: :nomatch

  defp skip_whitespace(raw_bytes, index) do
    case byte_at(raw_bytes, index) do
      byte when byte in [?\s, ?\t, ?\r, ?\n] -> skip_whitespace(raw_bytes, index + 1)
      _byte -> index
    end
  end

  defp byte_at(raw_bytes, index) when index < byte_size(raw_bytes),
    do: :binary.at(raw_bytes, index)

  defp byte_at(_raw_bytes, _index), do: nil

  defp restore_id(%Validated{id: id}, raw_bytes, id), do: {:ok, raw_bytes}

  defp restore_id(%Validated{id_span: {start_pos, length}}, raw_bytes, client_id) do
    with {:ok, encoded_id} <- Jason.encode(client_id) do
      prefix = binary_part(raw_bytes, 0, start_pos)
      suffix_start = start_pos + length
      suffix = binary_part(raw_bytes, suffix_start, byte_size(raw_bytes) - suffix_start)
      {:ok, IO.iodata_to_binary([prefix, encoded_id, suffix])}
    end
  end

  defp restore_id(%Validated{} = validated, raw_bytes, client_id) do
    case locate_id(validated, raw_bytes) do
      {:ok, located} -> restore_id(located, raw_bytes, client_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_response(%Validated{kind: :result}, client_id, restored_bytes) do
    {:ok, %Response.Success{id: client_id, jsonrpc: "2.0", raw_bytes: restored_bytes}}
  end

  defp build_response(
         %Validated{
           kind: :error,
           error_code: code,
           error_message: message,
           error_data: data
         },
         _client_id,
         _restored_bytes
       ) do
    {:error, JError.new(code, message, data: data)}
  end

  defp only_json_whitespace?(<<>>), do: true

  defp only_json_whitespace?(rest) when is_binary(rest) do
    rest
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in [32, 9, 10, 13]))
  end
end

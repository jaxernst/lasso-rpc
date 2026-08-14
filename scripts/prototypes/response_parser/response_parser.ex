defmodule LassoPrototype.ResponseParser do
  @moduledoc """
  PROTOTYPE: strict, one-pass JSON-RPC unary response validation.

  The parser uses OTP 27+'s `:json.decode/3` grammar implementation. Container
  callbacks retain only the top-level JSON-RPC fields and the bounded fields of
  a direct error object. All other arrays and objects collapse to markers.
  Successful correlation returns the original input binary.
  """

  @type response_kind :: :result | :error

  @type validated :: %{
          kind: response_kind(),
          id: integer() | binary() | nil,
          error_code: integer() | nil,
          error_message: binary() | nil,
          raw_bytes: binary()
        }

  @spec validate(binary(), integer() | binary() | nil) ::
          {:ok, validated()} | {:error, atom()}
  def validate(raw_bytes, expected_id) when is_binary(raw_bytes) do
    try do
      case :json.decode(raw_bytes, {:root, nil}, decoders()) do
        {{:container, :object}, {:root, fields}, <<>>} ->
          validate_fields(fields, expected_id, raw_bytes)

        {_value, _acc, <<>>} ->
          {:error, :not_a_response_object}

        {_value, _acc, _trailing} ->
          {:error, :trailing_data}
      end
    rescue
      _error -> {:error, :invalid_json}
    end
  end

  def validate(_raw_bytes, _expected_id), do: {:error, :invalid_input}

  defp decoders do
    %{
      array_start: &array_start/1,
      array_push: &array_push/2,
      array_finish: &array_finish/2,
      object_start: &object_start/1,
      object_push: &object_push/3,
      object_finish: &object_finish/2,
      integer: &decode_integer/1,
      float: fn _token -> :float end,
      string: &Function.identity/1,
      null: {:literal, :null}
    }
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
    %{
      code: :missing,
      code_count: 0,
      message: :missing,
      message_count: 0
    }
  end

  defp object_start({:root, _}), do: {:object, 0, initial_fields()}

  defp object_start({_parent_kind, depth, _parent_fields}) do
    fields = if depth + 1 == 1, do: initial_error_fields(), else: nil
    {:object, depth + 1, fields}
  end

  defp object_push(key, value, {:object, 0, fields}) do
    {:object, 0, capture_response_field(fields, key, value)}
  end

  defp object_push(key, value, {:object, 1, fields}) do
    {:object, 1, capture_error_field(fields, key, value)}
  end

  defp object_push(_key, _value, accumulator), do: accumulator

  defp object_finish({:object, 0, fields}, {:root, _}) do
    {{:container, :object}, {:root, fields}}
  end

  defp object_finish({:object, 1, fields}, old_accumulator) do
    {{:container, :object, fields}, old_accumulator}
  end

  defp object_finish({:object, _depth, _fields}, old_accumulator) do
    {{:container, :object}, old_accumulator}
  end

  defp array_start({:root, _}), do: {:array, 0, nil}

  defp array_start({_parent_kind, depth, _parent_fields}) do
    {:array, depth + 1, nil}
  end

  defp array_push(_value, accumulator), do: accumulator

  defp array_finish({:array, 0, _fields}, {:root, _}) do
    {{:container, :array}, {:root, :top_level_array}}
  end

  defp array_finish({:array, _depth, _fields}, old_accumulator) do
    {{:container, :array}, old_accumulator}
  end

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
    %{fields | message: value, message_count: fields.message_count + 1}
  end

  defp capture_error_field(fields, _key, _value), do: fields

  defp decode_integer(token) when byte_size(token) <= 18 do
    :erlang.binary_to_integer(token)
  end

  defp decode_integer(token), do: {:large_integer, token}

  defp normalize_id(value) when is_integer(value), do: value

  defp normalize_id({:large_integer, token}) do
    case Integer.parse(token) do
      {integer, ""} -> integer
      _other -> :invalid
    end
  end

  defp normalize_id({:literal, :null}), do: nil
  defp normalize_id(value) when is_binary(value), do: value
  defp normalize_id(_value), do: :invalid

  defp normalize_error_code(value) when is_integer(value), do: value

  defp normalize_error_code({:large_integer, token}) do
    case Integer.parse(token) do
      {integer, ""} -> integer
      _other -> :invalid
    end
  end

  defp normalize_error_code(_value), do: :invalid

  defp validate_fields(fields, expected_id, raw_bytes) do
    with :ok <- exactly_once(fields.jsonrpc_count, :duplicate_jsonrpc),
         :ok <- require_value(fields.jsonrpc, "2.0", :invalid_jsonrpc),
         :ok <- exactly_once(fields.id_count, :duplicate_id),
         :ok <- valid_id(fields.id),
         :ok <- matching_id(fields.id, expected_id),
         :ok <- no_method(fields.method_count),
         {:ok, kind} <- response_kind(fields),
         {:ok, error_fields} <- valid_error(kind, fields.error) do
      {:ok,
       %{
         kind: kind,
         id: fields.id,
         error_code: error_fields.code,
         error_message: error_fields.message,
         raw_bytes: raw_bytes
       }}
    end
  end

  defp exactly_once(1, _duplicate_reason), do: :ok
  defp exactly_once(0, _duplicate_reason), do: {:error, :missing_required_field}
  defp exactly_once(_count, duplicate_reason), do: {:error, duplicate_reason}

  defp require_value(value, value, _reason), do: :ok
  defp require_value(_actual, _expected, reason), do: {:error, reason}

  defp valid_id(:missing), do: {:error, :missing_id}
  defp valid_id(:invalid), do: {:error, :invalid_id}
  defp valid_id(_id), do: :ok

  defp matching_id(id, id), do: :ok
  defp matching_id(_actual, _expected), do: {:error, :id_mismatch}

  defp no_method(0), do: :ok
  defp no_method(_count), do: {:error, :response_contains_method}

  defp response_kind(%{result_count: 1, error_count: 0}), do: {:ok, :result}
  defp response_kind(%{result_count: 0, error_count: 1}), do: {:ok, :error}
  defp response_kind(%{result_count: 0, error_count: 0}), do: {:error, :missing_result_or_error}
  defp response_kind(_fields), do: {:error, :ambiguous_result_or_error}

  defp valid_error(:result, _error), do: {:ok, %{code: nil, message: nil}}

  defp valid_error(
         :error,
         {:container, :object, %{code: code, code_count: 1, message: message, message_count: 1}}
       )
       when is_integer(code) and is_binary(message),
       do: {:ok, %{code: code, message: message}}

  defp valid_error(:error, _error), do: {:error, :invalid_error_object}
end

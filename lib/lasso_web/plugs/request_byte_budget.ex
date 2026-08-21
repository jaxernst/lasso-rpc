defmodule LassoWeb.Plugs.RequestByteBudget do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias Lasso.Core.Request.ByteBudget

  @admission_key :lasso_request_body_admission
  @max_body_bytes 8_000_000
  @default_read_length_bytes 1_000_000

  defmodule CapacityError do
    @moduledoc false

    defexception message: "in-flight request byte capacity unavailable", plug_status: 503
  end

  defmodule HeaderError do
    @moduledoc false

    defexception [:message, plug_status: 400]
  end

  @doc false
  @spec max_body_bytes() :: pos_integer()
  def max_body_bytes, do: @max_body_bytes

  @doc false
  @spec max_buffered_body_bytes() :: pos_integer()
  def max_buffered_body_bytes, do: @max_body_bytes + @default_read_length_bytes

  @impl Plug
  def init(opts) do
    max_body_bytes = Keyword.get(opts, :max_body_bytes, @max_body_bytes)
    read_length_bytes = Keyword.get(opts, :read_length, @default_read_length_bytes)

    if not is_integer(max_body_bytes) or max_body_bytes <= 0 or
         not is_integer(read_length_bytes) or read_length_bytes <= 0 do
      raise ArgumentError, ":max_body_bytes and :read_length must be positive integers"
    end

    parser_opts =
      opts
      |> Keyword.delete(:max_body_bytes)
      |> Keyword.delete(:length)
      |> configure_parser_limits(max_body_bytes)
      |> Keyword.put_new(:read_length, read_length_bytes)
      |> Keyword.put(:body_reader, {__MODULE__, :read_body, []})
      |> Plug.Parsers.init()

    %{
      max_body_bytes: max_body_bytes,
      read_length_bytes: read_length_bytes,
      parser_opts: parser_opts
    }
  end

  defp configure_parser_limits(opts, max_body_bytes) do
    Keyword.update!(opts, :parsers, fn parsers ->
      Enum.map(parsers, fn
        parser when parser in [:json, Plug.Parsers.JSON] ->
          {parser, [length: max_body_bytes]}

        parser when parser in [:multipart, Plug.Parsers.MULTIPART] ->
          {parser, [length: max_body_bytes]}

        {parser, parser_opts} when parser in [:json, Plug.Parsers.JSON] ->
          {parser, Keyword.put(parser_opts, :length, max_body_bytes)}

        {parser, parser_opts} when parser in [:multipart, Plug.Parsers.MULTIPART] ->
          {parser, Keyword.put(parser_opts, :length, max_body_bytes)}

        parser ->
          parser
      end)
    end)
  end

  @impl Plug
  def call(conn, %{
        max_body_bytes: max_body_bytes,
        read_length_bytes: read_length_bytes,
        parser_opts: parser_opts
      }) do
    conn = admit(conn, max_body_bytes, read_length_bytes)

    try do
      Plug.Parsers.call(conn, parser_opts)
    catch
      kind, reason ->
        release(conn)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  def read_body(conn, opts) do
    conn = admit(conn, @max_body_bytes, @default_read_length_bytes)

    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        if Map.has_key?(conn.private, @admission_key),
          do: verify_body_chunk(status, body, conn),
          else: {status, body, conn}

      {:error, _reason} = error ->
        release(conn)
        error
    end
  end

  @doc false
  @spec release(Plug.Conn.t()) :: Plug.Conn.t()
  def release(conn) do
    case Map.get(conn.private, @admission_key) do
      %{reservation: %ByteBudget.Reservation{} = reservation} -> ByteBudget.release(reservation)
      _missing -> :ok
    end

    %{conn | private: Map.delete(conn.private, @admission_key)}
  end

  defp admit(conn, max_body_bytes, read_length_bytes) do
    if rpc_request?(conn) and not Map.has_key?(conn.private, @admission_key) do
      with {:ok, expected_length, reservation_bytes} <-
             admission_size(conn, max_body_bytes, read_length_bytes),
           {:ok, reservation} <- ByteBudget.reserve(reservation_bytes, self()) do
        conn
        |> put_private(@admission_key, %{
          reservation: reservation,
          expected_length: expected_length,
          observed_bytes: 0,
          max_body_bytes: max_body_bytes
        })
        |> register_before_send(&release/1)
      else
        {:error, :too_large} ->
          raise Plug.Parsers.RequestTooLargeError

        {:error, reason} when reason in [:malformed, :conflicting, :ambiguous_framing] ->
          raise HeaderError, message: header_error_message(reason)

        {:error, _capacity_reason} ->
          raise CapacityError
      end
    else
      conn
    end
  end

  defp admission_size(conn, max_body_bytes, read_length_bytes) do
    content_lengths = get_req_header(conn, "content-length")
    transfer_encodings = get_req_header(conn, "transfer-encoding")

    cond do
      content_lengths != [] and transfer_encodings != [] ->
        {:error, :ambiguous_framing}

      content_lengths == [] ->
        {:ok, :unknown, max_body_bytes + read_length_bytes}

      true ->
        case parse_content_lengths(content_lengths, max_body_bytes) do
          {:ok, content_length} ->
            {:ok, content_length, content_length}

          error ->
            error
        end
    end
  end

  defp parse_content_lengths(values, max_body_bytes) do
    values
    |> Enum.flat_map(&:binary.split(&1, ",", [:global]))
    |> Enum.reduce_while({:ok, nil}, fn raw_value, {:ok, expected} ->
      with value when value != "" <- trim_ows(raw_value),
           {:ok, parsed} <- parse_decimal(value, max_body_bytes) do
        if is_nil(expected) or expected == parsed do
          {:cont, {:ok, parsed}}
        else
          {:halt, {:error, :conflicting}}
        end
      else
        {:error, :too_large} -> {:halt, {:error, :too_large}}
        _malformed -> {:halt, {:error, :malformed}}
      end
    end)
    |> case do
      {:ok, nil} -> {:error, :malformed}
      result -> result
    end
  rescue
    _error -> {:error, :malformed}
  end

  defp parse_decimal(value, max_body_bytes),
    do: parse_decimal(value, max_body_bytes, 0)

  defp parse_decimal(<<>>, _max_body_bytes, parsed), do: {:ok, parsed}

  defp parse_decimal(<<digit, rest::binary>>, max_body_bytes, parsed)
       when digit in ?0..?9 do
    next = parsed * 10 + digit - ?0

    if next <= max_body_bytes do
      parse_decimal(rest, max_body_bytes, next)
    else
      {:error, :too_large}
    end
  end

  defp parse_decimal(_value, _max_body_bytes, _parsed), do: {:error, :malformed}

  defp trim_ows(value) do
    start = trim_ows_start(value, 0)
    finish = trim_ows_end(value, byte_size(value) - 1)

    if finish < start, do: "", else: binary_part(value, start, finish - start + 1)
  end

  defp trim_ows_start(value, index) when index < byte_size(value) do
    if :binary.at(value, index) in [?\s, ?\t],
      do: trim_ows_start(value, index + 1),
      else: index
  end

  defp trim_ows_start(_value, index), do: index

  defp trim_ows_end(_value, index) when index < 0, do: index

  defp trim_ows_end(value, index) do
    if :binary.at(value, index) in [?\s, ?\t],
      do: trim_ows_end(value, index - 1),
      else: index
  end

  defp verify_body_chunk(status, body, conn) do
    admission = Map.fetch!(conn.private, @admission_key)
    observed = admission.observed_bytes + byte_size(body)
    expected = admission.expected_length
    conn = put_private(conn, @admission_key, %{admission | observed_bytes: observed})

    cond do
      expected == :unknown and observed > admission.max_body_bytes ->
        reject_too_large!(conn)

      is_integer(expected) and observed > expected ->
        reject_body_length!(conn)

      status == :more and is_integer(expected) and observed == expected ->
        reject_body_length!(conn)

      status == :ok and is_integer(expected) and observed != expected ->
        reject_body_length!(conn)

      true ->
        {status, body, conn}
    end
  end

  defp reject_too_large!(conn) do
    release(conn)
    raise Plug.Parsers.RequestTooLargeError
  end

  defp reject_body_length!(conn) do
    release(conn)
    raise HeaderError, message: "content-length does not match the request body"
  end

  defp header_error_message(:malformed), do: "malformed content-length header"
  defp header_error_message(:conflicting), do: "conflicting content-length headers"

  defp header_error_message(:ambiguous_framing),
    do: "content-length and transfer-encoding conflict"

  defp rpc_request?(%Plug.Conn{method: "POST", request_path: "/rpc/" <> _rest}), do: true
  defp rpc_request?(_conn), do: false
end

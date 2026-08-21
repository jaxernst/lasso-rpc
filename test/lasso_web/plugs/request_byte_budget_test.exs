defmodule LassoWeb.Plugs.RequestByteBudgetTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Lasso.Core.Request.ByteBudget
  alias LassoWeb.ErrorJSON
  alias LassoWeb.Plugs.RequestByteBudget

  defmodule ReadSpyAdapter do
    @spec read_req_body({pid(), map()}, keyword()) :: {:ok | :more, binary(), {pid(), map()}}
    def read_req_body({owner, state}, opts) do
      send(owner, {:request_body_read, ByteBudget.stats()})

      case Plug.Adapters.Test.Conn.read_req_body(state, opts) do
        {status, body, next_state} -> {status, body, {owner, next_state}}
      end
    end
  end

  defmodule ReadErrorAdapter do
    @spec read_req_body({pid(), term()}, keyword()) :: {:error, term()}
    def read_req_body({owner, reason}, _opts) do
      send(owner, :request_body_read)
      {:error, reason}
    end
  end

  defmodule RaisingPipeline do
    use Plug.Router
    use Plug.ErrorHandler

    plug(RequestByteBudget,
      parsers: [:urlencoded, :multipart, :json],
      pass: ["*/*"],
      json_decoder: Lasso.JSON.Decoder
    )

    plug(:match)
    plug(:dispatch)

    post "/rpc/:chain" do
      _ = conn
      _ = chain
      raise "controller failure"
    end

    @impl Plug.ErrorHandler
    def handle_errors(conn, _assigns), do: send_resp(conn, conn.status, "error")
  end

  setup do
    Application.ensure_all_started(:lasso)
    await_empty()
    :ok
  end

  test "reserves Content-Length before the adapter reads and releases on response" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "eth_blockNumber", "id" => 1})
    before = ByteBudget.stats()

    conn =
      :post
      |> Plug.Test.conn("/rpc/ethereum", body)
      |> put_req_header("content-type", "application/json")
      |> put_content_length(byte_size(body))
      |> with_read_spy()

    conn = parse(conn)

    assert_received {:request_body_read, during_read}
    assert during_read.reservations == before.reservations + 1
    assert during_read.used_bytes == before.used_bytes + during_read.minimum_charge_bytes
    assert ByteBudget.stats().reservations == before.reservations + 1

    _conn = conn |> without_read_spy() |> send_resp(200, "{}")
    assert_empty(before)
  end

  test "unknown-length and transfer-encoded RPC bodies reserve the full parser maximum" do
    for transfer_encoding <- [nil, "chunked"] do
      before = ByteBudget.stats()

      conn =
        :post
        |> Plug.Test.conn("/rpc/ethereum", "")
        |> put_req_header("content-type", "application/octet-stream")
        |> maybe_put_transfer_encoding(transfer_encoding)
        |> parse()

      during = ByteBudget.stats()
      assert during.reservations == before.reservations + 1

      assert during.used_bytes ==
               before.used_bytes + RequestByteBudget.max_buffered_body_bytes()

      _conn = send_resp(conn, 200, "{}")
      assert_empty(before)
    end
  end

  test "a chunked body keeps one full reservation across every read" do
    before = ByteBudget.stats()

    conn =
      :post
      |> Plug.Test.conn("/rpc/ethereum", "1234")
      |> put_req_header("transfer-encoding", "chunked")

    assert {:more, "12", conn} = RequestByteBudget.read_body(conn, length: 2)

    during_first_read = ByteBudget.stats()
    assert during_first_read.reservations == before.reservations + 1

    assert during_first_read.used_bytes ==
             before.used_bytes + RequestByteBudget.max_buffered_body_bytes()

    assert {:ok, "34", conn} = RequestByteBudget.read_body(conn, length: 2)
    assert ByteBudget.stats() == during_first_read

    _conn = send_resp(conn, 200, "{}")
    assert_empty(before)
  end

  test "repeated admission and body reads never reserve twice" do
    body = "1234"
    before = ByteBudget.stats()

    conn =
      :post
      |> Plug.Test.conn("/rpc/ethereum", body)
      |> put_content_length(byte_size(body))

    assert {:more, "12", conn} = RequestByteBudget.read_body(conn, length: 2)
    once = ByteBudget.stats()
    assert once.reservations == before.reservations + 1

    assert {:ok, "34", conn} = RequestByteBudget.read_body(conn, length: 2)
    assert ByteBudget.stats() == once

    _conn = send_resp(conn, 200, "{}")
    assert_empty(before)
  end

  test "accepts the parser boundary and rejects an over-limit body before reading" do
    max_body_bytes = RequestByteBudget.max_body_bytes()
    before = ByteBudget.stats()

    accepted =
      :post
      |> Plug.Test.conn("/rpc/ethereum", "")
      |> put_req_header("content-type", "application/octet-stream")
      |> put_content_length(max_body_bytes)
      |> parse()

    assert ByteBudget.stats().used_bytes == before.used_bytes + max_body_bytes
    _accepted = send_resp(accepted, 200, "{}")
    assert_empty(before)

    rejected =
      :post
      |> Plug.Test.conn("/rpc/ethereum", "")
      |> put_req_header("content-type", "application/octet-stream")
      |> put_content_length(max_body_bytes + 1)
      |> with_read_spy()

    assert_raise Plug.Parsers.RequestTooLargeError, fn -> parse(rejected) end
    refute_received {:request_body_read, _stats}
    assert_empty(before)
  end

  test "rejects malformed and conflicting Content-Length before reading" do
    malformed_values = ["", "+1", "-1", "1x", "1,", "1, 2"]

    Enum.each(malformed_values, fn value ->
      before = ByteBudget.stats()

      conn =
        :post
        |> Plug.Test.conn("/rpc/ethereum", "{}")
        |> put_req_header("content-type", "application/json")
        |> put_raw_header("content-length", value)
        |> with_read_spy()

      assert_raise RequestByteBudget.HeaderError, fn -> parse(conn) end
      refute_received {:request_body_read, _stats}
      assert_empty(before)
    end)
  end

  test "accepts repeated identical Content-Length and rejects conflicting fields" do
    body = "{}"
    before = ByteBudget.stats()

    accepted =
      :post
      |> Plug.Test.conn("/rpc/ethereum", body)
      |> put_req_header("content-type", "application/json")
      |> put_raw_headers("content-length", ["2", "2"])
      |> parse()

    assert ByteBudget.stats().reservations == before.reservations + 1
    _accepted = send_resp(accepted, 200, "{}")
    assert_empty(before)

    rejected =
      :post
      |> Plug.Test.conn("/rpc/ethereum", body)
      |> put_req_header("content-type", "application/json")
      |> put_raw_headers("content-length", ["2", "3"])
      |> with_read_spy()

    assert_raise RequestByteBudget.HeaderError, fn -> parse(rejected) end
    refute_received {:request_body_read, _stats}
    assert_empty(before)
  end

  test "rejects Content-Length with Transfer-Encoding before reading" do
    before = ByteBudget.stats()

    conn =
      :post
      |> Plug.Test.conn("/rpc/ethereum", "{}")
      |> put_req_header("content-type", "application/json")
      |> put_content_length(2)
      |> put_req_header("transfer-encoding", "chunked")
      |> with_read_spy()

    assert_raise RequestByteBudget.HeaderError, fn -> parse(conn) end
    refute_received {:request_body_read, _stats}
    assert_empty(before)
  end

  test "rejects bodies that are shorter or longer than Content-Length and releases immediately" do
    for {declared, body} <- [{1, "{}"}, {3, "{}"}] do
      before = ByteBudget.stats()

      conn =
        :post
        |> Plug.Test.conn("/rpc/ethereum", body)
        |> put_req_header("content-type", "application/json")
        |> put_content_length(declared)

      assert_raise RequestByteBudget.HeaderError, fn -> parse(conn) end
      assert_empty(before)
    end
  end

  test "parser and adapter read errors release immediately" do
    before = ByteBudget.stats()

    malformed_json =
      :post
      |> Plug.Test.conn("/rpc/ethereum", "{")
      |> put_req_header("content-type", "application/json")
      |> put_content_length(1)

    assert_raise Plug.Parsers.ParseError, fn -> parse(malformed_json) end
    assert_empty(before)

    read_error =
      :post
      |> Plug.Test.conn("/rpc/ethereum", "{}")
      |> put_req_header("content-type", "application/json")
      |> put_content_length(2)
      |> Map.put(:adapter, {ReadErrorAdapter, {self(), :closed}})

    assert_raise Plug.BadRequestError, fn -> parse(read_error) end
    assert_received :request_body_read
    assert_empty(before)
  end

  test "a downstream controller exception releases through the error response" do
    body = ~s({"jsonrpc":"2.0","method":"eth_blockNumber","id":1})
    before = ByteBudget.stats()

    conn =
      :post
      |> Plug.Test.conn("/rpc/ethereum", body)
      |> put_req_header("content-type", "application/json")
      |> put_content_length(byte_size(body))

    assert_raise Plug.Conn.WrapperError, fn -> RaisingPipeline.call(conn, []) end
    assert_empty(before)
  end

  test "JSON, urlencoded, and multipart parsers share admission and release" do
    requests = [
      {"application/json", ~s({"jsonrpc":"2.0","method":"eth_blockNumber","id":1})},
      {"application/x-www-form-urlencoded", "jsonrpc=2.0&method=eth_blockNumber&id=1"},
      {"multipart/form-data; boundary=lasso",
       "--lasso\r\ncontent-disposition: form-data; name=\"jsonrpc\"\r\n\r\n2.0\r\n" <>
         "--lasso\r\ncontent-disposition: form-data; name=\"method\"\r\n\r\neth_blockNumber\r\n" <>
         "--lasso--\r\n"}
    ]

    Enum.each(requests, fn {content_type, body} ->
      before = ByteBudget.stats()

      conn =
        :post
        |> Plug.Test.conn("/rpc/ethereum", body)
        |> put_req_header("content-type", content_type)
        |> put_content_length(byte_size(body))
        |> parse()

      assert conn.body_params["jsonrpc"] == "2.0"
      assert ByteBudget.stats().reservations == before.reservations + 1

      _conn = send_resp(conn, 200, "{}")
      assert_empty(before)
    end)
  end

  test "multipart reserves its declared length before bypassing the body reader" do
    body =
      "--lasso\r\ncontent-disposition: form-data; name=\"jsonrpc\"\r\n\r\n2.0\r\n" <>
        "--lasso--\r\n"

    before = ByteBudget.stats()

    conn =
      :post
      |> Plug.Test.conn("/rpc/ethereum", body)
      |> put_req_header("content-type", "multipart/form-data; boundary=lasso")
      |> put_content_length(byte_size(body))
      |> with_read_spy()
      |> parse()

    assert_received {:request_body_read, during_read}

    assert during_read.used_bytes == before.used_bytes + during_read.minimum_charge_bytes

    assert conn.body_params["jsonrpc"] == "2.0"
    _conn = conn |> without_read_spy() |> send_resp(200, "{}")
    assert_empty(before)
  end

  test "non-RPC and WebSocket paths never consume the HTTP RPC budget" do
    before = ByteBudget.stats()

    for {method, path} <- [
          {:post, "/api/other"},
          {:get, "/ws/rpc/ethereum"},
          {:get, "/live/websocket"},
          {:post, "/rpc-not-a-route"}
        ] do
      conn =
        method
        |> Plug.Test.conn(path, "{}")
        |> put_req_header("content-type", "application/json")
        |> parse()

      assert ByteBudget.stats() == before
      _conn = send_resp(conn, 200, "{}")
    end
  end

  test "HTTP admission fails before reading when every eligible bucket is full" do
    stats = ByteBudget.stats()

    reservations =
      fill_all_small_buckets(
        stats.small_bucket_count,
        stats.small_bucket_limit_bytes,
        %{},
        4_096
      )

    on_exit(fn ->
      Enum.each(reservations, fn {_bucket, reservation} -> ByteBudget.release(reservation) end)
    end)

    conn =
      :post
      |> Plug.Test.conn("/rpc/ethereum", ~s({"jsonrpc":"2.0"}))
      |> put_req_header("content-type", "application/json")
      |> put_content_length(17)
      |> with_read_spy()

    assert_raise RequestByteBudget.CapacityError, fn -> parse(conn) end
    refute_received {:request_body_read, _stats}
  end

  test "parallel unknown-length admissions stay within aggregate capacity" do
    parent = self()
    worker_count = 16

    workers =
      for _index <- 1..worker_count do
        spawn(fn ->
          conn =
            :post
            |> Plug.Test.conn("/rpc/ethereum", "")
            |> put_req_header("content-type", "application/octet-stream")

          try do
            conn = parse(conn)
            send(parent, {:admitted, self()})

            receive do
              :release ->
                _conn = send_resp(conn, 200, "{}")
                send(parent, {:released, self()})
            end
          rescue
            RequestByteBudget.CapacityError -> send(parent, {:rejected, self()})
          end
        end)
      end

    results = Enum.map(workers, fn _worker -> receive_result() end)
    admitted = for {:admitted, pid} <- results, do: pid
    rejected = for {:rejected, pid} <- results, do: pid

    stats = ByteBudget.stats()
    assert admitted != []
    assert rejected != []

    assert length(admitted) <=
             stats.large_bucket_count *
               div(stats.large_bucket_limit_bytes, RequestByteBudget.max_buffered_body_bytes())

    assert stats.used_bytes <= stats.limit_bytes
    assert stats.reservations == length(admitted)

    Enum.each(admitted, &send(&1, :release))
    Enum.each(admitted, fn pid -> assert_receive {:released, ^pid}, 1_000 end)
    await_empty()
  end

  test "owner death is reclaimed by the budget audit" do
    parent = self()
    before = ByteBudget.stats()

    {pid, monitor} =
      spawn_monitor(fn ->
        conn =
          :post
          |> Plug.Test.conn("/rpc/ethereum", "")
          |> put_req_header("content-type", "application/octet-stream")
          |> parse()

        send(parent, {:held_reservation, ByteBudget.stats(), conn.state})
      end)

    assert_receive {:held_reservation, during, :unset}, 1_000
    assert during.reservations == before.reservations + 1
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000

    send(ByteBudget, :audit)
    await_empty()
  end

  test "capacity errors retain the retriable JSON-RPC transport response" do
    response =
      ErrorJSON.render("503.json", %{
        reason: %RequestByteBudget.CapacityError{}
      })

    assert %{
             "jsonrpc" => "2.0",
             "id" => nil,
             "error" => %{
               "code" => -32_008,
               "message" => "Local request byte capacity unavailable"
             }
           } = response
  end

  test "framing and size errors render as JSON-RPC responses at the endpoint" do
    malformed =
      :post
      |> Plug.Test.conn("/rpc/ethereum", "{}")
      |> put_req_header("content-type", "application/json")
      |> put_raw_header("content-length", "invalid")

    assert {400, %{"jsonrpc" => "2.0", "id" => nil, "error" => malformed_error}} =
             endpoint_error_response(malformed, RequestByteBudget.HeaderError)

    assert malformed_error["code"] == -32_700

    oversized =
      :post
      |> Plug.Test.conn("/rpc/ethereum", "")
      |> put_req_header("content-type", "application/json")
      |> put_content_length(RequestByteBudget.max_body_bytes() + 1)

    assert {413, %{"jsonrpc" => "2.0", "id" => nil, "error" => oversized_error}} =
             endpoint_error_response(oversized, Plug.Parsers.RequestTooLargeError)

    assert oversized_error == %{
             "code" => -32_600,
             "message" => "Invalid Request: request body too large"
           }
  end

  test "an oversized non-RPC endpoint request retains the generic 413 response" do
    body = String.duplicate(" ", RequestByteBudget.max_body_bytes() + 1)

    oversized =
      :post
      |> Plug.Test.conn("/api/other", body)
      |> put_req_header("content-type", "application/json")
      |> put_content_length(byte_size(body))

    assert {413, %{"errors" => %{"detail" => "Request Entity Too Large"}}} =
             endpoint_error_response(oversized, Plug.Parsers.RequestTooLargeError)
  end

  defp parse(conn) do
    opts =
      RequestByteBudget.init(
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Lasso.JSON.Decoder
      )

    RequestByteBudget.call(conn, opts)
  end

  defp with_read_spy(%Plug.Conn{adapter: {_adapter, state}} = conn),
    do: %{conn | adapter: {ReadSpyAdapter, {self(), state}}}

  defp without_read_spy(%Plug.Conn{adapter: {ReadSpyAdapter, {_owner, state}}} = conn),
    do: %{conn | adapter: {Plug.Adapters.Test.Conn, state}}

  defp put_content_length(conn, length),
    do: put_raw_header(conn, "content-length", Integer.to_string(length))

  defp put_raw_header(conn, name, value), do: put_raw_headers(conn, name, [value])

  defp put_raw_headers(conn, name, values) do
    headers = Enum.reject(conn.req_headers, fn {header, _value} -> header == name end)
    %{conn | req_headers: Enum.map(values, &{name, &1}) ++ headers}
  end

  defp maybe_put_transfer_encoding(conn, nil), do: conn

  defp maybe_put_transfer_encoding(conn, value),
    do: put_req_header(conn, "transfer-encoding", value)

  defp endpoint_error_response(%Plug.Conn{adapter: {_adapter, %{ref: ref}}} = conn, error) do
    assert_raise error, fn ->
      LassoWeb.Endpoint.call(conn, LassoWeb.Endpoint.init([]))
    end

    assert_receive {^ref, {status, _headers, body}}, 1_000
    {status, Jason.decode!(body)}
  end

  defp receive_result do
    receive do
      {:admitted, _pid} = result -> result
      {:rejected, _pid} = result -> result
    after
      2_000 -> flunk("parallel admission worker did not report")
    end
  end

  defp fill_all_small_buckets(bucket_count, _bytes, reservations, _attempts)
       when map_size(reservations) == bucket_count,
       do: reservations

  defp fill_all_small_buckets(_bucket_count, _bytes, _reservations, 0),
    do: flunk("could not fill every byte-budget bucket")

  defp fill_all_small_buckets(bucket_count, bytes, reservations, attempts) do
    reservations =
      case ByteBudget.reserve(bytes) do
        {:ok, reservation} -> Map.put(reservations, reservation.bucket, reservation)
        {:error, :byte_capacity} -> reservations
      end

    fill_all_small_buckets(bucket_count, bytes, reservations, attempts - 1)
  end

  defp assert_empty(before) do
    stats = ByteBudget.stats()
    assert stats.reservations == before.reservations
    assert stats.used_bytes == before.used_bytes
  end

  defp await_empty(attempts \\ 100)
  defp await_empty(0), do: flunk("byte budget did not return to zero")

  defp await_empty(attempts) do
    case ByteBudget.stats() do
      %{used_bytes: 0, reservations: 0} ->
        :ok

      _busy ->
        send(ByteBudget, :audit)
        Process.sleep(10)
        await_empty(attempts - 1)
    end
  end
end

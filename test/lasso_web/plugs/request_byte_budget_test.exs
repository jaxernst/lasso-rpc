defmodule LassoWeb.Plugs.RequestByteBudgetTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Lasso.Core.Request.ByteBudget
  alias LassoWeb.ErrorJSON
  alias LassoWeb.Plugs.RequestByteBudget

  setup do
    Application.ensure_all_started(:lasso)
    await_empty()
    :ok
  end

  test "an HTTP RPC body holds one reservation until the response is sent" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "eth_blockNumber", "id" => 1})
    before = ByteBudget.stats()
    conn = Plug.Test.conn(:post, "/rpc/ethereum", body)

    assert {:ok, ^body, conn} = RequestByteBudget.read_body(conn, [])

    during = ByteBudget.stats()
    assert during.reservations == before.reservations + 1
    assert during.used_bytes == before.used_bytes + during.minimum_charge_bytes

    _conn = send_resp(conn, 200, "{}")
    assert ByteBudget.stats().reservations == before.reservations
    assert ByteBudget.stats().used_bytes == before.used_bytes
  end

  test "non-RPC bodies do not consume the routing budget" do
    before = ByteBudget.stats()
    conn = Plug.Test.conn(:post, "/api/other", "{}")

    assert {:ok, "{}", _conn} = RequestByteBudget.read_body(conn, [])
    assert ByteBudget.stats() == before
  end

  test "HTTP admission fails before JSON decoding when every byte bucket is full" do
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

    conn = Plug.Test.conn(:post, "/rpc/ethereum", ~s({"jsonrpc":"2.0"}))

    assert_raise RequestByteBudget.CapacityError, fn ->
      RequestByteBudget.read_body(conn, [])
    end
  end

  test "capacity errors render as a retriable JSON-RPC transport rejection" do
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

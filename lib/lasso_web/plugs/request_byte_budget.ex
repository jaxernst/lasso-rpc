defmodule LassoWeb.Plugs.RequestByteBudget do
  @moduledoc false

  import Plug.Conn

  alias Lasso.Core.Request.ByteBudget

  @reservation_key :lasso_request_byte_budget_reservation

  defmodule CapacityError do
    @moduledoc false

    defexception message: "in-flight request byte capacity unavailable", plug_status: 503
  end

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        reserve_rpc_body(status, body, conn)

      {:error, _reason} = error ->
        error
    end
  end

  defp reserve_rpc_body(status, body, conn) do
    if rpc_request?(conn) and not Map.has_key?(conn.private, @reservation_key) do
      case ByteBudget.reserve(byte_size(body), self()) do
        {:ok, reservation} ->
          conn =
            conn
            |> put_private(@reservation_key, reservation)
            |> register_before_send(&release_reservation/1)

          {status, body, conn}

        {:error, _reason} ->
          raise CapacityError
      end
    else
      {status, body, conn}
    end
  end

  defp rpc_request?(%Plug.Conn{method: "POST", request_path: "/rpc" <> _rest}), do: true
  defp rpc_request?(_conn), do: false

  defp release_reservation(conn) do
    case Map.get(conn.private, @reservation_key) do
      %ByteBudget.Reservation{} = reservation -> ByteBudget.release(reservation)
      _missing -> :ok
    end

    conn
  end
end

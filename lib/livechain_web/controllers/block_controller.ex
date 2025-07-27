defmodule LivechainWeb.BlockController do
  use LivechainWeb, :controller

  def latest(conn, %{"chain_id" => chain_id}) do
    # TODO: Implement actual block fetching
    case Livechain.RPC.ChainManager.get_chain_status(chain_id) do
      {:ok, status} ->
        json(conn, %{
          chain_id: chain_id,
          latest_block: status.latest_block || %{},
          timestamp: System.system_time(:second)
        })

      {:error, reason} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Chain not found or not running", details: reason})
    end
  end

  def show(conn, %{"chain_id" => chain_id, "number" => block_number}) do
    # TODO: Implement actual block fetching by number
    json(conn, %{
      chain_id: chain_id,
      block_number: block_number,
      block: %{
        hash: "0x#{:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)}",
        number: block_number,
        timestamp: System.system_time(:second)
      }
    })
  end
end

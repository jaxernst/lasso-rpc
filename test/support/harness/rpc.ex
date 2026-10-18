defmodule Lasso.Test.Harness.Rpc do
  @moduledoc "Real Finch HTTP and Mint WebSocket clients for harness surfaces."
  alias Lasso.RPC.Transport.WebSocket.Client

  def call(credentials, method, params \\ [], opts \\ []) do
    id =
      Keyword.get_lazy(opts, :id, fn ->
        "harness-request-#{System.unique_integer([:positive])}"
      end)

    request = %{jsonrpc: "2.0", id: id, method: method, params: params}

    {:ok, response} =
      Finch.build(
        :post,
        credentials.rpc_url,
        [{"content-type", "application/json"}, {"x-request-id", to_string(id)}],
        Jason.encode!(request)
      )
      |> Finch.request(Lasso.Finch, receive_timeout: 5_000)

    body =
      case Jason.decode(response.body) do
        {:ok, body} -> body
        {:error, _} -> response.body
      end

    %{id: id, status: response.status, headers: response.headers, body: body}
  end

  @doc "Opens a real Mint socket; frames arrive as {:rpc_frame, reference, frame}."
  def wire!(url) do
    reference = make_ref()
    {:ok, pid} = Client.start_link(url, __MODULE__.Capture, {self(), reference}, owner: self())
    %{pid: pid, reference: reference}
  end

  def send!(wire, method, params \\ [], id \\ 1) do
    Client.cast(wire.pid, {:send, %{jsonrpc: "2.0", id: id, method: method, params: params}})
  end

  @doc "Closes the client synchronously before tenant retirement."
  def close!(wire), do: GenServer.stop(wire.pid)

  defmodule Capture do
    @moduledoc false
    def handle_connect(_, owner), do: {:ok, owner}

    def handle_frame(frame, {pid, ref} = owner) do
      send(pid, {:rpc_frame, ref, frame})
      {:ok, owner}
    end

    def handle_disconnect(reason, {pid, ref} = owner) do
      send(pid, {:rpc_disconnect, ref, reason})
      {:ok, owner}
    end

    def handle_cast({:send, request}, owner), do: {:reply, {:text, Jason.encode!(request)}, owner}
    def handle_info(_, owner), do: {:ok, owner}
  end
end

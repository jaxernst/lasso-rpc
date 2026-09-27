defmodule Lasso.Discovery.TransactionProbeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Lasso.Discovery.{Formatter, Probes.MethodSupport}
  alias Lasso.RPC.MethodRegistry

  defmodule Upstream do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      send(opts[:observer], {:discovery_request, request["method"]})

      response = %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "error" => %{"code" => -32_601, "message" => "Method not found"}
      }

      send_resp(conn, 200, Jason.encode!(response))
    end
  end

  test "full discovery avoids transaction and provider-local filter dispatch" do
    ref = {__MODULE__, make_ref()}
    prior_http_client = Application.get_env(:lasso, :http_client)

    {:ok, _pid} = Plug.Cowboy.http(Upstream, [observer: self()], ref: ref, port: 0)
    url = "http://127.0.0.1:#{:ranch.get_port(ref)}"
    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, prior_http_client)
      Plug.Cowboy.shutdown(ref)
    end)

    results = MethodSupport.probe(url, level: :full, timeout: 2_000)
    raw_tx = Enum.find(results, &(&1.method == "eth_sendRawTransaction"))

    assert raw_tx.status == :unverifiable
    assert raw_tx.duration_ms == 0
    assert MethodSupport.count_by_status(results).unverifiable == 1

    assert %{status: :unverifiable} =
             MethodSupport.probe_http_method(url, "eth_sendTransaction", 2_000)

    assert MethodRegistry.unverifiable?("eth_sendRawTransaction")
    assert MethodRegistry.unverifiable?("eth_sendTransaction")

    received = drain_methods([])
    assert "eth_blockNumber" in received
    assert "eth_getLogs" in received
    refute "eth_sendRawTransaction" in received
    refute "eth_sendTransaction" in received

    for method <- Lasso.Config.MethodConstraints.stateful_filter_methods() do
      refute method in received
      refute Enum.any?(results, &(&1.method == method))
    end

    formatted = Formatter.format_table(%{url: url, methods: results})
    assert formatted =~ "Cannot verify safely: 1"
    assert formatted =~ "eth_sendRawTransaction"
  end

  defp drain_methods(acc) do
    receive do
      {:discovery_request, method} -> drain_methods([method | acc])
    after
      0 -> acc
    end
  end
end

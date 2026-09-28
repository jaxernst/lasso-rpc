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

      response =
        case {opts[:mode], request["method"]} do
          {:evidence, "eth_chainId"} ->
            %{"jsonrpc" => "2.0", "id" => request["id"], "result" => "0x1"}

          {:evidence, "eth_blockNumber"} ->
            %{"jsonrpc" => "2.0", "id" => request["id"], "result" => "0xnot-hex"}

          {:evidence, "net_version"} ->
            %{"jsonrpc" => "2.0", "id" => 999, "result" => "1"}

          {:evidence, "eth_getBalance"} ->
            %{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "error" => %{"code" => -32_602, "message" => "Invalid params"}
            }

          _ ->
            %{
              "jsonrpc" => "2.0",
              "id" => request["id"],
              "error" => %{"code" => -32_601, "message" => "Method not found"}
            }
        end

      send_resp(conn, 200, Jason.encode!(response))
    end
  end

  test "method probe distinguishes verified reads from recognized and invalid responses" do
    ref = {__MODULE__, make_ref()}
    prior_http_client = Application.get_env(:lasso, :http_client)

    {:ok, _pid} =
      Plug.Cowboy.http(Upstream, [observer: self(), mode: :evidence], ref: ref, port: 0)

    url = "http://127.0.0.1:#{:ranch.get_port(ref)}"
    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, prior_http_client)
      Plug.Cowboy.shutdown(ref)
    end)

    valid_result = MethodSupport.probe_http_method(url, "eth_chainId", 2_000)
    invalid_result = MethodSupport.probe_http_method(url, "eth_blockNumber", 2_000)
    wrong_id = MethodSupport.probe_http_method(url, "net_version", 2_000)
    recognized = MethodSupport.probe_http_method(url, "eth_getBalance", 2_000)

    assert valid_result.status == :supported
    assert invalid_result.status == :unknown
    assert wrong_id.status == :unknown
    assert recognized.status == :recognized

    report =
      Formatter.format_table(%{
        methods: [Map.merge(recognized, %{method: "eth_getBalance", category: :state})]
      })

    assert report =~ "Recognized, unverified: 1"
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

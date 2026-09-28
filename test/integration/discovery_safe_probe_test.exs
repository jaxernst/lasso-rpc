defmodule Lasso.Integration.DiscoverySafeProbeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Lasso.Discovery.Probes.MethodSupport

  defmodule Upstream do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      send(opts[:observer], {:probe_request, request["method"], request["params"]})

      response = %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "error" => %{"code" => -32_000, "message" => "Method is not available"}
      }

      send_resp(conn, 200, Jason.encode!(response))
    end
  end

  test "operator probes use bounded valid parameters and recognize provider method refusals" do
    ref = {__MODULE__, make_ref()}
    prior_client = Application.get_env(:lasso, :http_client)
    {:ok, _pid} = Plug.Cowboy.http(Upstream, [observer: self()], ref: ref, port: 0)
    url = "http://127.0.0.1:#{:ranch.get_port(ref)}"
    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, prior_client)
      Plug.Cowboy.shutdown(ref)
    end)

    assert %{status: :unsupported} = MethodSupport.probe_http_method(url, "net_version", 2_000)
    assert_receive {:probe_request, "net_version", []}

    MethodSupport.probe_http_method(url, "eth_feeHistory", 2_000)
    assert_receive {:probe_request, "eth_feeHistory", ["0x4", "latest", []]}

    MethodSupport.probe_http_method(url, "eth_call", 2_000)

    assert_receive {:probe_request, "eth_call", [%{"gas" => "0x186a0"}, "latest"]}

    MethodSupport.probe_http_method(url, "debug_traceBlockByNumber", 2_000)

    assert_receive {:probe_request, "debug_traceBlockByNumber", ["0x0", options]}
    assert options["timeout"] == "1s"
    assert options["tracer"] == "callTracer"
  end
end

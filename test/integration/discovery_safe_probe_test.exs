defmodule Lasso.Integration.DiscoverySafeProbeTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Lasso.Discovery.Probes.MethodSupport
  alias Lasso.Discovery
  alias Lasso.Discovery.Formatter

  defmodule Upstream do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      send(opts[:observer], {:probe_request, request["method"], request["params"]})

      {status, message, code} =
        case opts[:mode] do
          :auth -> {401, "Unauthorized", -32_000}
          :quota -> {402, "Payment required: credits exhausted", -32_000}
          :quota_402_envelope -> {402, "Payment Required", 402}
          :typed_quota -> {200, "monthly quota exceeded", 30}
          :rate_limit -> {429, "Too many requests", -32_000}
          :quota_429 -> {429, "monthly quota exceeded", -32_005}
          :rate_limit_429 -> {429, "Rate limit exceeded", -32_005}
          :definitive_quota_word -> {200, "monthly quota exceeded", -32_700}
          _ -> {200, "Method is not available", -32_000}
        end

      response = %{
        "jsonrpc" => "2.0",
        "id" => request["id"],
        "error" => %{"code" => code, "message" => message}
      }

      body = if opts[:mode] == :quota, do: message, else: Jason.encode!(response)
      send_resp(conn, status, body)
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

  test "standard HTTP probing verifies log support without attempting subscription methods" do
    url = start_upstream(:unsupported)
    results = MethodSupport.probe(url, level: :standard, timeout: 2_000, concurrent: 2)

    assert is_list(results)
    assert Enum.any?(results, &(&1.method == "eth_getLogs"))
    assert_receive {:probe_request, "eth_getLogs", _}

    full_methods = MethodSupport.get_methods_for_level(:full)
    refute "eth_subscribe" in full_methods
    refute "eth_unsubscribe" in full_methods
  end

  test "HTTP method probing stops after authentication or quota exhaustion" do
    for {mode, reason} <- [
          auth: :auth_required,
          quota: :quota_exhausted,
          typed_quota: :quota_exhausted,
          quota_402_envelope: :quota_exhausted,
          quota_429: :quota_exhausted
        ] do
      url = start_upstream(mode)

      assert {:aborted, ^reason} =
               MethodSupport.probe(url, level: :critical, timeout: 2_000, concurrent: 2)
    end
  end

  test "an aborted operator probe reports the reason without recommending capability blocks" do
    url = start_upstream(:auth)
    result = Discovery.probe(url, probes: [:methods], method_level: :critical, concurrent: 2)

    assert result.methods == {:aborted, :auth_required}
    assert Discovery.generate_capabilities_config(result) == %{}
    assert Formatter.format_table(result) =~ "Method probing stopped"

    assert Formatter.format_json(result) |> Jason.decode!() |> get_in(["methods", "status"]) ==
             "aborted"
  end

  for mode <- [:rate_limit, :rate_limit_429] do
    test "#{mode} signals throttling without retrying the throttled method" do
      caller = self()
      url = start_upstream(unquote(mode))

      results =
        MethodSupport.probe(url,
          level: :critical,
          timeout: 2_000,
          concurrent: 100,
          on_throttle: fn info -> send(caller, {:throttled, info}) end
        )

      assert is_list(results)
      assert_receive {:throttled, %{phase: :methods}}
      assert count_probe_requests("eth_chainId", 0) == 1
    end
  end

  test "definitive JSON-RPC errors with quota words do not abort method discovery" do
    url = start_upstream(:definitive_quota_word)

    results = MethodSupport.probe(url, level: :critical, timeout: 2_000, concurrent: 2)

    assert is_list(results)
    assert Enum.all?(results, &(&1.status == :unknown))
  end

  defp count_probe_requests(method, count) do
    receive do
      {:probe_request, ^method, _params} -> count_probe_requests(method, count + 1)
    after
      0 -> count
    end
  end

  defp start_upstream(mode) do
    ref = {__MODULE__, make_ref()}
    prior_client = Application.get_env(:lasso, :http_client)
    {:ok, _pid} = Plug.Cowboy.http(Upstream, [observer: self(), mode: mode], ref: ref, port: 0)
    Application.put_env(:lasso, :http_client, Lasso.RPC.Transport.HTTP.Client.Finch)

    on_exit(fn ->
      Application.put_env(:lasso, :http_client, prior_client)
      Plug.Cowboy.shutdown(ref)
    end)

    "http://127.0.0.1:#{:ranch.get_port(ref)}"
  end
end

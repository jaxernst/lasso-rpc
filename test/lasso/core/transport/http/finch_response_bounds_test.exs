defmodule Lasso.RPC.Transport.HTTP.FinchResponseBoundsTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Request.RequestOwner
  alias Lasso.Core.Transport.{AttemptProtocol, UpstreamAdmission}
  alias Lasso.Core.Support.LogRangeLimit
  alias Lasso.RPC.{AttemptIdentity, AttemptTerminal}
  alias Lasso.RPC.Response
  alias Lasso.RPC.Transport.HTTP.Client.Finch, as: FinchClient
  alias Lasso.RPC.Transports.HTTP

  @admission __MODULE__.Admission
  @finch_name __MODULE__.Finch

  setup do
    start_supervised!(
      {UpstreamAdmission,
       name: @admission,
       shards: 2,
       node_limit: 4,
       upstream_limit: 4,
       response_byte_limit: 256,
       response_limit: 64}
    )

    start_supervised!(
      {Finch, name: @finch_name, pools: %{:default => [size: 2, count: 1, protocols: [:http1]]}}
    )

    on_exit(fn -> UpstreamAdmission.stop(@admission) end)
    :ok
  end

  test "rejects an oversized Content-Length before reading the response body" do
    {url, request} =
      serve_once("HTTP/1.1 200 OK\r\ncontent-length: 65\r\nconnection: keep-alive\r\n\r\n")

    assert {:error, {:response_limit, :response_too_large}} = rpc(url)

    assert {:ok, range_error} =
             LogRangeLimit.translate("eth_getLogs", {:response_limit, :response_too_large})

    assert range_error.code == -32_005
    assert range_error.data.action == :reduce_block_range
    assert request.() =~ "accept-encoding: identity"
    assert_empty()
    assert UpstreamAdmission.stats(@admission).response_rejected == 1
  end

  test "bounds chunked responses without Content-Length" do
    body = String.duplicate("x", 65)

    response =
      "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n" <>
        Integer.to_string(byte_size(body), 16) <> "\r\n" <> body <> "\r\n0\r\n\r\n"

    {url, request} = serve_once(response)

    assert {:error, {:response_limit, :response_too_large}} = rpc(url)
    request.()
    assert_empty()
  end

  test "rejects compressed bodies because the bounded path requests identity encoding" do
    response =
      "HTTP/1.1 200 OK\r\ncontent-encoding: gzip\r\ncontent-length: 8\r\n" <>
        "connection: close\r\n\r\nnot-gzip"

    {url, request} = serve_once(response)

    assert {:error, {:response_limit, :compressed_response}} = rpc(url)
    request.()
    assert_empty()
    assert UpstreamAdmission.stats(@admission).response_rejected == 1
  end

  test "response envelope rejection produces valid non-penalizing attempt evidence" do
    {url, request} =
      serve_once("HTTP/1.1 200 OK\r\ncontent-length: 65\r\nconnection: close\r\n\r\n")

    outcome =
      RequestOwner.execute(
        attempt_identity(),
        System.monotonic_time(:microsecond) + 1_000_000,
        fn -> rpc(url, attempt_dispatch: AttemptProtocol.context()) end
      )

    assert outcome.result == {:error, {:response_limit, :response_too_large}}

    assert %AttemptTerminal.Response{
             kind: :application_error,
             error_code: -32_005,
             error_category: :local_safety,
             io_duration_us: duration
           } = outcome.fact

    assert duration >= 0
    assert outcome.projection.breaker_effect == :none
    refute outcome.projection.fallback_eligible
    request.()
    assert_empty()
  end

  test "rejects malformed response framing without admission residue" do
    response =
      "HTTP/1.1 200 OK\r\ncontent-length: invalid\r\n" <>
        "connection: close\r\n\r\nnot-a-response"

    {url, request} = serve_once(response)

    assert {:error, _reason} = rpc(url)
    request.()
    assert_empty()
  end

  test "rejects conflicting response lengths without admission residue" do
    response =
      "HTTP/1.1 200 OK\r\ncontent-length: 2\r\ncontent-length: 3\r\n" <>
        "connection: close\r\n\r\n{}"

    {url, request} = serve_once(response)

    assert {:error, _reason} = rpc(url)
    request.()
    assert_empty()
  end

  test "rejects responses with both transfer encoding and content length" do
    response =
      "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\ncontent-length: 2\r\n" <>
        "connection: close\r\n\r\n2\r\n{}\r\n0\r\n\r\n"

    {url, request} = serve_once(response)

    assert {:error, _reason} = rpc(url)
    request.()
    assert_empty()
  end

  test "rejects repeated chunked transfer codings" do
    response =
      "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked, chunked\r\n" <>
        "connection: close\r\n\r\n2\r\n{}\r\n0\r\n\r\n"

    {url, request} = serve_once(response)

    assert {:error, _reason} = rpc(url)
    request.()
    assert_empty()
  end

  test "accepts a bounded raw response and releases its conservative copy charge" do
    body = ~s({"jsonrpc":"2.0","id":"bounded","result":"0x1"})

    response =
      "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n" <>
        "connection: close\r\n\r\n" <> body

    {url, request} = serve_once(response)

    assert {:ok, {:raw, ^body}} =
             FinchClient.request(
               %{url: url},
               "eth_blockNumber",
               [],
               request_id: "bounded",
               timeout: 1_000,
               finch_name: @finch_name,
               admission: @admission
             )

    request.()
    assert_empty()
    assert UpstreamAdmission.stats(@admission).peak_response_bytes == byte_size(body) * 2
  end

  test "generic consumers retain their byte lease through response processing" do
    body = ~s({"result":"bounded"})

    response =
      "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n" <>
        "connection: close\r\n\r\n" <> body

    {url, receive_request} = serve_once(response)
    request = Finch.build(:get, url)

    assert {:ok, ^body} =
             FinchClient.bounded_request(
               request,
               [finch_name: @finch_name, admission: @admission],
               fn {:ok, %Finch.Response{body: received}} ->
                 assert UpstreamAdmission.stats(@admission).response_bytes == byte_size(body) * 2
                 {:ok, received}
               end
             )

    receive_request.()
    assert_empty()
  end

  test "a successful transport response retains bytes through request ownership until consumption" do
    previous_client = Application.get_env(:lasso, :http_client)
    Application.put_env(:lasso, :http_client, FinchClient)
    on_exit(fn -> Application.put_env(:lasso, :http_client, previous_client) end)

    body = ~s({"jsonrpc":"2.0","id":"bounded","result":"0x1"})

    response =
      "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n" <>
        "connection: close\r\n\r\n" <> body

    {url, receive_request} = serve_once(response)
    {:ok, channel} = HTTP.open(%{url: url, id: "test"}, instance_id: "bounded-instance")
    before_bytes = UpstreamAdmission.stats().response_bytes

    outcome =
      RequestOwner.execute(
        attempt_identity(),
        System.monotonic_time(:microsecond) + 1_000_000,
        fn ->
          HTTP.request(
            channel,
            %{"method" => "eth_blockNumber", "params" => [], "id" => "bounded"},
            1_000
          )
        end
      )

    assert {:ok, %Response.Success{raw_bytes: ^body, capacity_lease: lease}, _elapsed} =
             outcome.result

    assert UpstreamAdmission.stats().response_bytes == before_bytes + byte_size(body) * 2
    assert :ok = UpstreamAdmission.release(lease, :test_consumed)
    assert UpstreamAdmission.stats().response_bytes == before_bytes
    receive_request.()
  end

  test "an expired generic request never consumes admission capacity" do
    request = Finch.build(:get, "http://127.0.0.1:1")

    assert {:error, {:local_capacity_rejection, :deadline}} =
             FinchClient.bounded_request(
               request,
               [
                 finch_name: @finch_name,
                 admission: @admission,
                 deadline_us: System.monotonic_time(:microsecond) - 1
               ],
               & &1
             )

    assert_empty()
  end

  defp rpc(url, extra_opts \\ []) do
    FinchClient.request(
      %{url: url},
      "eth_getLogs",
      [],
      Keyword.merge(
        [
          request_id: "bounded",
          timeout: 1_000,
          finch_name: @finch_name,
          admission: @admission
        ],
        extra_opts
      )
    )
  end

  defp attempt_identity do
    AttemptIdentity.new(
      request_id: "bounded",
      attempt_id: "bounded-attempt",
      profile: "public",
      chain_id: 1,
      upstream_instance_id: "bounded-instance",
      transport: :http,
      route_generation: 1,
      circuit_scope: :broad,
      circuit_epoch: 1,
      execution_safety: :replay_safe,
      routing_intent: "default",
      workload_key: "eth_getLogs",
      request_budget_ms: 1_000,
      candidate_admission_count: 1,
      dispatch_count: 1
    )
  end

  defp serve_once(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    parent = self()

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, request} = receive_headers(socket, "")
        send(parent, {:bounded_request, request})
        :ok = :gen_tcp.send(socket, response)
        Process.sleep(50)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    monitor = Process.monitor(server)

    request = fn ->
      assert_receive {:bounded_request, request}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^server, :normal}, 1_000
      request
    end

    {"http://127.0.0.1:#{port}", request}
  end

  defp receive_headers(socket, acc) do
    if :binary.match(acc, "\r\n\r\n") == :nomatch do
      case :gen_tcp.recv(socket, 0, 1_000) do
        {:ok, bytes} -> receive_headers(socket, acc <> bytes)
        error -> error
      end
    else
      {:ok, acc}
    end
  end

  defp assert_empty do
    assert %{node_inflight: 0, response_bytes: 0, leases: 0} =
             UpstreamAdmission.stats(@admission)
  end
end

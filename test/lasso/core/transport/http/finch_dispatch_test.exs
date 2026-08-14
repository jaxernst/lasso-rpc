defmodule Lasso.RPC.Transport.HTTP.FinchDispatchTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Transport.HTTP.DispatchTracker
  alias Lasso.Core.Transport.AttemptProtocol
  alias Lasso.RPC.Transport.HTTP.Client.Finch, as: FinchClient

  @finch_name __MODULE__.Client

  setup do
    start_supervised!(
      {Finch, name: @finch_name, pools: %{:default => [size: 1, count: 1, protocols: [:http1]]}}
    )

    :ok
  end

  test "adapter source uses only the public Finch request seam" do
    source = File.read!("lib/lasso/core/transport/http/adapters/finch.ex")

    assert source =~ "Finch.request(request, finch_name"
    refute source =~ "Finch.HTTP1"
    refute source =~ "Finch.Pool.Manager"
    refute source =~ "NimblePool"
    refute source =~ "Mint."
    refute source =~ "authorize_dispatch"
    refute source =~ "confirm_dispatched"
  end

  test "request encoding failure aborts before connection and returns a typed client error" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    test_pid = self()

    acceptor =
      spawn(fn ->
        result = :gen_tcp.accept(listener, 250)
        send(test_pid, {:accept_result, result})
      end)

    assert {:error, {:encode_error, _reason}} =
             FinchClient.request(
               %{url: "http://127.0.0.1:#{port}"},
               "eth_call",
               [self()],
               timeout: 100,
               finch_name: @finch_name
             )

    assert_receive {:accept_result, {:error, :timeout}}, 1_000
    refute Process.alive?(acceptor)
    :ok = :gen_tcp.close(listener)
  end

  test "invalid request URL aborts before pool checkout" do
    assert {:error, {:request_build_error, _reason}} =
             FinchClient.request(
               %{url: "not a URL"},
               "eth_blockNumber",
               [],
               timeout: 100,
               finch_name: @finch_name
             )
  end

  test "predispatch Finch failure is proven only while the tracker remains authoritative" do
    context = attempt_context()

    assert {:error, {:network_error, _message}} =
             FinchClient.request(
               %{url: "http://example.invalid"},
               "eth_blockNumber",
               [],
               timeout: 100,
               attempt_dispatch: context,
               request_fun: fn _request, _name, _options ->
                 {:error, %Finch.TransportError{reason: :econnrefused}}
               end
             )

    assert %{certainty: :not_dispatched} = AttemptProtocol.close(context)

    assert {:ok, %{kind: :predispatch_failure, reason: :pool_unavailable}} =
             AttemptProtocol.take_terminal_candidate(context)
  end

  test "send start followed by handler loss and timeout remains indeterminate" do
    context = attempt_context()

    assert {:error, :timeout} =
             FinchClient.request(
               %{url: "http://example.invalid"},
               "eth_blockNumber",
               [],
               timeout: 100,
               attempt_dispatch: context,
               request_fun: fn request, _name, _options ->
                 :telemetry.execute([:finch, :send, :start], %{}, %{request: request})
                 :ok = :telemetry.detach("lasso-finch-dispatch-tracker")
                 {:error, %Finch.TransportError{reason: :timeout}}
               end
             )

    assert %{certainty: :indeterminate} = AttemptProtocol.close(context)

    assert {:ok, %{kind: :transport_failure, certainty: :indeterminate, reason: :timeout}} =
             AttemptProtocol.take_terminal_candidate(context)

    assert :ok = DispatchTracker.audit_now()
    assert DispatchTracker.ready?()
  end

  test "missing tracker at the Finch boundary prevents a false not-dispatched claim" do
    context = attempt_context()

    assert {:error, {:network_error, _message}} =
             FinchClient.request(
               %{url: "http://example.invalid"},
               "eth_blockNumber",
               [],
               timeout: 100,
               attempt_dispatch: context,
               request_fun: fn _request, _name, _options ->
                 :ok = :telemetry.detach("lasso-finch-dispatch-tracker")
                 {:error, %Finch.TransportError{reason: :closed}}
               end
             )

    assert %{certainty: :indeterminate} = AttemptProtocol.close(context)

    assert {:ok, %{kind: :transport_failure, certainty: :indeterminate, reason: :closed}} =
             AttemptProtocol.take_terminal_candidate(context)

    assert :ok = DispatchTracker.audit_now()
  end

  test "deadline options preserve one exact remaining budget without clamping" do
    test_pid = self()

    assert {:error, {:local_capacity_rejection, :pool_unavailable}} =
             FinchClient.request(
               %{url: "http://example.invalid"},
               "eth_blockNumber",
               [],
               deadline_us: 10_000,
               monotonic_now_fun: fn -> 3_001 end,
               request_fun: fn _request, _name, options ->
                 send(test_pid, {:request_options, options})
                 {:error, %Finch.Error{reason: :pool_unavailable}}
               end
             )

    assert_receive {:request_options, [pool_timeout: 6, receive_timeout: 6, request_timeout: 6]}

    assert {:error, {:local_capacity_rejection, :deadline}} =
             FinchClient.request(
               %{url: "http://example.invalid"},
               "eth_blockNumber",
               [],
               deadline_us: 10_000,
               monotonic_now_fun: fn -> 9_001 end,
               request_fun: fn _request, _name, _options ->
                 send(test_pid, :expired_request_ran)
                 {:ok, %Finch.Response{status: 200, body: "{}"}}
               end
             )

    refute_receive :expired_request_ran
  end

  test "deadline recheck after receipt prevents entering Finch" do
    test_pid = self()
    context = attempt_context()
    counter = :counters.new(1, [])

    monotonic_now = fn ->
      :counters.add(counter, 1, 1)
      if :counters.get(counter, 1) == 1, do: 3_001, else: 10_000
    end

    assert {:error, {:local_capacity_rejection, :deadline}} =
             FinchClient.request(
               %{url: "http://example.invalid"},
               "eth_blockNumber",
               [],
               deadline_us: 10_000,
               attempt_dispatch: context,
               monotonic_now_fun: monotonic_now,
               request_fun: fn _request, _name, _options ->
                 send(test_pid, :deadline_recheck_request_ran)
                 {:ok, %Finch.Response{status: 200, body: "{}"}}
               end
             )

    assert %{certainty: :not_dispatched} = AttemptProtocol.close(context)
    assert {:ok, %{kind: :predispatch_failure}} = AttemptProtocol.take_terminal_candidate(context)
    refute_receive :deadline_recheck_request_ran
  end

  test "one adapter call performs one physical HTTP send" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    test_pid = self()
    context = attempt_context()
    response_body = ~s({"jsonrpc":"2.0","id":"physical-one","result":"0x1"})

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)
        {:ok, request, remainder} = receive_http_request(socket, "")
        send(test_pid, {:physical_request, request, remainder})

        response =
          "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(response_body)}\r\n" <>
            "connection: keep-alive\r\n\r\n" <> response_body

        :ok = :gen_tcp.send(socket, response)
        send(test_pid, {:after_response_bytes, :gen_tcp.recv(socket, 0, 100)})
        :gen_tcp.close(socket)
      end)

    server_monitor = Process.monitor(server)

    assert {:ok, {:raw, ^response_body}} =
             FinchClient.request(
               %{url: "http://127.0.0.1:#{port}"},
               "eth_blockNumber",
               [],
               request_id: "physical-one",
               timeout: 1_000,
               finch_name: @finch_name,
               attempt_dispatch: context
             )

    assert %{
             certainty: :dispatched,
             started_at_us: started_at_us,
             confirmed_at_us: confirmed_at_us
           } =
             AttemptProtocol.close(context)

    assert is_integer(started_at_us)
    assert is_integer(confirmed_at_us)
    assert confirmed_at_us >= started_at_us

    assert_receive {:physical_request, request, ""}, 1_000
    assert length(:binary.matches(request, "POST ")) == 1
    assert_receive {:after_response_bytes, result}, 1_000
    assert result in [{:error, :timeout}, {:error, :closed}]

    assert_receive {:DOWN, ^server_monitor, :process, ^server, :normal}, 1_000
    :ok = :gen_tcp.close(listener)
  end

  defp receive_http_request(socket, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {header_end, 4} ->
        body_start = header_end + 4
        headers = binary_part(acc, 0, body_start)
        content_length = content_length(headers)

        if byte_size(acc) >= body_start + content_length do
          request_size = body_start + content_length
          request = binary_part(acc, 0, request_size)
          remainder = binary_part(acc, request_size, byte_size(acc) - request_size)
          {:ok, request, remainder}
        else
          receive_more(socket, acc)
        end

      :nomatch ->
        receive_more(socket, acc)
    end
  end

  defp attempt_context do
    AttemptProtocol.new_context(
      self(),
      make_ref(),
      System.monotonic_time(:microsecond) + 5_000_000
    )
  end

  defp receive_more(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, bytes} -> receive_http_request(socket, acc <> bytes)
      error -> error
    end
  end

  defp content_length(headers) do
    [_, value] = Regex.run(~r/content-length:\s*(\d+)/i, headers)
    String.to_integer(value)
  end
end

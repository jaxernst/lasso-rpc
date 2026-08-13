defmodule Lasso.RPC.Transport.HTTP.FinchDispatchTest do
  use ExUnit.Case, async: false

  alias Lasso.RPC.Transport.HTTP.Client.Finch, as: FinchClient

  @finch_name __MODULE__.Client

  setup do
    start_supervised!(
      {Finch, name: @finch_name, pools: %{:default => [size: 1, count: 1, protocols: [:http1]]}}
    )

    :ok
  end

  test "rejected dispatch authorization prevents TCP connection and request send" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    test_pid = self()

    acceptor =
      spawn(fn ->
        result = :gen_tcp.accept(listener, 250)
        send(test_pid, {:accept_result, result})
      end)

    dead_lifecycle = spawn(fn -> :ok end)
    dead_monitor = Process.monitor(dead_lifecycle)
    assert_receive {:DOWN, ^dead_monitor, :process, ^dead_lifecycle, _reason}, 1_000

    assert {:error, {:local_capacity_rejection, :dispatch_cancelled}} =
             FinchClient.request(
               %{url: "http://127.0.0.1:#{port}"},
               "eth_blockNumber",
               [],
               timeout: 100,
               finch_name: @finch_name,
               attempt_dispatch: {dead_lifecycle, make_ref()}
             )

    assert_receive {:accept_result, {:error, :timeout}}, 1_000
    refute Process.alive?(acceptor)
    :ok = :gen_tcp.close(listener)
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
end

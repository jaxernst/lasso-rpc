defmodule Lasso.Core.Transport.AttemptProtocolTest do
  use ExUnit.Case, async: true

  alias Lasso.Core.Transport.AttemptProtocol

  test "terminal_at preserves the authoritative transport timestamp" do
    attempt_ref = make_ref()
    context = {self(), attempt_ref}

    assert :ok =
             AttemptProtocol.terminal_at(
               context,
               :response,
               %{response_kind: :error, io_duration_us: 7},
               41
             )

    assert_receive {:transport_observation, ^attempt_ref,
                    %{
                      kind: :response,
                      event_us: 41,
                      response_kind: :application_error,
                      io_duration_us: 7
                    }}
  end

  test "proven not-dispatched transport failure becomes a predispatch fact" do
    attempt_ref = make_ref()
    context = {self(), attempt_ref}

    assert :ok =
             AttemptProtocol.terminal_at(
               context,
               :transport_failure,
               %{reason: :network_error, certainty: :not_dispatched, elapsed_us: 0},
               42
             )

    assert_receive {:transport_observation, ^attempt_ref,
                    %{
                      kind: :predispatch_failure,
                      event_us: 42,
                      reason: :not_connected,
                      elapsed_us: 0
                    }}
  end

  test "authorization is a local deadline check and sends no lifecycle message" do
    lifecycle_pid = spawn(fn -> Process.sleep(:infinity) end)
    context = {lifecycle_pid, make_ref()}
    now = System.monotonic_time(:microsecond)

    assert AttemptProtocol.authorized?(context, now + 1_000_000)
    refute AttemptProtocol.authorized?(context, now - 1)
    assert {:message_queue_len, 0} = Process.info(lifecycle_pid, :message_queue_len)

    Process.exit(lifecycle_pid, :kill)
  end

  test "send start rejects a dead lifecycle owner" do
    lifecycle_pid = spawn(fn -> receive do: (:stop -> :ok) end)
    monitor = Process.monitor(lifecycle_pid)
    send(lifecycle_pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^lifecycle_pid, :normal}

    assert {:error, :owner_down} =
             AttemptProtocol.send_started({lifecycle_pid, make_ref()})
  end
end

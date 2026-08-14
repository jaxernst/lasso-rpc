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

  test "a backdated send start cannot authorize work after the actual deadline" do
    deadline_us = System.monotonic_time(:microsecond) + 1_000
    context = AttemptProtocol.new_context(self(), make_ref(), deadline_us)

    receive do
    after
      2 -> :ok
    end

    assert System.monotonic_time(:microsecond) >= deadline_us

    assert {:error, :deadline_expired} =
             AttemptProtocol.send_started_at(context, deadline_us - 1)

    assert %{certainty: :not_dispatched} = AttemptProtocol.close(context)
  end

  test "the request owner closes dispatch authorization atomically" do
    context =
      AttemptProtocol.new_context(
        self(),
        make_ref(),
        System.monotonic_time(:microsecond) + 1_000_000
      )

    assert %{certainty: :not_dispatched} = AttemptProtocol.close(context)
    assert {:error, :owner_down} = AttemptProtocol.send_started(context)
    assert %{certainty: :not_dispatched} = AttemptProtocol.close(context)
  end

  test "a send-start CAS that wins before closure is conservatively indeterminate" do
    context =
      AttemptProtocol.new_context(
        self(),
        make_ref(),
        System.monotonic_time(:microsecond) + 1_000_000
      )

    event_us = System.monotonic_time(:microsecond)

    assert :ok = AttemptProtocol.send_started_at(context, event_us)

    assert %{
             certainty: :indeterminate,
             started_at_us: ^event_us,
             confirmed_at_us: nil
           } = AttemptProtocol.close(context)
  end

  test "closure and send authorization have no unsafe split-brain result" do
    for _iteration <- 1..500 do
      context =
        AttemptProtocol.new_context(
          self(),
          make_ref(),
          System.monotonic_time(:microsecond) + 1_000_000
        )

      task = Task.async(fn -> AttemptProtocol.send_started(context) end)
      snapshot = AttemptProtocol.close(context)
      result = Task.await(task)

      assert {result, snapshot.certainty} in [
               {{:error, :owner_down}, :not_dispatched},
               {:ok, :indeterminate}
             ]
    end
  end

  test "positive send proof is retained in the immutable closure snapshot" do
    context =
      AttemptProtocol.new_context(
        self(),
        make_ref(),
        System.monotonic_time(:microsecond) + 1_000_000
      )

    :ok = AttemptProtocol.install_context(context)

    on_exit(fn -> AttemptProtocol.clear_context() end)

    assert :ok = AttemptProtocol.send_started(context)
    assert :ok = AttemptProtocol.send_confirmed(context)

    assert %{certainty: :dispatched, confirmed_at_us: confirmed_at_us} =
             AttemptProtocol.close(context)

    assert is_integer(confirmed_at_us)
  end

  test "late dispatch proof cannot revise the deadline gate" do
    deadline_us = System.monotonic_time(:microsecond) + 1_000_000
    context = AttemptProtocol.new_context(self(), make_ref(), deadline_us)

    assert :ok = AttemptProtocol.send_started_at(context, deadline_us - 1)
    assert :ok = AttemptProtocol.observe_at(context, :send_confirmed, deadline_us + 1, %{})

    observations = AttemptProtocol.gate_observations([], AttemptProtocol.close(context))
    assert Enum.any?(observations, &(&1.kind == :send_started and &1.event_us == deadline_us - 1))
    refute Enum.any?(observations, &(&1.kind == :send_confirmed))
  end

  test "late negative proof cannot erase timely send ambiguity" do
    for offset <- [0, 1] do
      deadline_us = System.monotonic_time(:microsecond) + 1_000_000
      context = AttemptProtocol.new_context(self(), make_ref(), deadline_us)

      assert :ok = AttemptProtocol.send_started_at(context, deadline_us - 1)

      assert :ok =
               AttemptProtocol.observe_at(
                 context,
                 :predispatch_failure,
                 deadline_us + offset,
                 %{reason: :not_connected, elapsed_us: 0}
               )

      assert %{certainty: :indeterminate, started_at_us: started_at_us} =
               AttemptProtocol.close(context)

      assert started_at_us == deadline_us - 1
    end
  end

  test "a closed dispatch gate is immutable" do
    deadline_us = System.monotonic_time(:microsecond) + 1_000_000
    context = AttemptProtocol.new_context(self(), make_ref(), deadline_us)

    assert :ok = AttemptProtocol.send_started_at(context, deadline_us - 10)
    assert %{certainty: :indeterminate} = snapshot = AttemptProtocol.close(context)

    assert :ok = AttemptProtocol.observe_at(context, :send_confirmed, deadline_us - 9, %{})

    assert :ok =
             AttemptProtocol.observe_at(context, :predispatch_failure, deadline_us - 8, %{
               reason: :not_connected,
               elapsed_us: 0
             })

    assert AttemptProtocol.close(context) == snapshot
  end

  test "negative proof racing closure has one immutable result" do
    for _iteration <- 1..500 do
      deadline_us = System.monotonic_time(:microsecond) + 1_000_000
      context = AttemptProtocol.new_context(self(), make_ref(), deadline_us)
      assert :ok = AttemptProtocol.send_started_at(context, deadline_us - 10)

      task =
        Task.async(fn ->
          AttemptProtocol.observe_at(context, :predispatch_failure, deadline_us - 9, %{
            reason: :not_connected,
            elapsed_us: 0
          })
        end)

      snapshot = AttemptProtocol.close(context)
      assert :ok = Task.await(task)
      assert snapshot.certainty in [:not_dispatched, :indeterminate]
      assert AttemptProtocol.close(context) == snapshot
    end
  end

  test "positive proof racing closure has one immutable result" do
    for _iteration <- 1..500 do
      deadline_us = System.monotonic_time(:microsecond) + 1_000_000
      context = AttemptProtocol.new_context(self(), make_ref(), deadline_us)
      assert :ok = AttemptProtocol.send_started_at(context, deadline_us - 10)

      task =
        Task.async(fn ->
          AttemptProtocol.observe_at(context, :send_confirmed, deadline_us - 9, %{})
        end)

      snapshot = AttemptProtocol.close(context)
      assert :ok = Task.await(task)
      assert snapshot.certainty in [:indeterminate, :dispatched]
      assert AttemptProtocol.close(context) == snapshot
    end
  end

  test "terminal candidates are task-local, exactly one, and bounded" do
    context =
      AttemptProtocol.new_context(
        self(),
        make_ref(),
        System.monotonic_time(:microsecond) + 1_000_000
      )

    :ok = AttemptProtocol.install_context(context)

    on_exit(fn -> AttemptProtocol.clear_context() end)

    assert :ok =
             AttemptProtocol.terminal(context, :response, %{
               response_kind: :success,
               io_duration_us: 3,
               ignored_body: String.duplicate("secret", 1_000)
             })

    assert :ok =
             AttemptProtocol.terminal(context, :transport_failure, %{
               reason: :closed,
               certainty: :dispatched
             })

    assert {:conflict, candidate} = AttemptProtocol.take_terminal_candidate(context)
    assert candidate.kind == :response
    refute inspect(candidate) =~ "secret"
    assert :missing = AttemptProtocol.take_terminal_candidate(context)
    refute_receive {:transport_observation, _, _}
  end
end

defmodule Lasso.Core.Transport.HTTP.DispatchTrackerTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Transport.AttemptProtocol
  alias Lasso.Core.Transport.HTTP.DispatchTracker

  @handler_id "lasso-finch-dispatch-tracker"
  @events [[:finch, :send, :start], [:finch, :send, :stop]]

  setup do
    if Process.whereis(DispatchTracker) == nil, do: start_supervised!(DispatchTracker)
    assert :ok = DispatchTracker.audit_now()
    :ok
  end

  test "application boot leaves the tracker ready before managed HTTP dispatch" do
    assert is_pid(Process.whereis(DispatchTracker))
    assert is_pid(Process.whereis(Lasso.Finch))
    assert {:ok, token} = DispatchTracker.ready_token()
    assert DispatchTracker.session_healthy?(token)
  end

  test "synchronously forwards bounded send observations correlated through request private" do
    {:ok, token} = DispatchTracker.ready_token()
    context = attempt_context()

    request =
      Finch.build(:post, "http://localhost", [], "{}")
      |> Finch.Request.put_private(:lasso_attempt, context)

    DispatchTracker.begin_attempt(context, token)
    :telemetry.execute([:finch, :send, :start], %{}, %{request: request})

    started_us = assert_started(context)

    assert DispatchTracker.attempt_state(context) == :started

    :telemetry.execute([:finch, :send, :stop], %{duration: 1}, %{request: request})

    confirmed_us = assert_confirmed(context)

    assert confirmed_us >= started_us
    assert DispatchTracker.attempt_state(context) == :confirmed
    DispatchTracker.clear_attempt(context)
  end

  test "adapter-opened ambiguity is emitted once before Finch reaches its send boundary" do
    {:ok, token} = DispatchTracker.ready_token()
    context = attempt_context()

    request =
      Finch.build(:post, "http://localhost", [], "{}")
      |> Finch.Request.put_private(:lasso_attempt, context)

    DispatchTracker.begin_attempt(context, token)
    assert :ok = DispatchTracker.open_send(context, token)

    event_us = assert_started(context)

    assert is_integer(event_us)

    :telemetry.execute([:finch, :send, :start], %{}, %{request: request})
    assert_started_once(context, event_us)
    assert DispatchTracker.attempt_state(context) == :started
    DispatchTracker.clear_attempt(context)
  end

  test "send stop carrying an error never confirms dispatch" do
    {:ok, token} = DispatchTracker.ready_token()
    context = attempt_context()

    request =
      Finch.build(:post, "http://localhost", [], "{}")
      |> Finch.Request.put_private(:lasso_attempt, context)

    DispatchTracker.begin_attempt(context, token)

    :telemetry.execute([:finch, :send, :start], %{}, %{request: request})
    assert_started(context)

    :telemetry.execute([:finch, :send, :stop], %{duration: 1}, %{
      request: request,
      error: :closed
    })

    refute_confirmed(context)
    assert DispatchTracker.attempt_state(context) == :started
    DispatchTracker.clear_attempt(context)
  end

  test "wrong handler replacement is rejected and repaired off the hot path" do
    {:ok, old_token} = DispatchTracker.ready_token()
    previous_count = DispatchTracker.status().degraded_count

    :ok = :telemetry.detach(@handler_id)

    assert :ok =
             :telemetry.attach_many(@handler_id, @events, fn _, _, _, _ -> :ok end, :wrong)

    refute DispatchTracker.session_healthy?(old_token)
    assert :ok = DispatchTracker.audit_now()
    assert DispatchTracker.ready?()
    assert DispatchTracker.status().degraded_count == previous_count + 1
    assert {:ok, new_token} = DispatchTracker.ready_token()
    assert new_token != old_token

    assert Enum.all?(@events, fn event ->
             Enum.any?(:telemetry.list_handlers(event), fn handler ->
               handler.id == @handler_id and
                 handler.function == (&DispatchTracker.handle_event/4) and
                 handler.config == %{token: new_token}
             end)
           end)
  end

  test "repair gives in-flight sessions a fresh incarnation without certainty regression" do
    context = attempt_context()
    {:ok, old_token} = DispatchTracker.ready_token()

    request =
      Finch.build(:post, "http://localhost", [], "{}")
      |> Finch.Request.put_private(:lasso_attempt, context)

    DispatchTracker.begin_attempt(context, old_token)
    :telemetry.execute([:finch, :send, :start], %{}, %{request: request})
    started_us = assert_started(context)
    assert DispatchTracker.attempt_state(context) == :started

    :ok = :telemetry.detach(@handler_id)
    assert :ok = DispatchTracker.audit_now()
    assert {:ok, new_token} = DispatchTracker.ready_token()
    assert new_token != old_token
    refute DispatchTracker.session_healthy?(old_token)
    assert DispatchTracker.attempt_state(context) == :started

    :telemetry.execute([:finch, :send, :stop], %{duration: 1}, %{request: request})
    assert_confirmed(context)
    assert DispatchTracker.attempt_state(context) == :confirmed

    :telemetry.execute([:finch, :send, :start], %{}, %{request: request})
    assert DispatchTracker.attempt_state(context) == :confirmed
    assert_started_once(context, started_us)
    DispatchTracker.clear_attempt(context)
  end

  test "restart keeps unobserved certainty, reclaims handlers, and returns ready" do
    context = attempt_context()
    {:ok, old_token} = DispatchTracker.ready_token()
    DispatchTracker.begin_attempt(context, old_token)

    confirmed_owner = start_confirmed_session(old_token)
    assert_receive {:confirmed_session_ready, ^confirmed_owner}, 1_000

    old_pid = Process.whereis(DispatchTracker)
    monitor = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :killed}

    _new_pid = await_restarted_tracker(old_pid)
    assert {:ok, new_token} = DispatchTracker.ready_token()
    assert new_token != old_token
    refute DispatchTracker.session_healthy?(old_token)
    assert DispatchTracker.session_healthy?(new_token)
    assert DispatchTracker.attempt_state(context) == :not_started

    send(confirmed_owner, {:read_state, self()})
    assert_receive {:confirmed_session_state, ^confirmed_owner, :confirmed}, 1_000

    send(confirmed_owner, :stop)
    DispatchTracker.clear_attempt(context)
  end

  defp await_restarted_tracker(old_pid, attempts \\ 100)

  defp await_restarted_tracker(_old_pid, 0), do: nil

  defp await_restarted_tracker(old_pid, attempts) do
    case Process.whereis(DispatchTracker) do
      pid when is_pid(pid) and pid != old_pid ->
        case DispatchTracker.ready_token() do
          {:ok, token} ->
            if DispatchTracker.session_healthy?(token) do
              pid
            else
              wait_for_restarted_tracker(old_pid, attempts)
            end

          {:error, :unavailable} ->
            wait_for_restarted_tracker(old_pid, attempts)
        end

      _ ->
        wait_for_restarted_tracker(old_pid, attempts)
    end
  end

  defp wait_for_restarted_tracker(old_pid, attempts) do
    receive do
    after
      10 -> await_restarted_tracker(old_pid, attempts - 1)
    end
  end

  defp start_confirmed_session(token) do
    parent = self()

    spawn_link(fn ->
      context = attempt_context()

      request =
        Finch.build(:post, "http://localhost", [], "{}")
        |> Finch.Request.put_private(:lasso_attempt, context)

      DispatchTracker.begin_attempt(context, token)
      :telemetry.execute([:finch, :send, :start], %{}, %{request: request})
      assert_started(context)
      :telemetry.execute([:finch, :send, :stop], %{duration: 1}, %{request: request})
      assert_confirmed(context)
      send(parent, {:confirmed_session_ready, self()})

      receive do
        {:read_state, caller} ->
          send(caller, {:confirmed_session_state, self(), DispatchTracker.attempt_state(context)})

          receive do
            :stop -> DispatchTracker.clear_attempt(context)
          end
      end
    end)
  end

  defp attempt_context do
    AttemptProtocol.new_context(
      self(),
      make_ref(),
      System.monotonic_time(:microsecond) + 5_000_000
    )
  end

  defp assert_started(%{gate: gate}) do
    timestamp = :atomics.get(gate, 2)
    assert timestamp != unset_timestamp()
    timestamp
  end

  defp assert_confirmed(%{gate: gate}) do
    timestamp = :atomics.get(gate, 3)
    assert timestamp != unset_timestamp()
    timestamp
  end

  defp assert_started_once(%{gate: gate}, started_us),
    do: assert(:atomics.get(gate, 2) == started_us)

  defp refute_confirmed(%{gate: gate}), do: assert(:atomics.get(gate, 3) == unset_timestamp())

  defp unset_timestamp, do: -9_223_372_036_854_775_808
end

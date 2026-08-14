defmodule Lasso.RPC.CircuitBreakerAttemptLifecycleTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Support.{AttemptLifecycle, CircuitBreaker}
  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.JSONRPC.Error, as: JError

  setup_all do
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  test "caller death after dispatch finalizes cancellation once and releases half-open admission" do
    id = start_half_open_breaker()
    test_pid = self()

    caller_pid =
      spawn(fn ->
        CircuitBreaker.call(
          id,
          fn ->
            send(test_pid, :attempt_started)
            Process.sleep(:infinity)
          end,
          5_000,
          on_terminal: fn result, elapsed_ms ->
            send(test_pid, {:terminal, result, elapsed_ms})
          end
        )
      end)

    assert_receive :attempt_started, 1_000
    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))
    assert :sys.get_state(breaker_pid).inflight_count == 1

    Process.exit(caller_pid, :kill)

    assert_receive {:terminal,
                    {:error, %JError{category: :cancelled, breaker_penalty?: false}, result_ms},
                    callback_ms},
                   1_000

    assert result_ms == callback_ms
    assert result_ms >= 0

    eventually(fn ->
      state = :sys.get_state(breaker_pid)
      state.inflight_count == 0 and state.inflight_attempts == %{}
    end)

    refute_receive {:terminal, _, _}, 100
  end

  test "caller death before dispatch releases admission without terminal attempt" do
    id = start_half_open_breaker()
    test_pid = self()

    caller_pid =
      spawn(fn ->
        {:allow, _token} =
          GenServer.call(
            CircuitBreaker.via_name(id),
            {:admit, System.monotonic_time(:millisecond)}
          )

        send(test_pid, :admitted)
        Process.sleep(:infinity)
      end)

    assert_receive :admitted, 1_000
    Process.exit(caller_pid, :kill)

    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))

    eventually(fn ->
      state = :sys.get_state(breaker_pid)
      state.inflight_count == 0 and state.inflight_attempts == %{}
    end)

    refute_receive {:terminal, _, _}, 100
    refute_receive :attempt_dispatched, 100
  end

  test "dispatch receipt survives lifecycle death after deferred confirmation" do
    id = start_half_open_breaker()
    test_pid = self()

    result =
      CircuitBreaker.call(
        id,
        fn ->
          :ok = AttemptLifecycle.mark_dispatched(AttemptLifecycle.dispatch_context())
          Process.sleep(:infinity)
        end,
        1_000,
        dispatch: :deferred,
        on_dispatch: fn dispatched_at_us ->
          send(test_pid, {:dispatch_receipt, dispatched_at_us})
          Process.exit(self(), :kill)
        end
      )

    assert_receive {:dispatch_receipt, dispatched_at_us}, 1_000
    assert is_integer(dispatched_at_us)
    assert {:executed, {:exception, {:exit, :killed, []}}} = result
  end

  test "repeated deferred confirmation emits one dispatch receipt" do
    id = start_half_open_breaker()
    test_pid = self()

    assert {:executed, :ok} =
             CircuitBreaker.call(
               id,
               fn ->
                 context = AttemptLifecycle.dispatch_context()
                 :ok = AttemptLifecycle.mark_dispatched(context)
                 :ok = AttemptLifecycle.confirm_dispatched(context)
               end,
               1_000,
               dispatch: :deferred,
               on_dispatch: fn dispatched_at_us ->
                 send(test_pid, {:dispatch_receipt, dispatched_at_us})
               end
             )

    assert_receive {:dispatch_receipt, _dispatched_at_us}, 1_000
    refute_receive {:dispatch_receipt, _dispatched_at_us}, 100
  end

  test "immediate dispatch receipt is emitted before the worker becomes runnable" do
    id = start_half_open_breaker()
    test_pid = self()

    assert {:executed, :ok} =
             CircuitBreaker.call(
               id,
               fn ->
                 send(test_pid, :worker_ran)
                 :ok
               end,
               1_000,
               on_dispatch: fn _dispatched_at_us -> send(test_pid, :dispatch_receipt) end
             )

    assert_receive :dispatch_receipt, 1_000
    assert_receive :worker_ran, 1_000
  end

  test "a completed operation wins over caller death" do
    id = start_half_open_breaker()
    test_pid = self()

    caller_pid =
      spawn(fn ->
        CircuitBreaker.call(
          id,
          fn ->
            {lifecycle_pid, _dispatch_ref} = AttemptLifecycle.dispatch_context()
            send(test_pid, {:operation_completed, lifecycle_pid})
            :ok
          end,
          5_000,
          on_terminal: fn result, elapsed_ms ->
            send(test_pid, {:terminal, result, elapsed_ms})
          end
        )
      end)

    assert_receive {:operation_completed, lifecycle_pid}, 1_000
    :erlang.suspend_process(lifecycle_pid)
    Process.sleep(20)
    Process.exit(caller_pid, :kill)
    :erlang.resume_process(lifecycle_pid)

    assert_receive {:terminal, :ok, elapsed_ms}, 1_000
    assert elapsed_ms >= 0
    refute_receive {:terminal, _, _}, 100
  end

  test "slow terminal work does not block the breaker or fail the completed call" do
    id = {"slow_terminal_#{System.unique_integer([:positive])}", :http}
    test_pid = self()

    {:ok, _breaker_pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 2, recovery_timeout: 60_000, success_threshold: 1}}
      )

    assert {:executed, :ok} =
             CircuitBreaker.call(id, fn -> :ok end, 1_000,
               on_terminal: fn _result, _elapsed_ms ->
                 send(test_pid, :callback_started)
                 Process.sleep(250)
                 send(test_pid, :callback_finished)
               end
             )

    assert_receive :callback_started, 1_000
    assert {:executed, :ok} = CircuitBreaker.call(id, fn -> :ok end, 1_000)
    assert_receive :callback_finished, 1_000
  end

  test "unsupported preflight and local capacity rejection do not mutate breaker health" do
    id = {"neutral_preflight_#{System.unique_integer([:positive])}", :http}

    {:ok, _breaker_pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 1, recovery_timeout: 60_000, success_threshold: 1}}
      )

    assert {:executed, {:error, :unsupported_method, 0}} =
             CircuitBreaker.call(id, fn -> {:error, :unsupported_method, 0} end)

    local_rejection =
      JError.new(-32_008, "pool full",
        category: :local_capacity_rejection,
        retriable?: true,
        breaker_penalty?: false
      )

    assert {:executed, {:error, ^local_rejection, 1}} =
             CircuitBreaker.call(id, fn -> {:error, local_rejection, 1} end)

    eventually(fn ->
      state = CircuitBreaker.get_state(id)
      state.state == :closed and state.failure_count == 0
    end)
  end

  test "a result admitted before an open transition cannot heal the new open episode" do
    id = {"stale_success_#{System.unique_integer([:positive])}", :http}
    test_pid = self()

    {:ok, _breaker_pid} =
      CircuitBreaker.start_link(
        {id,
         %{
           failure_threshold: 1,
           category_thresholds: %{provider_error: 1},
           recovery_timeout: 60_000,
           success_threshold: 1
         }}
      )

    _slow_success =
      spawn(fn ->
        CircuitBreaker.call(id, fn ->
          send(test_pid, {:slow_attempt_started, self()})
          receive do: (:release_slow_attempt -> :ok)
        end)
      end)

    assert_receive {:slow_attempt_started, slow_task}, 1_000

    failure =
      JError.new(-32_000, "provider failed",
        category: :provider_error,
        retriable?: true,
        breaker_penalty?: true
      )

    assert {:executed, {:error, ^failure}} =
             CircuitBreaker.call(id, fn -> {:error, failure} end)

    eventually(fn -> CircuitBreaker.get_state(id).state == :open end)
    send(slow_task, :release_slow_attempt)
    Process.sleep(50)

    assert CircuitBreaker.get_state(id).state == :open
  end

  test "a token from a replaced breaker cannot dispatch" do
    id = start_half_open_breaker()
    test_pid = self()
    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))

    {:allow, token} =
      GenServer.call(
        CircuitBreaker.via_name(id),
        {:admit, System.monotonic_time(:millisecond)}
      )

    Process.unlink(breaker_pid)
    Process.exit(breaker_pid, :kill)
    eventually(fn -> is_nil(GenServer.whereis(CircuitBreaker.via_name(id))) end)

    {:ok, replacement_pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 1, recovery_timeout: 60_000, success_threshold: 1}}
      )

    :sys.replace_state(replacement_pid, fn state -> %{state | state: :open} end)

    assert {:__attempt_lifecycle_rejected__, :token_not_found} =
             AttemptLifecycle.run(
               self(),
               id,
               token,
               fn -> send(test_pid, :stale_attempt_dispatched) end,
               100,
               fn result, elapsed_ms -> send(test_pid, {:terminal, result, elapsed_ms}) end
             )

    refute_receive :stale_attempt_dispatched, 100
    refute_receive {:terminal, _, _}, 100
    assert CircuitBreaker.get_state(id).state == :open
  end

  test "an untrappable task exit finalizes and releases its token" do
    id = start_half_open_breaker()
    test_pid = self()

    assert {:executed, {:exception, {:exit, :killed, []}}} =
             CircuitBreaker.call(id, fn -> Process.exit(self(), :kill) end, 1_000,
               on_terminal: fn result, elapsed_ms ->
                 send(test_pid, {:terminal, result, elapsed_ms})
               end
             )

    assert_receive {:terminal, {:exception, {:exit, :killed, []}}, elapsed_ms}, 1_000
    assert elapsed_ms >= 0

    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))

    eventually(fn ->
      state = :sys.get_state(breaker_pid)
      state.inflight_count == 0 and state.inflight_attempts == %{}
    end)
  end

  test "a stale half-open token does not decrement current generation capacity" do
    id = start_half_open_breaker()
    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))

    {:allow, stale_token} =
      GenServer.call(
        CircuitBreaker.via_name(id),
        {:admit, System.monotonic_time(:millisecond)}
      )

    :sys.replace_state(breaker_pid, fn state ->
      %{state | transition_generation: state.transition_generation + 1, inflight_count: 0}
    end)

    {:allow, current_token} =
      GenServer.call(
        CircuitBreaker.via_name(id),
        {:admit, System.monotonic_time(:millisecond)}
      )

    assert :ok = CircuitBreaker.report_attempt(id, stale_token, :ok)
    state = :sys.get_state(breaker_pid)
    assert state.inflight_count == 1
    assert Map.has_key?(state.inflight_attempts, current_token)

    assert :ok = CircuitBreaker.release_attempt(id, current_token)
  end

  test "a terminal half-open result resets current generation capacity" do
    id = start_half_open_breaker()
    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))

    assert {:executed, :ok} = CircuitBreaker.call(id, fn -> :ok end)

    state = :sys.get_state(breaker_pid)
    assert state.state == :closed
    assert state.inflight_count == 0
    assert state.inflight_attempts == %{}
  end

  test "deferred local queue timeout is admission, not a terminal attempt" do
    id = start_half_open_breaker()
    test_pid = self()

    assert {:rejected, :admission_timeout} =
             CircuitBreaker.call(id, fn -> Process.sleep(:infinity) end, 25,
               dispatch: :deferred,
               on_terminal: fn result, elapsed_ms ->
                 send(test_pid, {:terminal, result, elapsed_ms})
               end
             )

    refute_receive {:terminal, _, _}, 100

    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))
    state = :sys.get_state(breaker_pid)
    assert state.inflight_count == 0
    assert state.inflight_attempts == %{}
  end

  test "caller death while deferred work is queued emits no terminal attempt" do
    id = start_half_open_breaker()
    test_pid = self()

    caller_pid =
      spawn(fn ->
        CircuitBreaker.call(id, fn -> Process.sleep(:infinity) end, 1_000,
          dispatch: :deferred,
          on_terminal: fn result, elapsed_ms ->
            send(test_pid, {:terminal, result, elapsed_ms})
          end
        )
      end)

    eventually(fn ->
      breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))
      :sys.get_state(breaker_pid).inflight_count == 1
    end)

    Process.exit(caller_pid, :kill)
    refute_receive {:terminal, _, _}, 100

    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))

    eventually(fn ->
      state = :sys.get_state(breaker_pid)
      state.inflight_count == 0 and state.inflight_attempts == %{}
    end)
  end

  test "lifecycle death terminates its transport worker" do
    id = start_half_open_breaker()
    test_pid = self()

    caller_pid =
      spawn(fn ->
        result =
          CircuitBreaker.call(
            id,
            fn ->
              {lifecycle_pid, _dispatch_ref} = context = AttemptLifecycle.dispatch_context()
              :ok = AttemptLifecycle.mark_dispatched(context)
              send(test_pid, {:worker_started, lifecycle_pid, self()})

              receive do
                :ghost_side_effect -> send(test_pid, :ghost_side_effect_ran)
              end
            end,
            1_000,
            dispatch: :deferred
          )

        send(test_pid, {:caller_result, result})
      end)

    assert_receive {:worker_started, lifecycle_pid, worker_pid}, 1_000
    Process.exit(lifecycle_pid, :kill)

    assert_receive {:caller_result, {:executed, {:exception, {:exit, :killed, []}}}}, 1_000
    eventually(fn -> not Process.alive?(worker_pid) end)
    send(worker_pid, :ghost_side_effect)
    refute_receive :ghost_side_effect_ran, 100

    caller_monitor = Process.monitor(caller_pid)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller_pid, reason}, 1_000
    assert reason in [:normal, :noproc]

    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))

    eventually(fn ->
      state = :sys.get_state(breaker_pid)
      state.inflight_count == 0 and state.inflight_attempts == %{}
    end)
  end

  test "a cached deferred completion wins over caller death after dispatch confirmation" do
    id = start_half_open_breaker()
    test_pid = self()

    caller_pid =
      spawn(fn ->
        CircuitBreaker.call(
          id,
          fn ->
            context = AttemptLifecycle.dispatch_context()
            :ok = AttemptLifecycle.authorize_dispatch(context)
            :ok = AttemptLifecycle.confirm_dispatched(context)
            send(test_pid, :dispatch_confirmed)
            :ok
          end,
          1_000,
          dispatch: :deferred,
          on_terminal: fn result, elapsed_ms ->
            send(test_pid, {:terminal, result, elapsed_ms})
          end
        )
      end)

    assert_receive :dispatch_confirmed, 1_000
    Process.sleep(20)
    Process.exit(caller_pid, :kill)

    assert_receive {:terminal, :ok, elapsed_ms}, 1_000
    assert elapsed_ms >= 0
    refute_receive {:terminal, _, _}, 100
  end

  test "dispatch authorization rejects a dead caller even when its message arrives first" do
    id = start_half_open_breaker()
    test_pid = self()

    caller_pid =
      spawn(fn ->
        CircuitBreaker.call(
          id,
          fn ->
            {lifecycle_pid, _dispatch_ref} = context = AttemptLifecycle.dispatch_context()
            send(test_pid, {:ready_to_authorize, lifecycle_pid, context, self()})

            receive do
              :authorize -> :ok
            end

            case AttemptLifecycle.mark_dispatched(context) do
              :ok ->
                send(test_pid, {:authorization, :ok})
                send(test_pid, :ghost_dispatch)

              rejection ->
                send(test_pid, {:authorization, rejection})
                rejection
            end
          end,
          1_000,
          dispatch: :deferred,
          on_terminal: fn result, elapsed_ms ->
            send(test_pid, {:terminal, result, elapsed_ms})
          end
        )
      end)

    assert_receive {:ready_to_authorize, lifecycle_pid, _context, worker_pid}, 1_000
    :erlang.suspend_process(lifecycle_pid)
    send(worker_pid, :authorize)
    Process.sleep(20)
    Process.exit(caller_pid, :kill)
    :erlang.resume_process(lifecycle_pid)

    assert_receive {:authorization, {:error, :cancelled}}, 1_000
    refute_receive :ghost_dispatch, 100
    refute_receive {:terminal, _, _}, 100

    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))

    eventually(fn ->
      state = :sys.get_state(breaker_pid)
      state.inflight_count == 0 and state.inflight_attempts == %{}
    end)
  end

  test "an explicitly aborted transport dispatch remains admission evidence" do
    id = start_half_open_breaker()
    test_pid = self()

    transport_error =
      JError.new(-32_000, "local send failed",
        category: :network_error,
        retriable?: true,
        breaker_penalty?: true
      )

    assert {:executed, {:error, ^transport_error, 2}} =
             CircuitBreaker.call(
               id,
               fn ->
                 context = AttemptLifecycle.dispatch_context()
                 :ok = AttemptLifecycle.authorize_dispatch(context)
                 :ok = AttemptLifecycle.abort_dispatch(context)
                 {:error, transport_error, 2}
               end,
               1_000,
               dispatch: :deferred,
               on_terminal: fn result, elapsed_ms ->
                 send(test_pid, {:terminal, result, elapsed_ms})
               end
             )

    refute_receive {:terminal, _, _}, 100

    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))
    state = :sys.get_state(breaker_pid)
    assert state.state == :half_open
    assert state.failure_count == 0
    assert state.inflight_count == 0
    assert state.inflight_attempts == %{}
  end

  test "timed-out dispatch authorization cancels its queued grant" do
    id = start_half_open_breaker()
    test_pid = self()

    caller_pid =
      spawn(fn ->
        result =
          CircuitBreaker.call(
            id,
            fn ->
              {lifecycle_pid, _dispatch_ref} = context = AttemptLifecycle.dispatch_context()
              send(test_pid, {:authorization_ready, lifecycle_pid, self()})

              receive do
                :authorize -> :ok
              end

              authorization = AttemptLifecycle.mark_dispatched(context)
              send(test_pid, {:authorization_result, authorization})

              {:error,
               JError.new(-32_008, "cancelled locally",
                 category: :local_capacity_rejection,
                 retriable?: true,
                 breaker_penalty?: false
               ), 1_000}
            end,
            1_500,
            dispatch: :deferred,
            on_terminal: fn result, elapsed_ms ->
              send(test_pid, {:terminal, result, elapsed_ms})
            end
          )

        send(test_pid, {:caller_result, result})
      end)

    assert_receive {:authorization_ready, lifecycle_pid, worker_pid}, 1_000
    :erlang.suspend_process(lifecycle_pid)
    send(worker_pid, :authorize)
    Process.sleep(1_100)
    :erlang.resume_process(lifecycle_pid)

    assert_receive {:authorization_result, {:error, :cancelled}}, 500

    assert_receive {:caller_result,
                    {:executed, {:error, %JError{category: :local_capacity_rejection}, 1_000}}},
                   500

    refute_receive {:terminal, _, _}, 100
    refute Process.alive?(caller_pid)
  end

  test "local connection loss after confirmed dispatch invokes one terminal callback" do
    id = start_half_open_breaker()
    test_pid = self()

    connection_lost =
      JError.new(-32_008, "connection died",
        category: :local_capacity_rejection,
        retriable?: true,
        breaker_penalty?: false
      )

    assert {:executed, {:error, ^connection_lost, 50}} =
             CircuitBreaker.call(
               id,
               fn ->
                 context = AttemptLifecycle.dispatch_context()
                 :ok = AttemptLifecycle.mark_dispatched(context)
                 {:error, connection_lost, 50}
               end,
               1_000,
               dispatch: :deferred,
               on_terminal: fn result, elapsed_ms ->
                 send(test_pid, {:terminal, result, elapsed_ms})
               end
             )

    assert_receive {:terminal, {:error, ^connection_lost, 50}, elapsed_ms}, 1_000
    assert elapsed_ms >= 0
    refute_receive {:terminal, _, _}, 100
  end

  test "authorization without confirmation times out as predispatch" do
    id = start_half_open_breaker()
    test_pid = self()

    assert {:rejected, :admission_timeout} =
             CircuitBreaker.call(
               id,
               fn ->
                 context = AttemptLifecycle.dispatch_context()
                 :ok = AttemptLifecycle.authorize_dispatch(context)
                 Process.sleep(:infinity)
               end,
               25,
               dispatch: :deferred,
               on_terminal: fn result, elapsed_ms ->
                 send(test_pid, {:terminal, result, elapsed_ms})
               end
             )

    refute_receive {:terminal, _, _}, 100
  end

  test "caller death stops an authorized but unconfirmed transport" do
    id = start_half_open_breaker()
    test_pid = self()

    caller_pid =
      spawn(fn ->
        CircuitBreaker.call(
          id,
          fn ->
            context = AttemptLifecycle.dispatch_context()
            :ok = AttemptLifecycle.authorize_dispatch(context)
            send(test_pid, {:authorized_for_late_confirm, context, self()})

            receive do
              :confirm ->
                confirmation = AttemptLifecycle.confirm_dispatched(context)
                send(test_pid, {:late_confirmation, confirmation})
            end
          end,
          1_000,
          dispatch: :deferred,
          on_terminal: fn result, elapsed_ms ->
            send(test_pid, {:terminal, result, elapsed_ms})
          end
        )
      end)

    assert_receive {:authorized_for_late_confirm, _context, worker_pid}, 1_000
    Process.exit(caller_pid, :kill)
    send(worker_pid, :confirm)
    assert_receive {:late_confirmation, {:error, :cancelled}}, 1_000
    refute_receive {:terminal, _, _}, 100
  end

  test "deadline stops an authorized but unconfirmed transport" do
    id = start_half_open_breaker()
    test_pid = self()

    assert {:rejected, :admission_timeout} =
             CircuitBreaker.call(
               id,
               fn ->
                 context = AttemptLifecycle.dispatch_context()
                 :ok = AttemptLifecycle.authorize_dispatch(context)
                 Process.sleep(30)
                 confirmation = AttemptLifecycle.confirm_dispatched(context)
                 send(test_pid, {:late_deadline_confirmation, confirmation})
                 confirmation
               end,
               25,
               dispatch: :deferred,
               on_terminal: fn result, elapsed_ms ->
                 send(test_pid, {:terminal, result, elapsed_ms})
               end
             )

    assert_receive {:late_deadline_confirmation, {:error, :cancelled}}, 1_000
    refute_receive {:terminal, _, _}, 100

    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))
    state = :sys.get_state(breaker_pid)
    assert state.inflight_count == 0
    assert state.inflight_attempts == %{}
  end

  test "expired queued admission does not create a token for a live caller" do
    id = start_half_open_breaker()
    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))
    test_pid = self()

    :sys.suspend(breaker_pid)

    caller_pid =
      spawn(fn ->
        result = CircuitBreaker.call(id, fn -> send(test_pid, :admission_attempt_ran) end, 25)
        send(test_pid, {:admission_result, result})
        Process.sleep(:infinity)
      end)

    assert_receive {:admission_result, {:rejected, :admission_timeout}}, 1_000
    assert Process.alive?(caller_pid)
    :sys.resume(breaker_pid)
    Process.sleep(50)

    state = :sys.get_state(breaker_pid)
    assert state.inflight_count == 0
    assert state.inflight_attempts == %{}
    refute_receive :admission_attempt_ran, 100

    Process.exit(caller_pid, :kill)
  end

  test "attempt timing starts at confirmation rather than authorization" do
    id = start_half_open_breaker()
    test_pid = self()

    assert {:executed, :ok} =
             CircuitBreaker.call(
               id,
               fn ->
                 context = AttemptLifecycle.dispatch_context()
                 :ok = AttemptLifecycle.authorize_dispatch(context)
                 Process.sleep(50)
                 :ok = AttemptLifecycle.confirm_dispatched(context)
                 :ok
               end,
               1_000,
               dispatch: :deferred,
               on_terminal: fn result, elapsed_ms ->
                 send(test_pid, {:terminal, result, elapsed_ms})
               end
             )

    assert_receive {:terminal, :ok, elapsed_ms}, 1_000
    assert elapsed_ms >= 0
    assert elapsed_ms < 30
  end

  defp start_half_open_breaker do
    id = {"cancelled_half_open_#{System.unique_integer([:positive])}", :http}

    {:ok, breaker_pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 1, recovery_timeout: 60_000, success_threshold: 1}}
      )

    state = :sys.replace_state(breaker_pid, fn state -> %{state | state: :half_open} end)

    Snapshot.put(%Snapshot{
      breaker_id: id,
      state: :half_open,
      generation: state.transition_generation,
      epoch: state.process_epoch,
      owner_pid: breaker_pid,
      ready?: true,
      recovery_deadline_us: nil,
      half_open_capacity: 1,
      half_open_inflight: 0,
      control_health: :healthy
    })

    id
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end

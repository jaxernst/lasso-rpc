defmodule Lasso.RPC.CircuitBreakerAttemptLifecycleTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Support.{AttemptLifecycle, CircuitBreaker}
  alias Lasso.Core.Support.CircuitBreaker.Snapshot
  alias Lasso.Core.Transport.AttemptProtocol
  alias Lasso.JSONRPC.Error, as: JError

  setup_all do
    TestHelper.ensure_test_environment_ready()
    :ok
  end

  test "caller death after dispatch publishes no terminal fact and releases half-open admission" do
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

    refute_receive {:terminal, _, _}, 100

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

  test "dispatch receipt survives transport death after deferred confirmation" do
    id = start_half_open_breaker()
    test_pid = self()

    result =
      CircuitBreaker.call(
        id,
        fn ->
          :ok = AttemptLifecycle.mark_dispatched(AttemptLifecycle.dispatch_context())
          Process.exit(self(), :kill)
        end,
        1_000,
        dispatch: :deferred,
        on_dispatch: fn dispatched_at_us ->
          send(test_pid, {:dispatch_receipt, self(), dispatched_at_us})
        end
      )

    assert_receive {:dispatch_receipt, callback_pid, dispatched_at_us}, 1_000
    assert callback_pid == self()
    assert is_integer(dispatched_at_us)
    assert {:executed, {:exception, {:exit, :killed, []}}} = result
  end

  test "repeated deferred confirmation emits one dispatch receipt" do
    id = start_half_open_breaker()
    test_pid = self()
    callback_key = {__MODULE__, make_ref()}

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
                 Process.put(callback_key, Process.get(callback_key, 0) + 1)
                 send(test_pid, {:dispatch_receipt, self(), dispatched_at_us})
               end
             )

    assert_receive {:dispatch_receipt, callback_pid, _dispatched_at_us}, 1_000
    assert callback_pid == self()
    assert Process.get(callback_key) == 1
    refute_receive {:dispatch_receipt, _, _dispatched_at_us}, 100
    Process.delete(callback_key)
  end

  test "task death after send start commits dispatch once and terminalizes once" do
    id = start_half_open_breaker()
    test_pid = self()

    assert {:executed, {:exception, {:exit, :killed, []}}} =
             CircuitBreaker.call(
               id,
               fn ->
                 context = AttemptLifecycle.dispatch_context()
                 :ok = AttemptProtocol.send_started(context)
                 :ok = AttemptProtocol.send_started(context)
                 Process.exit(self(), :kill)
               end,
               1_000,
               dispatch: :deferred,
               on_dispatch: fn started_at_us ->
                 send(test_pid, {:dispatch_receipt, started_at_us})
               end,
               on_terminal: fn result, elapsed_ms ->
                 send(test_pid, {:terminal, result, elapsed_ms})
               end
             )

    assert_receive {:dispatch_receipt, started_at_us}, 1_000
    assert is_integer(started_at_us)
    refute_receive {:dispatch_receipt, _}, 100

    assert_receive {:terminal, {:exception, {:exit, :killed, []}}, elapsed_ms}, 1_000
    assert elapsed_ms >= 0
    refute_receive {:terminal, _, _}, 100

    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))

    eventually(fn ->
      state = :sys.get_state(breaker_pid)
      state.inflight_count == 0 and state.inflight_attempts == %{}
    end)
  end

  test "caller publishes the latched receipt when the lifecycle owner dies" do
    id = start_half_open_breaker()
    test_pid = self()

    caller_pid =
      spawn(fn ->
        dispatch_ref = make_ref()
        caller = self()

        result =
          CircuitBreaker.call(
            id,
            fn ->
              {lifecycle_pid, _attempt_ref} = context = AttemptLifecycle.dispatch_context()
              send(test_pid, {:owner_death_ready, lifecycle_pid, self()})

              receive do
                :cross_send ->
                  :ok = AttemptProtocol.send_started(context)
                  send(test_pid, :owner_death_send_crossed)
                  Process.sleep(:infinity)
              end
            end,
            1_000,
            dispatch: :deferred,
            on_dispatch: fn started_at_us ->
              send(caller, {:pipeline_dispatch_receipt, dispatch_ref, started_at_us})
            end
          )

        send(
          test_pid,
          {:owner_death_result, result, drain_dispatch_receipts(dispatch_ref, [])}
        )
      end)

    caller_monitor = Process.monitor(caller_pid)
    assert_receive {:owner_death_ready, lifecycle_pid, task_pid}, 1_000
    send(task_pid, :cross_send)
    assert_receive :owner_death_send_crossed, 1_000

    Process.exit(lifecycle_pid, :kill)

    assert_receive {:owner_death_result, {:executed, {:exception, {:exit, :killed, []}}},
                    [started_at_us]},
                   1_000

    assert is_integer(started_at_us)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller_pid, reason}, 1_000
    assert reason in [:normal, :noproc]
  end

  test "caller closes a suspended lifecycle without authorizing a late callback" do
    id = start_half_open_breaker()
    test_pid = self()

    caller_pid =
      spawn(fn ->
        dispatch_ref = make_ref()
        caller = self()

        result =
          CircuitBreaker.call(
            id,
            fn ->
              {lifecycle_pid, _attempt_ref} = context = AttemptLifecycle.dispatch_context()
              send(test_pid, {:ready_to_cross_send, lifecycle_pid, self()})

              receive do
                :cross_send ->
                  :ok = AttemptProtocol.send_started(context)
                  Process.sleep(:infinity)
              end
            end,
            100,
            dispatch: :deferred,
            on_dispatch: fn started_at_us ->
              Process.put({:pipeline_dispatch_receipt, dispatch_ref}, started_at_us)
              send(caller, {:pipeline_dispatch_receipt, dispatch_ref, started_at_us})
            end,
            on_terminal: fn result, elapsed_ms ->
              send(test_pid, {:suspended_owner_terminal, result, elapsed_ms})
            end
          )

        receipts = drain_dispatch_receipts(dispatch_ref, [])

        send(
          test_pid,
          {:suspended_owner_result, result, receipts,
           Process.get({:pipeline_dispatch_receipt, dispatch_ref})}
        )
      end)

    caller_monitor = Process.monitor(caller_pid)

    assert_receive {:ready_to_cross_send, lifecycle_pid, task_pid}, 1_000
    :erlang.suspend_process(lifecycle_pid)
    send(task_pid, :cross_send)

    assert_receive {:suspended_owner_result,
                    {:executed, {:error, %JError{category: :timeout, retriable?: true}, 100}},
                    [started_at_us], callback_started_at_us},
                   1_000

    assert is_integer(started_at_us)
    assert callback_started_at_us == started_at_us

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller_pid, reason}, 1_000
    assert reason in [:normal, :noproc]

    refute_receive {:suspended_owner_terminal, _, _}, 100

    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))

    eventually(fn ->
      state = :sys.get_state(breaker_pid)
      state.inflight_count == 0 and state.inflight_attempts == %{}
    end)
  end

  test "suspended lifecycle accepts D-1 and rejects D and D+1 terminal observations" do
    Enum.each([-1, 0, 1], fn offset_us ->
      id = start_half_open_breaker()
      test_pid = self()
      terminal_ref = make_ref()
      client_deadline_us = System.monotonic_time(:microsecond) + 500_000

      transport_error =
        JError.new(-32_008, "local transport result",
          category: :local_capacity_rejection,
          retriable?: true,
          breaker_penalty?: false
        )

      caller_pid =
        spawn(fn ->
          result =
            CircuitBreaker.call(
              id,
              fn ->
                {lifecycle_pid, _attempt_ref} = context = AttemptLifecycle.dispatch_context()
                attempt_deadline_us = AttemptProtocol.deadline_us()

                send(
                  test_pid,
                  {:decision_ready, terminal_ref, lifecycle_pid, self(), attempt_deadline_us}
                )

                receive do
                  {:emit, ^offset_us} ->
                    :ok =
                      AttemptProtocol.terminal_at(
                        context,
                        :response,
                        %{response_kind: :success, io_duration_us: 0},
                        attempt_deadline_us + offset_us
                      )

                    {:error, transport_error, 0}
                end
              end,
              25,
              deadline_us: client_deadline_us,
              dispatch: :deferred,
              on_terminal: fn result, elapsed_ms ->
                send(test_pid, {:decision_terminal, terminal_ref, result, elapsed_ms})
              end
            )

          send(test_pid, {:decision_result, terminal_ref, result})
        end)

      assert_receive {:decision_ready, ^terminal_ref, lifecycle_pid, task_pid,
                      attempt_deadline_us},
                     1_000

      :erlang.suspend_process(lifecycle_pid)
      task_monitor = Process.monitor(task_pid)
      send(task_pid, {:emit, offset_us})
      assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, :normal}, 1_000
      wait_until_monotonic(attempt_deadline_us)
      :erlang.resume_process(lifecycle_pid)

      assert_receive {:decision_result, ^terminal_ref,
                      {:executed, {:error, ^transport_error, 0}}},
                     1_000

      if offset_us == -1 do
        assert_receive {:decision_terminal, ^terminal_ref, {:error, ^transport_error, 0},
                        elapsed_ms},
                       1_000

        assert elapsed_ms >= 0
      else
        refute_receive {:decision_terminal, ^terminal_ref, _, _}, 50
      end

      caller_monitor = Process.monitor(caller_pid)
      assert_receive {:DOWN, ^caller_monitor, :process, ^caller_pid, reason}, 1_000
      assert reason in [:normal, :noproc]
    end)
  end

  test "transport task exposes immutable eligibility and settlement deadlines" do
    id = start_half_open_breaker()
    test_pid = self()
    client_deadline_us = System.monotonic_time(:microsecond) + 500_000

    transport_error =
      JError.new(-32_008, "local transport result",
        category: :local_capacity_rejection,
        retriable?: true,
        breaker_penalty?: false
      )

    assert {:executed, {:error, ^transport_error, 0}} =
             CircuitBreaker.call(
               id,
               fn ->
                 attempt_deadline_us = AttemptProtocol.deadline_us()
                 settlement_deadline_us = AttemptProtocol.settlement_deadline_us()

                 send(
                   test_pid,
                   {:attempt_deadlines, attempt_deadline_us, settlement_deadline_us}
                 )

                 :ok = AttemptProtocol.predispatch_failure(AttemptProtocol.context(), :local)
                 {:error, transport_error, 0}
               end,
               25,
               deadline_us: client_deadline_us,
               dispatch: :deferred
             )

    assert_receive {:attempt_deadlines, attempt_deadline_us, settlement_deadline_us}, 1_000
    assert settlement_deadline_us == min(client_deadline_us, attempt_deadline_us + 1_000)
  end

  test "short attempt settles D-1 after its cutoff and rejects D and D+1" do
    Enum.each([-1, 0, 1], fn offset_us ->
      id = start_half_open_breaker()
      test_pid = self()
      result_ref = make_ref()
      client_deadline_us = System.monotonic_time(:microsecond) + 500_000

      transport_error =
        JError.new(-32_008, "local transport result",
          category: :local_capacity_rejection,
          retriable?: true,
          breaker_penalty?: false
        )

      spawn(fn ->
        result =
          CircuitBreaker.call(
            id,
            fn ->
              {lifecycle_pid, _attempt_ref} = context = AttemptProtocol.context()
              attempt_deadline_us = AttemptProtocol.deadline_us()

              :ok =
                AttemptProtocol.terminal_at(
                  context,
                  :response,
                  %{response_kind: :success, io_duration_us: 0},
                  attempt_deadline_us + offset_us
                )

              send(
                test_pid,
                {:short_attempt_ready, result_ref, lifecycle_pid, self(), attempt_deadline_us}
              )

              receive do
                :finish_after_cutoff ->
                  yield_until_monotonic(attempt_deadline_us + 1)
                  send(test_pid, {:short_attempt_finished, result_ref})
                  {:error, transport_error, 0}
              end
            end,
            100,
            deadline_us: client_deadline_us,
            dispatch: :deferred
          )

        send(test_pid, {:short_attempt_result, result_ref, result})
      end)

      assert_receive {:short_attempt_ready, ^result_ref, lifecycle_pid, task_pid,
                      attempt_deadline_us},
                     1_000

      eventually(fn ->
        match?({:message_queue_len, 0}, Process.info(lifecycle_pid, :message_queue_len))
      end)

      send(task_pid, :finish_after_cutoff)
      assert_receive {:short_attempt_finished, ^result_ref}, 1_000
      assert System.monotonic_time(:microsecond) >= attempt_deadline_us

      if offset_us == -1 do
        assert_receive {:short_attempt_result, ^result_ref,
                        {:executed, {:error, ^transport_error, 0}}},
                       1_000
      else
        assert_receive {:short_attempt_result, ^result_ref, {:rejected, :admission_timeout}},
                       1_000
      end
    end)
  end

  test "caller timeout closes publication before a suspended lifecycle can report late" do
    id = start_half_open_breaker()
    test_pid = self()
    terminal_ref = make_ref()

    caller_pid =
      spawn(fn ->
        result =
          CircuitBreaker.call(
            id,
            fn ->
              {lifecycle_pid, _attempt_ref} = context = AttemptLifecycle.dispatch_context()
              send(test_pid, {:timeout_close_ready, lifecycle_pid, self()})

              receive do
                :cross_send ->
                  :ok = AttemptProtocol.send_started(context)
                  send(test_pid, :timeout_close_send_started)
                  Process.sleep(:infinity)
              end
            end,
            50,
            dispatch: :deferred,
            on_terminal: fn result, elapsed_ms ->
              send(test_pid, {:timeout_close_terminal, terminal_ref, result, elapsed_ms})
            end
          )

        send(test_pid, {:timeout_close_result, terminal_ref, result})
      end)

    assert_receive {:timeout_close_ready, lifecycle_pid, task_pid}, 1_000
    :erlang.suspend_process(lifecycle_pid)
    send(task_pid, :cross_send)
    assert_receive :timeout_close_send_started, 1_000

    assert_receive {:timeout_close_result, ^terminal_ref,
                    {:executed, {:error, %JError{category: :timeout}, 50}}},
                   1_000

    refute Process.alive?(lifecycle_pid)
    refute Process.alive?(task_pid)
    refute_receive {:timeout_close_terminal, ^terminal_ref, _, _}, 100

    caller_monitor = Process.monitor(caller_pid)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller_pid, reason}, 1_000
    assert reason in [:normal, :noproc]
  end

  test "not-dispatched transport failure releases an open send reservation" do
    id = start_half_open_breaker()
    test_pid = self()

    transport_error =
      JError.new(-32_008, "pool unavailable",
        category: :local_capacity_rejection,
        retriable?: true,
        breaker_penalty?: false
      )

    assert {:executed, {:error, ^transport_error, 2}} =
             CircuitBreaker.call(
               id,
               fn ->
                 context = AttemptLifecycle.dispatch_context()
                 :ok = AttemptProtocol.send_started(context)

                 :ok =
                   AttemptProtocol.terminal(context, :transport_failure, %{
                     reason: :network_error,
                     certainty: :not_dispatched,
                     elapsed_us: 0
                   })

                 {:error, transport_error, 2}
               end,
               1_000,
               dispatch: :deferred,
               on_dispatch: fn started_at_us ->
                 send(test_pid, {:dispatch_receipt, started_at_us})
               end,
               on_terminal: fn result, elapsed_ms ->
                 send(test_pid, {:terminal, result, elapsed_ms})
               end
             )

    refute_receive {:dispatch_receipt, _}, 100
    refute_receive {:terminal, _, _}, 100

    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))
    state = :sys.get_state(breaker_pid)
    assert state.state == :half_open
    assert state.failure_count == 0
    assert state.inflight_count == 0
    assert state.inflight_attempts == %{}
  end

  test "immediate dispatch receipt is emitted before the worker becomes runnable" do
    id = start_half_open_breaker()
    test_pid = self()

    assert {:executed, :ok} =
             CircuitBreaker.call(
               id,
               fn ->
                 send(test_pid, {:immediate_order, :worker_ran})
                 :ok
               end,
               1_000,
               on_dispatch: fn _dispatched_at_us ->
                 send(test_pid, {:immediate_order, :dispatch_receipt})
               end
             )

    assert_receive {:immediate_order, first_event}, 1_000
    assert first_event == :dispatch_receipt
    assert_receive {:immediate_order, second_event}, 1_000
    assert second_event == :worker_ran
  end

  test "a completed operation is not published after its caller dies" do
    id = start_half_open_breaker()
    test_pid = self()

    caller_pid =
      spawn(fn ->
        CircuitBreaker.call(
          id,
          fn ->
            {lifecycle_pid, _dispatch_ref} = AttemptLifecycle.dispatch_context()
            send(test_pid, {:operation_ready, lifecycle_pid, self()})

            receive do
              :complete_operation -> :ok
            end
          end,
          5_000,
          on_terminal: fn result, elapsed_ms ->
            send(test_pid, {:terminal, result, elapsed_ms})
          end
        )
      end)

    assert_receive {:operation_ready, lifecycle_pid, task_pid}, 1_000
    :erlang.suspend_process(lifecycle_pid)
    task_monitor = Process.monitor(task_pid)
    send(task_pid, :complete_operation)
    assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, :normal}, 1_000
    Process.exit(caller_pid, :kill)
    if Process.alive?(lifecycle_pid), do: :erlang.resume_process(lifecycle_pid)

    refute_receive {:terminal, _, _}, 100
  end

  test "a blocked compatibility terminal callback cannot delay the attempt result" do
    id = {"slow_terminal_#{System.unique_integer([:positive])}", :http}
    test_pid = self()

    {:ok, _breaker_pid} =
      CircuitBreaker.start_link(
        {id, %{failure_threshold: 2, recovery_timeout: 60_000, success_threshold: 1}}
      )

    caller_pid =
      spawn(fn ->
        result =
          CircuitBreaker.call(id, fn -> :ok end, 1_000,
            on_terminal: fn _result, _elapsed_ms ->
              send(test_pid, {:callback_started, self()})

              receive do
                :release_callback -> send(test_pid, :callback_finished)
              end
            end
          )

        send(test_pid, {:attempt_result, result})
      end)

    assert_receive {:attempt_result, {:executed, :ok}}, 1_000
    assert_receive {:callback_started, callback_pid}, 1_000
    refute callback_pid == caller_pid
    refute_receive :callback_finished, 100

    send(callback_pid, :release_callback)
    assert_receive :callback_finished, 1_000
    refute_receive :callback_finished, 100
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

    eventually(fn ->
      state = :sys.get_state(breaker_pid)
      state.state == :closed and state.inflight_count == 0 and state.inflight_attempts == %{}
    end)
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

  test "dispatch authorization performs no lifecycle request reply" do
    lifecycle_pid = spawn(fn -> Process.sleep(:infinity) end)
    context = {lifecycle_pid, make_ref()}
    {:message_queue_len, before_count} = Process.info(lifecycle_pid, :message_queue_len)

    assert :ok = AttemptLifecycle.authorize_dispatch(context)
    {:message_queue_len, after_count} = Process.info(lifecycle_pid, :message_queue_len)
    assert after_count == before_count

    Process.exit(lifecycle_pid, :kill)
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

  test "dispatch confirmation is one-way while the lifecycle owner is suspended" do
    lifecycle_pid = spawn(fn -> Process.sleep(:infinity) end)
    context = {lifecycle_pid, make_ref()}
    :erlang.suspend_process(lifecycle_pid)

    assert :ok = AttemptLifecycle.mark_dispatched(context)
    assert {:message_queue_len, 2} = Process.info(lifecycle_pid, :message_queue_len)

    Process.exit(lifecycle_pid, :kill)
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
    refute_receive {:late_confirmation, _}, 100
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

    refute_receive {:late_deadline_confirmation, _}, 100
    refute_receive {:terminal, _, _}, 100

    breaker_pid = GenServer.whereis(CircuitBreaker.via_name(id))
    state = :sys.get_state(breaker_pid)
    assert state.inflight_count == 0
    assert state.inflight_attempts == %{}
  end

  test "attempt timeout stops blocking transport before the shared client deadline" do
    id = start_half_open_breaker()
    started_at_ms = System.monotonic_time(:millisecond)
    client_deadline_us = System.monotonic_time(:microsecond) + 500_000

    assert {:executed, {:error, %JError{category: :timeout, retriable?: true}, 25}} =
             CircuitBreaker.call(
               id,
               fn ->
                 :ok = AttemptProtocol.send_started(AttemptProtocol.context())
                 Process.sleep(:infinity)
               end,
               25,
               deadline_us: client_deadline_us,
               dispatch: :deferred
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms
    assert elapsed_ms < 250
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

  defp drain_dispatch_receipts(dispatch_ref, receipts) do
    receive do
      {:pipeline_dispatch_receipt, ^dispatch_ref, started_at_us} ->
        drain_dispatch_receipts(dispatch_ref, [started_at_us | receipts])
    after
      0 -> Enum.reverse(receipts)
    end
  end

  defp wait_until_monotonic(deadline_us) do
    remaining_us = deadline_us - System.monotonic_time(:microsecond)

    if remaining_us > 0 do
      timer_ref = make_ref()
      Process.send_after(self(), {:monotonic_deadline, timer_ref}, div(remaining_us + 999, 1_000))
      assert_receive {:monotonic_deadline, ^timer_ref}, 1_000
      wait_until_monotonic(deadline_us)
    end
  end

  defp yield_until_monotonic(deadline_us) do
    if System.monotonic_time(:microsecond) < deadline_us do
      :erlang.yield()
      yield_until_monotonic(deadline_us)
    end
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

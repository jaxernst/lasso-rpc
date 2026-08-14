defmodule Lasso.Core.Request.RequestOwnerTest do
  use ExUnit.Case, async: true

  alias Lasso.Core.Request.RequestOwner
  alias Lasso.Core.Transport.AttemptProtocol
  alias Lasso.RPC.AttemptIdentity
  alias Lasso.RPC.AttemptTerminal

  defp identity(execution_safety \\ :replay_safe) do
    AttemptIdentity.new(
      request_id: "request",
      attempt_id: "attempt",
      profile: "public",
      chain_id: 1,
      upstream_instance_id: "instance",
      transport: :http,
      route_generation: 1,
      circuit_scope: :broad,
      circuit_epoch: 1,
      execution_safety: execution_safety,
      routing_intent: "default",
      workload_key: "eth_blockNumber",
      request_budget_ms: 100,
      candidate_admission_count: 1,
      dispatch_count: 1
    )
  end

  defp deadline_after(ms),
    do: System.monotonic_time(:microsecond) + ms * 1_000

  defp success_terminal(context, io_duration_us \\ 1) do
    AttemptProtocol.terminal(context, :response, %{
      response_kind: :success,
      io_duration_us: io_duration_us
    })
  end

  defp await_down(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
  end

  defp wait_past(deadline_us) do
    if System.monotonic_time(:microsecond) <= deadline_us do
      receive do
      after
        1 -> wait_past(deadline_us)
      end
    end
  end

  defp await_mailbox(pid, predicate, timeout_ms \\ 1_000) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_await_mailbox(pid, predicate, deadline_ms)
  end

  defp do_await_mailbox(pid, predicate, deadline_ms) do
    messages =
      case Process.info(pid, :messages) do
        {:messages, messages} -> messages
        nil -> flunk("process exited before the expected mailbox state")
      end

    if predicate.(messages) do
      messages
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        flunk("expected mailbox state did not arrive")
      else
        receive do
        after
          1 -> do_await_mailbox(pid, predicate, deadline_ms)
        end
      end
    end
  end

  test "the current process owns one linked and monitored transport task" do
    owner = self()

    outcome =
      RequestOwner.execute(identity(), deadline_after(100), fn ->
        task = self()

        send(
          owner,
          {:topology, task, Process.info(task, :links), Process.info(task, :monitored_by)}
        )

        success_terminal(AttemptProtocol.context())
        {:ok, :response}
      end)

    assert_receive {:topology, task, {:links, links}, {:monitored_by, monitored_by}}
    assert self() in links
    assert self() in monitored_by
    refute task == self()

    assert outcome.result == {:ok, :response}
    assert outcome.committed?
    assert %AttemptTerminal.Response{} = outcome.fact
    assert outcome.projection.recommended_action == :return_response
  end

  test "the task result and terminal fact settle as one completion" do
    outcome =
      RequestOwner.execute(identity(), deadline_after(100), fn ->
        success_terminal(AttemptProtocol.context(), 7)
        {:ok, :deferred}
      end)

    assert outcome.result == {:ok, :deferred}
    assert %AttemptTerminal.Response{io_duration_us: 7} = outcome.fact
  end

  test "authoritative response facts are unchanged by redundant gate proof" do
    without_gate =
      RequestOwner.execute(identity(), deadline_after(100), fn ->
        success_terminal(AttemptProtocol.context(), 7)
        {:ok, :response}
      end)

    with_gate =
      RequestOwner.execute(identity(), deadline_after(100), fn ->
        context = AttemptProtocol.context()
        assert :ok = AttemptProtocol.send_started(context)
        assert :ok = AttemptProtocol.send_confirmed(context)
        success_terminal(context, 7)
        {:ok, :response}
      end)

    assert with_gate.fact == without_gate.fact
    assert with_gate.projection == without_gate.projection
  end

  test "missing, conflicting, mismatched, and malformed terminals fail conservatively" do
    cases = [
      {:missing,
       fn ->
         {:ok, :missing}
       end},
      {:conflicting,
       fn ->
         context = AttemptProtocol.context()
         success_terminal(context)

         AttemptProtocol.terminal(context, :transport_failure, %{
           reason: :closed,
           certainty: :dispatched,
           io_duration_us: 2
         })

         {:ok, :conflicting}
       end},
      {:mismatched,
       fn ->
         success_terminal(AttemptProtocol.context())
         {:error, :contradictory_return}
       end},
      {:predispatch_mismatched,
       fn ->
         AttemptProtocol.predispatch_failure(AttemptProtocol.context(), :not_connected)
         {:ok, :contradictory_return}
       end},
      {:failure_mismatched,
       fn ->
         AttemptProtocol.terminal(AttemptProtocol.context(), :transport_failure, %{
           reason: :closed,
           certainty: :indeterminate
         })

         {:ok, :contradictory_return}
       end},
      {:malformed,
       fn ->
         AttemptProtocol.terminal(AttemptProtocol.context(), :response, %{
           response_kind: :application_error,
           io_duration_us: 1
         })

         {:error, :upstream_error}
       end}
    ]

    for {_name, fun} <- cases do
      started_us = System.monotonic_time(:microsecond)
      outcome = RequestOwner.execute(identity(), deadline_after(1_000), fun)

      assert %AttemptTerminal.TransportFailure{
               reason: :unknown,
               dispatch_certainty: certainty
             } = outcome.fact

      assert certainty in [:indeterminate, :dispatched]
      assert match?({:error, {:attempt_protocol, _bounded_reason}}, outcome.result)
      assert System.monotonic_time(:microsecond) - started_us < 250_000
      assert outcome.committed?
    end
  end

  test "missing terminal proof is unsafe for unknown work" do
    outcome =
      RequestOwner.execute(identity(:unknown), deadline_after(100), fn ->
        {:ok, :missing}
      end)

    assert %AttemptTerminal.TransportFailure{dispatch_certainty: :indeterminate} = outcome.fact
    refute outcome.projection.fallback_eligible
    assert outcome.projection.recommended_action == :finish_unsafe_indeterminate
  end

  test "a response candidate cannot survive task death" do
    outcome =
      RequestOwner.execute(identity(), deadline_after(100), fn ->
        success_terminal(AttemptProtocol.context())
        exit({:secret, String.duplicate("credential", 10_000)})
      end)

    assert outcome.result == {:error, {:transport_task_exit, :transport_crashed}}

    assert %AttemptTerminal.TransportFailure{
             reason: :unknown,
             dispatch_certainty: :dispatched
           } = outcome.fact

    refute inspect(outcome) =~ "credential"
  end

  test "authoritative pre-send proof releases tentative send ambiguity" do
    outcome =
      RequestOwner.execute(identity(), deadline_after(100), fn ->
        context = AttemptProtocol.context()
        assert :ok = AttemptProtocol.send_started(context)
        assert :ok = AttemptProtocol.predispatch_failure(context, :not_connected)
        {:error, :not_connected}
      end)

    assert outcome.result == {:error, :not_connected}

    assert %AttemptTerminal.PredispatchFailure{
             reason: :not_connected,
             elapsed_us: 0
           } = outcome.fact

    assert outcome.projection.recommended_action == :try_next_candidate
  end

  test "predispatch proof cannot erase a confirmed send" do
    outcome =
      RequestOwner.execute(identity(:unknown), deadline_after(100), fn ->
        context = AttemptProtocol.context()
        assert :ok = AttemptProtocol.send_started(context)
        assert :ok = AttemptProtocol.send_confirmed(context)
        assert :ok = AttemptProtocol.predispatch_failure(context, :not_connected)
        {:error, :not_connected}
      end)

    assert %AttemptTerminal.TransportFailure{dispatch_certainty: :dispatched} = outcome.fact
    assert outcome.projection.breaker_effect == :failure
    refute outcome.projection.fallback_eligible
  end

  test "positive proof after a predispatch candidate prevents unsafe fallback" do
    for _iteration <- 1..100 do
      outcome =
        RequestOwner.execute(identity(:unknown), deadline_after(100), fn ->
          context = AttemptProtocol.context()
          transport_task = self()

          confirmer =
            spawn(fn ->
              receive do
                :confirm ->
                  AttemptProtocol.send_confirmed(context)
                  send(transport_task, :confirmed)
              end
            end)

          send(confirmer, :confirm)
          assert :ok = AttemptProtocol.predispatch_failure(context, :not_connected)
          assert_receive :confirmed
          {:error, :not_connected}
        end)

      assert %AttemptTerminal.TransportFailure{dispatch_certainty: :dispatched} = outcome.fact
      refute outcome.projection.fallback_eligible
      refute match?(%AttemptTerminal.PredispatchFailure{}, outcome.fact)
    end
  end

  test "D and D+1 terminal stamps are expired" do
    for offset <- [0, 1] do
      deadline_us = deadline_after(100)

      outcome =
        RequestOwner.execute(identity(), deadline_us, fn ->
          assert :ok = AttemptProtocol.send_started(AttemptProtocol.context())
          assert :ok = AttemptProtocol.send_confirmed(AttemptProtocol.context())

          AttemptProtocol.terminal_at(
            AttemptProtocol.context(),
            :response,
            %{response_kind: :success, io_duration_us: 1},
            deadline_us + offset
          )

          {:ok, offset}
        end)

      assert %AttemptTerminal.Deadline{dispatch_certainty: :dispatched} = outcome.fact
      assert outcome.result == {:error, :deadline_expired}
    end
  end

  test "a response at D is ineligible but still proves dispatch" do
    deadline_us = deadline_after(100)

    outcome =
      RequestOwner.execute(identity(:unknown), deadline_us, fn ->
        AttemptProtocol.terminal_at(
          AttemptProtocol.context(),
          :response,
          %{response_kind: :success, io_duration_us: 1},
          deadline_us
        )

        {:ok, :too_late}
      end)

    assert outcome.result == {:error, :deadline_expired}
    assert %AttemptTerminal.Deadline{dispatch_certainty: :dispatched} = outcome.fact
    refute outcome.projection.fallback_eligible
  end

  test "a negative proof after D cannot erase D-1 ambiguity" do
    test_pid = self()
    deadline_us = deadline_after(50)

    owner =
      spawn(fn ->
        outcome =
          RequestOwner.execute(identity(:unknown), deadline_us, fn ->
            context = AttemptProtocol.context()
            assert :ok = AttemptProtocol.send_started_at(context, deadline_us - 1)
            send(test_pid, {:negative_transport_ready, self()})
            assert_receive :report_late_negative

            assert :ok =
                     AttemptProtocol.observe_at(
                       context,
                       :predispatch_failure,
                       deadline_us + 1,
                       %{reason: :not_connected, elapsed_us: 0}
                     )

            {:error, :not_connected}
          end)

        send(test_pid, {:negative_owner_outcome, outcome})
      end)

    assert_receive {:negative_transport_ready, task}
    assert :erlang.suspend_process(owner)
    wait_past(deadline_us)

    await_mailbox(owner, fn messages ->
      Enum.any?(messages, &match?({:request_owner_cutoff, _, _}, &1))
    end)

    send(task, :report_late_negative)
    assert :erlang.resume_process(owner)

    assert_receive {:negative_owner_outcome, outcome}, 1_000
    assert outcome.result == {:error, :deadline_expired}
    assert %AttemptTerminal.Deadline{dispatch_certainty: :indeterminate} = outcome.fact
    refute outcome.projection.fallback_eligible
  end

  test "runtime error categories map to the four canonical application classes" do
    cases = [
      {:invalid_params, :deterministic, :return_response, :none},
      {:rate_limit, :quota, :try_next_candidate, :none},
      {:method_not_found, :capability, :try_next_candidate, :none},
      {:server_error, :provider_failure, :try_next_candidate, :failure}
    ]

    for {runtime_category, canonical_category, action, breaker_effect} <- cases do
      outcome =
        RequestOwner.execute(identity(), deadline_after(100), fn ->
          AttemptProtocol.terminal(AttemptProtocol.context(), :response, %{
            response_kind: :error,
            error_code: -32_000,
            error_category: runtime_category,
            io_duration_us: 1
          })

          {:error, :application_error}
        end)

      assert %AttemptTerminal.Response{
               kind: :application_error,
               error_category: ^canonical_category
             } = outcome.fact

      assert outcome.projection.recommended_action == action
      assert outcome.projection.breaker_effect == breaker_effect
    end
  end

  test "a completion already queued before the cutoff marker remains eligible" do
    for _iteration <- 1..20 do
      test_pid = self()
      deadline_us = deadline_after(50)

      owner =
        spawn(fn ->
          outcome =
            RequestOwner.execute(identity(), deadline_us, fn ->
              send(test_pid, {:transport_ready, self()})
              assert_receive :complete
              success_terminal(AttemptProtocol.context())
              {:ok, :timely}
            end)

          send(test_pid, {:owner_outcome, outcome})
        end)

      assert_receive {:transport_ready, task}
      assert :erlang.suspend_process(owner)
      send(task, :complete)

      await_mailbox(owner, fn messages ->
        Enum.any?(messages, &match?({_task_ref, %RequestOwner.AttemptCompletion{}}, &1))
      end)

      wait_past(deadline_us)

      await_mailbox(owner, fn messages ->
        Enum.any?(messages, &match?({:request_owner_cutoff, _, _}, &1))
      end)

      assert :erlang.resume_process(owner)

      assert_receive {:owner_outcome, outcome}, 1_000
      assert outcome.result == {:ok, :timely}
      assert %AttemptTerminal.Response{} = outcome.fact
    end
  end

  test "a D-1 stamp delivered after the prearmed cutoff marker is late" do
    for _iteration <- 1..20 do
      test_pid = self()
      deadline_us = deadline_after(25)

      owner =
        spawn(fn ->
          outcome =
            RequestOwner.execute(identity(), deadline_us, fn ->
              send(test_pid, {:transport_waiting, self()})
              assert_receive :complete_after_cutoff

              AttemptProtocol.terminal_at(
                AttemptProtocol.context(),
                :response,
                %{response_kind: :success, io_duration_us: 1},
                deadline_us - 1
              )

              {:ok, :too_late}
            end)

          send(test_pid, {:owner_outcome, outcome})
        end)

      assert_receive {:transport_waiting, task}
      assert :erlang.suspend_process(owner)
      wait_past(deadline_us)

      await_mailbox(owner, fn messages ->
        Enum.any?(messages, &match?({:request_owner_cutoff, _, _}, &1))
      end)

      send(task, :complete_after_cutoff)

      await_mailbox(owner, fn messages ->
        Enum.any?(messages, &match?({_task_ref, %RequestOwner.AttemptCompletion{}}, &1))
      end)

      assert :erlang.resume_process(owner)

      assert_receive {:owner_outcome, outcome}, 1_000
      assert outcome.result == {:error, :deadline_expired}
      assert %AttemptTerminal.Deadline{} = outcome.fact
    end
  end

  test "a caller already down prevents transport task creation" do
    test_pid = self()
    caller = spawn(fn -> :ok end)
    await_down(caller)

    outcome =
      RequestOwner.execute(
        identity(),
        deadline_after(100),
        fn ->
          send(test_pid, :transport_should_not_run)
          {:ok, :impossible}
        end,
        caller_pid: caller
      )

    refute_receive :transport_should_not_run
    assert outcome.result == {:error, :caller_abandoned}

    assert %AttemptTerminal.Cancelled{
             dispatch_certainty: :not_dispatched,
             censoring_boundary_us: 0
           } = outcome.fact
  end

  test "caller death uses the strongest dispatch certainty and a truthful censor" do
    phases = [
      {fn _context -> :ok end, :not_dispatched, 0},
      {fn context -> assert :ok = AttemptProtocol.send_started(context) end, :indeterminate,
       :positive},
      {fn context ->
         assert :ok = AttemptProtocol.send_started(context)
         assert :ok = AttemptProtocol.send_confirmed(context)
       end, :dispatched, :positive}
    ]

    for {prepare, certainty, expected_boundary} <- phases do
      test_pid = self()
      caller = spawn(fn -> Process.sleep(:infinity) end)

      killer =
        spawn(fn ->
          receive do
            {:task_ready, task_pid} ->
              monitor = Process.monitor(task_pid)
              Process.exit(caller, :kill)

              receive do
                {:DOWN, ^monitor, :process, ^task_pid, reason} ->
                  send(test_pid, {:transport_stopped, reason})
              end
          end
        end)

      outcome =
        RequestOwner.execute(
          identity(),
          deadline_after(100),
          fn ->
            prepare.(AttemptProtocol.context())
            send(killer, {:task_ready, self()})
            Process.sleep(:infinity)
          end,
          caller_pid: caller
        )

      assert_receive {:transport_stopped, :killed}

      assert %AttemptTerminal.Cancelled{
               reason: :caller_abandoned,
               dispatch_certainty: ^certainty,
               censoring_boundary_us: boundary
             } = outcome.fact

      if expected_boundary == :positive, do: assert(boundary > 0), else: assert(boundary == 0)
      assert outcome.result == {:error, :caller_abandoned}
      assert outcome.committed?
    end
  end

  test "caller abandonment overrides an unpaired response candidate" do
    caller = spawn(fn -> Process.sleep(:infinity) end)

    killer =
      spawn(fn ->
        receive do
          {:candidate_ready, task_pid} ->
            Process.exit(caller, :kill)
            send(task_pid, :hold)
        end
      end)

    outcome =
      RequestOwner.execute(
        identity(),
        deadline_after(100),
        fn ->
          success_terminal(AttemptProtocol.context())
          send(killer, {:candidate_ready, self()})
          assert_receive :hold
          Process.sleep(:infinity)
        end,
        caller_pid: caller
      )

    assert outcome.result == {:error, :caller_abandoned}
    assert %AttemptTerminal.Cancelled{dispatch_certainty: :dispatched} = outcome.fact
  end

  test "task death is conservative before send, during send, and after dispatch proof" do
    phases = [
      {fn _context -> :ok end, :indeterminate},
      {fn context -> assert :ok = AttemptProtocol.send_started(context) end, :indeterminate},
      {fn context ->
         assert :ok = AttemptProtocol.send_started(context)
         assert :ok = AttemptProtocol.send_confirmed(context)
       end, :dispatched}
    ]

    for {prepare, certainty} <- phases do
      outcome =
        RequestOwner.execute(identity(), deadline_after(100), fn ->
          prepare.(AttemptProtocol.context())
          exit(:transport_crashed)
        end)

      assert %AttemptTerminal.TransportFailure{
               reason: :unknown,
               dispatch_certainty: ^certainty
             } = outcome.fact

      assert outcome.result == {:error, {:transport_task_exit, :transport_crashed}}
      assert outcome.committed?
    end
  end

  test "restoring trap_exit preserves the caller's unrelated exit semantics" do
    parent = self()

    for {prior, reason, expected} <- [
          {false, :normal, :survives},
          {false, :unrelated_failure, :dies},
          {true, :normal, :traps},
          {true, :unrelated_failure, :traps}
        ] do
      helper =
        spawn(fn ->
          Process.flag(:trap_exit, prior)

          outcome =
            RequestOwner.execute(
              identity(),
              deadline_after(100),
              fn ->
                success_terminal(AttemptProtocol.context())
                {:ok, :done}
              end,
              test_before_restore: fn ->
                linked = spawn_link(fn -> exit(reason) end)

                await_mailbox(self(), fn messages ->
                  Enum.any?(messages, &match?({:EXIT, ^linked, ^reason}, &1))
                end)
              end
            )

          pending_exit =
            receive do
              {:EXIT, _pid, pending_reason} -> pending_reason
            after
              0 -> nil
            end

          send(parent, {:helper_survived, self(), outcome, pending_exit})
        end)

      monitor = Process.monitor(helper)

      case expected do
        :dies ->
          assert_receive {:DOWN, ^monitor, :process, ^helper, :unrelated_failure}
          refute_receive {:helper_survived, ^helper, _outcome, _pending}

        :survives ->
          assert_receive {:helper_survived, ^helper, outcome, nil}
          assert outcome.committed?

        :traps ->
          assert_receive {:helper_survived, ^helper, outcome, ^reason}
          assert outcome.committed?
      end
    end
  end

  test "deadline wakeup p95 stays within the bounded runtime tolerance" do
    overshoots =
      for _iteration <- 1..30 do
        deadline_us = deadline_after(5)

        outcome =
          RequestOwner.execute(identity(), deadline_us, fn ->
            Process.sleep(:infinity)
          end)

        assert outcome.result == {:error, :deadline_expired}
        max(System.monotonic_time(:microsecond) - deadline_us, 0)
      end

    p95 = overshoots |> Enum.sort() |> Enum.at(28)

    assert p95 <= 25_000,
           "deadline wakeup p95 exceeded 25ms: p95=#{p95}us max=#{Enum.max(overshoots)}us"
  end
end

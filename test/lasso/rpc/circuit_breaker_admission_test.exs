defmodule Lasso.RPC.CircuitBreakerAdmissionTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Support.CircuitBreaker
  alias Lasso.Core.Support.CircuitBreaker.{Admission, AdmissionReceipt, Snapshot, Storage}

  setup do
    id = {"admission-#{System.unique_integer([:positive])}", :http}
    {:ok, breaker_pid} = CircuitBreaker.start_link({id, %{recovery_timeout: 60_000}})

    on_exit(fn ->
      if Process.alive?(breaker_pid), do: GenServer.stop(breaker_pid)
      :ets.delete(Storage.snapshot_table(), id)
    end)

    %{id: id, breaker_pid: breaker_pid}
  end

  test "closed admission uses one snapshot lookup and does not cross the owner", %{
    id: id,
    breaker_pid: breaker_pid
  } do
    test_pid = self()
    handler_id = "admission-count-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:lasso, :circuit_breaker, :snapshot_admission],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:admission_measurements, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    deadline_us = System.monotonic_time(:microsecond) + 25_000

    assert {:ok, %AdmissionReceipt{kind: :closed}} = Admission.check(id, deadline_us)
    assert {:transport_ran, :ok} = run_after_admission(id, deadline_us, fn -> :ok end)

    assert_receive {:admission_measurements, %{snapshot_lookups: 1, synchronous_owner_calls: 0},
                    %{decision: :allow}}
  end

  test "open admission denies while its owner is suspended", %{
    id: id,
    breaker_pid: breaker_pid
  } do
    CircuitBreaker.open(id)
    assert %{state: :open} = CircuitBreaker.get_state(id)
    :sys.suspend(breaker_pid)
    on_exit(fn -> if Process.alive?(breaker_pid), do: :sys.resume(breaker_pid) end)

    deadline_us = System.monotonic_time(:microsecond) + 25_000
    assert {:error, :circuit_open} = Admission.check(id, deadline_us)
  end

  test "missing, unready, and dead-owner snapshots fail closed", %{id: id} do
    :ets.delete(Storage.snapshot_table(), id)
    assert {:error, :admission_unavailable} = Admission.check(id, deadline_us())

    put_snapshot(id, self(), ready?: false)
    assert {:error, :admission_unavailable} = Admission.check(id, deadline_us())

    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    owner_monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}

    put_snapshot(id, owner)
    assert {:error, :admission_unavailable} = Admission.check(id, deadline_us())
  end

  test "the open recovery boundary is exceptional and equality expires", %{id: id} do
    now_us = System.monotonic_time(:microsecond)
    put_snapshot(id, self(), state: :open, recovery_deadline_us: now_us + 1)

    assert {:error, :circuit_open} = Admission.check(id, now_us + 10, now_us)

    assert {:exceptional, %Snapshot{state: :open}} =
             Admission.check(id, now_us + 10, now_us + 1)

    assert {:error, :admission_timeout} = Admission.check(id, now_us + 1, now_us + 1)
  end

  defp run_after_admission(id, deadline_us, fun) do
    case Admission.check(id, deadline_us) do
      {:ok, _receipt} -> {:transport_ran, fun.()}
      other -> other
    end
  end

  defp put_snapshot(id, owner_pid, overrides \\ []) do
    defaults = [
      breaker_id: id,
      state: :closed,
      generation: 1,
      epoch: 1,
      owner_pid: owner_pid,
      ready?: true,
      recovery_deadline_us: nil,
      half_open_capacity: 1,
      half_open_inflight: 0,
      control_health: :healthy
    ]

    defaults
    |> Keyword.merge(overrides)
    |> then(&struct!(Snapshot, &1))
    |> Snapshot.put()
  end

  defp deadline_us, do: System.monotonic_time(:microsecond) + 25_000
end

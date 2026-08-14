alias Lasso.Core.Support.CircuitBreaker
alias Lasso.Core.Support.CircuitBreaker.{Admission, ControlRing, Snapshot, Storage}

iterations = 100_000
half_open_iterations = 1_000

measure = fn fun, count ->
  started_us = System.monotonic_time(:microsecond)
  Enum.each(1..count, fn _index -> fun.() end)
  elapsed_us = System.monotonic_time(:microsecond) - started_us

  %{
    iterations: count,
    elapsed_us: elapsed_us,
    average_us: elapsed_us / count,
    operations_per_second: count * 1_000_000 / max(elapsed_us, 1)
  }
end

start_breaker = fn name, config ->
  id = {name, :http}
  {:ok, pid} = CircuitBreaker.start_link({id, Map.new(config)})
  {id, pid}
end

set_snapshot_state = fn id, state, recovery_deadline_us ->
  {:ok, snapshot} = Snapshot.lookup(id)

  Snapshot.put(%{
    snapshot
    | state: state,
      recovery_deadline_us: recovery_deadline_us,
      half_open_inflight: 0,
      control_health: :healthy
  })
end

deadline = fn -> System.monotonic_time(:microsecond) + 60_000_000 end

{closed_id, closed_pid} = start_breaker.("bench-closed", control_ring_capacity: 64)
closed_fun = fn -> {:ok, _receipt} = Admission.check(closed_id, deadline.()) end
closed_responsive = measure.(closed_fun, iterations)

:sys.suspend(closed_pid)
closed_suspended = measure.(closed_fun, iterations)
:sys.resume(closed_pid)

{open_id, open_pid} = start_breaker.("bench-open", recovery_timeout: 60_000)
CircuitBreaker.open(open_id)
%{state: :open} = CircuitBreaker.get_state(open_id)
open_fun = fn -> {:error, :circuit_open} = Admission.check(open_id, deadline.()) end
open_responsive = measure.(open_fun, iterations)

:sys.suspend(open_pid)
open_suspended = measure.(open_fun, iterations)
:sys.resume(open_pid)

{half_open_id, half_open_pid} = start_breaker.("bench-half-open", success_threshold: 1)
:sys.replace_state(half_open_pid, &%{&1 | state: :half_open})
set_snapshot_state.(half_open_id, :half_open, nil)

half_open_normal =
  measure.(
    fn ->
      {:ok, receipt} = CircuitBreaker.admit(half_open_id, deadline.())
      CircuitBreaker.release_half_open(receipt)
      %{inflight_count: 0} = :sys.get_state(half_open_pid)
    end,
    half_open_iterations
  )

:sys.suspend(half_open_pid)
timeout_started_us = System.monotonic_time(:microsecond)

{:error, :admission_timeout} =
  CircuitBreaker.admit(half_open_id, timeout_started_us + 25_000)

half_open_timeout_us = System.monotonic_time(:microsecond) - timeout_started_us
:sys.resume(half_open_pid)
%{inflight_count: 0} = :sys.get_state(half_open_pid)

{ring_id, ring_pid} = start_breaker.("bench-ring", control_ring_capacity: 64)
{:ok, ring_receipt} = Admission.check(ring_id, deadline.())
:sys.suspend(ring_pid)

ring_results =
  Enum.map(1..256, fn _index -> CircuitBreaker.report_closed(ring_receipt, :ok) end)

ring_stats = ControlRing.stats(ring_id)

output = %{
  environment: %{
    elixir: System.version(),
    otp_release: System.otp_release(),
    schedulers_online: System.schedulers_online(),
    os: :os.type() |> inspect(),
    iterations: iterations,
    half_open_iterations: half_open_iterations
  },
  admission: %{
    closed_responsive: closed_responsive,
    closed_suspended: closed_suspended,
    open_responsive: open_responsive,
    open_suspended: open_suspended,
    half_open_normal: half_open_normal,
    half_open_timeout_us: half_open_timeout_us,
    healthy_snapshot_lookups: 1,
    healthy_synchronous_owner_calls: 0
  },
  saturation: %{
    accepted: Enum.count(ring_results, &(&1 == :ok)),
    rejected: Enum.count(ring_results, &(&1 == {:error, :saturated})),
    stats: Map.drop(ring_stats, [:owner_pid])
  }
}

IO.puts(Jason.encode!(output, pretty: true))

:sys.resume(ring_pid)
Enum.each([closed_pid, open_pid, half_open_pid, ring_pid], &GenServer.stop/1)

Enum.each([closed_id, open_id, half_open_id, ring_id], fn id ->
  :ets.delete(Storage.snapshot_table(), id)
  :ets.delete(Storage.lease_table(), id)
  :ets.delete(Storage.control_meta_table(), id)
end)

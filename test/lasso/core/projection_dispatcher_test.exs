defmodule Lasso.Core.ProjectionDispatcherTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.{ProjectionDispatcher, ProjectionLane}

  @scope {"profile", 1}

  test "enqueue is nonblocking through named ETS and distinguishes unavailable from unknown class" do
    unavailable = unique_name(:unavailable)

    assert {:drop, :unavailable, :untracked} =
             ProjectionDispatcher.enqueue(unavailable, :diagnostics, @scope, "fact")

    parent = self()
    name = unique_name(:dispatcher)

    dispatcher =
      start_dispatcher(name,
        diagnostics: lane_opts(fn _scope, payload -> send(parent, {:diagnostic, payload}) end)
      )

    assert {:drop, :unknown_sink_class, :untracked} =
             ProjectionDispatcher.enqueue(name, :analytics, @scope, "fact")

    :erlang.suspend_process(dispatcher)
    assert {:ok, _token} = ProjectionDispatcher.enqueue(name, :diagnostics, @scope, "fact")
    assert_receive {:diagnostic, "fact"}
    assert {:message_queue_len, 0} = Process.info(dispatcher, :message_queue_len)
    :erlang.resume_process(dispatcher)
  end

  test "normal enqueue stays within the four-operation ETS budget" do
    parent = self()
    name = unique_name(:operation_budget)

    _dispatcher =
      start_dispatcher(name,
        diagnostics:
          lane_opts(fn _scope, _payload -> :ok end,
            test_hook: fn event -> send(parent, event) end
          )
      )

    assert {:ok, token} = ProjectionDispatcher.enqueue(name, :diagnostics, @scope, "fact")
    assert_receive {:enqueue_ops, ^token, lane_operations}

    # The lane reports its control lookup plus fixed slot probes. The named
    # dispatcher registry lookup is the one remaining ETS operation.
    assert lane_operations + 1 <= 4
  end

  test "lazy enqueue resolves the lane without crossing the dispatcher" do
    parent = self()
    name = unique_name(:lazy)

    dispatcher =
      start_dispatcher(name,
        diagnostics: lane_opts(fn _scope, payload -> send(parent, {:diagnostic, payload}) end)
      )

    :erlang.suspend_process(dispatcher)

    assert {:ok, _token} =
             ProjectionDispatcher.enqueue_lazy(name, :diagnostics, @scope, fn ->
               {:ok, "lazy"}
             end)

    assert_receive {:diagnostic, "lazy"}
    assert {:message_queue_len, 0} = Process.info(dispatcher, :message_queue_len)
    :erlang.resume_process(dispatcher)
  end

  test "hung sinks and saturation stay isolated between fixed sink classes" do
    parent = self()
    name = unique_name(:isolation)

    _dispatcher =
      start_dispatcher(name,
        analytics:
          lane_opts(fn _scope, payload ->
            send(parent, {:analytics_started, self(), payload})
            receive do: (:release -> :ok)
          end),
        learned_feedback:
          lane_opts(fn _scope, payload -> send(parent, {:learned, payload}) end,
            coalesce: :latest,
            scope_capacity: 1
          )
      )

    assert {:ok, _token} = ProjectionDispatcher.enqueue(name, :analytics, @scope, "slow")
    assert_receive {:analytics_started, analytics_worker, "slow"}

    assert {:ok, _token} =
             ProjectionDispatcher.enqueue(name, :learned_feedback, @scope, "fast")

    assert_receive {:learned, "fast"}
    send(analytics_worker, :release)
  end

  test "lane restart swaps its incarnation without suppressing another class" do
    parent = self()
    name = unique_name(:restart)

    _dispatcher =
      start_dispatcher(name,
        diagnostics: lane_opts(fn _scope, payload -> send(parent, {:diagnostic, payload}) end),
        analytics: lane_opts(fn _scope, payload -> send(parent, {:analytics, payload}) end)
      )

    {:ok, old_lane} = ProjectionDispatcher.lane(name, :diagnostics)
    old_incarnation = ProjectionLane.metadata(old_lane).incarnation
    monitor = Process.monitor(old_lane)
    Process.exit(old_lane, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^old_lane, :killed}

    new_lane = await_replacement(name, :diagnostics, old_lane)
    refute ProjectionLane.metadata(new_lane).incarnation == old_incarnation

    assert {:ok, _token} = ProjectionDispatcher.enqueue(name, :analytics, @scope, "independent")
    assert_receive {:analytics, "independent"}
    assert {:ok, _token} = ProjectionDispatcher.enqueue(name, :diagnostics, @scope, "recovered")
    assert_receive {:diagnostic, "recovered"}
  end

  test "dispatcher death removes the registry and supervision rebuilds every lane" do
    parent = self()
    name = unique_name(:dispatcher_restart)

    dispatcher =
      start_dispatcher(name,
        diagnostics: lane_opts(fn _scope, payload -> send(parent, {:delivered, payload}) end)
      )

    {:ok, old_lane} = ProjectionDispatcher.lane(name, :diagnostics)
    {old_worker, _generation} = ProjectionLane.workers(old_lane)[0]
    dispatcher_monitor = Process.monitor(dispatcher)
    lane_monitor = Process.monitor(old_lane)
    worker_monitor = Process.monitor(old_worker)
    Process.exit(dispatcher, :kill)

    assert_receive {:DOWN, ^dispatcher_monitor, :process, ^dispatcher, :killed}
    assert_receive {:DOWN, ^lane_monitor, :process, ^old_lane, _reason}
    assert_receive {:DOWN, ^worker_monitor, :process, ^old_worker, _reason}

    replacement = await_dispatcher(name, dispatcher)
    assert Process.alive?(replacement)
    assert {:ok, _new_lane} = ProjectionDispatcher.lane(name, :diagnostics)
    assert {:ok, _token} = ProjectionDispatcher.enqueue(name, :diagnostics, @scope, "after")
    assert_receive {:delivered, "after"}
  end

  test "critical lease accounting is not a configurable projection class" do
    name = unique_name(:invalid)
    previous = Process.flag(:trap_exit, true)

    assert {:error, {%ArgumentError{}, _stacktrace}} =
             ProjectionDispatcher.start_link(
               name: name,
               lanes: [critical_lease_accounting: lane_opts(fn _scope, _payload -> :ok end)]
             )

    Process.flag(:trap_exit, previous)
  end

  defp start_dispatcher(name, lanes) do
    start_supervised!({ProjectionDispatcher, name: name, lanes: lanes})
  end

  defp lane_opts(sink, overrides \\ []) do
    Keyword.merge(
      [
        capacity: 4,
        byte_capacity: 16_384,
        scope_capacity: 2,
        scope_byte_capacity: 8_192,
        shards: 1,
        max_age_ms: 1_000,
        audit_interval_ms: 60_000,
        sink: sink
      ],
      overrides
    )
  end

  defp unique_name(suffix),
    do: Module.concat(__MODULE__, "#{suffix}_#{System.unique_integer([:positive])}")

  defp await_replacement(name, sink_class, old_lane) do
    await_replacement(name, sink_class, old_lane, deadline_ms())
  end

  defp await_replacement(name, sink_class, old_lane, deadline) do
    case ProjectionDispatcher.lane(name, sink_class) do
      {:ok, lane} when lane != old_lane ->
        lane

      _ ->
        wait_until(deadline, "projection lane was not replaced")
        await_replacement(name, sink_class, old_lane, deadline)
    end
  end

  defp await_dispatcher(name, old_dispatcher) do
    await_dispatcher(name, old_dispatcher, deadline_ms())
  end

  defp await_dispatcher(name, old_dispatcher, deadline) do
    case Process.whereis(name) do
      dispatcher when is_pid(dispatcher) and dispatcher != old_dispatcher ->
        dispatcher

      _ ->
        wait_until(deadline, "dispatcher was not restarted")
        await_dispatcher(name, old_dispatcher, deadline)
    end
  end

  defp deadline_ms, do: System.monotonic_time(:millisecond) + 1_000

  defp wait_until(deadline, message) do
    remaining = deadline - System.monotonic_time(:millisecond)
    if remaining <= 0, do: flunk(message)

    receive do
    after
      min(remaining, 5) -> :ok
    end
  end
end

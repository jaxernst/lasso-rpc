defmodule Lasso.Core.Transport.UpstreamAdmissionTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.Request.{ExecutionScope, RequestOwner}
  alias Lasso.Core.Transport.{AttemptProtocol, UpstreamAdmission}
  alias Lasso.RPC.{AttemptIdentity, Response}

  @admission __MODULE__.Admission

  setup do
    start_supervised!(
      {UpstreamAdmission,
       name: @admission,
       shards: 2,
       node_limit: 3,
       upstream_limit: 2,
       response_byte_limit: 100,
       response_limit: 50}
    )

    on_exit(fn -> UpstreamAdmission.stop(@admission) end)
    :ok
  end

  test "node and origin concurrency reject without exceeding their exact limits" do
    assert {:ok, first} = acquire(:origin_a, "instance-a")
    assert {:ok, second} = acquire(:origin_a, "instance-a")
    assert {:error, :upstream_capacity} = acquire(:origin_a, "instance-a")

    assert {:ok, third} = acquire(:origin_b, "instance-b")
    assert {:error, :node_capacity} = acquire(:origin_c, "instance-c")

    assert %{node_inflight: 3, leases: 3} = UpstreamAdmission.stats(@admission)

    Enum.each([first, second, third], &UpstreamAdmission.release(&1, :test_complete))
    assert %{node_inflight: 0, leases: 0} = UpstreamAdmission.stats(@admission)
  end

  test "per-response and aggregate byte limits are charged before retention" do
    assert {:ok, first} = acquire(:origin_a, "instance-a")
    assert :ok = UpstreamAdmission.reserve_response(first, 30, 2)
    assert {:error, :response_too_large} = UpstreamAdmission.reserve_response(first, 31, 2)

    assert {:ok, second} = acquire(:origin_b, "instance-b")

    assert {:error, :response_byte_capacity} =
             UpstreamAdmission.reserve_response(second, 21, 2)

    assert %{response_bytes: 60, response_rejected: 1, byte_rejected: 1} =
             UpstreamAdmission.stats(@admission)

    assert :ok = UpstreamAdmission.transfer(first, self())

    assert %{node_inflight: 1, response_bytes: 60, retained_responses: 1} =
             UpstreamAdmission.stats(@admission)

    assert :ok = UpstreamAdmission.release(first, :sent)
    assert :ok = UpstreamAdmission.release(second, :test_complete)

    assert %{node_inflight: 0, response_bytes: 0, leases: 0} =
             UpstreamAdmission.stats(@admission)
  end

  test "owner death reclaims request and response capacity" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, lease} = acquire(:origin_a, "instance-a", owner: owner)
    assert :ok = UpstreamAdmission.reserve_response(lease, 20, 2)

    Process.exit(owner, :kill)
    await_empty()

    stats = UpstreamAdmission.stats(@admission)
    assert %{node_inflight: 0, response_bytes: 0, leases: 0} = stats
    assert stats.reclaimed >= 1
  end

  test "untrappable partition exit restarts admission with fresh request and response capacity" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, lease} = acquire(:origin_a, "instance-a", owner: owner)
    assert :ok = UpstreamAdmission.reserve_response(lease, 20, 2)

    admission = GenServer.whereis(@admission)
    admission_monitor = Process.monitor(admission)

    worker =
      GenServer.whereis({:via, PartitionSupervisor, {@admission, lease.worker_index}})

    monitor = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 1_000
    assert_receive {:DOWN, ^admission_monitor, :process, ^admission, :killed}, 1_000
    assert is_pid(await_admission_restart(admission))
    await_empty()

    assert %{node_inflight: 0, response_bytes: 0, leases: 0} =
             UpstreamAdmission.stats(@admission)

    assert {:ok, replacement} = acquire(:origin_a, "instance-a")
    assert :ok = UpstreamAdmission.release(replacement, :test_complete)
    Process.exit(owner, :kill)
  end

  test "public operations fail closed while the partition registry is absent" do
    admission = Module.concat(@admission, Unavailable)

    assert {:ok, supervisor} =
             UpstreamAdmission.start_link(
               name: admission,
               shards: 2,
               node_limit: 3,
               upstream_limit: 2,
               response_byte_limit: 100,
               response_limit: 50
             )

    Process.unlink(supervisor)
    monitor = Process.monitor(supervisor)
    Process.exit(supervisor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^supervisor, :killed}

    on_exit(fn -> UpstreamAdmission.stop(admission) end)

    assert %{available?: false} = UpstreamAdmission.stats(admission)

    assert {:error, :admission_unavailable} =
             acquire(:origin_a, "instance-a", admission: admission)

    lease = %UpstreamAdmission.Lease{
      admission: admission,
      worker_index: 0,
      token: make_ref()
    }

    assert {:error, :admission_unavailable} = UpstreamAdmission.reserve_response(lease, 1)
  end

  test "normal handoff owner exit retains bytes until the response owner releases them" do
    parent = self()

    task =
      Task.async(fn ->
        assert {:ok, lease} = acquire(:origin_a, "instance-a")
        assert :ok = UpstreamAdmission.reserve_response(lease, 20, 2)
        assert :ok = UpstreamAdmission.transfer(lease, parent)
        lease
      end)

    lease = Task.await(task)
    await_stat(:retained_responses, 1)

    assert %{node_inflight: 0, response_bytes: 40, retained_responses: 1} =
             UpstreamAdmission.stats(@admission)

    assert :ok = UpstreamAdmission.release(lease, :sent)
    await_empty()
  end

  test "successive owner transfers preserve capacity across process exits" do
    parent = self()
    middle = spawn(fn -> transfer_lease(parent) end)

    assert_receive {:transferred, ^middle, lease}, 1_000
    await_stat(:retained_responses, 1)

    Process.exit(middle, :kill)
    await_stat(:retained_responses, 1)

    assert %{node_inflight: 0, response_bytes: 40, leases: 1} =
             UpstreamAdmission.stats(@admission)

    assert :ok = UpstreamAdmission.release(lease, :sent)
    await_empty()
  end

  test "request ownership hands retained batch responses to the caller" do
    parent = self()

    request_owner =
      spawn(fn ->
        scope = ExecutionScope.monitored(self(), parent)
        caller_guard = ExecutionScope.open(scope)

        outcome =
          RequestOwner.execute(
            identity(),
            System.monotonic_time(:microsecond) + 1_000_000,
            fn -> admitted_success() end,
            caller_guard: caller_guard
          )

        ExecutionScope.close(caller_guard)
        send(parent, {:owned_response, self(), outcome})
      end)

    monitor = Process.monitor(request_owner)

    assert_receive {:owned_response, ^request_owner, outcome}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^request_owner, :normal}, 1_000
    assert {:ok, %Response.Success{capacity_lease: lease}} = outcome.result

    await_stat(:retained_responses, 1)

    assert %{node_inflight: 0, response_bytes: 40, leases: 1} =
             UpstreamAdmission.stats(@admission)

    assert :ok = UpstreamAdmission.release(lease, :batch_sent)
    await_empty()
  end

  test "unsafe admission configurations fail before startup" do
    assert_raise ArgumentError, ~r/divisible/, fn ->
      UpstreamAdmission.start_link(
        name: Module.concat(@admission, Indivisible),
        shards: 3,
        node_limit: 4,
        upstream_limit: 4,
        response_byte_limit: 100,
        response_limit: 50
      )
    end

    assert_raise ArgumentError, ~r/Finch connection capacity/, fn ->
      UpstreamAdmission.start_link(
        name: Module.concat(@admission, PoolOversubscription),
        shards: 30,
        node_limit: 300,
        upstream_limit: 300,
        response_byte_limit: 100,
        response_limit: 50
      )
    end

    assert_raise ArgumentError, ~r/conservative maximum response charge/, fn ->
      UpstreamAdmission.start_link(
        name: Module.concat(@admission, ByteOversubscription),
        shards: 2,
        node_limit: 4,
        upstream_limit: 4,
        response_byte_limit: 100,
        response_limit: 51
      )
    end
  end

  test "telemetry carries bounded class, instance, bytes, and release reason" do
    handler_id = "upstream-admission-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:lasso, :upstream_admission, :accepted],
          [:lasso, :upstream_admission, :released]
        ],
        fn event, measurements, metadata, owner ->
          send(owner, {:admission_event, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, lease} =
             acquire(:origin_a, "instance-a",
               metadata: %{method_class: :replay_safe, transport: :http}
             )

    assert_receive {:admission_event, [:lasso, :upstream_admission, :accepted], _measurements,
                    %{
                      method_class: :replay_safe,
                      transport: :http,
                      upstream_instance_id: "instance-a"
                    }}

    assert :ok = UpstreamAdmission.reserve_response(lease, 20, 2)
    assert :ok = UpstreamAdmission.transfer(lease, self())
    assert :ok = UpstreamAdmission.release(lease, :sent)

    assert_receive {:admission_event, [:lasso, :upstream_admission, :released],
                    %{bytes: 20, count: 1},
                    %{reason: :sent, retained?: true, method_class: :replay_safe}}
  end

  defp acquire(capacity_key, instance_id, opts \\ []) do
    UpstreamAdmission.acquire(
      capacity_key,
      instance_id,
      Keyword.put_new(opts, :admission, @admission)
    )
  end

  defp transfer_lease(parent) do
    {:ok, lease} = acquire(:origin_a, "instance-a")
    :ok = UpstreamAdmission.reserve_response(lease, 20, 2)
    :ok = UpstreamAdmission.transfer(lease, parent)
    send(parent, {:transferred, self(), lease})
    Process.sleep(:infinity)
  end

  defp admitted_success do
    context = AttemptProtocol.context()
    {:ok, lease} = acquire(:origin_a, "instance-a")
    :ok = UpstreamAdmission.reserve_response(lease, 20, 2)
    :ok = UpstreamAdmission.transfer(lease, context.owner)

    :ok =
      AttemptProtocol.terminal(context, :response, %{
        response_kind: :success,
        io_duration_us: 1
      })

    {:ok,
     %Response.Success{
       id: "request",
       jsonrpc: "2.0",
       raw_bytes: ~s({"jsonrpc":"2.0","id":"request","result":"0x1"}),
       capacity_lease: lease
     }}
  end

  defp identity do
    AttemptIdentity.new(
      request_id: "request",
      attempt_id: "attempt",
      profile: "public",
      chain_id: 1,
      upstream_instance_id: "instance-a",
      transport: :http,
      route_generation: 1,
      circuit_scope: :broad,
      circuit_epoch: 1,
      execution_safety: :replay_safe,
      routing_intent: "default",
      workload_key: "eth_blockNumber",
      request_budget_ms: 1_000,
      candidate_admission_count: 1,
      dispatch_count: 1
    )
  end

  defp await_empty(attempts \\ 100)

  defp await_empty(0), do: flunk("admission capacity did not return to zero")

  defp await_empty(attempts) do
    case UpstreamAdmission.stats(@admission) do
      %{node_inflight: 0, response_bytes: 0, leases: 0} ->
        :ok

      _busy ->
        Process.sleep(10)
        await_empty(attempts - 1)
    end
  end

  defp await_stat(key, value, attempts \\ 100)

  defp await_stat(_key, _value, 0), do: flunk("admission statistic did not converge")

  defp await_stat(key, value, attempts) do
    if Map.get(UpstreamAdmission.stats(@admission), key) == value do
      :ok
    else
      Process.sleep(10)
      await_stat(key, value, attempts - 1)
    end
  end

  defp await_admission_restart(previous, attempts \\ 100)

  defp await_admission_restart(_previous, 0), do: flunk("admission supervisor did not restart")

  defp await_admission_restart(previous, attempts) do
    case GenServer.whereis(@admission) do
      pid when is_pid(pid) and pid != previous ->
        pid

      _not_restarted ->
        Process.sleep(10)
        await_admission_restart(previous, attempts - 1)
    end
  end
end

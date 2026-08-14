defmodule Lasso.Core.ProjectionLaneTest do
  use ExUnit.Case, async: false

  alias Lasso.Core.ProjectionLane
  alias Lasso.RPC.{AdmissionTerminal, ExecutionFact.Codec}

  @scope_a {"profile-a", 1}

  test "retains only encoded binary facts within the structural four-KiB bound" do
    parent = self()
    {lane, metadata} = start_lane(sink: fn scope, payload -> send(parent, {scope, payload}) end)
    worker = worker(lane)
    suspend(worker)

    fact =
      AdmissionTerminal.new(
        request_id: "request-1",
        profile: "profile-a",
        chain_id: 1,
        routing_intent: "default",
        workload_key: "read",
        reason: :local_capacity,
        candidate_admission_count: 1,
        dispatch_count: 0,
        elapsed_us: 2
      )

    assert {:ok, fact_token} = ProjectionLane.enqueue_fact(metadata, @scope_a, fact)

    assert {:ok, maximum_token} =
             ProjectionLane.enqueue(metadata, {"profile-b", 1}, :binary.copy("x", 4_096))

    assert metadata.max_payload_bytes == Codec.max_bytes()

    stats = ProjectionLane.stats(lane)
    assert stats.retained_items == 2
    assert stats.bytes <= stats.byte_capacity

    for {_shard, shard_stats} <- stats.shards,
        {_key, _state, _token, _scope, _at, size, payload} <- :ets.tab2list(shard_stats.table) do
      assert is_binary(payload)
      assert byte_size(payload) == size
      assert size <= Codec.max_bytes()
    end

    assert {:drop, :invalid_payload, :untracked} =
             ProjectionLane.enqueue(metadata, @scope_a, %{request_body: "not encoded"})

    assert {:drop, :invalid_payload, :untracked} =
             ProjectionLane.enqueue(metadata, @scope_a, :binary.copy("x", 4_097))

    assert :cancelled = ProjectionLane.cancel(metadata, fact_token)
    assert :cancelled = ProjectionLane.cancel(metadata, maximum_token)
    resume(worker)
  end

  test "a cancelled row is never reinserted by a stale worker claim" do
    parent = self()

    hook = fn
      {:before_claim, token} ->
        send(parent, {:before_claim, self(), token})
        receive do: ({:release_claim, ^token} -> :ok)

      event ->
        send(parent, event)
    end

    {lane, metadata} =
      start_lane(
        capacity: 1,
        scope_capacity: 1,
        sink: fn _scope, payload -> send(parent, {:delivered, payload}) end,
        test_hook: hook
      )

    worker = worker(lane)
    assert {:ok, first} = ProjectionLane.enqueue(metadata, @scope_a, "first")
    assert_receive {:before_claim, ^worker, ^first}
    assert :cancelled = ProjectionLane.cancel(metadata, first)

    assert {:ok, second} = ProjectionLane.enqueue(metadata, @scope_a, "second")
    send(worker, {:release_claim, first})
    assert_receive {:before_claim, ^worker, ^second}
    assert ProjectionLane.stats(lane).retained_items == 1
    refute_received {:delivered, "first"}

    send(worker, {:release_claim, second})
    assert_receive {:delivered, "second"}
    assert_receive {:completed, ^second, :ok}
    barrier(worker)
    assert ProjectionLane.stats(lane).retained_items == 0
  end

  test "cancellation reports the exact queued or delivering state" do
    parent = self()

    {lane, metadata} =
      start_lane(
        sink: fn _scope, payload ->
          send(parent, {:sink_entered, self(), payload})
          receive do: (:release_sink -> :ok)
        end
      )

    worker = worker(lane)
    suspend(worker)
    assert {:ok, queued} = ProjectionLane.enqueue(metadata, @scope_a, "queued")
    assert :cancelled = ProjectionLane.cancel(metadata, queued)
    resume(worker)
    barrier(worker)
    refute_received {:sink_entered, _, "queued"}

    assert {:ok, delivering} = ProjectionLane.enqueue(metadata, @scope_a, "delivering")
    assert_receive {:sink_entered, ^worker, "delivering"}
    assert :delivering = ProjectionLane.cancel(metadata, delivering)
    send(worker, :release_sink)
    barrier(worker)
    assert :not_found = ProjectionLane.cancel(metadata, delivering)
  end

  test "producer death after atomic publication cannot lose its wake forever" do
    parent = self()

    hook = fn
      {:published, token} ->
        send(parent, {:published, self(), token})
        receive do: (:never -> :ok)

      event ->
        send(parent, event)
    end

    {lane, metadata} =
      start_lane(
        test_hook: hook,
        sink: fn _scope, payload -> send(parent, {:delivered, payload}) end
      )

    producer = spawn(fn -> ProjectionLane.enqueue(metadata, @scope_a, "published") end)
    assert_receive {:published, ^producer, token}
    Process.exit(producer, :kill)
    assert ProjectionLane.stats(lane).queued_items == 1

    assert :ok = ProjectionLane.audit(lane)
    assert_receive {:delivered, "published"}
    assert_receive {:completed, ^token, :ok}
  end

  test "automatic audit repairs producer death after wake ownership but before send" do
    parent = self()

    hook = fn
      {:wake_claimed, shard, generation, bucket} ->
        send(parent, {:wake_claimed, self(), shard, generation, bucket})
        receive do: (:never -> :ok)

      {:audit, shard, generation} ->
        send(parent, {:automatic_audit, shard, generation})

      event ->
        send(parent, event)
    end

    {_lane, metadata} =
      start_lane(
        capacity: 1,
        scope_capacity: 1,
        audit_interval_ms: 1,
        test_hook: hook,
        sink: fn _scope, payload -> send(parent, {:delivered, payload}) end
      )

    producer = spawn(fn -> ProjectionLane.enqueue(metadata, @scope_a, "repair") end)
    assert_receive {:wake_claimed, ^producer, 0, 1, 0}
    Process.exit(producer, :kill)

    assert_receive {:automatic_audit, 0, 1}
    assert_receive {:delivered, "repair"}
    assert_receive {:completed, _token, :ok}
  end

  test "an enqueue between an empty scan and wake settlement is not lost" do
    parent = self()

    hook = fn
      {:before_empty_settle, bucket} ->
        send(parent, {:before_empty_settle, self(), bucket})
        receive do: ({:settle, ^bucket} -> :ok)

      event ->
        send(parent, event)
    end

    {lane, metadata} =
      start_lane(
        capacity: 1,
        scope_capacity: 1,
        test_hook: hook,
        sink: fn _scope, payload -> send(parent, {:delivered, payload}) end
      )

    worker = worker(lane)
    suspend(worker)
    assert {:ok, cancelled} = ProjectionLane.enqueue(metadata, @scope_a, "cancelled")
    assert :cancelled = ProjectionLane.cancel(metadata, cancelled)
    resume(worker)
    assert_receive {:before_empty_settle, ^worker, 0}

    assert {:ok, replacement} = ProjectionLane.enqueue(metadata, @scope_a, "replacement")
    send(worker, {:settle, 0})
    assert_receive {:delivered, "replacement"}
    assert_receive {:completed, ^replacement, :ok}
    barrier(worker)
    assert ProjectionLane.stats(lane).retained_items == 0
  end

  test "unique scope floods remain structurally bounded and every overflow is tracked" do
    {lane, metadata} = start_lane(capacity: 8, scope_capacity: 2, shards: 2)
    suspend_workers(lane)

    results =
      for index <- 1..2_000 do
        ProjectionLane.enqueue(metadata, {"profile-#{index}", index}, "x")
      end

    accepted = for {:ok, token} <- results, do: token
    drops = for {:drop, :bucket_contended, degradation} <- results, do: degradation

    assert length(accepted) <= metadata.capacity
    assert length(accepted) + length(drops) == length(results)
    assert Enum.all?(drops, &match?(%ProjectionLane.Degradation{}, &1))

    stats = ProjectionLane.stats(lane)
    assert stats.retained_items <= metadata.capacity
    assert MapSet.size(stats.active_scopes) <= metadata.capacity
    assert stats.counters.bucket_contended == length(drops)

    for {_shard, shard_stats} <- stats.shards do
      assert :ets.info(shard_stats.table, :size) <= div(metadata.capacity, metadata.shards)
      assert shard_stats.message_queue_len <= metadata.buckets_per_shard
    end

    Enum.each(accepted, fn token -> assert :cancelled = ProjectionLane.cancel(metadata, token) end)

    assert ProjectionLane.stats(lane).retained_items == 0
    resume_workers(lane)
  end

  test "concurrent publication and cancellation preserve fixed storage" do
    {lane, metadata} = start_lane(capacity: 64, scope_capacity: 8, shards: 2)
    suspend_workers(lane)

    results =
      1..256
      |> Task.async_stream(
        fn index -> ProjectionLane.enqueue(metadata, {"profile-#{index}", 1}, "x") end,
        max_concurrency: 64,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    tokens = for {:ok, token} <- results, do: token
    assert length(tokens) <= metadata.capacity
    assert ProjectionLane.stats(lane).retained_items == length(tokens)

    tokens
    |> Task.async_stream(&ProjectionLane.cancel(metadata, &1),
      max_concurrency: 64,
      ordered: false
    )
    |> Enum.each(fn {:ok, result} -> assert result == :cancelled end)

    assert %{retained_items: 0, queued_items: 0, bytes: 0} = ProjectionLane.stats(lane)
    resume_workers(lane)
  end

  test "item and retained-byte caps are structural rather than reconciled counters" do
    {lane, metadata} =
      start_lane(
        capacity: 2,
        byte_capacity: 6,
        scope_capacity: 1,
        scope_byte_capacity: 4
      )

    suspend_workers(lane)
    [scope_a, scope_b] = scopes_in_distinct_buckets(metadata, 2)

    assert metadata.max_payload_bytes == 3

    assert {:drop, :invalid_payload, :untracked} =
             ProjectionLane.enqueue(metadata, scope_a, "1234")

    assert {:ok, first} = ProjectionLane.enqueue(metadata, scope_a, "123")
    assert {:ok, second} = ProjectionLane.enqueue(metadata, scope_b, "456")

    assert %{retained_items: 2, queued_items: 2, bytes: 6} = ProjectionLane.stats(lane)
    assert :cancelled = ProjectionLane.cancel(metadata, first)
    assert :cancelled = ProjectionLane.cancel(metadata, second)
    assert %{retained_items: 0, bytes: 0} = ProjectionLane.stats(lane)
    resume_workers(lane)
  end

  test "one bucket rotates fairly across colliding profile and chain scopes" do
    parent = self()

    {lane, metadata} =
      start_lane(
        capacity: 4,
        scope_capacity: 4,
        sink: fn _scope, payload -> send(parent, payload) end
      )

    worker = worker(lane)
    suspend(worker)

    for {scope, payload} <- [
          {{"profile-a", 1}, "a1"},
          {{"profile-b", 1}, "b1"},
          {{"profile-a", 1}, "a2"},
          {{"profile-b", 1}, "b2"}
        ] do
      assert {:ok, _token} = ProjectionLane.enqueue(metadata, scope, payload)
    end

    resume(worker)
    assert_receive "a1"
    assert_receive "b1"
    assert_receive "a2"
    assert_receive "b2"
  end

  test "latest-value coalescing has exact tokens and an independent degradation epoch" do
    parent = self()

    {lane, metadata} =
      start_lane(
        capacity: 1,
        scope_capacity: 1,
        coalesce: :latest,
        sink: fn _scope, payload -> send(parent, {:delivered, payload}) end
      )

    worker = worker(lane)
    suspend(worker)
    assert {:ok, first} = ProjectionLane.enqueue(metadata, @scope_a, "first")

    assert {:coalesced, second, degradation_1} =
             ProjectionLane.enqueue(metadata, @scope_a, "second")

    assert {:coalesced, third, degradation_2} =
             ProjectionLane.enqueue(metadata, @scope_a, "third")

    refute first == second
    refute second == third
    assert :not_found = ProjectionLane.cancel(metadata, first)
    assert :not_found = ProjectionLane.cancel(metadata, second)
    assert :stale = ProjectionLane.recover(metadata, degradation_1)
    assert :recovered = ProjectionLane.recover(metadata, degradation_2)

    assert {:coalesced, fourth, degradation_3} =
             ProjectionLane.enqueue(metadata, @scope_a, "fourth")

    assert :stale = ProjectionLane.recover(metadata, degradation_2)
    assert degradation_3.epoch > degradation_2.epoch
    assert ProjectionLane.stats(lane).retained_items == 1

    resume(worker)
    assert_receive {:delivered, "fourth"}
    barrier(worker)
    assert :not_found = ProjectionLane.cancel(metadata, fourth)
  end

  test "a worker reads then loses a coalescing race without restoring stale data" do
    parent = self()

    hook = fn
      {:before_claim, token} ->
        send(parent, {:before_claim, self(), token})
        receive do: ({:release_claim, ^token} -> :ok)

      event ->
        send(parent, event)
    end

    {lane, metadata} =
      start_lane(
        capacity: 1,
        scope_capacity: 1,
        coalesce: :latest,
        sink: fn _scope, payload -> send(parent, {:delivered, payload}) end,
        test_hook: hook
      )

    worker = worker(lane)
    assert {:ok, old} = ProjectionLane.enqueue(metadata, @scope_a, "old")
    assert_receive {:before_claim, ^worker, ^old}

    assert {:coalesced, latest, _degradation} =
             ProjectionLane.enqueue(metadata, @scope_a, "latest")

    send(worker, {:release_claim, old})
    assert_receive {:before_claim, ^worker, ^latest}
    send(worker, {:release_claim, latest})
    assert_receive {:delivered, "latest"}
    refute_received {:delivered, "old"}
    barrier(worker)
    assert ProjectionLane.stats(lane).retained_items == 0
  end

  test "queue age expires at the injected monotonic boundary" do
    parent = self()
    {:ok, clock} = Agent.start_link(fn -> 10 end)

    {lane, metadata} =
      start_lane(
        now: fn -> Agent.get(clock, & &1) end,
        max_age_ms: 5,
        test_hook: fn event -> send(parent, event) end,
        sink: fn _scope, payload -> send(parent, {:unexpected_delivery, payload}) end
      )

    worker = worker(lane)
    suspend(worker)
    assert {:ok, token} = ProjectionLane.enqueue(metadata, @scope_a, "expired")
    Agent.update(clock, fn _ -> 15 end)
    resume(worker)

    assert_receive {:completed, ^token, :expired}
    refute_received {:unexpected_delivery, _payload}
    assert ProjectionLane.stats(lane).counters.expired == 1
  end

  test "raising and exiting sinks degrade observably without killing the worker" do
    parent = self()

    sink = fn _scope, payload ->
      case payload do
        "raise" -> raise "sink failed"
        "exit" -> exit(:sink_failed)
        "healthy" -> send(parent, :healthy_delivery)
      end
    end

    {lane, metadata} =
      start_lane(
        sink: sink,
        test_hook: fn event -> send(parent, event) end
      )

    worker = worker(lane)
    assert {:ok, raised} = ProjectionLane.enqueue(metadata, @scope_a, "raise")
    assert_receive {:degraded, raised_degradation, :sink_failure}
    assert_receive {:completed, ^raised, :sink_failure}
    assert Process.alive?(worker)
    assert :recovered = ProjectionLane.recover(metadata, raised_degradation)

    assert {:ok, exited} = ProjectionLane.enqueue(metadata, @scope_a, "exit")
    assert_receive {:degraded, exited_degradation, :sink_failure}
    assert_receive {:completed, ^exited, :sink_failure}
    assert Process.alive?(worker)
    assert exited_degradation.epoch > raised_degradation.epoch
    assert ProjectionLane.stats(lane).counters.sink_failure == 2

    assert {:ok, healthy} = ProjectionLane.enqueue(metadata, @scope_a, "healthy")
    assert_receive :healthy_delivery
    assert_receive {:completed, ^healthy, :ok}
  end

  test "worker death discards its optional queued and delivering facts and advances generation" do
    parent = self()

    {lane, metadata} =
      start_lane(
        sink: fn _scope, payload ->
          send(parent, {:entered, self(), payload})
          receive do: (:release -> :ok)
        end,
        test_hook: fn event -> send(parent, event) end
      )

    old_worker = worker(lane)
    assert {:ok, token} = ProjectionLane.enqueue(metadata, @scope_a, "delivering")
    assert_receive {:entered, ^old_worker, "delivering"}
    Process.exit(old_worker, :kill)
    assert_receive {:worker_restarted, 0, replacement, 2}
    assert ProjectionLane.stats(lane).retained_items == 0
    assert :not_found = ProjectionLane.cancel(metadata, token)

    assert {:ok, replacement_token} = ProjectionLane.enqueue(metadata, @scope_a, "replacement")
    assert_receive {:entered, ^replacement, "replacement"}
    send(replacement, :release)
    barrier(replacement)
    assert :not_found = ProjectionLane.cancel(metadata, replacement_token)
  end

  test "worker death while queued cannot strand capacity in another owner" do
    parent = self()

    {lane, metadata} =
      start_lane(
        sink: fn _scope, payload -> send(parent, {:delivered, payload}) end,
        test_hook: fn event -> send(parent, event) end
      )

    old_worker = worker(lane)
    suspend(old_worker)
    assert {:ok, old_token} = ProjectionLane.enqueue(metadata, @scope_a, "old")
    assert ProjectionLane.stats(lane).queued_items == 1

    Process.exit(old_worker, :kill)
    assert_receive {:worker_restarted, 0, replacement, 2}
    assert ProjectionLane.stats(lane).retained_items == 0
    assert :not_found = ProjectionLane.cancel(metadata, old_token)
    refute_received {:delivered, "old"}

    assert {:ok, new_token} = ProjectionLane.enqueue(metadata, @scope_a, "new")
    assert_receive {:delivered, "new"}
    barrier(replacement)
    assert :not_found = ProjectionLane.cancel(metadata, new_token)
  end

  test "a hung sink is isolated to its fixed shard" do
    parent = self()

    sink = fn _scope, payload ->
      if payload == "slow" do
        send(parent, {:slow, self()})
        receive do: (:release -> :ok)
      else
        send(parent, {:fast, self(), payload})
      end
    end

    {_lane, metadata} = start_lane(capacity: 4, scope_capacity: 1, shards: 2, sink: sink)
    slow_scope = scope_in_shard(metadata, 0)
    fast_scope = scope_in_shard(metadata, 1)

    assert {:ok, _token} = ProjectionLane.enqueue(metadata, slow_scope, "slow")
    assert_receive {:slow, slow_worker}
    assert {:ok, _token} = ProjectionLane.enqueue(metadata, fast_scope, "fast")
    assert_receive {:fast, fast_worker, "fast"}
    refute slow_worker == fast_worker
    send(slow_worker, :release)
  end

  test "normal lane shutdown terminates all fixed workers" do
    {lane, _metadata} = start_lane(shards: 2)
    workers = lane |> ProjectionLane.workers() |> Map.values() |> Enum.map(&elem(&1, 0))
    monitors = Map.new(workers, &{Process.monitor(&1), &1})

    GenServer.stop(lane, :normal)

    for {reference, worker} <- monitors do
      assert_receive {:DOWN, ^reference, :process, ^worker, _reason}
    end
  end

  defp start_lane(overrides) do
    defaults = [
      capacity: 8,
      byte_capacity: 32_768,
      scope_capacity: 2,
      scope_byte_capacity: 8_192,
      shards: 1,
      max_age_ms: 1_000,
      audit_interval_ms: 60_000,
      sink: fn _scope, _payload -> :ok end
    ]

    lane = start_supervised!({ProjectionLane, Keyword.merge(defaults, overrides)})
    {lane, ProjectionLane.metadata(lane)}
  end

  defp worker(lane, shard \\ 0) do
    {worker, _generation} = ProjectionLane.workers(lane)[shard]
    worker
  end

  defp suspend_workers(lane),
    do: Enum.each(ProjectionLane.workers(lane), fn {_shard, {pid, _}} -> suspend(pid) end)

  defp resume_workers(lane),
    do: Enum.each(ProjectionLane.workers(lane), fn {_shard, {pid, _}} -> resume(pid) end)

  defp suspend(process) do
    :erlang.suspend_process(process)
    on_exit(fn -> if Process.alive?(process), do: :erlang.resume_process(process) end)
  end

  defp resume(process) do
    if Process.alive?(process) and :erlang.is_process_alive(process),
      do: :erlang.resume_process(process)
  catch
    :error, :badarg -> :ok
  end

  defp barrier(worker) do
    reference = make_ref()
    send(worker, {:barrier, self(), reference})
    assert_receive {:barrier, ^reference}
  end

  defp scopes_in_distinct_buckets(metadata, count) do
    1..10_000
    |> Enum.reduce_while(%{}, fn index, scopes ->
      scope = {"profile-#{index}", 1}
      {_shard, bucket} = scope_location(metadata, scope)
      scopes = Map.put_new(scopes, bucket, scope)

      if map_size(scopes) == count,
        do: {:halt, Map.values(scopes)},
        else: {:cont, scopes}
    end)
  end

  defp scope_in_shard(metadata, wanted_shard) do
    Enum.find_value(1..10_000, fn index ->
      scope = {"profile-#{index}", 1}
      {shard, _bucket} = scope_location(metadata, scope)
      if shard == wanted_shard, do: scope
    end)
  end

  defp scope_location(metadata, {profile, chain}) do
    normalized = {profile, Integer.to_string(chain)}
    global_bucket = :erlang.phash2(normalized, metadata.shards * metadata.buckets_per_shard)

    {div(global_bucket, metadata.buckets_per_shard),
     rem(global_bucket, metadata.buckets_per_shard)}
  end
end

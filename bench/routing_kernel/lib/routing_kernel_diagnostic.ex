defmodule Lasso.Bench.RoutingKernel.StructuralTrace do
  @moduledoc false

  @snapshot_timeout_ms 5_000

  @ets_reads [
    :first,
    :info,
    :last,
    :lookup,
    :lookup_element,
    :match,
    :match_object,
    :member,
    :next,
    :prev,
    :select,
    :select_count,
    :slot,
    :tab2list
  ]
  @ets_writes [
    :delete,
    :delete_all_objects,
    :delete_object,
    :insert,
    :insert_new,
    :select_delete,
    :select_replace,
    :take,
    :update_counter,
    :update_element
  ]

  def start do
    spawn_link(fn -> loop(empty()) end)
  end

  def configuration do
    %{
      flags: ["call", "procs", "send", "receive", "set_on_spawn"],
      ets_pattern: "{:ets, :_, :_}",
      snapshot_timeout_ms: @snapshot_timeout_ms
    }
  end

  def snapshot(tracer) do
    reference = make_ref()
    send(tracer, {:snapshot, self(), reference})

    receive do
      {:structural_trace_snapshot, ^reference, counters} -> counters
    after
      @snapshot_timeout_ms -> raise "structural trace collector did not respond"
    end
  end

  def stop(tracer), do: send(tracer, :stop)

  defp empty do
    %{
      messages_sent: 0,
      messages_received: 0,
      sends_by_tag: %{},
      receives_by_tag: %{},
      process_spawns: 0,
      process_exits: 0,
      ets_reads: 0,
      ets_writes: 0,
      ets_other: 0,
      ets_by_operation: %{}
    }
  end

  defp loop(counters) do
    receive do
      {:trace, _pid, :send, message, _destination} ->
        loop(count_message(counters, :send, message))

      {:trace, _pid, :send_to_non_existing_process, message, _destination} ->
        loop(count_message(counters, :send, message))

      {:trace, _pid, :receive, message} ->
        loop(count_message(counters, :receive, message))

      {:trace, _pid, :spawn, _child, _mfa} ->
        loop(Map.update!(counters, :process_spawns, &(&1 + 1)))

      {:trace, _pid, :exit, _reason} ->
        loop(Map.update!(counters, :process_exits, &(&1 + 1)))

      {:trace, _pid, :call, {:ets, operation, arguments}} ->
        loop(count_ets(counters, operation, length(arguments)))

      {:snapshot, caller, reference} ->
        send(caller, {:structural_trace_snapshot, reference, counters})
        loop(counters)

      :stop ->
        :ok

      _message ->
        loop(counters)
    end
  end

  defp count_message(counters, direction, message) do
    {total_key, tags_key} =
      case direction do
        :send -> {:messages_sent, :sends_by_tag}
        :receive -> {:messages_received, :receives_by_tag}
      end

    tag = message_tag(message)

    counters
    |> Map.update!(total_key, &(&1 + 1))
    |> Map.update!(tags_key, &Map.update(&1, tag, 1, fn count -> count + 1 end))
  end

  defp count_ets(counters, operation, arity) do
    category =
      cond do
        operation in @ets_reads -> :ets_reads
        operation in @ets_writes -> :ets_writes
        true -> :ets_other
      end

    operation_key = "#{operation}/#{arity}"

    counters
    |> Map.update!(category, &(&1 + 1))
    |> Map.update!(:ets_by_operation, fn operations ->
      Map.update(operations, operation_key, 1, fn count -> count + 1 end)
    end)
  end

  defp message_tag(message) when is_atom(message), do: Atom.to_string(message)

  defp message_tag(message) when is_tuple(message) and tuple_size(message) > 0 do
    case elem(message, 0) do
      tag when is_atom(tag) -> Atom.to_string(tag)
      tag when is_reference(tag) -> "reference_reply"
      _tag -> "tuple_#{tuple_size(message)}"
    end
  end

  defp message_tag(_message), do: "other"
end

defmodule Lasso.Bench.RoutingKernel.ClosedBreakerSuccess do
  @moduledoc false

  alias Lasso.Core.{ProjectionLane, Support.CircuitBreaker}
  alias Lasso.RPC.{AttemptIdentity, AttemptTerminal, ExecutionProjector}

  @profile "routing-kernel-diagnostic"
  @chain_id 1
  @transport :http
  @request_id "routing-kernel-request"
  @attempt_id "routing-kernel-attempt"
  @route_generation 1
  @execution_safety :replay_safe
  @routing_intent "state_read"
  @workload_key "read"
  @candidate_admission_count 1
  @dispatch_count 1
  @prepared_response :prepared_response
  @scope {@profile, @chain_id}
  @timeout_ms 5_000
  @failure_threshold 5
  @recovery_timeout_ms 60_000
  @success_threshold 1
  @lane_capacity 2_048
  @lane_byte_capacity 8_388_608
  @lane_scope_capacity 2_048
  @lane_scope_byte_capacity 8_388_608
  @lane_shards 1
  @lane_max_age_ms 1_000
  @lane_audit_interval_ms 60_000
  @projection_drain_timeout_ms 5_000

  def configuration do
    %{
      timeout_ms: @timeout_ms,
      breaker: %{
        failure_threshold: @failure_threshold,
        recovery_timeout_ms: @recovery_timeout_ms,
        success_threshold: @success_threshold
      },
      projection_lane: %{
        capacity: @lane_capacity,
        byte_capacity: @lane_byte_capacity,
        scope_capacity: @lane_scope_capacity,
        scope_byte_capacity: @lane_scope_byte_capacity,
        shards: @lane_shards,
        max_age_ms: @lane_max_age_ms,
        audit_interval_ms: @lane_audit_interval_ms
      },
      prepared_request: %{
        request_id: @request_id,
        attempt_id: @attempt_id,
        profile: @profile,
        chain_id: @chain_id,
        transport: Atom.to_string(@transport),
        request_budget_ms: @timeout_ms,
        route_generation: @route_generation,
        execution_safety: Atom.to_string(@execution_safety),
        routing_intent: @routing_intent,
        workload_key: @workload_key,
        candidate_admission_count: @candidate_admission_count,
        dispatch_count: @dispatch_count
      },
      prepared_response: Atom.to_string(@prepared_response),
      projection_scope: [@profile, @chain_id],
      projection_drain_timeout_ms: @projection_drain_timeout_ms,
      breaker_id_pattern: "routing-kernel-diagnostic-<run-unique>:http"
    }
  end

  def setup do
    ensure_runtime!()
    suffix = System.unique_integer([:positive])
    breaker_id = {"routing-kernel-diagnostic-#{suffix}", @transport}

    {:ok, breaker} =
      CircuitBreaker.start_link(
        {breaker_id,
         %{
           failure_threshold: @failure_threshold,
           recovery_timeout: @recovery_timeout_ms,
           success_threshold: @success_threshold
         }}
      )

    delivered = :atomics.new(1, signed: false)
    handoffs = :atomics.new(2, signed: false)

    {:ok, lane} =
      ProjectionLane.start_link(
        capacity: @lane_capacity,
        byte_capacity: @lane_byte_capacity,
        scope_capacity: @lane_scope_capacity,
        scope_byte_capacity: @lane_scope_byte_capacity,
        shards: @lane_shards,
        max_age_ms: @lane_max_age_ms,
        audit_interval_ms: @lane_audit_interval_ms,
        sink: fn _scope, _payload -> :atomics.add(delivered, 1, 1) end
      )

    identity =
      AttemptIdentity.new(
        request_id: @request_id,
        attempt_id: @attempt_id,
        profile: @profile,
        chain_id: @chain_id,
        upstream_instance_id: elem(breaker_id, 0),
        transport: @transport,
        route_generation: @route_generation,
        circuit_scope: :broad,
        circuit_epoch: 1,
        execution_safety: @execution_safety,
        routing_intent: @routing_intent,
        workload_key: @workload_key,
        request_budget_ms: @timeout_ms,
        candidate_admission_count: @candidate_admission_count,
        dispatch_count: @dispatch_count
      )

    %{
      breaker: breaker,
      breaker_id: breaker_id,
      lane: lane,
      lane_metadata: ProjectionLane.metadata(lane),
      identity: identity,
      delivered: delivered,
      handoffs: handoffs
    }
  end

  def teardown(state) do
    if Process.alive?(state.lane), do: GenServer.stop(state.lane)
    if Process.alive?(state.breaker), do: GenServer.stop(state.breaker)
    :ok
  end

  def run_once(state, :timed) do
    owner = self()
    reference = make_ref()
    started_us = System.monotonic_time(:microsecond)

    result =
      CircuitBreaker.call(state.breaker_id, &prepared_success/0, @timeout_ms,
        deadline_us: started_us + @timeout_ms * 1_000,
        on_dispatch: fn dispatched_at_us ->
          send(owner, {:routing_kernel_dispatch, reference, dispatched_at_us})
        end,
        on_terminal: fn terminal_result, elapsed_ms ->
          decided_at_us = System.monotonic_time(:microsecond)
          enqueue_projection(state, terminal_result, elapsed_ms)
          send(owner, {:routing_kernel_decision, reference, decided_at_us})
        end
      )

    finished_us = System.monotonic_time(:microsecond)
    dispatched_at_us = receive_stamp!(:routing_kernel_dispatch, reference)
    decided_at_us = receive_stamp!(:routing_kernel_decision, reference)
    assert_success!(result)

    %{
      local_total_us: finished_us - started_us,
      local_pre_dispatch_us: dispatched_at_us - started_us,
      synthetic_dispatch_to_decision_us: decided_at_us - dispatched_at_us,
      local_post_decision_us: finished_us - decided_at_us
    }
  end

  def run_once(state, :counter) do
    owner = self()
    reference = make_ref()

    attempt = fn ->
      result = prepared_success()
      checkpoint = process_checkpoint()
      send(owner, {:routing_kernel_task_checkpoint, reference, checkpoint})
      result
    end

    result =
      CircuitBreaker.call(state.breaker_id, attempt, @timeout_ms,
        on_dispatch: fn dispatched_at_us ->
          send(owner, {:routing_kernel_dispatch, reference, dispatched_at_us})
        end,
        on_terminal: fn terminal_result, elapsed_ms ->
          enqueue_projection(state, terminal_result, elapsed_ms)
          checkpoint = process_checkpoint()
          send(owner, {:routing_kernel_lifecycle_checkpoint, reference, checkpoint})
        end
      )

    _dispatched_at_us = receive_stamp!(:routing_kernel_dispatch, reference)
    task = receive_checkpoint!(:routing_kernel_task_checkpoint, reference)
    lifecycle = receive_checkpoint!(:routing_kernel_lifecycle_checkpoint, reference)
    assert_success!(result)
    %{task: task, lifecycle: lifecycle}
  end

  def run_once(state, :structural) do
    owner = self()
    reference = make_ref()

    result =
      CircuitBreaker.call(state.breaker_id, &prepared_success/0, @timeout_ms,
        on_dispatch: fn dispatched_at_us ->
          send(owner, {:routing_kernel_dispatch, reference, dispatched_at_us})
        end,
        on_terminal: fn terminal_result, elapsed_ms ->
          enqueue_projection(state, terminal_result, elapsed_ms)
        end
      )

    _dispatched_at_us = receive_stamp!(:routing_kernel_dispatch, reference)
    assert_success!(result)
    :ok
  end

  def projection_deliveries(state), do: :atomics.get(state.delivered, 1)

  def projection_handoffs(state) do
    %{accepted: :atomics.get(state.handoffs, 1), dropped: :atomics.get(state.handoffs, 2)}
  end

  def await_projection_idle!(state) do
    await_projection_idle!(
      state,
      System.monotonic_time(:millisecond) + @projection_drain_timeout_ms
    )
  end

  defp prepared_success, do: {:ok, @prepared_response, 0}

  defp enqueue_projection(state, {:ok, @prepared_response, _io_ms}, elapsed_ms) do
    terminal =
      AttemptTerminal.Response.new(
        state.identity,
        :success,
        elapsed_ms |> Kernel.*(1_000) |> round()
      )

    %ExecutionProjector{recommended_action: :return_response} =
      ExecutionProjector.project(terminal)

    case ProjectionLane.enqueue_fact(state.lane_metadata, @scope, terminal) do
      {:ok, _token} -> :atomics.add(state.handoffs, 1, 1)
      {:coalesced, _token, _degradation} -> :atomics.add(state.handoffs, 1, 1)
      {:drop, _reason, _degradation} -> :atomics.add(state.handoffs, 2, 1)
    end

    :ok
  end

  defp enqueue_projection(_state, result, _elapsed_ms),
    do: raise("unexpected terminal result: #{inspect(result)}")

  defp receive_stamp!(tag, reference) do
    receive do
      {^tag, ^reference, stamp} -> stamp
    after
      @timeout_ms -> raise "missing #{tag} timestamp"
    end
  end

  defp receive_checkpoint!(tag, reference) do
    receive do
      {^tag, ^reference, checkpoint} -> checkpoint
    after
      @timeout_ms -> raise "missing #{tag} checkpoint"
    end
  end

  defp process_checkpoint do
    info =
      self()
      |> Process.info([:reductions, :total_heap_size, :heap_size, :memory, :garbage_collection])
      |> Map.new()

    %{
      reductions: info.reductions,
      total_heap_words: info.total_heap_size,
      heap_words: info.heap_size,
      memory_bytes: info.memory,
      minor_gcs: Keyword.fetch!(info.garbage_collection, :minor_gcs)
    }
  end

  defp assert_success!({:executed, {:ok, @prepared_response, 0}}), do: :ok
  defp assert_success!(result), do: raise("unexpected routing-kernel result: #{inspect(result)}")

  defp await_projection_idle!(state, deadline_ms) do
    case ProjectionLane.stats(state.lane) do
      %{retained_items: 0} ->
        :ok

      stats ->
        if System.monotonic_time(:millisecond) < deadline_ms do
          Process.sleep(1)
          await_projection_idle!(state, deadline_ms)
        else
          raise "projection lane did not drain: #{inspect(stats)}"
        end
    end
  end

  defp ensure_runtime! do
    ensure_registry!()
    ensure_instance_state_table!()

    tables = [
      :lasso_circuit_breaker_snapshots,
      :lasso_circuit_breaker_leases,
      :lasso_circuit_breaker_control,
      :lasso_circuit_breaker_control_meta
    ]

    case Enum.count(tables, &(:ets.whereis(&1) != :undefined)) do
      0 -> Lasso.Core.Support.CircuitBreaker.Storage.create_tables!()
      4 -> :ok
      _count -> raise "circuit-breaker ETS runtime is only partially initialized"
    end
  end

  defp ensure_instance_state_table! do
    if :ets.whereis(:lasso_instance_state) == :undefined do
      :ets.new(:lasso_instance_state, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])
    end

    :ok
  end

  defp ensure_registry! do
    case Process.whereis(Lasso.Registry) do
      nil ->
        {:ok, _registry} =
          Registry.start_link(
            keys: :unique,
            name: Lasso.Registry,
            partitions: System.schedulers_online()
          )

        :ok

      _pid ->
        :ok
    end
  end
end

defmodule Lasso.Bench.RoutingKernel.Runner do
  @moduledoc false

  alias Lasso.Bench.RoutingKernel.{ClosedBreakerSuccess, StructuralTrace}

  @schema "lasso.routing-kernel-diagnostic"
  @schema_version 1
  @configuration_version 1
  @default_iterations 1_000
  @default_warmup 100
  @default_structural_iterations 100
  @maximum_iterations 1_000
  @worker_timeout_ms 60_000
  @structural_timeout_ms 30_000
  @trace_barrier_timeout_ms 5_000

  def main(arguments) do
    arguments
    |> parse_arguments!()
    |> run()
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  def run(options \\ []) do
    iterations = bounded!(options, :iterations, @default_iterations)
    warmup = bounded_non_negative!(options, :warmup, @default_warmup)

    structural_iterations =
      bounded!(
        options,
        :structural_iterations,
        min(iterations, @default_structural_iterations)
      )

    state = ClosedBreakerSuccess.setup()

    try do
      counter = counter_pass(state, iterations, warmup)
      timing = timing_pass(state, iterations, warmup)
      structural = structural_pass(state, structural_iterations, warmup)

      %{
        schema: @schema,
        schema_version: @schema_version,
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        claim_scope: "diagnostic_only",
        layer: %{
          id: 1,
          name: "routing_kernel",
          implemented: true,
          scenario: "closed_breaker_prepared_success"
        },
        extension_layers: [
          %{
            id: 2,
            name: "equal_semantics_proxy",
            implemented: false,
            required_boundary: "raw HTTP with matched validation, capacity, and timeouts"
          },
          %{
            id: 3,
            name: "production_union",
            implemented: false,
            required_boundary: "profiles, failures, projections, Cloud work, and multiple nodes"
          }
        ],
        revision: revision(),
        runtime: runtime(),
        configuration: configuration(iterations, warmup, structural_iterations),
        fixture: fixture(),
        measurements: %{
          counter: counter,
          timing: timing,
          structural: structural
        },
        validity: %{
          launch_acceptance_eligible: false,
          erpc_comparison_eligible: false,
          transport_claim_eligible: false,
          reasons: [
            "synthetic prepared response; no JSON or socket work",
            "developer-machine microdiagnostic without fixed-resource isolation",
            "request-tree accounting excludes asynchronous breaker and projection consumer work",
            "ERTS does not expose cumulative allocated or reclaimed words for this process tree"
          ]
        }
      }
    after
      ClosedBreakerSuccess.teardown(state)
    end
  end

  defp counter_pass(state, iterations, warmup) do
    in_worker(fn ->
      warm_worker!(state, :counter, warmup, "counter warmup")
      projection_before = projection_snapshot(state)
      owner_before = owner_checkpoint()

      child_totals =
        Enum.reduce(1..iterations, empty_child_totals(), fn _index, totals ->
          state
          |> ClosedBreakerSuccess.run_once(:counter)
          |> add_child_checkpoints(totals)
        end)

      owner_after = owner_checkpoint()
      projection = finish_projection_window!(state, projection_before, iterations, "counter")

      %{
        iterations: iterations,
        successful_iterations: iterations,
        attribution_scope: "synchronous_request_process_tree_checkpoints",
        asynchronous_breaker_owner_included: false,
        asynchronous_projection_worker_included: false,
        projection: projection,
        reductions: reduction_counters(owner_before, owner_after, child_totals, iterations),
        garbage_collections:
          garbage_collection_counters(owner_before, owner_after, child_totals, iterations),
        word_accounting: word_accounting(owner_before, owner_after, child_totals, iterations)
      }
    end)
  end

  defp timing_pass(state, iterations, warmup) do
    in_worker(fn ->
      warm_worker!(state, :timed, warmup, "timing warmup")
      projection_before = projection_snapshot(state)

      samples =
        Enum.map(1..iterations, fn _index ->
          ClosedBreakerSuccess.run_once(state, :timed)
        end)

      projection = finish_projection_window!(state, projection_before, iterations, "timing")

      %{
        iterations: iterations,
        successful_iterations: length(samples),
        projection: projection,
        instrumentation: %{
          dispatch_stamp_message_per_success: 1,
          decision_stamp_message_per_success: 1,
          timestamp_unit: "microsecond",
          disclosed_effect: "timing includes both instrumentation messages"
        },
        local_timing_us: summarize_timings(samples)
      }
    end)
  end

  defp structural_pass(state, iterations, warmup) do
    tracer = StructuralTrace.start()

    worker =
      spawn(fn ->
        receive do
          {:warm_structural, caller} ->
            warm_worker!(state, :structural, warmup, "structural warmup")
            send(caller, {:structural_warm, self()})

            receive do
              {:run_structural, ^caller} ->
                Enum.each(1..iterations, fn _index ->
                  ClosedBreakerSuccess.run_once(state, :structural)
                end)

                send(caller, {:structural_complete, self()})
            end
        end
      end)

    try do
      send(worker, {:warm_structural, self()})

      receive do
        {:structural_warm, ^worker} -> :ok
      after
        @structural_timeout_ms -> raise "structural diagnostic warmup timed out"
      end

      projection_before = projection_snapshot(state)
      1 = :erlang.trace_pattern({:ets, :_, :_}, true, [:local]) |> normalize_trace_pattern!()

      1 =
        :erlang.trace(worker, true, [
          :call,
          :procs,
          :send,
          :receive,
          :set_on_spawn,
          {:tracer, tracer}
        ])

      send(worker, {:run_structural, self()})

      receive do
        {:structural_complete, ^worker} -> :ok
      after
        @structural_timeout_ms -> raise "structural diagnostic timed out"
      end

      await_trace_delivery!()
      raw = StructuralTrace.snapshot(tracer)
      projection = finish_projection_window!(state, projection_before, iterations, "structural")

      %{
        iterations: iterations,
        attribution_scope: "request_owner_process_tree",
        asynchronous_breaker_owner_included: false,
        asynchronous_projection_worker_included: false,
        projection: projection,
        harness_messages: %{sent: 1, received: 1},
        messages: %{
          sent: max(raw.messages_sent - 1, 0),
          received: max(raw.messages_received - 1, 0),
          sent_per_success: per_iteration(raw.messages_sent - 1, iterations),
          received_per_success: per_iteration(raw.messages_received - 1, iterations),
          sent_by_tag_raw: raw.sends_by_tag,
          received_by_tag_raw: raw.receives_by_tag
        },
        process_spawns: %{
          total: raw.process_spawns,
          per_success: per_iteration(raw.process_spawns, iterations),
          exits_observed: raw.process_exits
        },
        ets: %{
          reads: raw.ets_reads,
          writes: raw.ets_writes,
          other: raw.ets_other,
          total: raw.ets_reads + raw.ets_writes + raw.ets_other,
          reads_per_success: per_iteration(raw.ets_reads, iterations),
          writes_per_success: per_iteration(raw.ets_writes, iterations),
          other_per_success: per_iteration(raw.ets_other, iterations),
          by_operation: raw.ets_by_operation
        }
      }
    after
      if Process.alive?(worker), do: :erlang.trace(worker, false, [:all])
      :erlang.trace_pattern({:ets, :_, :_}, false, [:local])
      if Process.alive?(worker), do: Process.exit(worker, :kill)
      if Process.alive?(tracer), do: StructuralTrace.stop(tracer)
    end
  end

  defp in_worker(fun) do
    parent = self()
    {worker, monitor} = spawn_monitor(fn -> send(parent, {:worker_result, self(), fun.()}) end)

    receive do
      {:worker_result, ^worker, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        raise "diagnostic worker exited: #{inspect(reason)}"
    after
      @worker_timeout_ms -> raise "diagnostic worker timed out"
    end
  end

  defp owner_checkpoint do
    info =
      self()
      |> Process.info([
        :reductions,
        :total_heap_size,
        :heap_size,
        :memory,
        :message_queue_len,
        :garbage_collection
      ])
      |> Map.new()

    %{
      reductions: info.reductions,
      total_heap_words: info.total_heap_size,
      heap_words: info.heap_size,
      memory_bytes: info.memory,
      message_queue_len: info.message_queue_len,
      minor_gcs: Keyword.fetch!(info.garbage_collection, :minor_gcs)
    }
  end

  defp empty_child_totals do
    empty = %{reductions: 0, total_heap_words: 0, heap_words: 0, memory_bytes: 0, minor_gcs: 0}
    %{task: empty, lifecycle: empty}
  end

  defp add_child_checkpoints(%{task: task, lifecycle: lifecycle}, totals) do
    %{
      task: sum_checkpoint(totals.task, task),
      lifecycle: sum_checkpoint(totals.lifecycle, lifecycle)
    }
  end

  defp sum_checkpoint(total, checkpoint) do
    Map.new(total, fn {key, value} -> {key, value + Map.fetch!(checkpoint, key)} end)
  end

  defp reduction_counters(owner_before, owner_after, children, iterations) do
    owner = owner_after.reductions - owner_before.reductions
    checkpointed_total = owner + children.lifecycle.reductions + children.task.reductions

    %{
      measurement: "synchronous_process_info_checkpoints",
      checkpointed_total: checkpointed_total,
      checkpointed_per_success: per_iteration(checkpointed_total, iterations),
      components: %{
        request_owner: owner,
        compatibility_lifecycle: children.lifecycle.reductions,
        transport_task: children.task.reductions
      },
      checkpoint_boundaries: %{
        request_owner: "after warmup through all measured completions",
        compatibility_lifecycle: "after terminal projection, before final owner reply and exit",
        transport_task: "after prepared result construction, before result handoff and exit"
      },
      instrumentation: %{
        task_checkpoint_message_per_success: 1,
        lifecycle_checkpoint_message_per_success: 1,
        disclosed_effect: "checkpoint collection is included in request-owner reductions"
      }
    }
  end

  defp garbage_collection_counters(owner_before, owner_after, children, iterations) do
    owner_minor_gcs = owner_after.minor_gcs - owner_before.minor_gcs
    total_minor_gcs = owner_minor_gcs + children.lifecycle.minor_gcs + children.task.minor_gcs

    %{
      measurement: "process_info_minor_gc_checkpoints",
      forced_collections_in_measured_window: 0,
      minor_gcs: %{
        total: total_minor_gcs,
        per_success: per_iteration(total_minor_gcs, iterations),
        components: %{
          request_owner: owner_minor_gcs,
          compatibility_lifecycle: children.lifecycle.minor_gcs,
          transport_task: children.task.minor_gcs
        }
      },
      gc_time: %{available: false, reason: "no attributable process-tree GC-time counter"}
    }
  end

  defp word_accounting(owner_before, owner_after, children, iterations) do
    %{
      allocated_words: %{
        available: false,
        reason: "ERTS exposes no cumulative allocated-word counter for an arbitrary process tree"
      },
      reclaimed_words: %{
        available: false,
        reason: "VM-global reclaimed words would mix asynchronous consumer work"
      },
      live_heap_checkpoints: %{
        measurement: "process_info_live_heap_capacity_not_cumulative_allocation",
        request_owner: %{
          total_heap_words_before: owner_before.total_heap_words,
          total_heap_words_after: owner_after.total_heap_words,
          total_heap_words_delta: owner_after.total_heap_words - owner_before.total_heap_words,
          heap_words_before: owner_before.heap_words,
          heap_words_after: owner_after.heap_words,
          memory_bytes_delta: owner_after.memory_bytes - owner_before.memory_bytes,
          final_message_queue_len: owner_after.message_queue_len
        },
        compatibility_lifecycle: live_checkpoint_summary(children.lifecycle, iterations),
        transport_task: live_checkpoint_summary(children.task, iterations)
      }
    }
  end

  defp live_checkpoint_summary(component, iterations) do
    %{
      terminal_total_heap_words_sum: component.total_heap_words,
      terminal_total_heap_words_mean: per_iteration(component.total_heap_words, iterations),
      terminal_heap_words_sum: component.heap_words,
      terminal_heap_words_mean: per_iteration(component.heap_words, iterations),
      terminal_memory_bytes_sum: component.memory_bytes,
      terminal_memory_bytes_mean: per_iteration(component.memory_bytes, iterations)
    }
  end

  defp warm_worker!(state, mode, warmup, label) do
    before = projection_snapshot(state)
    Enum.each(1..warmup//1, fn _index -> ClosedBreakerSuccess.run_once(state, mode) end)
    _projection = finish_projection_window!(state, before, warmup, label)
    :ok
  end

  defp projection_snapshot(state) do
    %{
      deliveries: ClosedBreakerSuccess.projection_deliveries(state),
      handoffs: ClosedBreakerSuccess.projection_handoffs(state)
    }
  end

  defp finish_projection_window!(state, before, expected, label) do
    after_handoffs = ClosedBreakerSuccess.projection_handoffs(state)

    handoffs = %{
      accepted: after_handoffs.accepted - before.handoffs.accepted,
      dropped: after_handoffs.dropped - before.handoffs.dropped
    }

    if handoffs.dropped != 0 or handoffs.accepted != expected do
      raise "#{label} projection handoff mismatch: #{inspect(handoffs)}"
    end

    ClosedBreakerSuccess.await_projection_idle!(state)
    deliveries = ClosedBreakerSuccess.projection_deliveries(state) - before.deliveries

    if deliveries != expected,
      do: raise("#{label} projection delivery mismatch: #{deliveries}/#{expected}")

    %{handoffs: handoffs, deliveries_observed: deliveries}
  end

  defp summarize_timings(samples) do
    samples
    |> hd()
    |> Map.keys()
    |> Map.new(fn key ->
      values = Enum.map(samples, &Map.fetch!(&1, key))
      {key, summary(values)}
    end)
  end

  defp summary(values) do
    sorted = Enum.sort(values)

    %{
      min: hd(sorted),
      mean: Enum.sum(sorted) / length(sorted),
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95),
      p99: percentile(sorted, 0.99),
      max: List.last(sorted)
    }
  end

  defp percentile(sorted, quantile) do
    index = max(ceil(length(sorted) * quantile) - 1, 0)
    Enum.at(sorted, index)
  end

  defp fixture do
    %{
      prepared_request: true,
      prepared_response: true,
      response_value: "prepared_response",
      included: [
        "closed-breaker admission",
        "compatibility lifecycle ownership",
        "one synthetic transport task",
        "breaker success reporting",
        "terminal fact construction and canonical projection",
        "bounded projection-lane enqueue"
      ],
      excluded: [
        "candidate listing and route-plan ranking",
        "request parsing and encoding",
        "response parsing and validation",
        "HTTP and WebSocket I/O",
        "Finch pool admission",
        "downstream response delivery",
        "asynchronous breaker-owner work",
        "asynchronous projection-sink work",
        "Cloud authentication and metering"
      ],
      fast_path_invariant_under_test: %{
        target_request_lifecycle_owners: 1,
        route_generations: 1,
        prepared_requests: 1,
        validation_passes: 0,
        distributed_operations: 0
      },
      known_compatibility_deviations: [
        "one additional lifecycle process between the request owner and transport task"
      ]
    }
  end

  defp configuration(iterations, warmup, structural_iterations) do
    %{
      version: @configuration_version,
      cli: %{
        iterations: iterations,
        warmup_iterations_per_worker: warmup,
        structural_iterations: structural_iterations,
        maximum_iterations_per_pass: @maximum_iterations
      },
      scenario: ClosedBreakerSuccess.configuration(),
      measurement: %{
        counter_attribution: "synchronous request-process-tree checkpoints",
        structural_attribution: "request-owner process tree with set_on_spawn",
        asynchronous_consumers: "excluded after bounded handoff",
        forced_gc_in_measured_windows: false,
        timing_clock: "System.monotonic_time(:microsecond)",
        timing_instrumentation_messages_per_success: 2,
        structural_trace: StructuralTrace.configuration(),
        worker_timeout_ms: @worker_timeout_ms,
        structural_timeout_ms: @structural_timeout_ms,
        trace_barrier_timeout_ms: @trace_barrier_timeout_ms,
        output_destination: "stdout"
      }
    }
  end

  defp revision do
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true)
    {status, 0} = System.cmd("git", ["status", "--porcelain"], stderr_to_stdout: true)

    %{
      commit: String.trim(commit),
      dirty: String.trim(status) != "",
      benchmark_revision: System.get_env("LASSO_BENCHMARK_REVISION") || "working-tree"
    }
  end

  defp runtime do
    %{
      elixir: System.version(),
      otp_release: System.otp_release(),
      erts: :erlang.system_info(:version) |> List.to_string(),
      architecture: :erlang.system_info(:system_architecture) |> List.to_string(),
      schedulers: System.schedulers(),
      schedulers_online: System.schedulers_online(),
      dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers),
      dirty_io_schedulers: :erlang.system_info(:dirty_io_schedulers),
      lasso_application_started: application_started?(:lasso),
      word_size_bytes: :erlang.system_info(:wordsize)
    }
  end

  defp application_started?(application) do
    Enum.any?(Application.started_applications(), fn {name, _description, _version} ->
      name == application
    end)
  end

  defp parse_arguments!(arguments) do
    arguments = if List.first(arguments) == "--", do: tl(arguments), else: arguments

    {options, rest, invalid} =
      OptionParser.parse(arguments,
        strict: [iterations: :integer, warmup: :integer, structural_iterations: :integer]
      )

    if rest != [] or invalid != [],
      do: raise(ArgumentError, "invalid arguments: #{inspect(rest ++ invalid)}")

    options
  end

  defp bounded!(options, key, default) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value > 0 and value <= @maximum_iterations ->
        value

      value ->
        raise ArgumentError,
              "#{key} must be between 1 and #{@maximum_iterations}, got: #{inspect(value)}"
    end
  end

  defp bounded_non_negative!(options, key, default) do
    case Keyword.get(options, key, default) do
      value when is_integer(value) and value >= 0 and value <= @maximum_iterations ->
        value

      value ->
        raise ArgumentError,
              "#{key} must be between 0 and #{@maximum_iterations}, got: #{inspect(value)}"
    end
  end

  defp normalize_trace_pattern!(count) when is_integer(count) and count > 0, do: 1

  defp normalize_trace_pattern!(count),
    do: raise("ETS call tracing is unavailable: #{inspect(count)}")

  defp await_trace_delivery! do
    reference = :erlang.trace_delivered(:all)

    receive do
      {:trace_delivered, :all, ^reference} -> :ok
    after
      @trace_barrier_timeout_ms -> raise "trace delivery barrier timed out"
    end
  end

  defp per_iteration(value, iterations), do: value / iterations
end

defmodule Lasso.Bench.RoutingKernelDiagnosticTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  Code.require_file(
    "../../../bench/routing_kernel/lib/routing_kernel_diagnostic.ex",
    __DIR__
  )

  alias Lasso.Bench.RoutingKernel.Runner

  test "emits an explicitly diagnostic Layer 1 result with attributable counters" do
    result = Runner.run(iterations: 4, warmup: 1, structural_iterations: 3)

    assert result.schema == "lasso.routing-kernel-diagnostic"
    assert result.schema_version == 1
    assert result.claim_scope == "diagnostic_only"

    assert result.layer == %{
             id: 1,
             implemented: true,
             name: "routing_kernel",
             scenario: "closed_breaker_prepared_success"
           }

    refute result.validity.launch_acceptance_eligible
    refute result.validity.erpc_comparison_eligible
    refute result.validity.transport_claim_eligible
    assert result.configuration.version == 1
    assert result.configuration.cli.maximum_iterations_per_pass == 1_000
    assert result.configuration.scenario.projection_lane.capacity == 2_048
    refute result.configuration.measurement.forced_gc_in_measured_windows

    counter = result.measurements.counter
    assert counter.iterations == 4
    assert counter.successful_iterations == 4
    assert counter.projection.deliveries_observed == 4
    assert counter.projection.handoffs == %{accepted: 4, dropped: 0}
    assert counter.reductions.checkpointed_total > 0
    assert counter.reductions.components.compatibility_lifecycle > 0
    assert counter.garbage_collections.forced_collections_in_measured_window == 0
    refute counter.word_accounting.allocated_words.available
    refute counter.word_accounting.reclaimed_words.available

    timing = result.measurements.timing
    assert timing.iterations == 4
    assert timing.successful_iterations == 4
    assert timing.projection.deliveries_observed == 4
    assert timing.projection.handoffs == %{accepted: 4, dropped: 0}
    assert timing.instrumentation.decision_stamp_message_per_success == 1
    assert timing.local_timing_us.local_total_us.max >= 0

    structural = result.measurements.structural
    assert structural.iterations == 3
    assert structural.attribution_scope == "request_owner_process_tree"
    assert structural.projection.handoffs == %{accepted: 3, dropped: 0}
    assert structural.process_spawns.total == 6
    assert structural.messages.sent > 0
    assert structural.messages.received > 0
    assert structural.messages.sent_by_tag_raw["run_attempt"] == 3
    assert structural.messages.sent_by_tag_raw["attempt_task_result"] == 3
    assert structural.messages.sent_by_tag_raw["routing_kernel_dispatch"] == 3
    assert structural.ets.reads in [15, 18]
    assert structural.ets.writes == 3
    assert structural.ets.other == 0
    assert structural.ets.by_operation["insert_new/2"] == 3
    assert structural.ets.by_operation["lookup_element/4"] == 3
    assert structural.ets.by_operation["lookup/2"] in [12, 15]
    assert structural.ets.total == structural.ets.reads + structural.ets.writes
  end

  test "rejects invalid diagnostic sizes" do
    assert_raise ArgumentError, fn -> Runner.run(iterations: 0) end
    assert_raise ArgumentError, fn -> Runner.run(iterations: 1_001) end
    assert_raise ArgumentError, fn -> Runner.run(warmup: -1) end
    assert_raise ArgumentError, fn -> Runner.run(structural_iterations: 0) end
  end

  test "main emits exactly one JSON document after compilation" do
    output =
      capture_io(fn ->
        Runner.main([
          "--iterations",
          "2",
          "--warmup",
          "1",
          "--structural-iterations",
          "1"
        ])
      end)

    assert %{
             "schema" => "lasso.routing-kernel-diagnostic",
             "measurements" => %{
               "counter" => %{"successful_iterations" => 2},
               "timing" => %{"successful_iterations" => 2},
               "structural" => %{"iterations" => 1}
             }
           } = Jason.decode!(output)
  end
end

[
  # =============================================================================
  # Mix Tasks - Known false positives
  # =============================================================================
  # Mix.shell/0 is available at runtime but Dialyzer doesn't see it
  ~r"lib/mix/tasks/.*",

  # =============================================================================
  # Opaque Type Internals
  # =============================================================================
  # MapSet internal representation - false positive from strict opaque checking
  ~r"lib/lasso/core/support/dedupe_cache.ex.*contract_with_opaque",
  ~r"lib/lasso/core/streaming/stream_state.ex.*contract_with_opaque",

  # =============================================================================
  # Known False Positives
  # =============================================================================
  # BenchmarkStore function handles all cases correctly despite warning
  ~r"lib/lasso/core/benchmarking/benchmark_store_adapter.ex.*no_return"
]

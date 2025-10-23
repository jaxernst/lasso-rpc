[
  # Opaque type internals - MapSet internal representation
  # This is a false positive from Dialyzer's strict checking of opaque types
  ~r"lib/lasso/core/support/dedupe_cache.ex:30.*contract_with_opaque",
  ~r"lib/lasso/core/streaming/stream_state.ex:22.*contract_with_opaque",

  # MockProvider is test-only utility with intentional type flexibility
  ~r"lib/lasso_battle/mock_provider.ex:91.*call",
  ~r"lib/lasso_battle/mock_provider.ex:78.*no_return",

  # BenchmarkStore function handles all cases correctly despite warning
  ~r"lib/lasso/core/benchmarking/benchmark_store_adapter.ex:117.*no_return"

  # Compile-time environment check - pattern matching is intentional
  # When compiled in dev/prod, :test pattern can never match (by design)
]

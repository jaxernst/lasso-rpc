[
  # Opaque type internals - MapSet internal representation
  # This is a false positive from Dialyzer's strict checking of opaque types
  ~r"lib/lasso/core/support/dedupe_cache.ex:30.*contract_with_opaque",
  ~r"lib/lasso/core/streaming/stream_state.ex:22.*contract_with_opaque",

  # MockProvider is test-only utility with intentional type flexibility
  ~r"lib/lasso_battle/mock_provider.ex:91.*call",
  ~r"lib/lasso_battle/mock_provider.ex:78.*no_return",
  ~r"lib/lasso_battle/mock_provider.ex:195.*unused_fun",

  # BenchmarkStore function handles all cases correctly despite warning
  ~r"lib/lasso/core/benchmarking/benchmark_store_adapter.ex:117.*no_return",

  # Compile-time environment check - pattern matching is intentional
  # When compiled in dev/prod, :test pattern can never match (by design)
  ~r"lib/lasso/application.ex:113.*pattern_match",

  # Test helper pattern match coverage - all cases are handled correctly
  ~r"lib/lasso/testing/integration_helper.ex:369.*pattern_match_cov",
  ~r"lib/lasso/testing/mock_http_provider.ex:206.*pattern_match_cov",

  # TelemetrySync test utility - specs are intentionally broader for test flexibility
  ~r"lib/lasso/testing/telemetry_sync.ex:83.*invalid_contract",
  ~r"lib/lasso/testing/telemetry_sync.ex:187.*invalid_contract",
  ~r"lib/lasso/testing/telemetry_sync.ex:189.*no_return"
]

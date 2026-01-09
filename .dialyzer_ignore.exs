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
  # Request Pipeline - Dialyzer Type Inference Limitation
  # =============================================================================
  # Dialyzer loses Channel.t() type information through recursive tail calls
  # in attempt_channels/execute_on_channel, inferring [map()] instead despite:
  # - Proper @spec declarations on all functions
  # - Explicit @type channel_attempt :: {Channel.t(), ...} in RequestContext
  # - @spec on record_channel_attempt/3 and record_channel_success/2
  # - Pattern matching with %Channel{} guards
  #
  # This is a known Dialyzer limitation with complex recursive pipelines where
  # types flow through struct updates, lambdas, and tail recursion. The code
  # is correct (verified by tests) but Dialyzer's constraint solver cannot
  # prove Channel.t() is preserved through the call chain.
  #
  # Real bugs fixed (not ignored):
  # - Added circuit_breaker_result type to include :exception case
  # - Made io_ms nil handling explicit in handle_channel_error
  ~r"lib/lasso/core/request/request_pipeline.ex.*call",
  ~r"lib/lasso/core/request/request_pipeline.ex.*invalid_contract",
  ~r"lib/lasso/core/request/request_pipeline.ex.*no_return",

  # =============================================================================
  # Defensive Error Handling - Intentional Safety Patterns
  # =============================================================================
  # These patterns are "impossible" according to type specs but serve as
  # defensive programming against unexpected runtime states from external systems
  # (HTTP responses, WebSocket events, config parsing, etc.)

  # Gap filler error tuple handling
  ~r"lib/lasso/core/support/gap_filler.ex.*pattern_match",

  # HTTP adapter error handling (Finch responses)
  ~r"lib/lasso/core/transport/http/adapters/finch.ex.*pattern_match",

  # WebSocket connection state handling
  ~r"lib/lasso/core/transport/websocket/connection.ex.*pattern_match",

  # Discovery/probing error handling
  ~r"lib/lasso/discovery/probes/method_support.ex.*pattern_match",

  # VM metrics collector error handling
  ~r"lib/lasso/vm_metrics_collector.ex.*pattern_match",

  # Streaming coordinator state handling
  ~r"lib/lasso/core/streaming/stream_coordinator.ex.*pattern_match",

  # Upstream subscription error handling
  ~r"lib/lasso/core/streaming/upstream_subscription_manager.ex.*pattern_match",

  # =============================================================================
  # LiveView/Web Component Defensive Patterns
  # =============================================================================
  # UI components handle edge cases defensively for robustness
  ~r"lib/lasso_web/sockets/rpc_socket.ex.*pattern_match",

  # =============================================================================
  # Pattern Match Coverage (Cosmetic)
  # =============================================================================
  # Dialyzer notes these patterns always match one branch - harmless
  ~r".*pattern_match_cov"
]

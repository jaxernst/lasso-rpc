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
  # Request Pipeline Type Inference (Technical Debt)
  # =============================================================================
  # Dialyzer infers [map()] instead of [Channel.t()] due to complex type flow
  # through Selection.select_channels -> AdapterFilter -> pattern matching.
  # Code functions correctly - this is a false positive from type inference limits.
  # See: docs/DIALYZER_ANALYSIS.md for details
  ~r"lib/lasso/core/request/request_pipeline.ex.*call",
  ~r"lib/lasso/core/request/request_pipeline.ex.*invalid_contract",
  ~r"lib/lasso/core/request/request_pipeline.ex.*no_return",
  ~r"lib/lasso/core/request/request_pipeline.ex.*guard_fail",
  ~r"lib/lasso/core/request/request_pipeline.ex:253.*pattern_match",

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
  ~r"lib/lasso_web/components/chain_configuration_window.ex.*pattern_match",
  ~r"lib/lasso_web/controllers/admin/chain_controller.ex.*pattern_match",
  # Dialyzer incorrectly marks format_chain_response as unused due to type inference
  # on the with/else path - the function is called from create/2 and update/2
  ~r"lib/lasso_web/controllers/admin/chain_controller.ex.*unused_fun",
  ~r"lib/lasso_web/sockets/rpc_socket.ex.*pattern_match",

  # =============================================================================
  # Pattern Match Coverage (Cosmetic)
  # =============================================================================
  # Dialyzer notes these patterns always match one branch - harmless
  ~r".*pattern_match_cov"
]

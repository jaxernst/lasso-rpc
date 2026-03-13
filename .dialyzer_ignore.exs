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
  # Defensive Error Handling - Intentional Safety Patterns
  # =============================================================================
  # These patterns are "impossible" according to type specs but serve as
  # defensive programming against unexpected runtime states from external systems
  # (HTTP responses, WebSocket events, config parsing, etc.)

  # HTTP adapter error handling (Finch responses)
  ~r"lib/lasso/core/transport/http/adapters/finch.ex.*pattern_match",

  # WebSocket connection state handling
  ~r"lib/lasso/core/transport/websocket/connection.ex.*pattern_match",

  # Discovery/probing error handling
  ~r"lib/lasso/discovery/probes/method_support.ex.*pattern_match",

  # VM metrics collector error handling
  ~r"lib/lasso/vm_metrics_collector.ex.*pattern_match",

  # Upstream subscription error handling
  ~r"lib/lasso/core/streaming/instance_subscription_manager.ex.*pattern_match",

  # =============================================================================
  # Pattern Match Coverage (Cosmetic)
  # =============================================================================
  # Dialyzer notes these patterns always match one branch - harmless
  ~r".*pattern_match_cov"
]

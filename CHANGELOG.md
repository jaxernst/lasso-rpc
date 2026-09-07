# Changelog

All notable changes to Lasso RPC will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Configuration and operator controls

- Reject unsupported YAML fields, invalid values, duplicate provider IDs, and unresolved credentials before activation; retain the active configuration on a failed reload or missing public profile.
- Honor profile WebSocket backfill limits and application circuit-breaker thresholds. Read the documented `LW_BETA` setting.
- Clamp request tester rates across profile changes and distinguish HTTP strategy selection from priority-based subscriptions.
- Correct obsolete provider capability settings in the example profiles. Remove unused configuration facades, controls, and logging claims; document the supported routing and observability contracts.


### Changed

- Run Docker containers as UID/GID 10001 with a smaller runtime image, an image health check, and OCI source/license metadata
- Add a Compose deployment with persistent profiles/history, a read-only root filesystem, and upgrade guidance

### Fixed

- Load the profiles seeded under `LASSO_DATA_DIR` and allow explicit runtime profile/history directories
- Resolve benchmark snapshot storage when the collector starts instead of when the code is compiled
- Use local HTTP URLs and persistent storage in the Docker helper

## [0.3.3] - 2026-09-07

### Changed

- Made setup, deployment, configuration, and contributor documentation self-contained
- Removed unused profile-downgrade and crawler-preview plugs, unreachable editing forms, and unused landing-page assets
- Removed private lint extensions, unrelated vendor tooling, and obsolete planning documents

### Fixed

- Derived metrics API success rates, latency samples, and provider counts from actual local measurements; unavailable counters return `null`
- Included the dashboard favicon in Docker builds
- Corrected asset-build prerequisites, provider-credential examples, VM metrics defaults, and test commands
- Clarified dashboard access controls and removed unsupported performance estimates

## [0.3.2] - 2026-09-07

### Changed

- Refreshed the self-hosted dashboard with shared topology styling, chain logos, touch/pinch navigation, responsive details, and an HTTP/WebSocket request tester
- Documented file-based profile management and configuration reloads
- Made provider status reflect transport availability and observation freshness; unavailable measurements display as unknown

### Fixed

- Updated Mint to 1.10.0 to address the September 2026 security advisories
- Preserved upstream JSON-RPC error codes and data, refined quota/revert classification, and handled HTTP error bodies consistently
- Recognized method-specific block selectors without misclassifying transaction hashes as historical block requests
- Removed credential-bearing paths and query strings from displayed provider endpoints
- Preserved final request-tester outcomes when stopping and counted JSON-RPC errors returned with HTTP 200 as errors
- Loaded metrics from bulk cache completion and rejected stale results after profile switches
- Guarded invalid dashboard tabs and chain identifiers, empty-profile metrics, and tester profile changes
- Stabilized WebSocket recovery tests by waiting for the recovery transition

### Documentation

- Documented YAML profile reloads and clarified that tester rate settings do not enforce client quotas

## [0.3.1] - 2026-09-04

### Fixed

- Time-aligned fast-chain consensus using bounded HTTP observation credit while preserving WebSocket heads as direct evidence
- Rejected stale block observations from provider lag decisions instead of manufacturing current synchronization state
- Stored each worker's effective freshness and polling cadence with block-height observations so routing and dashboard status share one contract

## [0.3.0] - 2026-08-28

### Added

- Bounded request execution with explicit ownership, deadlines, byte budgets, terminal facts, and projection lanes for HTTP and WebSocket traffic
- Precompiled routing plans, candidate cursors, and bounded routing evidence used by every public selection strategy
- Generation-bound transport dispatch and strict upstream JSON-RPC response validation
- A validated Mint WebSocket client that resolves each configured origin once, pins the connection to that address set, and preserves the original HTTP and TLS authority
- Cluster-aware circuit-breaker admission, recovery control, and transport diagnostics

### Changed

- Upgraded the release runtime to Erlang/OTP 28 and the routing stack to Phoenix 1.8 and Finch 0.23
- Reworked provider selection to defer cold evidence, reuse immutable routing state, and avoid unnecessary materialization on the request path
- Strengthened WebSocket subscription ownership, reconnection, gap-fill bounds, and stale-generation handling
- Aggregated request and dashboard diagnostics through bounded local projection lanes
- Kept self-hosted localhost and private-network providers supported while pinning each WebSocket connection to its resolved address set

### Fixed

- Applied provider-specific error rules consistently to live HTTP and WebSocket transports
- Preserved provider metadata on WebSocket errors and classified structural execution evidence before ambiguous provider messages
- Prevented stale or cancelled transport attempts from being accepted after their request owner or connection generation changed
- Made provider capability reads safe when configuration fields are absent
- Corrected dashboard routing counters, provider details, and cluster-wide activity reconciliation
- Hardened response-size admission, batch accounting, circuit recovery races, and WebSocket continuity cleanup

## [0.2.0] - 2026-08-05

### Fixed

- Updated Cowboy to 2.18.0 and Cowlib to 2.19.0 to remediate the HTTP header parsing and HPACK/QPACK memory-exhaustion advisories reported by `mix hex.audit`
- `run-docker.sh` now provides the production-required `LASSO_NODE_ID` for local Docker runs, preventing a startup failure on a clean checkout
- Added standard `mix assets.setup`, `mix assets.build`, and `mix assets.deploy` aliases so local and release asset builds use the same commands

- `/api/health` no longer returns 500 on single-node deployments (missing `regions` field on cluster topology)
- Invalid provider override (e.g. `/rpc/provider/nonexistent/ethereum`) now returns a clean `-32602 "Provider not found"` error instead of a misleading "All circuits open" exhaustion message
- WebSocket connections to unknown profiles (`/ws/rpc/profile/zzz/...`) and unknown provider overrides (`/ws/rpc/provider/ghost/...`) are now rejected at handshake; previously they silently fell back to default routing and returned subscription IDs that never delivered events

### Documentation

- Aligned public setup, API, deployment, configuration, and architecture docs with the canonical `public` profile, current routes, and the OSS authentication model

### Changed

- Lasso RPC is now licensed under Apache-2.0 to support broader self-hosting, distribution, and commercial embedding
- Profiles are now loaded exclusively from YAML files in `config/profiles/`; profile slugs are opaque routing IDs, chain aliases resolve to positive integer EIP-155 IDs internally, and `default` remains an alias for `public`
- Configuration reloads publish a complete new snapshot only after validation; malformed YAML or invalid chain IDs leave the last known-good snapshot active. A cold restart loads profiles from disk before routing begins
- Dashboard and RPC routes accept both configured chain aliases and decimal chain IDs, while WebSocket startup attempts are jittered to avoid synchronized upstream handshakes
- Default profile (`config/profiles/default.yml`) removed in favor of the canonical `public` profile; existing `default` slug requests still work via the alias system, eliminating the `Duplicate chain IDs detected across profiles` startup warning
- `public` profile pruned of broken provider configurations: removed dead WebSocket URLs from LlamaRPC (Ethereum and Base), removed unreachable `arbitrum_meowrpc` (TLS failure), removed `base_sepolia_onfinality` (returns 401 Unauthorized)
- Removed undefined optional lint-check warnings
- Hardcoded `"default"` string fallbacks across controllers, plugs, and dashboard components replaced with `Lasso.Config.ProfileValidator.default_profile/0` to remove a class of single-source-of-truth drift bugs
- `HealthController` topology logic extracted to `Lasso.Cluster.HealthTopology` and shared with the cloud variant so the OSS/cloud controllers can no longer drift independently
- Several integration tests strengthened from `assert error != nil` to assert the specific `JSONRPC.Error` shape, code, and category — closes a regression channel that had previously masked a bug fix being lost during sync

## [0.1.0] - 2026-01-06

### Added

- Multi-provider, multi-chain Ethereum JSON-RPC proxy for HTTP and WebSocket
- Intelligent routing strategies: fastest, load-balanced, latency-weighted
- Per-method, per-transport latency benchmarking
- Profile system for isolated routing configurations (dev/staging/prod/multi-tenant)
- Circuit breakers with per-provider, per-transport state
- WebSocket subscription multiplexing with gap-filling on provider failover
- LiveView real-time dashboard with:
  - Provider health monitoring
  - Routing decision breakdowns
  - Per-method latency metrics
  - Issue logs and circuit breaker state
  - RPC load testing interface
- Transport-aware failover and retry logic
- Configurable rate limiting per profile
- OpenTelemetry integration for observability
- Support for Ethereum, Base, and extensible to other EVM chains
- Pre-configured public provider support (LlamaRPC, PublicNode, DRPC, etc.)

### Documentation

- Comprehensive README with quick start guide
- Architecture documentation (ARCHITECTURE.md)
- Testing guide (TESTING.md)
- Observability setup (OBSERVABILITY.md)
- RPC standards compliance (RPC_STANDARDS.md)
- Contributing guidelines (CONTRIBUTING.md)
- Security policy (SECURITY.md)

### Infrastructure

- Docker support with multi-stage builds
- GitHub Actions CI pipeline (test, lint, type-check)
- Credo and Dialyzer static analysis
- Comprehensive test suite (unit + integration)

[Unreleased]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.3...HEAD
[0.3.3]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jaxernst/lasso-rpc/releases/tag/v0.1.0

# Changelog

All notable changes to Lasso RPC will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `/api/health` no longer returns 500 on single-node deployments (missing `regions` field on cluster topology)
- Invalid provider override (e.g. `/rpc/provider/nonexistent/ethereum`) now returns a clean `-32602 "Provider not found"` error instead of a misleading "All circuits open" exhaustion message
- WebSocket connections to unknown profiles (`/ws/rpc/profile/zzz/...`) and unknown provider overrides (`/ws/rpc/provider/ghost/...`) are now rejected at handshake; previously they silently fell back to default routing and returned subscription IDs that never delivered events

### Changed

- Default profile (`config/profiles/default.yml`) removed in favor of the canonical `public` profile; existing `default` slug requests still work via the alias system, eliminating the `Duplicate chain IDs detected across profiles` startup warning
- `public` profile pruned of broken provider configurations: removed dead WebSocket URLs from LlamaRPC (Ethereum and Base), removed unreachable `arbitrum_meowrpc` (TLS failure), removed `base_sepolia_onfinality` (returns 401 Unauthorized)
- `.credo.exs` ExSlop checks made conditional, eliminating "Ignoring an undefined check" noise on every credo run
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

[Unreleased]: https://github.com/jaxernst/lasso-rpc/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/jaxernst/lasso-rpc/releases/tag/v0.1.0

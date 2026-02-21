# Changelog

All notable changes to Lasso RPC will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

# Changelog

All notable changes to Lasso RPC will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.5] - 2026-09-23

### Security

- Upgrade Phoenix to 1.8.14, Cowboy to 2.19.0, Cowlib to 2.20.0, and Ranch to 2.3.0. Cowlib 2.20.0 resolves `CVE-2026-43971`; the two remaining acknowledged Cowlib advisories affect encoder paths Lasso does not call.

### Fixed

- Correct Public Arbitrum archive routing: thirdweb and Blast now serve historical state reads. dRPC, PublicNode, Tenderly, and Nodies remain available for recent traffic but no longer claim historical-state support.
- Keep pinned numeric reads eligible when no fresh head is available to establish their age. Once age is known, requests beyond the configured threshold still require an archival provider.
- Return structured, non-retriable admission errors when a request requires archival support or a transport that no configured provider supplies, without recording an upstream attempt. Explicit invalid-argument evidence also takes precedence over incidental provider, authentication, throttling, or retry wording in the request error.

### Documentation and project operations

- Correct the load-balanced routing summaries to describe bounded distinct-provider fallback for replay-safe reads, while keeping health tiers, recovered-head preference, dispatch limits, and provider capacity constraints explicit.
- Add a provider-neutral migration and canary guide, support and maintainer policies, ownership rules, and structured issue and pull request templates.

### Compatibility

- No configuration or journal migration is required. Retry budgets and method-safety dispatch limits are unchanged.
- Unknown block age no longer establishes an archival requirement for numeric selectors. Requests can reach eligible providers within the normal execution budget; provider responses still drive ordinary failover. Known-old requests retain archival admission.
- EIP-1898 state reads selected by block hash now require an archival provider, because their age cannot be established before dispatch. A chain with no archival provider rejects them at admission.
- The bundled Public Arbitrum provider set changes. Operators with local profile overrides retain their configured routes and should review archival declarations against historical state reads, not header availability alone.
- Lasso OSS continues to require authentication and inbound rate limiting at the operator's ingress boundary.

## [0.4.4] - 2026-09-20

### Fixed

- Give distinct physical provider instances a first pass within each availability tier for load-balanced replay-safe unary fallback, before alternate HTTP/WebSocket routes consume the attempt budget. Alternate transports remain available, and lazy and eager selection follow the same tier ordering.

### Documentation

- Clarify the existing latency-weighted fallback: recent latency measurements receive weighted ordering before shuffled unmeasured routes when no candidate qualifies.

### Compatibility

- No configuration or journal migration is required. The three-dispatch replay-safe budget, original request deadline, candidate admission limits, and existing dispatch rules for transactions, stateful methods, and unknown methods are unchanged.
- Health tiers and explicit recovered-head preference retain precedence. Healthy-sibling deferral is bounded by the cursor's remaining candidate limit; other routing strategies retain their existing behavior.
- Trying another provider first can delay a working alternate transport. A hash selector can still leave more distinct providers eligible than the dispatch budget covers. Historical state availability remains provider-dependent; this release does not certify archive workload coverage or provider capacity.

## [0.4.3] - 2026-09-20

### Fixed

- Reject HTTP dispatch to a physical provider endpoint after a malformed or mismatched `eth_chainId` probe. A later matching probe restores admission; ordinary request successes cannot clear the rejection. Probe results are fenced by configuration generation and observation order, and unrelated configuration reloads retain the rejection.
- Drain buffered orphan log additions and removals in their original per-log order before replacement-block additions during WebSocket recovery, including replacements at different block heights.
- Remove URL user information, paths, queries and fragments from provider diagnostics and catalog endpoint projections. Diagnostic origins still contain the scheme, host and port.
- Update Mint to 1.10.1.

### Documentation and maintenance

- Clarify local/global block protection, hash-pinned state reads, routing metadata, and the boundary between self-hosted Core and hosted Lasso Cloud.
- Document the default mock-backed test suite and the separate PostgreSQL/Anvil integration checks; remove an unused failover policy module.

### Compatibility

- No configuration or journal migration is required. Retain the existing journal and follow the documented replacement procedure for global continuity deployments.
- Unknown HTTP identity keeps normal admission until a probe provides evidence. The guard does not infer WebSocket identity from an HTTP endpoint or attest arbitrary provider responses.
- Core deduplicates positive and removed logs separately. Repeated removal and re-addition of the same log within the deduplication window is not fully modeled; this release does not guarantee recovery through every repeated reorg sequence.
- Historical state availability and provider capacity remain provider-dependent. These fixes do not qualify hosted Public or Premium profiles for archive workloads.

## [0.4.2] - 2026-09-11

### Changed

- Local block continuity captures the mandatory floor once per request and atomically retains the greatest accepted height. Sequential nonoverlapping requests within one application generation remain nondecreasing; overlapping responses can complete out of height order.
- Connected BEAM instances exchange accepted-height hints through bounded background work. Hints prefer suitable providers without raising the local admission floor or removing valid fallbacks. Local mode requires no publication database or peer acknowledgment. Recovery after an application restart or node switch is best effort, with no promised time or block-gap bound.
- Provider preference uses transport observations with the captured route's freshness settings. Existing health, capability, explicit override and fallback-group rules retain precedence; a stalled preferred provider leaves time for a valid fallback within the existing request deadline.

### Fixed

- Propagate committed publication snapshots between runtimes and retry stale closure acknowledgments from already received revisions, avoiding extra journal reads at cutover. Preserve periodic recovery, boot checks, durable closure, and the invalidation topic used by older runtimes; no schema or configuration changes are required.

- Reconcile journal inventory in one supervised background task, allowing committed updates to proceed while a read is slow. Stale inventory results cannot regress a newer publication; cold bootstrap still requires a successful inventory.

- Avoid serialized journal transactions for locally ineligible block proposals and unchanged readiness evidence. Provider checks continue so anchor, provider, floor and freshness changes can still drive publication; observation timestamps alone no longer repeat readiness writes. No configuration or journal migration is required.

### Compatibility

- Existing `off`, `local` and `global` configuration values remain valid. Global retains its durable coordinated contract and journal/membership requirements. Explicit number/hash state reads retain their targets. Local floors and hints are volatile application state; losing all copies loses that history.
- Local choices still require an eligible provider response and can fail when a provider regresses and every fallback is unavailable or quota-limited. This release does not add a retained-response cache or certify any customer's provider capacity.

## [0.4.1] - 2026-09-10

### Fixed

- Acknowledge closed publication gates concurrently across scopes, with at most four acknowledgment tasks independent of provider probes. Cross-region database latency no longer accumulates serially across all closing scopes. Gates still require durable acknowledgment before a newer publication can open; request deadlines and selectors are unchanged.

- Supervise the coordinator and its background tasks together, so a coordinator crash stops blocked tasks before replacement work starts.

### Compatibility

- No configuration or journal migration changes. Upgrade from v0.4.0 using the existing graceful replacement procedure and retain acknowledged history. Binaries predating global publication remain unsafe after enrollment.

## [0.4.0] - 2026-09-10

### Added

- Opt-in `global` block continuity: profile/chain block choices use a durable fleet publication, with local serving grants and no per-request PostgreSQL lookup. Repeated heights are allowed; stale or unavailable publication returns an error.
- Optional PostgreSQL journal, explicit install/upgrade command, and release-console operations for membership, graceful replacement and retained-floor recovery. Ordinary `off` and instance-only `local` deployments require no database server.
- Standard hash-pinned logical-read guide and executable viem/SEL/Multicall/worker example, including query deadlines, bounded routing evidence and whole-query reorg recovery.
- Browser-readable profile, request and routing metadata for local and upstream responses.

### Compatibility

- The policy covers `eth_blockNumber` and `eth_getBlockByNumber("latest", ...)`. State reads retain their original number/hash/tag; applications propagate one hash through the complete logical request.
- Global deployments must retain one journal and a complete, explicitly managed instance roster. Do not delete or restore older journal history while serving the same protected profile identities. See the publication operations guide before enabling or rolling back.
- Provider-observed canonicality is not finality or proof of arbitrary `eth_call` execution. One provider is supported without provider redundancy.


## [0.3.6] - 2026-09-08

### Fixed

- Restore the routing catalog automatically after its owner restarts. Failed recovery publications discard their unfinished tables and retry without requiring a configuration reload.

## [0.3.5] - 2026-09-07

### Fixed

- New profiles can subscribe through shared WebSocket upstreams after configuration reload without restarting the node. Routing eligibility reads the physical connection state instead of requiring a pre-existing profile channel cache entry.
- Exclude disconnected WebSocket upstreams even when profile channel caches still contain their wrappers; publish connected state before notifying consumers.
- Container acceptance checks cover subscription acknowledgment, block delivery, and unsubscribe for newly reloaded profiles sharing existing connections.

### Compatibility

- No YAML schema or storage migration. Distribute and reload profile files on each node; environment and mount changes still require recreation. Existing v0.3.4 installations should retain the restart workaround until upgraded.

### Distribution

- Publish versioned AMD64/ARM64 container images with anonymous installation checks, build provenance, SBOMs, and signed publication attestations.
- Attach a standalone Compose recipe and native verification reports to each container release; document installation, custom profiles, image pinning, migration, and rollback.
- Pass an optional local `.env` file into source-built Compose containers so provider credentials reach the running application.

## [0.3.4] - 2026-09-07

### Compatibility

- Configuration validation now rejects unsupported settings that were previously ignored. Check custom profiles against `docs/CONFIGURATION.md` before upgrading; the bundled profiles use the supported schema. A rejected reload retains the active configuration.

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
- Stop and clear request tester runs when switching between profiles, including profiles with identical chain lists
- Keep the profile selector accessible above floating dashboard panels

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

[Unreleased]: https://github.com/jaxernst/lasso-rpc/compare/v0.4.5...HEAD
[0.4.5]: https://github.com/jaxernst/lasso-rpc/compare/v0.4.4...v0.4.5
[0.4.4]: https://github.com/jaxernst/lasso-rpc/compare/v0.4.3...v0.4.4
[0.4.3]: https://github.com/jaxernst/lasso-rpc/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/jaxernst/lasso-rpc/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/jaxernst/lasso-rpc/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.6...v0.4.0
[0.3.6]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.5...v0.3.6
[0.3.5]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/jaxernst/lasso-rpc/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/jaxernst/lasso-rpc/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/jaxernst/lasso-rpc/releases/tag/v0.1.0

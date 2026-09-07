# OSS / Cloud parity assessment — 2026-09-07

This assessment accompanies the v0.3.2 release candidate. The OSS baseline was `b8dfb0d5` and the hosted source revision inspected was `d210a2644`. It records a scoped sync, not a claim that the two repositories are identical.

## Release recommendation

Release v0.3.2 before the hosted launch once the candidate passes CI and review. The public main branch's dependency audit failed on Mint advisories; the candidate updates Mint to 1.10.0. The dashboard also had visible drift and several correctness seams. These are worthwhile release changes independent of the broader core synchronization work below.

## Dashboard and shared correctness changes

| Area | Candidate behavior |
| --- | --- |
| Visuals and navigation | Shared topology layout, chain icons, branding, solid panels, pan/zoom, touch gestures, copy feedback, mobile navigation and details |
| Provider evidence | Transport-aware status, quota/circuit state, profile freshness thresholds, raw observed heights, and explicit unknown measurements |
| Endpoints | File-configured profile routes, numeric chain identities, configured strategies, and origin-only provider URL display |
| Profiles | Every configured YAML profile is selectable; configuration guidance replaces hosted create/upgrade actions |
| Request tester | HTTP and WebSocket requests, configured profile/chain/strategy selection, final outcomes after stop, and accurate JSON-RPC error counts |
| Metrics and activity | Empty-profile handling, zero-vs-missing success data, consistent subscription chain identities, and lifecycle events excluded from RPC counters |
| RPC correctness | Method-specific block selectors, preserved error codes/data, bounded classification evidence, and consistent HTTP error bodies |
| Dependencies | Mint 1.10.0 and CAStore 1.0.21 |

The self-hosted build retains support for localhost and private-network upstreams. Hosted provider inventories, credentials, deployment configuration, and database modules are not part of this sync.

## Deliberate product boundaries

OSS owns routing, failover, streaming, observability, and file-configured profiles. Cloud owns account identity, client API keys, billing, entitlements, and database-backed profile lifecycle. The OSS dashboard must not show nonfunctional create-profile, sign-in, upgrade, guest-access, or billing controls.

OSS profiles can contain custom nodes and provider credentials in YAML. The lack of an in-browser profile editor is not a restriction on configuring custom providers. Profile changes are applied by restart or explicit configuration reload; see [Configuration](CONFIGURATION.md#multiple-profiles).

`rps_limit` limits choices in the dashboard request tester. `burst_limit` is profile metadata. Neither provides OSS client authentication or per-client ingress quota enforcement. Operators configure those at their network boundary.

## Shared-core gaps requiring follow-up

The inspected Cloud revision includes additional shared runtime changes beyond this candidate:

- Adaptive routing and exploration, with related selection and evidence lifecycle changes.
- Head-observation and capability-freshness architecture changes that require coordinated probe, storage, routing, and dashboard contracts.
- WebSocket ingress, continuity, and capacity/budget lifecycle changes.
- Shared managed-capacity admission and related execution behavior that require separating reusable runtime contracts from hosted policy.

These are not all Cloud-only features. They require a separate dependency-aware sync and regression review; copying individual files would leave incompatible runtime contracts. This release does not certify parity for those areas. Keep the existing OSS execution architecture until each coherent change can be ported and verified as a unit.

## Verification

- Full hermetic suite: 1,632 tests passed before the final browser-discovered lifecycle fix; focused dashboard and simulator tests cover subsequent fixes, with CI rerunning the complete suite.
- Warnings-as-errors compilation, formatting, strict Credo, Dialyzer, and dependency audit.
- Production assets, release assembly, and Docker image build.
- Browser checks at desktop and phone widths: profile selector, topology selection, metrics, provider details, request tester start/stop, final counters, and horizontal overflow.
- Container smoke checks cover health, configured chains, the dashboard, real HTTP RPC, and invalid profile/provider responses.

The full suite excludes the repository's separately tagged real-provider and slow tests. Live public-provider smoke checks provide narrower availability evidence, not an upstream uptime guarantee. Existing documented Cowlib encoder-only advisory exclusions remain unchanged; no new advisory exclusions were introduced.

## Maintaining parity

For each shared change, record the source revision, destination commit, dependent runtime contracts, and tests. Keep this matrix current when another sync lands. Treat dashboard changes as requiring both file-profile and hosted-profile checks, including empty profiles, profile switching, stale observations, and the tester's HTTP/WebSocket lifecycle.

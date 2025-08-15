Livechain Multi-Region Latency Routing: Technical Design Options and Recommendations
Goals
Route each client request to the closest Livechain node and then to the lowest-latency upstream RPC provider.
Keep the system highly available, fault tolerant, and cost-efficient.
Prefer BEAM for dynamic routing and resilience; use minimal external services for global ingress where practical.
Support HTTP and WebSocket semantics (sticky sessions for WS).
Scope and Responsibilities
BEAM/Elixir (application team):
Region-local provider discovery, benchmarking, scoring, and selection
Circuit breaking, failover, and health checking per provider
Region-tagged metrics, telemetry, and per-region leaderboards
API behavior for HTTP+WS and client-visible headers (e.g., X-Livechain-Region)
Infrastructure (platform/DevOps team):
Global ingress and geo-routing to nearest region
TLS termination, session affinity for WS, cross-region failover
Base images, environment config (LIVECHAIN_REGION), deploy, scaling
DNS/anycast/LB setup, observability stack, and secrets

1. Global Routing (Client → Nearest Region)
   Options
   DNS Latency-Based Routing (e.g., Route 53, NS1)
   Pros: Simple, cost-effective, no new proxies; good global reach
   Cons: TTL and resolver caching affect responsiveness to outages; session stickiness via DNS only is weak
   Complexity: Low–Medium
   Managed Anycast/L7 LB (e.g., Cloudflare Load Balancing, AWS Global Accelerator)
   Pros: Strong geo proximity, fast failover, session affinity for WS, built-in health checks
   Cons: Vendor dependency, additional cost
   Complexity: Low–Medium
   Self-hosted Anycast/BGP (DIY)
   Pros: Minimal SaaS reliance, max control
   Cons: High complexity and operational risk; not recommended at early stage
   Complexity: Very High
   Fly.io/Render region placement (platform-native)
   Pros: Very simple global footprint + anycast
   Cons: Platform lock-in, cost tradeoffs; less control over LB behavior
   Complexity: Low
   Recommendations
   Short-term (fast path): Use DNS latency-based routing (Route 53) to regional endpoints; accept its limitations for early phases.
   Medium-term (production): Use a managed anycast/L7 LB (Cloudflare LB or AWS Global Accelerator) for:
   Geo routing + health checks
   Session affinity for WebSockets
   Faster cross-region failover
2. Regional Node Architecture (In-Region Routing)
   Core pattern
   Each region runs a full Livechain deployment (stateless HTTP tier + WS tier).
   Region is explicitly configured (LIVECHAIN_REGION).
   All high-cardinality processes are local (we already moved to Registry).
   Per-region provider selection is done by ProviderPool using region-local metrics.
   Provider selection and benchmarking
   Passive benchmarking (existing): Prefer the provider that wins races in real traffic; keep per-region scores.
   Active probing (augment): Low-frequency probes (e.g., eth_chainId, eth_blockNumber) to maintain a baseline when traffic is light.
   Scoring: Per-region, per-method; use EMA for latency, track failure rate; rank by P95 or P90 latency with health gates.
   TTL/aging: Decay stale metrics; cap retention windows; prefer fresh data.
   WebSocket and HTTP handling
   HTTP: Can be served by any regional node; no affinity required.
   WebSocket: Requires stickiness (LB-managed cookie or header affinity). Reconnects should prefer the same region, but LB may move sessions if region is degraded.
   Failover within region
   Circuit breakers per provider
   Step-down on failure rates, cooldowns for rate limits
   Fallback to next best provider by score or priority
3. Cross-Region Strategy
   Independence vs Coordination
   Independent per-region scores (Recommended initially)
   Pros: Simple, resilient to partitions; selection tuned to local network conditions
   Cons: No immediate cross-region intelligence; cold regions bootstrap from probes
   Coordinated global summaries
   Pros: Faster cold-start; visibility across regions
   Cons: Needs replication bus (e.g., Kafka, S3 snapshots, gRPC), conflict resolution, versioning
   Recommendation: Start with independent per-region metrics. Optionally publish hourly snapshots to object storage for analytics and drift detection.
4. Data and Metrics
   Region-tag all telemetry and provider scores
   Track:
   Latency distributions (P50/P95), error rates, success counts
   Per-method metrics when impactful (e.g., eth_getLogs vs eth_chainId)
   Persist hourly snapshots (JSON) for auditing and regression analysis
   Expose status endpoints (/api/status, /api/region) and include X-Livechain-Region header in responses
5. Provider Regionality Considerations
   Many RPC providers are anycast/multi-region behind single URLs; actual path varies per region.
   If providers offer region-specific endpoints (e.g., us-east, eu-west), allow optional per-region URLs in config; fall back to global endpoints otherwise.
   Treat “region” in provider config as a hint; always validate via live measurements.
6. Failure Modes and Resilience
   Region degradation: LB detects and routes to next nearest region. WS reconnects land on healthy region.
   Provider degradation: Circuit breakers open; ProviderPool rotates to next candidates; cooldown with exponential backoff for rate limits.
   Network partitions: Region independence minimizes blast radius; no reliance on cross-region coordination for core routing.
7. Security and Multi-Tenancy
   Terminate TLS at the LB or at the node; prefer LB termination with TLS to origin, depending on platform.
   Enforce per-tenant quotas in the HTTP layer; include tenant ID in metrics and leaderboards if applicable.
   Consider per-tenant region preferences/pinning where required (configuration or JWT claims).
8. Observability
   Minimum:
   X-Livechain-Region response header
   Region- and provider-tagged telemetry on latency, error rate, breaker events
   WS connection status channels already exist; surface region
   External:
   LB health checks visible in dashboards
   Synthetic probes per region for end-to-end
9. Hosting Provider Tradeoffs
   AWS
   Route 53 latency-based routing (Low complexity, eventual consistency)
   Global Accelerator (Best performance/health checks/WS stickiness, higher cost)
   ALB/NLB per region (simple regional ingress)
   Cloudflare
   Global LB with geo routing, session affinity, and health checks; simple setup; vendor lock-in
   Bare metal/Hetzner/OVH
   Requires GeoDNS (third-party DNS) or building anycast; lower infra cost; higher operational complexity
   Fly.io
   Easiest global distribution + anycast; tight platform coupling
   Recommendation: If minimizing third-party services is a hard constraint, start with Route 53 latency routing; otherwise, prefer Cloudflare LB for the best balance of performance and simplicity.
10. Phased Implementation Plan
    Phase 0 (now; no infra changes)
    Tag metrics by region; add LIVECHAIN_REGION and return X-Livechain-Region header
    Keep per-region leaderboards and scoring (already aligned with Registry)
    Phase 1 (global ingress)
    Route HTTP/WS to nearest region using Route 53 latency-based routing (or Cloudflare LB)
    Ensure session affinity for WS at the LB
    Phase 2 (latency discovery hardening)
    Add low-QPS active probes per provider per region; use P95 with TTL to augment passive data
    Tune breaker + cooldown thresholds for high traffic vs. quiet hours
    Phase 3 (failover & SLOs)
    LB health checks with automatic regional failover
    Regional SLO dashboards and alerts; monthly cost/perf review
    Phase 4 (optional)
    Cross-region metric snapshots for analytics (not required for routing)
    Region-specific provider endpoints if supported by vendors
11. Decision Matrix (Quick Picks)
    Global routing: Cloudflare LB with session affinity (Recommended) or Route 53 latency-based (Minimal vendor)
    Session affinity: LB-managed cookie/hash; mandatory for WS
    Regional topology: Independent per-region instances (Recommended)
    Provider selection: Per-region passive-first scoring + low-QPS active probes
    Provider endpoints: Use global anycast URLs; allow optional region-specific overrides
    Observability: Region header, per-region metrics, breaker events; synthetic checks
    DR: LB-based region failover; in-app provider failover
12. Risks and Mitigations
    DNS caching delays during regional failover → Use low TTL; prefer managed L7 LB for fast failover
    Vendor lock-in concerns → Keep app stateless; keep provider selection logic in BEAM; support multiple LB providers
    Low-traffic regions → Active probes + snapshot seeding
    WS reconnection storms on failover → Backoff + jitter; LB tuning; breaker cooldowns

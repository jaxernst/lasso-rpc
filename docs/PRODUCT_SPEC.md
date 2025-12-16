# Lasso RPC Product Specification

**Version**: 1.0 Draft
**Last Updated**: December 2024
**Status**: Planning

---

## Executive Summary

Lasso is a high-performance blockchain RPC aggregator that provides smart routing, failover, and deep observability for EVM chains. This document outlines the product strategy for packaging Lasso as a commercial service while maintaining an open-source core.

### Target Users
- **Primary**: Crypto-native developers building blockchain applications
- **Secondary**: Small-to-medium crypto companies needing reliable RPC infrastructure

### Value Proposition
- **For users of managed service**: Geo-distributed edge proxying, curated provider pools, zero-config reliability
- **For self-hosters**: Full-featured RPC aggregator with dashboard, bring your own providers

---

## Product Architecture

### Two-Tier Model

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Lasso Core (Open Source)                       │
│  AGPL Licensed - Self-hostable                                      │
│                                                                     │
│  Includes:                                                          │
│  - RPC proxy with smart routing and failover                        │
│  - Provider health monitoring and circuit breakers                  │
│  - Real-time dashboard with network topology visualization          │
│  - Profile system (multiple config sets)                            │
│  - YAML-based configuration                                         │
│  - WebSocket subscription support                                   │
│  - Full telemetry and observability                                 │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                                  │ Fork / Extend
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Lasso Managed Service                            │
│  Proprietary additions (separate repository)                        │
│                                                                     │
│  Adds:                                                              │
│  - API key generation and validation                                │
│  - Usage metering and rate limiting                                 │
│  - Pre-configured provider profiles (Public, Premium)               │
│  - Payment processing (credits, subscriptions)                      │
│  - Geo-distributed edge deployment                                  │
│  - Multi-tenant isolation                                           │
└─────────────────────────────────────────────────────────────────────┘
```

### Repository Strategy

| Repository | License | Contents |
|------------|---------|----------|
| `lasso-rpc` (public) | AGPL-3.0 | Core proxy, dashboard, profile system |
| `lasso-cloud` (private) | Proprietary | API keys, billing, managed profiles, edge config |

**Rationale**: Separate repositories provide clean licensing boundaries. The managed service fork tracks upstream core and adds proprietary modules. AGPL ensures improvements to core routing/proxy logic flow back to the community while allowing proprietary managed-service features.

---

## Product Tiers

### Free Tier: Lasso Public

| Attribute | Value |
|-----------|-------|
| **Price** | Free |
| **Request Limit** | 250,000 requests/month |
| **Rate Limit** | 25 requests/second |
| **Providers** | Curated public endpoints (LlamaRPC, PublicNode, DRPC, etc.) |
| **Chains** | All supported mainnet + testnet chains |
| **Dashboard** | Full access to public profile view |
| **Support** | Community (GitHub issues) |

**Purpose**: Attract developers, demonstrate value, convert to paid tiers.

**Risk Mitigation**: Public providers have their own rate limits. Lasso's circuit breakers will manage degraded providers. Per-key rate limiting prevents individual abuse from affecting pool.

---

### Premium Tier: Lasso Premium

| Attribute | Value |
|-----------|-------|
| **Price** | Prepaid credits (request-based) |
| **Providers** | Premium infrastructure (partner-operated nodes) |
| **Rate Limit** | Based on credit tier |
| **Dashboard** | Full access with premium provider visibility |
| **Support** | Email support |

**Credit Model**:
- Users purchase request credits upfront
- Credits decrement per successful request
- Unused credits do not expire (or long expiry, TBD)
- Bulk discounts for larger credit packages

**Provider Strategy**: Partner with professional node operators to provide dedicated infrastructure. Lasso handles routing/proxy, partner handles node operation.

---

### BYOI Tier: Bring Your Own Infrastructure

| Attribute | Value |
|-----------|-------|
| **Price** | Monthly subscription (base) + optional credits for Lasso providers |
| **Providers** | User-configured endpoints + optional Lasso providers |
| **Features** | Full routing, failover, observability on user's infra |
| **Dashboard** | Private profile with user's providers + any added Lasso providers |
| **Support** | Email support |

**Configuration**: Users create custom profiles via dashboard (YAML editor or form). Format validation on save; no connectivity testing (user responsibility).

**Value Proposition**: Users get Lasso's routing intelligence, dashboard, and geo-distributed edge proxying for their own infrastructure.

---

### Hybrid BYOI Model

BYOI profiles can include both user-owned and Lasso-managed providers, enabling powerful hybrid configurations:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Hybrid BYOI Profile                          │
│                                                                 │
│  User-Owned Providers          Lasso-Managed Providers          │
│  ────────────────────          ───────────────────────          │
│  ✓ my-dedicated-node (pri:1)   ✓ lasso-premium-alchemy (pri:2)  │
│  ✓ my-backup-node (pri:1)      ✓ lasso-public-llamarpc (pri:3)  │
│                                                                 │
│  Cost: Included in subscription    Cost: Per-request metering   │
└─────────────────────────────────────────────────────────────────┘
```

**Use Cases**:

| Scenario | Configuration | Cost Model |
|----------|---------------|------------|
| **Redundancy** | User node primary, Lasso Premium failover | Sub + credits when failover activates |
| **Burst Handling** | User node for baseline, Lasso for spikes | Sub + credits during traffic spikes |
| **Cost Optimization** | User node for heavy ops, Lasso Public for simple queries | Sub only (public is free) |
| **Environment Separation** | Prod uses dedicated node, dev uses Lasso Public | Sub only (public is free) |

**Provider Ownership & Metering**:

| Provider Type | Ownership | Metering | Cost |
|---------------|-----------|----------|------|
| User-defined endpoints | `user` | None | Included in subscription |
| Lasso Premium providers | `lasso` | Credits | Per successful request |
| Lasso Public providers | `lasso` | Rate-limited | Free (subject to tier rate limits) |

**Routing Behavior**:
- Use the existing `priority` strategy
- Set user-owned providers at priority 1
- Set Lasso providers at priority 2+ (failover/overflow)
- Circuit breakers handle failures; lower-priority providers activate on upstream failure

**Metering Implementation**:
- `provider_id` that served the request is already tracked in `RequestContext`
- After request completion, check provider ownership from profile config
- If `ownership == :lasso` and `metering == :premium` → decrement credits
- If `ownership == :lasso` and `metering == :public` → count against rate limit
- If `ownership == :user` → no metering

**Configuration Format**: Deferred to technical specification phase. Options include:
- Ownership flag per provider in unified list
- Separate sections for user vs Lasso providers
- Reference syntax for Lasso provider catalog

---

## Technical Architecture

### Profile System

Profiles are the core abstraction for multi-tenant configuration. Each profile is a complete `chains.yml` equivalent.

```
Profile {
  id: string (uuid)
  name: string
  type: :managed | :byoi
  owner_key: api_key_id (for BYOI profiles)
  config: %{
    chains: %{chain_name => ChainConfig}
  }
  created_at: datetime
  updated_at: datetime
}
```

**Built-in Profiles (Managed Service)**:
- `lasso-public`: Free tier, public providers
- `lasso-premium`: Premium tier, partner infrastructure

**User Profiles (BYOI)**:
- Created via dashboard
- Owned by an API key
- Stored in managed service database

**Implementation** (validated feasible):
- Composite keys in ETS: `{:chains, profile_id}` → chains map
- Hot-path overhead: ~7ns per request (negligible)
- Backward compatible with optional `profile_id` parameter

---

### API Key System

API keys are the primary identity and access control mechanism. No user accounts required.

```
APIKey {
  key_id: string (public identifier, e.g., "lasso_pk_...")
  secret: string (shown once on creation, e.g., "lasso_sk_...")
  profile_id: string (which profile this key uses)
  tier: :free | :premium | :byoi
  rate_limit_rps: integer
  monthly_limit: integer | nil
  credits_remaining: integer | nil (for premium)
  created_at: datetime
  last_used_at: datetime
  enabled: boolean
}
```

**Key Issuance**:
- Self-service via dashboard "Generate Key" button
- Key secret shown once; user must copy immediately
- No recovery (generate new key if lost)

**Key Validation** (validated feasible):
- ETS-cached lookup: < 0.15ms overhead per request
- Placed in plug chain before JSON parsing
- Invalid keys rejected before expensive processing

**Key → Profile Mapping**:
- Free keys → `lasso-public` profile
- Premium keys → `lasso-premium` profile
- BYOI keys → user's custom profile

---

### Request Flow

```
Client Request
    │
    ▼
┌─────────────────────────────────────────┐
│ Edge Proxy (geo-distributed)            │
│ - TLS termination                       │
│ - Regional routing                      │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ API Key Validation Plug                 │  < 0.15ms
│ - Extract key from header/query         │
│ - ETS lookup for key data               │
│ - Reject invalid keys (before parsing)  │
│ - Attach profile_id to conn             │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ Rate Limit Check                        │  < 0.1ms
│ - Per-key rate limiting                 │
│ - Credit balance check (premium)        │
│ - Reject if over limit                  │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ Request Pipeline (existing core)        │
│ - Provider selection (profile-aware)    │  < 5ms typical
│ - Circuit breaker gating                │
│ - Upstream request + failover           │
│ - Response handling                     │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│ Usage Recording (async)                 │  0ms (non-blocking)
│ - Increment request counter             │
│ - Decrement credits (premium)           │
│ - Emit telemetry                        │
└─────────────────────────────────────────┘
    │
    ▼
Response to Client

Total Lasso overhead: < 10ms (preserved from current)
```

---

### Dashboard Multi-Tenancy

The dashboard is part of OSS core but gains multi-tenant capabilities in managed service.

**OSS Core Dashboard**:
- Shows all configured profiles
- Profile selector in UI
- Events/metrics scoped to selected profile
- No access control (your deployment, your data)

**Managed Service Dashboard**:
- API key required for dashboard access (or session from key generation)
- Shows only profiles accessible to that key
- Free keys see: Lasso Public profile (read-only)
- BYOI keys see: Their custom profile (read/write)
- Events filtered to user's traffic only

**Event Scoping Implementation**:
- Profile ID included in `RequestContext`
- `publish_routing_decision` broadcasts to profile-scoped topic: `routing:decisions:#{profile_id}`
- Dashboard subscribes only to accessible profile topics

---

### Usage Metering and Billing

**Metering Approach**:
- Async increment of counters (non-blocking to request path)
- ETS-based counters with periodic persistence to database
- Counter key: `{api_key_id, date}` for daily aggregation

**Credit System (Premium Tier)**:
```
CreditBalance {
  api_key_id: string
  credits_remaining: integer
  credits_purchased: integer
  last_purchase_at: datetime
}
```

- Credits decremented per successful request
- Rate limiting kicks in when credits exhausted
- Dashboard shows credit balance and usage graphs

**Subscription System (BYOI Tier)**:
```
Subscription {
  api_key_id: string
  plan: :byoi_monthly
  status: :active | :past_due | :cancelled
  current_period_start: datetime
  current_period_end: datetime
}
```

- Monthly billing cycle
- Access suspended on payment failure (grace period TBD)

---

## Data Model (Managed Service)

Minimal persistence layer for managed service features:

```
┌─────────────────┐     ┌─────────────────┐
│    api_keys     │     │    profiles     │
├─────────────────┤     ├─────────────────┤
│ id (PK)         │     │ id (PK)         │
│ key_id          │──┐  │ name            │
│ secret_hash     │  │  │ type            │
│ profile_id (FK) │──┼──│ owner_key_id    │
│ tier            │  │  │ config (JSONB)  │
│ rate_limit_rps  │  │  │ created_at      │
│ monthly_limit   │  │  │ updated_at      │
│ enabled         │  │  └─────────────────┘
│ created_at      │  │
│ last_used_at    │  │  ┌─────────────────┐
└─────────────────┘  │  │ credit_balances │
                     │  ├─────────────────┤
┌─────────────────┐  │  │ api_key_id (FK) │
│  usage_daily    │  └──│ credits         │
├─────────────────┤     │ updated_at      │
│ api_key_id (FK) │     └─────────────────┘
│ date            │
│ request_count   │     ┌─────────────────┐
│ success_count   │     │  subscriptions  │
│ error_count     │     ├─────────────────┤
└─────────────────┘     │ api_key_id (FK) │
                        │ plan            │
                        │ status          │
                        │ period_start    │
                        │ period_end      │
                        └─────────────────┘
```

**Database Choice**: PostgreSQL (simple, reliable, JSONB for profile configs)

**Caching Strategy**:
- API keys: ETS cache with TTL, invalidate on update
- Profiles: ETS cache (same as core ConfigStore pattern)
- Credit balances: ETS with write-through to DB

---

## OSS Core Features

Features included in the open-source `lasso-rpc` repository:

### Included in OSS

| Feature | Description |
|---------|-------------|
| RPC Proxy | HTTP and WebSocket RPC proxying |
| Smart Routing | Strategy-based provider selection (fastest, round-robin, etc.) |
| Failover | Automatic retry on provider failure |
| Circuit Breakers | Per-provider, per-transport failure isolation |
| Health Monitoring | Continuous provider health probing |
| Dashboard | Real-time network topology, metrics, events |
| Profile System | Multiple configuration profiles |
| Configuration | YAML-based chain/provider configuration |
| Telemetry | Prometheus-compatible metrics export |
| WebSocket Subscriptions | eth_subscribe support with deduplication |

### NOT in OSS (Managed Service Only)

| Feature | Rationale |
|---------|-----------|
| API Key Validation | Requires managed key storage |
| Rate Limiting (per-key) | Requires key association |
| Usage Metering | Requires persistence |
| Credit/Billing | Commercial feature |
| Pre-built Profiles | Lasso-managed provider agreements |
| Edge Deployment Config | Operational concern |

---

## Implementation Phases

### Phase 1: Core Profile System (OSS)

**Goal**: Enable profile switching in dashboard and routing

**Changes to `lasso-rpc`**:
1. Extend ConfigStore for multi-profile support (composite keys)
2. Add `profile_id` parameter threading through Selection/RequestPipeline
3. Add profile selector to dashboard
4. Scope dashboard events by profile

**Outcome**: Self-hosters can configure multiple profiles and switch between them.

---

### Phase 2: Managed Service Foundation

**Goal**: API key generation and validation

**New in `lasso-cloud`**:
1. API key generation endpoint and dashboard UI
2. API key validation plug (ETS-cached)
3. Key → profile mapping
4. PostgreSQL schema for keys

**Outcome**: Users can generate API keys and make authenticated requests.

---

### Phase 3: Usage and Rate Limiting

**Goal**: Enforce limits and track usage

**New in `lasso-cloud`**:
1. Rate limiting plug (per-key)
2. Usage counter system (ETS + DB)
3. Dashboard usage display
4. Monthly limit enforcement

**Outcome**: Free tier is rate-limited; usage is tracked.

---

### Phase 4: Premium and BYOI

**Goal**: Paid tiers with credit system and custom profiles

**New in `lasso-cloud`**:
1. Credit balance system
2. BYOI profile creation UI
3. BYOI YAML editor with format validation
4. Subscription management

**Outcome**: Full product with all three tiers operational.

---

### Phase 5: Payment Integration

**Goal**: Accept payments for credits and subscriptions

**New in `lasso-cloud`**:
1. Payment provider integration (Stripe recommended for simplicity)
2. Credit purchase flow
3. Subscription billing
4. Invoice/receipt generation

**Outcome**: Self-service payment for premium and BYOI tiers.

---

## Key Technical Decisions

### Decision 1: API Key Validation Overhead

**Decision**: Validate via ETS lookup in plug chain
**Rationale**: Validated at < 0.15ms overhead. Placed before JSON parsing to reject unauthorized requests early.
**Trade-off**: Requires ETS cache management, but matches existing ConfigStore pattern.

### Decision 2: Profile Storage

**Decision**: Composite keys in single ETS table
**Rationale**: ~7ns overhead per request. Simpler than multiple tables. Backward compatible.
**Trade-off**: Requires threading `profile_id` through ~30 call sites.

### Decision 3: No User Accounts

**Decision**: API keys are the identity; no login/password system
**Rationale**: Simplest possible model. Keys are bearer tokens. No recovery needed (generate new key).
**Trade-off**: No key management across devices. Lost keys require regeneration.

### Decision 4: BYOI Format-Only Validation

**Decision**: Validate YAML syntax, not endpoint connectivity
**Rationale**: Faster activation, user is responsible for their endpoints. Connectivity can change.
**Trade-off**: Users may configure broken endpoints; they'll see failures in dashboard.

### Decision 5: Separate Repositories

**Decision**: Fork OSS core for managed service
**Rationale**: Clean licensing boundary. AGPL core can evolve independently. Managed features are proprietary.
**Trade-off**: Must keep fork in sync with upstream. Established pattern but requires discipline.

### Decision 6: Generous Free Tier

**Decision**: 250K requests/month free
**Rationale**: Attract developers, demonstrate value. Circuit breakers manage provider limits.
**Trade-off**: Potential for abuse. Mitigated by per-key rate limiting (25 RPS).

### Decision 7: Hybrid BYOI with Mixed Provider Ownership

**Decision**: BYOI profiles can include both user-owned and Lasso-managed providers
**Rationale**: Enables compelling use cases (redundancy, burst handling, cost optimization). Metering is per-provider based on ownership. Public providers in hybrid profiles are free but rate-limited.
**Trade-off**: Metering complexity - must track which provider served each request. However, `provider_id` is already tracked in `RequestContext`, making implementation straightforward.

### Decision 8: Priority Strategy for Hybrid Routing

**Decision**: Use existing `priority` strategy instead of adding new "cheapest" strategy
**Rationale**: Users set their providers at priority 1, Lasso providers at priority 2+. Existing failover behavior handles the rest. Avoids adding new strategy complexity.
**Trade-off**: Less explicit cost optimization, but priority achieves the same outcome with familiar semantics.

---

## Success Metrics

### Product Metrics

| Metric | Target |
|--------|--------|
| Free tier sign-ups | Track growth |
| Free → Paid conversion | > 5% |
| BYOI adoption | Track as % of paid |
| Monthly active keys | Track retention |

### Technical Metrics

| Metric | Target |
|--------|--------|
| P50 Lasso overhead | < 5ms |
| P99 Lasso overhead | < 15ms |
| Availability | 99.9% |
| Provider failover success rate | > 95% |

---

## Open Questions

1. **Credit pricing**: What should 1M requests cost?
2. **BYOI pricing**: Monthly subscription amount?
3. **Premium partner**: Who operates the premium infrastructure?
4. **Key expiration**: Should free tier keys expire after inactivity?
5. **Crypto payments**: Add as alternative payment method later?
6. **Hybrid config format**: Which approach for mixing user + Lasso providers in config? (Deferred to technical spec)

---

## Appendix: Validated Technical Findings

### A. Request Pipeline Overhead Analysis

Current Lasso overhead breakdown (before upstream I/O):
- Plug chain: ~0.3ms
- JSON parsing: 0.5-2ms
- Chain resolution: 0.1-0.2ms
- Provider selection: 1-5ms
- **Total pre-upstream**: 2-8ms

Added overhead for managed service:
- API key validation: < 0.15ms
- Rate limit check: < 0.1ms
- Usage recording: 0ms (async)
- **Total added**: < 0.3ms

**Conclusion**: Managed service features add < 5% overhead to existing pipeline.

### B. ETS Lookup Performance

Benchmarked patterns in existing codebase:
- ConfigStore `get_chain`: ~100ns
- Composite key lookup: ~107ns (+7ns)
- At 10K RPS: 30K lookups/sec = 3.2ms total CPU time

**Conclusion**: ETS-based key and profile lookups are negligible.

### C. Profile System Call Sites

Modules requiring `profile_id` parameter:
- `Selection` module (3 functions)
- `RequestPipeline` (2 functions)
- `AdapterFilter` (2 functions)
- `ProviderPool` (initialization)
- `TransportRegistry` (initialization)
- Dashboard helpers (5-10 functions)

**Total**: 25-35 call sites, all backward-compatible with optional parameter.

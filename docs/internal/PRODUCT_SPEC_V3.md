# Lasso RPC Product Specification v3

**Version**: 3.0
**Last Updated**: December 2024
**Status**: Implementation Ready

---

## Executive Summary

Lasso is a high-performance blockchain RPC aggregator providing intelligent routing, automatic failover, and observability for EVM chains. It routes requests across multiple upstream providers with full profile-scoped isolation.

### Core Value Proposition

| For...                    | Lasso Provides...                                    |
| ------------------------- | ---------------------------------------------------- |
| **Managed service users** | Geo-distributed edge, curated providers, reliability |
| **BYOK users**            | Intelligent routing for your infrastructure          |
| **Self-hosters (OSS)**    | Full-featured aggregator, dashboard, no lock-in      |

---

## Product Architecture

### Two-Tier Model

```
┌─────────────────────────────────────────────────────────────┐
│                  Lasso Core (Open Source)                    │
│  License: AGPL-3.0                                           │
│                                                              │
│  • Profile-scoped routing engine                            │
│  • Config backend abstraction (File/DB)                    │
│  • Multi-profile support with full isolation                │
│  • Dashboard & observability                                │
│  • WebSocket support (eth_subscribe)                         │
│  • Rate limiting (Hammer + ETS)                              │
└─────────────────────────────────────────────────────────────┘
                            │
                            │ Fork / Extend
                            ▼
┌─────────────────────────────────────────────────────────────┐
│              Lasso Managed Service (SaaS)                    │
│  License: Proprietary                                       │
│                                                              │
│  • Identity & access (accounts, API keys)                   │
│  • Usage & billing (CU metering, subscriptions)            │
│  • Managed profiles (lasso-free, lasso-premium)            │
│  • BYOK profile management                                  │
└─────────────────────────────────────────────────────────────┘
```

### Repository Strategy

| Repository              | License     | Contents                            |
| ----------------------- | ----------- | ----------------------------------- |
| `lasso-rpc` (public)    | AGPL-3.0    | Core routing, profiles, dashboard   |
| `lasso-cloud` (private) | Proprietary | Identity, billing, managed profiles |

**OSS/Proprietary Split**: Routing, profiles, and dashboard are OSS. Identity, billing, and managed profile provisioning are proprietary.

---

## Profile System Architecture

### Profile-Scoped Isolation

Every component is fully isolated by profile. No conditional sharing or heuristics.

**Profile-Scoped Components:**

- Circuit breakers
- Rate limiters
- Metrics/benchmarks
- Provider health state
- WebSocket connections
- Streaming subscriptions
- Selection state

**Global Components (shared across profiles):**

- Block cache (immutable data)
- Block heights (via BlockSync.Registry)
- HTTP connection pools (Finch, by URL host)

### Profile Types

| Type            | Description                  | Usage                 |
| --------------- | ---------------------------- | --------------------- |
| `lasso-free`    | Free tier managed profile    | SaaS: Free tier users |
| `lasso-premium` | Premium tier managed profile | SaaS: Pro tier users  |
| `byok`          | Bring Your Own Keys          | SaaS: BYOK tier, OSS  |

### URL Structure

Profile is required in path, with default fallback:

```
# OSS (no auth, default profile fallback)
POST /rpc/:chain                    # Uses "default" profile (lasso-free default for SaaS version)
POST /rpc/:profile/:chain           # Explicit profile

# SaaS (API key required, default profile fallback)
POST /rpc/:chain?key=lasso_abc123   # Uses account's default profile
POST /rpc/:profile/:chain?key=...   # Explicit profile

# WebSocket
/ws/rpc/:chain                      # Default profile
/ws/rpc/:profile/:chain             # Explicit profile
```

### Config Backend Abstraction

OSS uses file-based backend, SaaS uses database backend:

```elixir
# OSS
config :lasso,
  config_backend: Lasso.Config.Backend.File,
  config_backend_config: [profiles_dir: "config/profiles"]

# SaaS
config :lasso,
  config_backend: LassoCloud.Config.Backend.Database
```

**Critical Rule**: SaaS depends on OSS, never the reverse. OSS must be fully functional standalone.

---

## Product Tiers

### Free Tier: Lasso Free

| Attribute         | Value                    |
| ----------------- | ------------------------ |
| **Price**         | $0                       |
| **Monthly Limit** | 100,000 CU               |
| **Rate Limit**    | 10 requests/second       |
| **Providers**     | Curated public endpoints |
| **Chains**        | All supported chains     |
| **Dashboard**     | Full access (read-only)  |
| **Support**       | Community (GitHub)       |

**Profile**: Uses `lasso-free` managed profile.

### Pro Tier: Lasso Premium

| Attribute      | Value                  |
| -------------- | ---------------------- |
| **Price**      | Prepaid CU credits     |
| **Providers**  | Premium infrastructure |
| **Rate Limit** | 100-1000 RPS (by tier) |
| **Dashboard**  | Full access            |
| **Support**    | Email support          |

**Profile**: Uses `lasso-premium` managed profile.

**Credit Packages** (illustrative):
| Package | CU Credits | Price |
| ------- | ---------- | ------ |
| Starter | 1M CU | $29 |
| Growth | 10M CU | $199 |
| Scale | 100M CU | $1,499 |

### BYOK Tier: Bring Your Own Keys

| Attribute           | Value                       |
| ------------------- | --------------------------- |
| **Price**           | $299/month base             |
| **Your Providers**  | Unlimited (included)        |
| **Lasso Providers** | Optional (pay-per-CU)       |
| **Dashboard**       | Full access, profile editor |
| **Support**         | Email, priority response    |

**Profile**: Users create custom `byok` profiles with their own providers.

---

## Compute Unit (CU) Pricing Model

### Bytes-Based Calculation

CU cost = `(bytes_in + bytes_out) / 1024 * method_multiplier`

| Method Category | Multiplier | Examples                     |
| --------------- | ---------- | ---------------------------- |
| Core            | 1.0        | eth_blockNumber, eth_chainId |
| State           | 1.5        | eth_call, eth_estimateGas    |
| Filters         | 2.0        | eth_getLogs                  |
| Debug           | 5.0        | debug_traceTransaction       |
| Trace           | 5.0        | trace_block                  |

**Minimum**: 1 CU per request (even if calculated cost < 1).

### Async Metering

- Writes to ETS buffer, flushes periodically to DB
- CU limits checked every 60s (not per-request)
- Over-limit subscriptions marked in ETS for rate limiting

---

## Identity and Access System

### Account Model

```
Account
├── has_many API Keys (account-scoped)
└── has_many Subscriptions
    └── belongs_to Profile (with CU limits)
```

**Key Decision**: API keys belong to accounts, not profiles. One key accesses all profiles the account is subscribed to.

### Database Schema (SaaS)

```sql
-- Accounts
CREATE TABLE accounts (
  id UUID PRIMARY KEY,
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255),
  wallet_address VARCHAR(42),
  tier VARCHAR(20) NOT NULL DEFAULT 'free',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Profiles (OSS + SaaS)
CREATE TABLE profiles (
  id UUID PRIMARY KEY,
  slug VARCHAR(50) UNIQUE NOT NULL,
  name VARCHAR(100) NOT NULL,
  type VARCHAR(20) NOT NULL,  -- lasso-free, lasso-premium, byok
  config TEXT NOT NULL,  -- YAML text
  default_rps_limit INTEGER NOT NULL DEFAULT 100,
  default_burst_limit INTEGER NOT NULL DEFAULT 500,
  account_id UUID REFERENCES accounts(id),  -- NULL for managed profiles
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Subscriptions (links accounts to profiles with limits)
CREATE TABLE subscriptions (
  id UUID PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts(id),
  profile_id UUID NOT NULL REFERENCES profiles(id),
  status VARCHAR(20) NOT NULL DEFAULT 'active',
  cu_limit BIGINT NOT NULL,
  cu_used_this_period BIGINT NOT NULL DEFAULT 0,
  rps_limit_override INTEGER,
  burst_limit_override INTEGER,
  period_start TIMESTAMPTZ NOT NULL,
  period_end TIMESTAMPTZ NOT NULL,
  UNIQUE (account_id, profile_id)
);

-- API Keys
CREATE TABLE api_keys (
  id UUID PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts(id),
  key_hash VARCHAR(64) NOT NULL UNIQUE,
  key_prefix VARCHAR(12) NOT NULL,
  enabled BOOLEAN NOT NULL DEFAULT true,
  expires_at TIMESTAMPTZ
);

-- Credit Balances (for Pro tier)
CREATE TABLE credit_balances (
  id UUID PRIMARY KEY,
  account_id UUID UNIQUE NOT NULL REFERENCES accounts(id),
  balance BIGINT NOT NULL DEFAULT 0,
  reserved BIGINT NOT NULL DEFAULT 0,
  lifetime_purchased BIGINT NOT NULL DEFAULT 0,
  lifetime_used BIGINT NOT NULL DEFAULT 0
);
```

### API Key Format

**Format**: `lasso_abc123def456xyz789qrs` (32 chars, base62)

**Validation** (<0.1ms via ETS):

- Hash lookup in ETS cache
- Constant-time secret comparison
- Extract from: `x-lasso-api-key` header → Bearer token → `?key=` query param

### Authentication Methods

1. **Email + Password** (Primary)

   - Standard registration flow
   - Email verification required
   - Password reset via email

2. **Wallet Authentication** (Secondary, Phase 3)
   - Sign message to prove ownership
   - No password needed

---

## Request Flow (SaaS)

```
Client Request (POST /rpc/:profile/:chain)
    │
    ├── 1. Profile Resolution (< 0.1ms)
    │   - Extract profile from path (or default)
    │   - ETS lookup: profile metadata
    │
    ├── 2. API Key Validation (< 0.2ms)
    │   - Extract key from header/query
    │   - ETS lookup: key_hash → {account_id, enabled}
    │   - Constant-time hash comparison
    │
    ├── 3. Subscription Check (< 0.1ms)
    │   - ETS lookup: {account_id, profile_id} → subscription
    │   - Verify active status
    │
    ├── 4. Rate Limit Check (< 0.1ms)
    │   - Hammer (ETS backend): {account_id, profile} bucket
    │   - Dual-window: burst + sustained
    │
    ├── 5. CU Pre-Authorization (< 0.1ms)
    │   - Calculate CU cost (bytes-based)
    │   - Atomic reserve from credit balance (if Pro tier)
    │   - Store reservation_id in RequestContext
    │
    ├── 6. Request Pipeline (Core - OSS) (< 5ms)
    │   - Profile-scoped provider selection
    │   - Circuit breaker gating
    │   - Upstream request with timeout
    │   - Retry/failover on failure
    │
    └── 7. Post-Request Processing (async)
        - Record provider attribution
        - Finalize CU reservation (confirm/refund)
        - Emit telemetry events
        - Update last_used_at (debounced)

Total Lasso overhead target: < 10ms (excluding upstream latency)
```

### Error Handling

The request flow handles various failure scenarios at each step:

1. **Profile Resolution Errors**

   - Invalid profile: Returns `400 Bad Request` with error message
   - Profile not found: Falls back to "default" profile if available, otherwise `404 Not Found`

2. **API Key Validation Errors**

   - Missing key: Returns `401 Unauthorized`
   - Invalid key: Returns `401 Unauthorized` (no distinction for security)
   - Disabled key: Returns `403 Forbidden`

3. **Subscription Check Errors**

   - No subscription: Returns `402 Payment Required`
   - Subscription expired: Returns `402 Payment Required`
   - Subscription suspended: Returns `403 Forbidden`

4. **Rate Limit Errors**

   - Rate limit exceeded: Returns `429 Too Many Requests` with `Retry-After` header
   - Burst limit exceeded: Returns `429 Too Many Requests` with `Retry-After` header

5. **CU Pre-Authorization Errors**

   - Insufficient credits: Returns `402 Payment Required` with credit balance
   - Calculation error: Logs error, continues without pre-auth (free tier behavior)

6. **Request Pipeline Errors**

   - All providers failed: Returns `503 Service Unavailable` with `Retry-After` header
   - Timeout: Returns `504 Gateway Timeout`
   - Invalid RPC method: Returns `400 Bad Request` with method validation error
   - Invalid params: Returns `400 Bad Request` with param validation error

7. **Post-Request Processing Errors**
   - Errors in async processing are logged but do not affect the response
   - CU reservation failures are logged and refunded if possible

**Logging**: All errors are logged with appropriate severity (error, warning, info) and include request context (request_id, profile, chain, method).

**Retry Eligibility**: Errors marked as `retriable?: true` in the JSON-RPC error response indicate the client may retry the request. The `Retry-After` header (in seconds) provides guidance on when to retry.

**Opaque Responses**: For security, internal errors (e.g., provider selection failures) return generic error messages to clients. Detailed error information is available in logs and telemetry.

### CU Deduction Strategy

**Reserve-and-Reconcile**:

1. Reserve CU atomically before request (prevents overdraw)
2. After provider selection, reconcile:
   - If user's provider served → refund reservation
   - If Lasso provider served → confirm reservation

---

## Dashboard Architecture

### Multi-Profile Event Model

Dashboard subscribes to profile-scoped PubSub topics:

```elixir
# Profile-scoped topics
"provider_pool:events:#{profile}:#{chain}"
"circuit:events:#{profile}:#{chain}"
"block_sync:#{profile}:#{chain}"

# Global topics (for aggregation)
"block_sync:#{chain}"
"health_probe:#{chain}"
```

**Dual-Broadcast Pattern**: Global workers (BlockSync, HealthProbe) broadcast to both global and profile-scoped topics, eliminating filtering in hot path.

### Dashboard Features by Tier

| Feature                 | Free          | Pro | BYOK |
| ----------------------- | ------------- | --- | ---- |
| Real-time topology view | ✓ (read-only) | ✓   | ✓    |
| Request routing stream  | ✓             | ✓   | ✓    |
| Provider health status  | ✓             | ✓   | ✓    |
| Circuit breaker state   | ✓             | ✓   | ✓    |
| CU usage graphs         | ✓ (limited)   | ✓   | ✓    |
| Profile editor          | -             | -   | ✓    |
| API key management      | ✓             | ✓   | ✓    |
| Cost breakdown          | -             | ✓   | ✓    |

---

## Security Considerations

### API Key Security

- Constant-time hash comparison (Bcrypt.verify_pass)
- Secrets never logged (redact from logs)
- HTTPS only for key transmission

### BYOK Endpoint Security (SSRF Prevention)

Validate at profile creation:

- Block private IP ranges (RFC1918, link-local, loopback)
- Resolve hostnames and validate resolved IPs
- Block dangerous ports (22, 23, 25, 3306, 5432, 6379)
- Support IPv4 and IPv6

### Credit System Security

**Atomic Credit Operations**:

- Single atomic DB query for reservation
- DB constraint: `balance >= 0`
- No race conditions possible

### Rate Limit Security

- Tuple-based bucket keys prevent injection attacks
- Profile-scoped isolation (separate buckets per profile)
- Distributed rate limiting: Redis backend for SaaS (optional)

### Security Operations

**Audit Logging**:

- All authentication attempts (success and failure) are logged with timestamps, IP addresses, and user identifiers
- All configuration changes (profile creation, chain updates, provider modifications) are logged with user attribution
- All administrative actions are logged with full context
- Audit logs are retained for a minimum of 90 days (configurable per deployment)
- Audit logs are stored separately from application logs and are tamper-evident

**DDoS Mitigation**:

- Rate limiting at multiple layers: per-API-key, per-IP, per-profile
- Circuit breakers prevent cascading failures from overwhelming upstream providers
- Automatic IP blocking for repeated authentication failures (configurable threshold)
- Request size limits to prevent resource exhaustion attacks
- Connection limits per client to prevent connection exhaustion

**Secrets Rotation**:

- API keys can be rotated without service interruption (old keys remain valid until expiration)
- Database credentials are rotated using environment variable updates (requires deployment)
- TLS certificates are automatically renewed via Let's Encrypt or similar ACME provider
- Secrets are never stored in code or configuration files (use environment variables or secret management systems)

**Incident Response**:

- All errors are logged with request context (request_id, profile, chain, method)
- Critical errors trigger alerts via configured notification channels (email, Slack, PagerDuty)
- Incident response playbook includes steps for: API key compromise, provider outage, data breach
- Post-incident reviews are conducted for all critical incidents

**TLS/Transport Security**:

- All external communications use TLS 1.2 or higher
- Internal service-to-service communication uses mTLS where applicable
- Certificate pinning for critical upstream provider connections
- Regular security scans for known vulnerabilities

### Compliance & Privacy

**Data Residency**:

- Customer data (profiles, chains, providers) can be stored in region-specific deployments
- API keys and authentication data are stored in the same region as customer data
- Telemetry and metrics data can be configured for regional storage
- Cross-region data transfer is minimized and logged

**GDPR/CCPA Compliance**:

- Users can request export of all their data (profiles, chains, API keys, usage history)
- Users can request deletion of their data (subject to retention requirements for billing/legal)
- Data processing activities are documented and logged
- Privacy policy clearly states data collection, processing, and retention practices

**Audit Logging for Compliance**:

- All data access (reads and writes) are logged with user attribution
- Data retention policies are enforced (configurable per data type)
- Audit logs are immutable and cannot be modified or deleted
- Regular compliance audits are conducted to verify adherence to policies

**PII Classification**:

- API keys are classified as sensitive PII and are encrypted at rest
- IP addresses are classified as PII and are anonymized in logs after 30 days
- User email addresses are classified as PII and are only used for authentication and notifications
- No other PII is collected unless explicitly required for service operation

**Password Policy** (for SaaS deployments with user accounts):

- Minimum 12 characters
- Require uppercase, lowercase, numbers, and special characters
- Password history: prevent reuse of last 5 passwords
- Account lockout after 5 failed attempts (15-minute lockout period)
- Password expiration: 90 days (configurable)

**Session Security**:

- Session tokens are cryptographically secure (128-bit minimum)
- Sessions expire after 24 hours of inactivity
- Sessions are invalidated on password change
- Multi-factor authentication (MFA) is required for administrative accounts

---

## Implementation Roadmap

### Phase 0: Profile Foundation (Complete)

**Status**: ✅ Implemented

**Changes**:

- Profile-scoped routing with full isolation
- Config backend abstraction (File/DB)
- Global vs profile-scoped component architecture
- Two-phase initialization (ETS → supervisors → load)
- Best-effort hot reload
- Chain name validation (canonical allowlist)

**Outcome**: Multi-profile OSS system with full isolation.

---

### Phase 1: Identity Foundation

**Goal**: User accounts and API key generation

**New in `lasso-cloud`**:

| Task                | Description                             |
| ------------------- | --------------------------------------- |
| Account model       | Users table, registration, login        |
| Email verification  | Send verification email, confirm flow   |
| Session management  | Cookie sessions for dashboard           |
| API key generation  | Create keys, show-once secret           |
| Key management UI   | List, name, revoke keys                 |
| Key validation plug | ETS-cached lookup, constant-time verify |
| Subscription model  | Account → Profile links with limits     |

**Security requirements**:

- [ ] Constant-time secret comparison
- [ ] Secrets never logged
- [ ] HTTPS only

**Outcome**: Users can register, generate API keys, and make authenticated requests.

---

### Phase 2: Metering and Rate Limiting

**Goal**: Track usage and enforce limits

**New in `lasso-cloud`**:

| Task                 | Description                                    |
| -------------------- | ---------------------------------------------- |
| CU cost calculation  | Bytes-based with method multipliers            |
| Rate limiting plug   | Per-account+profile RPS limits, sliding window |
| Usage recording      | Async writes to usage_daily table              |
| Credit balance table | Track CU balance per account                   |
| Dashboard usage view | Graphs of CU usage over time                   |
| Low balance alerts   | Email when CU drops below threshold            |

**Security requirements**:

- [ ] Atomic credit reservation (DB constraint)
- [ ] Rate limit cannot be bypassed by multiple keys

**Outcome**: Free tier is rate-limited; usage is tracked; foundation for paid tiers.

---

### Phase 3: Pro Tier Launch

**Goal**: Paid tier with credit purchases

**New in `lasso-cloud`**:

| Task                   | Description                                       |
| ---------------------- | ------------------------------------------------- |
| Stripe integration     | Customer creation, payment methods                |
| Credit purchase flow   | Select package, checkout, credit account          |
| Credit deduction       | Reserve-and-reconcile per request                 |
| Pro profile assignment | On purchase, create subscription to lasso-premium |
| Receipts/invoices      | Generate for purchases                            |
| Balance dashboard      | Show credits remaining, usage rate                |

**Outcome**: Users can purchase CU credits and use premium providers.

---

### Phase 4: BYOK Tier Launch

**Goal**: Custom profile creation and hybrid model

**New in `lasso-cloud`**:

| Task                      | Description                                     |
| ------------------------- | ----------------------------------------------- |
| Profile editor UI         | Visual + YAML modes                             |
| BYOK endpoint validation  | Format + SSRF protection                        |
| Subscription billing      | Monthly charge via Stripe                       |
| Hybrid metering           | Track provider ownership, conditional CU charge |
| Cost visibility dashboard | Your nodes vs Lasso breakdown                   |

**Security requirements**:

- [ ] SSRF prevention on user endpoints
- [ ] Ownership cannot be spoofed

**Outcome**: Full BYOK tier with hybrid provider support.

---

### Phase 5: Polish and Scale

**Goal**: Production hardening

| Task                      | Description                          |
| ------------------------- | ------------------------------------ |
| Key rotation              | Overlap period, graceful deprecation |
| Wallet authentication     | Sign-to-login flow                   |
| Team/org support          | Multiple users per account           |
| Distributed rate limiting | Redis backend for accurate limits    |
| Geo-distributed edge      | Multi-region deployment config       |
| Public status page        | Provider uptime transparency         |

**Outcome**: Production-ready managed service.

---

## Success Metrics

### Product Metrics

| Metric                  | Target                |
| ----------------------- | --------------------- |
| Account registrations   | Track growth          |
| Free → Pro conversion   | > 5%                  |
| BYOK adoption           | Track as % of revenue |
| Monthly active accounts | Track retention       |
| CU consumption growth   | Month-over-month      |

### Technical Metrics

| Metric                        | Target    |
| ----------------------------- | --------- |
| P50 Lasso overhead            | < 5ms     |
| P99 Lasso overhead            | < 15ms    |
| Availability                  | 99.9%     |
| Failed requests (Lasso fault) | < 0.1%    |
| API key validation latency    | < 1ms P99 |
| Credit operation latency      | < 5ms P99 |

### Business Metrics

| Metric                    | Target |
| ------------------------- | ------ |
| Monthly Recurring Revenue | Track  |
| Customer Acquisition Cost | Track  |
| Lifetime Value            | Track  |
| Gross Margin              | > 60%  |

---

## Open Questions

| Question                           | Category   | Expected Resolution             |
| ---------------------------------- | ---------- | ------------------------------- |
| Credit pricing ($/M CU)            | Business   | Market research + cost analysis |
| BYOK subscription price            | Business   | Competitive analysis            |
| Premium infrastructure source      | Operations | Partner conversations           |
| Key farming prevention approach    | Security   | Phase 2 implementation          |
| Wallet auth priority               | Product    | Phase 5 decision                |
| Chain cost multipliers             | Business   | 6 months post-launch            |
| Distributed rate limiting approach | Technical  | Phase 5 implementation          |

---

## Risk Register

| Risk                                   | Likelihood | Impact   | Mitigation                              |
| -------------------------------------- | ---------- | -------- | --------------------------------------- |
| Public provider rate limiting/blocking | Medium     | High     | Diversify providers, run fallback nodes |
| Credit system race conditions          | Low        | Critical | Atomic DB operations, extensive testing |
| SSRF via BYOK endpoints                | Medium     | Critical | IP blocklist validation                 |
| Alchemy launches BYOK tier             | Medium     | High     | Move fast, build community moat         |
| Key farming abuse                      | High       | Medium   | Email verification, monitoring          |
| Fork competition (AGPL)                | Low        | Medium   | Stay ahead on features, build brand     |
| Silent failover cost surprise          | High       | High     | Proactive notifications, budget limits  |

---

## Appendix A: Glossary

| Term                   | Definition                                                   |
| ---------------------- | ------------------------------------------------------------ |
| **CU (Compute Unit)**  | Unit of metering; bytes-based with method multipliers        |
| **BYOK**               | Bring Your Own Keys; users configure their own RPC endpoints |
| **Profile**            | A complete configuration set (chains, providers, settings)   |
| **Provider**           | An upstream RPC endpoint (e.g., Alchemy, user's node)        |
| **Circuit Breaker**    | Mechanism to stop sending requests to a failing provider     |
| **Selection Strategy** | Algorithm for choosing which provider handles a request      |
| **Managed Profile**    | Lasso-operated profile (lasso-free, lasso-premium)           |
| **User Profile**       | BYOK profile created by user                                 |

---

## Appendix B: API Reference

### Authentication

All SaaS API requests require an API key:

```
Authorization: Bearer lasso_abc123...
# OR
x-lasso-api-key: lasso_abc123...
# OR
?key=lasso_abc123...
```

### RPC Endpoint

```
POST /rpc/:profile/:chain
Content-Type: application/json

{
  "jsonrpc": "2.0",
  "method": "eth_blockNumber",
  "params": [],
  "id": 1
}
```

Response includes optional Lasso metadata:

```json
{
  "jsonrpc": "2.0",
  "result": "0x125c0a9",
  "id": 1,
  "_lasso": {
    "provider": "alchemy",
    "latency_ms": 45,
    "cu_cost": 1,
    "cu_remaining": 999999
  }
}
```

### WebSocket Endpoint

```
wss://api.lasso.sh/ws/rpc/:profile/:chain?key=lasso_abc123...
```

Supports standard `eth_subscribe` methods.

---

## Document History

| Version | Date     | Changes                                                         |
| ------- | -------- | --------------------------------------------------------------- |
| 1.0     | Dec 2024 | Initial draft                                                   |
| 2.0     | Dec 2024 | Post-review revision: CU pricing, account system, security      |
| 3.0     | Dec 2024 | Routing profiles integration, bytes-based CU, profile isolation |

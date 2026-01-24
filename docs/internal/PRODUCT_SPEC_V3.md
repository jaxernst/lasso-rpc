# Lasso RPC Product Specification v3

**Version**: 3.1
**Last Updated**: January 2026
**Status**: Phase 1-2 Implemented

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

## Compute Unit (CU) Metering System

### Overview

The CU metering system tracks usage across HTTP and WebSocket requests with sub-millisecond overhead. It uses an ETS-based accumulator for fast writes with periodic database flushes.

### Bytes-Based Calculation

CU cost = `max(1, ceil((bytes_in + bytes_out) / 1024 * method_multiplier))`

| Method Category | Multiplier | Examples                                          |
| --------------- | ---------- | ------------------------------------------------- |
| Core            | 1.0        | eth_blockNumber, eth_chainId, eth_gasPrice        |
| State           | 1.5        | eth_call, eth_estimateGas, eth_getBalance         |
| Filters         | 2.0        | eth_getLogs, eth_getFilterChanges, eth_newFilter  |
| Debug/Trace     | 5.0        | debug_traceTransaction, trace_block, trace_call   |
| Push Events     | 0.25x base | eth_subscription notifications (server-initiated) |

**Minimum**: 1 CU per request (even if calculated cost < 1).

### State Methods (1.5x)

```
eth_call, eth_estimateGas, eth_getBalance, eth_getCode, eth_getStorageAt,
eth_getTransactionCount, eth_getTransactionReceipt, eth_getTransactionByHash,
eth_getTransactionByBlockHashAndIndex, eth_getTransactionByBlockNumberAndIndex,
eth_getBlockByHash, eth_getBlockByNumber, eth_getBlockTransactionCountByHash,
eth_getBlockTransactionCountByNumber, eth_getUncleByBlockHashAndIndex,
eth_getUncleByBlockNumberAndIndex, eth_getUncleCountByBlockHash,
eth_getUncleCountByBlockNumber
```

### Filter Methods (2.0x)

```
eth_getLogs, eth_getFilterChanges, eth_getFilterLogs, eth_newFilter,
eth_newBlockFilter, eth_newPendingTransactionFilter, eth_uninstallFilter
```

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Request Path                                  │
│                                                                      │
│  HTTP Request ──► CUPlug ──────────────────────┐                    │
│                   (register_before_send)        │                    │
│                                                 ▼                    │
│  WebSocket ───► RPCSocket ────► CUAccumulator (ETS)                 │
│                 (per-request)    write_concurrency: true            │
│                                  ~0.001ms per write                  │
│                                         │                            │
│                                         │ every 10 seconds           │
│                                         ▼                            │
│                              Subscriptions.increment_cu_usage/2     │
│                                  (Batch DB update)                   │
└─────────────────────────────────────────────────────────────────────┘
```

### HTTP Metering (CUPlug)

CUPlug registers a `before_send` callback to record CU after response is built:

1. **Single requests**: Calculate CU from `lasso_request_context`
2. **Batch requests**: Sum CU for each request in `lasso_request_contexts` + base overhead
3. **Subscription ID**: Retrieved from `conn.assigns[:cached_subscription].id`

### WebSocket Metering (RPCSocket)

WebSocket connections meter CU at multiple points:

1. **Per-request**: After response is built, before sending
2. **Push events**: When sending subscription notifications (0.25x multiplier)

```elixir
# Request metering
record_cu_usage(state, method, request_bytes, response_bytes)

# Push event metering (generous 0.25x since server-initiated)
record_push_event_cu(subscription_id, bytes_out)
```

### CU Accumulator

ETS-based buffer for high-throughput CU recording:

| Setting            | Value                         |
| ------------------ | ----------------------------- |
| Flush interval     | 10 seconds                    |
| ETS options        | `write_concurrency: true`     |
| Write latency      | ~0.001ms (lock-free)          |
| Failure handling   | Retry on next flush           |

### Quota Enforcement

**HTTP Requests** (ProfileResolverPlug):
- Checked after authentication, before request processing
- Returns `429 Too Many Requests` when quota exceeded

**WebSocket Connections**:
- Checked at connection time (rejects if over quota)
- Per-request lightweight check via cached subscription data
- Returns JSON-RPC error when quota exceeded mid-session

### Period Rotation

The `PeriodRotationWorker` runs every minute to rotate expired billing periods:

1. Query subscriptions where `period_end < now()`
2. For each expired subscription:
   - Reset `cu_used_this_period` to 0
   - Set `period_start` to now
   - Set `period_end` to now + 1 month
3. Update KeyCache to reflect new period

This ensures quotas reset automatically at billing period boundaries.

---

## Identity and Access System

### Subscription Model: Profile-Based Subscriptions

**Subscription = Account + Profile + Plan**

- **Plan** = billing terms template (RPS limit, CU quota, monthly price)
- **Profile** = routing configuration (chains, providers, settings)
- **Subscription** = grants an account access to a profile under specific billing terms

```
Account
├── has_many API Keys (account-scoped)
└── has_many Subscriptions
    └── Subscription
        ├── profile_slug  ← what routing config they access
        ├── plan_id       ← billing terms for this access
        ├── status, cu_used_this_period, period_start/end
```

**Key Decision**: API keys belong to accounts, not profiles. One key accesses all profiles the account is subscribed to. Users add subscriptions to unlock profiles.

### Example Scenarios

**New User (Free Access)**:
```
Account: alice@example.com
Subscriptions:
  └── profile: "default", plan: "free" (10 RPS, 100k CU/mo, $0)
```

**User with Premium Profile**:
```
Account: bob@example.com
Subscriptions:
  ├── profile: "default", plan: "free" (10 RPS, 100k CU/mo, $0)
  └── profile: "premium", plan: "pro" (100 RPS, unlimited CU, $29/mo)
```

**BYOK User with Multiple Custom Profiles**:
```
Account: dave@example.com
Subscriptions:
  ├── profile: "dave-mainnet", plan: "byok" ($99/mo)
  ├── profile: "dave-testnet", plan: "byok" ($99/mo)
  └── profile: "dave-l2", plan: "byok" ($99/mo)
```

### Database Schema (SaaS)

```sql
-- Accounts (external auth)
CREATE TABLE accounts (
  id UUID PRIMARY KEY,
  external_provider VARCHAR(50) NOT NULL,
  external_user_id VARCHAR(255) NOT NULL,
  email VARCHAR(255) NOT NULL,
  email_verified BOOLEAN NOT NULL DEFAULT false,
  display_name VARCHAR(255),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (external_provider, external_user_id)
);

-- Plans (billing templates)
CREATE TABLE plans (
  id UUID PRIMARY KEY,
  slug VARCHAR(50) UNIQUE NOT NULL,      -- "free", "pro", "byok"
  name VARCHAR(100) NOT NULL,
  tier VARCHAR(20) NOT NULL,             -- for categorization/display
  commercial_rps_limit INTEGER NOT NULL,
  commercial_burst_limit INTEGER NOT NULL,
  cu_quota_monthly BIGINT,               -- NULL = unlimited
  monthly_price_cents INTEGER NOT NULL DEFAULT 0,
  active BOOLEAN NOT NULL DEFAULT true,
  timestamps
);

-- Subscriptions (grants access to profiles under billing terms)
CREATE TABLE subscriptions (
  id UUID PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  plan_id UUID NOT NULL REFERENCES plans(id) ON DELETE RESTRICT,
  profile_slug VARCHAR(50) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'active',
  cu_used_this_period BIGINT NOT NULL DEFAULT 0,
  period_start TIMESTAMPTZ,
  period_end TIMESTAMPTZ,
  timestamps
);

-- One active subscription per account+profile
CREATE UNIQUE INDEX subscriptions_account_profile_active_unique
  ON subscriptions (account_id, profile_slug) WHERE status = 'active';

-- API Keys (full key stored for validation)
CREATE TABLE api_keys (
  id UUID PRIMARY KEY,
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  full_key VARCHAR(64) NOT NULL UNIQUE,
  key_prefix VARCHAR(12) NOT NULL,
  name VARCHAR(100),
  enabled BOOLEAN NOT NULL DEFAULT true,
  expires_at TIMESTAMPTZ
);

-- Seed data for plans
INSERT INTO plans (slug, name, tier, commercial_rps_limit, commercial_burst_limit, cu_quota_monthly, monthly_price_cents)
VALUES
  ('free', 'Free', 'free', 10, 20, 100000, 0),
  ('pro', 'Pro', 'pro', 100, 200, NULL, 2900),
  ('byok', 'BYOK', 'byok', 1000, 2000, NULL, 9900);
```

### Stripe Compatibility

This model maps to Stripe:

| Our Model | Stripe Concept |
|-----------|----------------|
| Plan | Stripe Price |
| Subscription | Stripe Subscription Item |
| Account's subscriptions | One Stripe Subscription with multiple Items |

Adding a profile = adding a Subscription Item to customer's Stripe Subscription.

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

### HTTP Request Flow

```
Client Request (POST /rpc/:profile/:chain)
    │
    ├── 1. API Key Validation (APIKeyAuthPlug) (< 0.2ms)
    │   - Extract key from header/query
    │   - ETS lookup: full_key → cache_data
    │   - Fallback to DB on cache miss
    │   - Assign: api_key_cache_data (includes subscriptions map)
    │
    ├── 2. Profile Resolution (ProfileResolverPlug) (< 0.1ms)
    │   - Extract profile from path (default: "default")
    │   - Validate profile exists in ConfigStore
    │   - Check subscription access (O(1) map lookup)
    │   - Check quota: cu_used_this_period < cu_quota_monthly
    │   - Assign: profile, cached_subscription, cached_plan
    │
    ├── 3. Rate Limit Check (RateLimitPlug) (< 0.1ms)
    │   - Hammer (ETS backend): {account_id, profile} bucket
    │   - Effective limit: min(commercial_rps_limit, profile.rps_limit)
    │
    ├── 4. Request Pipeline (Core - OSS)
    │   - Profile-scoped provider selection
    │   - Circuit breaker gating
    │   - Upstream request with timeout
    │   - Retry/failover on failure
    │
    └── 5. CU Recording (CUPlug, before_send callback)
        - Calculate CU: (bytes_in + bytes_out) / 1024 * multiplier
        - Record to ETS accumulator (~0.001ms, lock-free)
        - Batch flush to DB every 10 seconds

Total Lasso overhead target: < 10ms (excluding upstream latency)
```

### WebSocket Request Flow

```
WebSocket Connect (ws/rpc/:profile/:chain?key=...)
    │
    ├── 1. Validate API Key & Subscription
    │   - Same as HTTP flow steps 1-2
    │   - Store subscription_id in socket state
    │
    └── 2. Compute Effective RPS Limit
        - min(plan.commercial_rps_limit, profile.rps_limit)

Per-Request:
    │
    ├── 1. Rate Limit Check (per-request)
    ├── 2. Quota Check (lightweight, from cached data)
    ├── 3. Execute RPC Method
    └── 4. Record CU (method + request_bytes + response_bytes)

Push Events (eth_subscription notifications):
    └── Record CU with 0.25x multiplier (server-initiated, generous)
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

### CU Recording Strategy

**Post-Request Accumulation**:

1. Request completes and response size is known
2. CU calculated: `max(1, ceil((bytes_in + bytes_out) / 1024 * multiplier))`
3. CU recorded to ETS accumulator (lock-free, ~0.001ms)
4. Accumulator flushes to DB every 10 seconds via `increment_cu_usage/2`

**Quota Enforcement**:

- Pre-request check against cached `cu_used_this_period`
- Allows slight overdraw between flush intervals (acceptable tradeoff)
- Period rotation resets usage to 0 at billing boundaries

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

**Status**: ✅ Implemented

**Goal**: User accounts, API keys, and profile-based subscriptions

**Implemented in `lasso-cloud`**:

| Component               | Description                                    | File(s)                                        |
| ----------------------- | ---------------------------------------------- | ---------------------------------------------- |
| Account model           | External auth (Clerk), account creation        | `lib/lasso_cloud/accounts/account.ex`          |
| API key generation      | Secure key generation with prefix              | `lib/lasso_cloud/auth/api_keys.ex`             |
| Key validation          | ETS-cached lookup with DB fallback             | `lib/lasso_cloud/auth/key_cache.ex`            |
| API key auth plug       | Extract and validate keys from requests        | `lib/lasso_cloud/auth/plugs/api_key_auth_plug.ex` |
| Subscription model      | Profile-based subscriptions (Account+Profile+Plan) | `lib/lasso_cloud/subscriptions/subscription.ex` |
| Subscription helpers    | Cache data utilities                           | `lib/lasso_cloud/subscriptions/subscription_helpers.ex` |
| Plans                   | Billing templates (free, pro, byok)            | `lib/lasso_cloud/billing/plan.ex`              |
| Profile access control  | Subscription-based profile access              | `lib/lasso_web/plugs/profile_resolver_plug.ex` |

**Security implemented**:

- [x] Constant-time hash comparison via ETS lookup
- [x] Secrets never logged (full_key stored but not exposed)
- [x] HTTPS enforced at infrastructure level

**Outcome**: Users can authenticate with API keys and access profiles based on their subscriptions.

---

### Phase 2: Metering and Rate Limiting

**Status**: ✅ Implemented

**Goal**: Track CU usage and enforce quotas/rate limits

**Implemented in `lasso-cloud`**:

| Component               | Description                                    | File(s)                                        |
| ----------------------- | ---------------------------------------------- | ---------------------------------------------- |
| CU cost calculation     | Bytes-based with method multipliers            | `lib/lasso_cloud/metering/cu_cost.ex`          |
| CU accumulator          | ETS buffer with periodic DB flush (10s)        | `lib/lasso_cloud/metering/cu_accumulator.ex`   |
| HTTP metering           | Plug-based metering via before_send            | `lib/lasso_cloud/metering/cu_plug.ex`          |
| WebSocket metering      | Per-request and push event metering            | `lib/lasso_web/sockets/rpc_socket.ex`          |
| Period rotation         | Automatic billing period reset                 | `lib/lasso_cloud/subscriptions/period_rotation_worker.ex` |
| Quota enforcement       | 429 response when quota exceeded               | `lib/lasso_web/plugs/profile_resolver_plug.ex` |
| Rate limiting           | Per-account+profile RPS limits via Hammer      | `lib/lasso_cloud/rate_limit.ex`                |

**Architecture**:
- ETS write latency: ~0.001ms (lock-free)
- DB flush interval: 10 seconds
- Period check interval: 1 minute
- Rate limit: Sliding window via Hammer

**Security implemented**:

- [x] Quota checked per-request (cached data, O(1))
- [x] Rate limits scoped to account+profile (no bypass via multiple keys)
- [x] Period rotation handles edge cases (deleted subscriptions)

**Outcome**: Free tier quota enforced; usage tracked per-subscription; rate limiting active.

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
| 3.1     | Jan 2026 | Phase 1-2 implementation: profile-based subscriptions, CU metering, quota enforcement, period rotation |

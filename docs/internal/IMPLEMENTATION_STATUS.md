# Lasso Cloud Implementation Status

**Last Updated**: January 2025  
**Product Spec Version**: 3.0  
**Assessment Date**: Current

## Executive Summary

You're approximately **40-50% complete** toward the full product spec. The foundation (Phase 0 and Phase 1) is solid, but critical Phase 2 features (CU metering, credit system) are missing, and Phases 3-5 haven't started.

**Current State**:
- ✅ **Phase 0**: Complete (Profile foundation)
- ✅ **Phase 1**: ~90% complete (Identity foundation - missing subscription cache ETS)
- ⚠️ **Phase 2**: ~30% complete (Rate limiting done, CU metering missing)
- ❌ **Phase 3**: 0% (Pro tier not started)
- ❌ **Phase 4**: 0% (BYOK tier not started)
- ❌ **Phase 5**: 0% (Polish and scale not started)

**Critical Path to Launch**: Phase 2 completion is blocking everything else. Without CU metering and credit balances, you cannot launch paid tiers.

---

## Phase 0: Profile Foundation ✅

**Status**: Complete

All core routing infrastructure is in place:
- ✅ Profile-scoped routing with full isolation
- ✅ Config backend abstraction (File/DB)
- ✅ Global vs profile-scoped component architecture
- ✅ Two-phase initialization (ETS → supervisors → load)
- ✅ Best-effort hot reload
- ✅ Chain name validation (canonical allowlist)

**No action needed** - This is your solid foundation.

---

## Phase 1: Identity Foundation ⚠️

**Status**: ~90% Complete

### ✅ Completed

1. **Account Model**
   - ✅ Accounts table with WorkOS integration
   - ✅ External auth provider support (WorkOS)
   - ✅ Account creation/update from external auth
   - ✅ Default subscription provisioning on account creation

2. **API Key System**
   - ✅ API key generation (`lasso_` prefix, base62 encoding)
   - ✅ Key storage (full keys in DB for display)
   - ✅ ETS-based key cache (`KeyCache`) for fast lookups
   - ✅ Key validation plug (`APIKeyAuthPlug`)
   - ✅ Multiple auth methods (header, Bearer token, query param)
   - ✅ Key management UI (generate, list, revoke)
   - ✅ Constant-time lookups (ETS cache)

3. **Subscription Model**
   - ✅ Subscriptions table (links accounts to profiles)
   - ✅ Subscription status management (active/suspended/cancelled)
   - ✅ Rate limit fields (rps_limit, burst_limit)
   - ✅ Subscription access checks in request flow

4. **Authentication Flow**
   - ✅ WorkOS OAuth integration
   - ✅ Session management (cookie-based)
   - ✅ Dashboard authentication (optional and required)
   - ✅ Account loading from session

### ⚠️ Missing / Incomplete

1. **Subscription Schema Mismatch**
   - ❌ Missing `cu_limit` field (BIGINT)
   - ❌ Missing `cu_used_this_period` field (BIGINT)
   - ❌ Missing `period_start` field (TIMESTAMPTZ)
   - ❌ Missing `period_end` field (TIMESTAMPTZ)
   - ❌ Missing `rps_limit_override` field (INTEGER, nullable)
   - ❌ Missing `burst_limit_override` field (INTEGER, nullable)
   - **Impact**: Cannot track CU usage or enforce monthly limits

2. **Subscription Cache (ETS)**
   - ❌ No ETS cache for subscription lookups (currently DB queries)
   - ❌ No cache warming on startup
   - ❌ No PubSub invalidation on subscription updates
   - **Impact**: Subscription checks hit DB on every request (slow)

3. **API Key Security**
   - ⚠️ Keys stored as plaintext in DB (not hashed)
   - ⚠️ No constant-time hash comparison (using direct string match)
   - **Impact**: Security risk if DB is compromised

4. **Account Schema Mismatch**
   - ❌ Missing `tier` field (VARCHAR(20), default 'free')
   - ❌ Missing `wallet_address` field (VARCHAR(42), nullable)
   - ❌ Missing `password_hash` field (VARCHAR(255), nullable) - though using WorkOS, so may not be needed
   - **Impact**: Cannot distinguish free vs pro vs BYOK accounts

### Required Work

1. **Migration**: Add missing subscription fields
   ```elixir
   add :cu_limit, :bigint, null: false, default: 100_000
   add :cu_used_this_period, :bigint, null: false, default: 0
   add :period_start, :utc_datetime, null: false
   add :period_end, :utc_datetime, null: false
   add :rps_limit_override, :integer
   add :burst_limit_override, :integer
   ```

2. **Subscription Cache**: Create `LassoCloud.Subscriptions.Cache` (similar to `KeyCache`)
   - ETS table: `:lasso_subscriptions`
   - Cache key: `{account_id, profile_slug}`
   - Cache value: `%{status: "active", cu_limit: ..., rps_limit: ...}`
   - Warm on startup, invalidate on updates

3. **API Key Hashing**: Consider hashing keys in DB (though current approach is acceptable for Phase 1)

4. **Account Tier Field**: Add `tier` field to accounts table

---

## Phase 2: Metering and Rate Limiting ⚠️

**Status**: ~30% Complete

### ✅ Completed

1. **Rate Limiting**
   - ✅ Rate limit plug (`LassoCloud.RateLimit.Plug`)
   - ✅ Per-account+profile rate limiting (Hammer with ETS backend)
   - ✅ RPS limits from subscription
   - ✅ 429 responses with Retry-After header
   - ✅ Burst limit support (though not fully implemented)

### ❌ Missing / Critical Gaps

1. **CU Cost Calculation**
   - ❌ No CU calculation module
   - ❌ No method multiplier mapping
   - ❌ No bytes-based calculation
   - ❌ No minimum CU enforcement (1 CU per request)
   - **Impact**: Cannot meter usage or charge customers

2. **Usage Recording**
   - ❌ No `usage_daily` table
   - ❌ No async usage buffer (ETS)
   - ❌ No periodic flush to DB
   - ❌ No usage tracking per request
   - **Impact**: No usage history or analytics

3. **Credit Balance System**
   - ❌ No `credit_balances` table
   - ❌ No credit reservation system
   - ❌ No atomic credit operations
   - ❌ No balance constraints
   - **Impact**: Cannot support Pro tier prepaid credits

4. **CU Limit Enforcement**
   - ❌ No periodic CU limit checks (60s interval)
   - ❌ No over-limit subscription marking in ETS
   - ❌ No CU limit exceeded responses (402 Payment Required)
   - **Impact**: Free tier cannot enforce monthly CU limits

5. **Dashboard Usage View**
   - ❌ No CU usage graphs
   - ❌ No usage history display
   - ❌ No cost breakdown
   - **Impact**: Users cannot see their usage

6. **Low Balance Alerts**
   - ❌ No email alerts
   - ❌ No threshold monitoring
   - **Impact**: Users hit limits unexpectedly

### Required Work

1. **CU Calculation Module** (`LassoCloud.Metering.CUCalculator`)
   ```elixir
   defmodule LassoCloud.Metering.CUCalculator do
     @bytes_per_cu 1024
     @method_multipliers %{
       "eth_blockNumber" => 1.0,
       "eth_chainId" => 1.0,
       "eth_call" => 1.5,
       "eth_estimateGas" => 1.5,
       "eth_getLogs" => 2.0,
       "debug_traceTransaction" => 5.0,
       "trace_block" => 5.0
     }
     
     def calculate(method, bytes_in, bytes_out) do
       base_cu = div(bytes_in + bytes_out, @bytes_per_cu)
       multiplier = Map.get(@method_multipliers, method, 1.0)
       max(1, trunc(base_cu * multiplier))
     end
   end
   ```

2. **Usage Buffer** (`LassoCloud.Metering.UsageBuffer`)
   - ETS table for buffering usage events
   - Periodic flush (every 60s or 1000 events)
   - Write to `usage_daily` table

3. **Credit Balance System** (`LassoCloud.Credits`)
   - Migration: Create `credit_balances` table
   - Schema: `LassoCloud.Credits.CreditBalance`
   - Context: `LassoCloud.Credits` with `reserve/3`, `confirm/2`, `refund/2`
   - Atomic operations with DB constraints

4. **CU Limit Checker** (`LassoCloud.Metering.LimitChecker`)
   - Periodic task (every 60s)
   - Check `cu_used_this_period >= cu_limit`
   - Mark over-limit subscriptions in ETS
   - Update subscription status if needed

5. **Request Flow Integration**
   - Add CU calculation in request pipeline
   - Add CU pre-authorization (reserve credits for Pro tier)
   - Add post-request CU recording (async)
   - Add CU limit checks before request processing

6. **Usage Dashboard**
   - Create `UsageLive` view
   - Graph CU usage over time
   - Show current period usage vs limit
   - Show credit balance (for Pro tier)

---

## Phase 3: Pro Tier Launch ❌

**Status**: 0% Complete

### ❌ All Missing

1. **Stripe Integration**
   - ❌ No Stripe client
   - ❌ No customer creation
   - ❌ No payment method management
   - ❌ No webhook handling

2. **Credit Purchase Flow**
   - ❌ No purchase UI
   - ❌ No package selection
   - ❌ No checkout flow
   - ❌ No credit account creation

3. **Credit Deduction**
   - ❌ No reserve-and-reconcile system
   - ❌ No provider ownership tracking
   - ❌ No conditional CU charging

4. **Pro Profile Assignment**
   - ❌ No automatic subscription to `lasso-premium` on purchase
   - ❌ No profile upgrade flow

5. **Receipts/Invoices**
   - ❌ No receipt generation
   - ❌ No invoice system

6. **Balance Dashboard**
   - ❌ No credit balance display
   - ❌ No usage rate calculation
   - ❌ No low balance warnings

**Blocked By**: Phase 2 (credit system must exist first)

---

## Phase 4: BYOK Tier Launch ❌

**Status**: 0% Complete

### ❌ All Missing

1. **Profile Editor UI**
   - ❌ No visual profile editor
   - ❌ No YAML editor mode
   - ❌ No profile creation flow

2. **BYOK Endpoint Validation**
   - ❌ No SSRF prevention
   - ❌ No IP range validation (RFC1918, loopback)
   - ❌ No port validation
   - ❌ No DNS resolution validation

3. **Subscription Billing**
   - ❌ No monthly charge system
   - ❌ No subscription management

4. **Hybrid Metering**
   - ❌ No provider ownership tracking
   - ❌ No conditional CU charging (user's nodes vs Lasso nodes)

5. **Cost Visibility Dashboard**
   - ❌ No cost breakdown (your nodes vs Lasso)
   - ❌ No hybrid usage tracking

**Blocked By**: Phase 2 (metering must exist first)

---

## Phase 5: Polish and Scale ❌

**Status**: 0% Complete

### ❌ All Missing

1. **Key Rotation**
   - ❌ No overlap period support
   - ❌ No graceful deprecation

2. **Wallet Authentication**
   - ❌ No sign-to-login flow
   - ❌ No wallet address verification

3. **Team/Org Support**
   - ❌ No multi-user accounts
   - ❌ No organization model

4. **Distributed Rate Limiting**
   - ❌ No Redis backend option
   - ❌ Currently ETS-only (single node)

5. **Geo-Distributed Edge**
   - ❌ No multi-region deployment config
   - ❌ No region-specific routing

6. **Public Status Page**
   - ❌ No provider uptime transparency
   - ❌ No public status API

**Not Blocking**: These are nice-to-haves for scale, not required for launch.

---

## Database Schema Gaps

### Missing Tables

1. **`credit_balances`** (Phase 2)
   ```sql
   CREATE TABLE credit_balances (
     id UUID PRIMARY KEY,
     account_id UUID UNIQUE NOT NULL REFERENCES accounts(id),
     balance BIGINT NOT NULL DEFAULT 0,
     reserved BIGINT NOT NULL DEFAULT 0,
     lifetime_purchased BIGINT NOT NULL DEFAULT 0,
     lifetime_used BIGINT NOT NULL DEFAULT 0
   );
   ```

2. **`usage_daily`** (Phase 2)
   ```sql
   CREATE TABLE usage_daily (
     id UUID PRIMARY KEY,
     account_id UUID NOT NULL REFERENCES accounts(id),
     profile_slug VARCHAR(50) NOT NULL,
     date DATE NOT NULL,
     cu_used BIGINT NOT NULL DEFAULT 0,
     request_count BIGINT NOT NULL DEFAULT 0,
     UNIQUE (account_id, profile_slug, date)
   );
   ```

3. **`profiles`** (Phase 4 - for BYOK)
   ```sql
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
   ```

### Missing Fields

1. **`accounts` table**
   - `tier` VARCHAR(20) DEFAULT 'free'
   - `wallet_address` VARCHAR(42) (nullable)

2. **`subscriptions` table**
   - `cu_limit` BIGINT
   - `cu_used_this_period` BIGINT
   - `period_start` TIMESTAMPTZ
   - `period_end` TIMESTAMPTZ
   - `rps_limit_override` INTEGER (nullable)
   - `burst_limit_override` INTEGER (nullable)

---

## Request Flow Status

### Current Flow (Partial)

```
1. Profile Resolution ✅
2. API Key Validation ✅
3. Subscription Check ⚠️ (DB query, should be ETS)
4. Rate Limit Check ✅
5. CU Pre-Authorization ❌ (Missing)
6. Request Pipeline ✅ (Core OSS)
7. Post-Request Processing ⚠️ (Partial - no CU recording)
```

### Missing Steps

1. **CU Pre-Authorization** (Step 5)
   - Calculate CU cost
   - Reserve credits (Pro tier)
   - Store reservation_id

2. **Post-Request CU Recording** (Step 7)
   - Record CU usage
   - Finalize reservation (confirm/refund)
   - Update usage buffer

---

## Security Gaps

### Critical

1. **API Key Storage**
   - ⚠️ Keys stored as plaintext (not hashed)
   - Consider hashing for defense-in-depth

2. **Constant-Time Comparison**
   - ⚠️ Using direct string match (not constant-time)
   - Should use `Plug.Crypto.secure_compare/2`

### Medium Priority

1. **SSRF Prevention** (Phase 4)
   - Not implemented (BYOK not started)

2. **Rate Limit Bypass**
   - ⚠️ ETS backend is per-node (not distributed)
   - Multiple keys from same account share same bucket (good)
   - But multiple nodes = separate counters (acceptable for Phase 1)

---

## Recommended Implementation Order

### Immediate (Blocking Launch)

1. **Complete Phase 1** (1-2 days)
   - Add missing subscription fields
   - Create subscription ETS cache
   - Add account tier field

2. **Implement Phase 2 Core** (1-2 weeks)
   - CU calculation module
   - Usage buffer and recording
   - Credit balance system
   - CU limit enforcement
   - Request flow integration

3. **Phase 2 Dashboard** (3-5 days)
   - Usage graphs
   - CU usage display
   - Low balance alerts

### Short Term (Enable Paid Tiers)

4. **Phase 3: Pro Tier** (2-3 weeks)
   - Stripe integration
   - Credit purchase flow
   - Reserve-and-reconcile
   - Pro profile assignment

### Medium Term (Expand Market)

5. **Phase 4: BYOK Tier** (3-4 weeks)
   - Profile editor
   - SSRF validation
   - Hybrid metering
   - Monthly billing

### Long Term (Scale)

6. **Phase 5: Polish** (Ongoing)
   - Key rotation
   - Wallet auth
   - Distributed rate limiting
   - Multi-region

---

## Estimated Time to Launch

**Minimum Viable Launch** (Free tier only):
- Phase 1 completion: 1-2 days
- Phase 2 core (CU metering, limits): 1-2 weeks
- Testing and polish: 1 week
- **Total: 3-4 weeks**

**Full Launch** (Free + Pro + BYOK):
- Phase 1-2: 2-3 weeks
- Phase 3: 2-3 weeks
- Phase 4: 3-4 weeks
- Testing and polish: 2 weeks
- **Total: 9-12 weeks**

---

## Critical Dependencies

1. **CU Metering** → Blocks Pro tier
2. **Credit System** → Blocks Pro tier
3. **Subscription Cache** → Performance requirement
4. **Usage Recording** → Analytics and billing
5. **CU Limit Enforcement** → Free tier compliance

---

## Next Steps

1. **Review this assessment** with team
2. **Prioritize Phase 2** (critical path)
3. **Create detailed tickets** for Phase 2 tasks
4. **Set up Stripe account** (for Phase 3)
5. **Design CU calculation** method mapping (complete list)
6. **Plan database migrations** (subscription fields, credit_balances, usage_daily)

---

## Notes

- WorkOS integration is solid - no changes needed
- Rate limiting is functional but needs subscription cache for performance
- Dashboard is good foundation but needs usage views
- Core routing (OSS) is production-ready
- Security is acceptable for Phase 1 but should improve for production



# Lasso RPC Product Specification v2

**Version**: 2.0
**Last Updated**: December 2024
**Status**: Planning (Post-Review)

---

## Document Overview

This specification represents the refined product vision for Lasso RPC following comprehensive technical, UX, and market analysis. It incorporates feedback from:
- UX/Developer Experience review
- EVM technical architecture validation
- Ethereum infrastructure market positioning analysis
- Technical correctness and security audit

### How to Read This Document

- **Decisions** are marked with rationale and confidence level
- **Open Questions** are flagged with `[OPEN]` and expected resolution timing
- **Security Considerations** are marked with `[SECURITY]`
- **Implementation Notes** provide guidance for engineering

---

## Executive Summary

### What is Lasso?

Lasso is a high-performance blockchain RPC aggregator that provides intelligent routing, automatic failover, and deep observability for EVM chains. It routes requests across multiple upstream providers, selecting the best available endpoint based on health, latency, and configuration.

### Strategic Positioning

**Primary positioning**: "The RPC aggregator for infrastructure teams"

Lasso is NOT competing with Alchemy on features (enhanced APIs, SDKs, webhooks). Instead, Lasso owns the **routing and reliability layer** that sits in front of RPC providers—including Alchemy itself.

**Target Users** (in priority order):

| Segment | Pain Point | Lasso Value |
|---------|------------|-------------|
| **Infrastructure Teams** (L2s, bridges, indexers) | Need dedicated nodes + cloud fallback | BYOI with intelligent failover |
| **Cost-Conscious Production Apps** | $5K+/mo Alchemy bills | Multi-provider cost optimization |
| **Privacy-Conscious Developers** | Don't want centralized RPC dependency | Self-hosted OSS + own nodes |
| **Multi-Chain Projects** | Managing different providers per chain | Unified interface, consistent behavior |

### Core Value Proposition

| For... | Lasso Provides... |
|--------|-------------------|
| **Managed service users** | Geo-distributed edge proxying, curated provider pools, zero-config reliability, real-time observability |
| **BYOI users** | Intelligent routing for your own infrastructure, premium fallback when needed, cost visibility |
| **Self-hosters (OSS)** | Full-featured RPC aggregator, dashboard, bring your own providers, no vendor lock-in |

---

## Product Architecture

### Two-Tier Model

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Lasso Core (Open Source)                          │
│  License: AGPL-3.0                                                       │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │ Core Routing Engine                                                 ││
│  │ - HTTP and WebSocket RPC proxying                                   ││
│  │ - Strategy-based provider selection (priority, fastest, round-robin)││
│  │ - Per-provider circuit breakers with configurable thresholds        ││
│  │ - Automatic retry and failover                                      ││
│  │ - Provider health monitoring (block height, latency, errors)        ││
│  └─────────────────────────────────────────────────────────────────────┘│
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │ Configuration System                                                ││
│  │ - YAML-based chain/provider configuration                           ││
│  │ - Multi-profile support (switch between config sets)                ││
│  │ - Runtime provider registration                                     ││
│  │ - Per-chain monitoring and selection parameters                     ││
│  └─────────────────────────────────────────────────────────────────────┘│
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │ Dashboard & Observability                                           ││
│  │ - Real-time network topology visualization                          ││
│  │ - Provider health and circuit breaker status                        ││
│  │ - Request routing decisions stream                                  ││
│  │ - Prometheus-compatible metrics export                              ││
│  │ - Profile selector (switch views)                                   ││
│  └─────────────────────────────────────────────────────────────────────┘│
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │ WebSocket Support                                                   ││
│  │ - eth_subscribe with automatic deduplication                        ││
│  │ - Connection pooling and management                                 ││
│  │ - Subscription lifecycle handling                                   ││
│  └─────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    │ Fork / Extend
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      Lasso Managed Service                               │
│  License: Proprietary                                                    │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │ Identity & Access                                                   ││
│  │ - User accounts with email/password or wallet auth                  ││
│  │ - API key generation and management                                 ││
│  │ - Key → Profile → Tier mapping                                      ││
│  │ - Session management for dashboard access                           ││
│  └─────────────────────────────────────────────────────────────────────┘│
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │ Usage & Billing                                                     ││
│  │ - Compute Unit (CU) based metering                                  ││
│  │ - Per-request cost tracking with provider attribution               ││
│  │ - Credit balance management                                         ││
│  │ - Rate limiting (per-key, per-tier)                                 ││
│  │ - Subscription billing (BYOI tier)                                  ││
│  └─────────────────────────────────────────────────────────────────────┘│
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │ Managed Profiles                                                    ││
│  │ - Pre-configured Lasso Public profile (free tier)                   ││
│  │ - Pre-configured Lasso Premium profile (paid tier)                  ││
│  │ - BYOI profile creation and management                              ││
│  │ - Hybrid profile support (user + Lasso providers)                   ││
│  └─────────────────────────────────────────────────────────────────────┘│
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────────┐│
│  │ Operations                                                          ││
│  │ - Geo-distributed edge deployment configuration                     ││
│  │ - Provider agreements and curated pools                             ││
│  │ - Customer support tooling                                          ││
│  └─────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────┘
```

### Repository Strategy

| Repository | License | Contents | Notes |
|------------|---------|----------|-------|
| `lasso-rpc` (public) | AGPL-3.0 | Core routing, dashboard, profile system | Community contributions welcome |
| `lasso-cloud` (private) | Proprietary | Identity, billing, managed profiles, ops | Forks and tracks upstream |

**OSS/Proprietary Split Considerations**:

The boundary between OSS and proprietary is cleanest when drawn at **identity and billing**. Everything that routes requests and displays data is OSS. Everything that identifies who is making requests and charges for them is proprietary.

```
[WATCH OUT] Complications to monitor:

1. Profile System Boundary
   - OSS: Profile switching, profile-scoped events
   - Proprietary: Profile ownership, access control
   - Risk: If OSS needs to "know" about ownership for metering hooks,
           the boundary gets blurry. Solution: OSS emits events with
           profile_id, proprietary layer interprets ownership.

2. Rate Limiting
   - Could be in OSS (useful for self-hosters)
   - Could be proprietary (tied to billing)
   - Recommendation: Basic rate limiting in OSS (configurable per-profile),
                     advanced limits (CU-based, burst handling) in proprietary

3. Usage Telemetry
   - OSS emits Prometheus metrics (request counts, latencies)
   - Proprietary aggregates for billing
   - Risk: If billing needs more granular data than OSS emits
   - Solution: OSS emits comprehensive telemetry events; proprietary
               subscribes and aggregates. Don't add billing-specific
               code to OSS.

4. Dashboard Access Control
   - OSS dashboard shows all profiles (your deployment, your data)
   - Proprietary dashboard filters by user's accessible profiles
   - Implementation: Proprietary adds auth plug that sets `accessible_profiles`
                     in conn, dashboard respects this list
```

**Sync Strategy**: `lasso-cloud` maintains a fork of `lasso-rpc`. Changes to core routing flow upstream to OSS. Proprietary features are additive modules that hook into OSS extension points (plugs, telemetry handlers, PubSub subscribers).

---

## Product Tiers

### Tier Overview

| Tier | Target User | Price Model | Key Differentiator |
|------|-------------|-------------|-------------------|
| **Free** | Developers, testing | Free (rate limited) | Try before you buy |
| **Pro** | Production apps | Prepaid CU credits | Reliable, fast providers |
| **BYOI** | Infrastructure teams | Monthly subscription + optional CU | Your nodes + Lasso routing |

### Free Tier: Lasso Public

**Purpose**: Developer acquisition, product demonstration, low-stakes production use

| Attribute | Value | Rationale |
|-----------|-------|-----------|
| **Price** | $0 | Acquisition funnel |
| **Monthly Limit** | 100,000 CU | ~100K simple calls, enough for dev/test |
| **Rate Limit** | 10 requests/second | Prevents abuse, pushes heavy users to paid |
| **Providers** | Curated public endpoints | LlamaRPC, PublicNode, DRPC, 1RPC, etc. |
| **Chains** | All supported chains | No artificial restrictions |
| **Dashboard** | Full access (read-only for Public profile) | Shows product value |
| **Support** | Community (GitHub) | Scalable support model |

**Risk Mitigation**:
- Per-key rate limiting prevents single-key abuse
- Monthly CU limit prevents runaway usage
- Public providers have their own limits; Lasso's circuit breakers manage degradation

```
[OPEN] Key Farming Prevention
Concern: Nothing stops creating 1000 keys for 10K RPS capacity
Options:
  a) Email verification required (adds friction)
  b) Phone verification for >1 key per email
  c) Proof-of-work/CAPTCHA on key generation
  d) IP-based rate limiting on key creation
  e) Accept some abuse, monitor and ban patterns

Decision: Start with (a) email verification. Revisit if abuse detected.
Timeline: Decide during Phase 2 implementation
```

### Pro Tier: Lasso Pro

**Purpose**: Production applications needing reliable, fast RPC

| Attribute | Value | Rationale |
|-----------|-------|-----------|
| **Price** | Prepaid CU credits | Simple, predictable, no surprise bills |
| **Providers** | Premium infrastructure | Partner-operated nodes, Alchemy/Infura resale, or Lasso-operated |
| **Rate Limit** | Based on credit tier (100-1000 RPS) | Scales with commitment |
| **Dashboard** | Full access with Pro profile | Complete observability |
| **Support** | Email support | Reasonable for paid tier |

**Credit Packages** (illustrative, pricing TBD):

| Package | CU Credits | Price | Effective Rate |
|---------|------------|-------|----------------|
| Starter | 1M CU | $29 | $0.029/1K CU |
| Growth | 10M CU | $199 | $0.020/1K CU |
| Scale | 100M CU | $1,499 | $0.015/1K CU |

**Credit Behavior**:
- Credits do not expire (or 12-month expiry, TBD)
- Low balance warnings at 20%, 10%, 5%
- On exhaustion: Requests rejected with clear error (no silent degradation)

```
[OPEN] Premium Infrastructure Source
Options:
  a) Partner with independent node operators (revenue share)
  b) Resell Alchemy/Infura (margin play, transparent about backend)
  c) Run Lasso-operated nodes (capital intensive, full control)
  d) Hybrid: Own nodes for critical chains, partners for long tail

Recommendation: Start with (b) for speed to market, migrate to (c)/(d)
                as volume justifies. Be transparent: "Powered by Alchemy"
                is fine if routing adds value.

Timeline: Decide before Phase 4 (Premium tier launch)
```

### BYOI Tier: Bring Your Own Infrastructure

**Purpose**: Infrastructure teams who run their own nodes and want Lasso's routing layer

| Attribute | Value | Rationale |
|-----------|-------|-----------|
| **Price** | $299/month base | Sustainable, obvious ROI vs Alchemy enterprise |
| **Your Providers** | Unlimited, included in subscription | Core value prop |
| **Lasso Providers** | Optional, pay-per-CU | Hybrid flexibility |
| **Dashboard** | Full access, profile editor | Configure your setup |
| **Support** | Email support, priority response | B2B expectation |

**BYOI Value Proposition**:
> "You already run nodes. Lasso makes them more reliable with intelligent routing,
> automatic failover, and real-time observability. When your nodes are overloaded
> or down, Lasso seamlessly routes to premium providers—you only pay for what you use."

**Hybrid Configuration Model**:

```yaml
# Example BYOI profile with hybrid providers
profile:
  name: "Production Infrastructure"
  type: byoi

chains:
  ethereum:
    providers:
      # User's own nodes (included in subscription)
      - id: my-primary-node
        url: https://eth-node-1.mycompany.internal
        ws_url: wss://eth-node-1.mycompany.internal
        priority: 1
        ownership: user

      - id: my-backup-node
        url: https://eth-node-2.mycompany.internal
        priority: 1
        ownership: user

      # Lasso providers (pay per CU when used)
      - ref: lasso-pro-alchemy        # Reference to Lasso catalog
        priority: 2                    # Failover only

      - ref: lasso-public-llamarpc    # Free fallback (rate limited)
        priority: 3
```

**Provider Reference System**:

To prevent ownership fraud (users claiming Lasso providers as their own), BYOI profiles use a **reference system** for Lasso providers:

```
[SECURITY] Provider Namespace Protection

- User-defined providers: Any ID not starting with "lasso-"
- Lasso providers: Referenced by "ref: lasso-*" syntax
- Validation: Profile save rejects provider IDs starting with "lasso-"
- Catalog: Lasso maintains provider catalog with ownership/metering metadata
```

---

## Compute Unit (CU) Pricing Model

### Why CU-Based Pricing?

Flat per-request pricing creates problems:
- `eth_blockNumber` and `eth_getLogs` (10K blocks) have vastly different costs
- Flat pricing either overcharges simple calls or subsidizes expensive ones
- Industry standard (Alchemy, Infura) uses CU/CU-equivalent

### CU Cost Table

| Method | Base CU | Notes |
|--------|---------|-------|
| **Simple Reads** | | |
| `eth_blockNumber` | 1 | Cached, trivial |
| `eth_chainId` | 1 | Cached, trivial |
| `eth_gasPrice` | 1 | |
| `net_version` | 1 | |
| **Standard Reads** | | |
| `eth_getBalance` | 5 | Single account lookup |
| `eth_getTransactionCount` | 5 | |
| `eth_getCode` | 5 | |
| `eth_getStorageAt` | 5 | |
| `eth_getBlockByNumber` | 5 | |
| `eth_getBlockByHash` | 5 | |
| `eth_getTransactionByHash` | 5 | |
| `eth_getTransactionReceipt` | 5 | |
| **Execution** | | |
| `eth_call` | 10 | State execution |
| `eth_estimateGas` | 10 | |
| `eth_createAccessList` | 15 | |
| **Write Operations** | | |
| `eth_sendRawTransaction` | 20 | Propagation cost |
| **Log Queries** | | |
| `eth_getLogs` | 10 + (blocks/100) | Scales with range |
| | | Max: 100 CU (caps at 9000 blocks) |
| **Trace/Debug** | | |
| `trace_block` | 100 | Heavy computation |
| `trace_transaction` | 50 | |
| `debug_traceTransaction` | 100 | |
| `debug_traceCall` | 75 | |
| **Subscriptions** | | |
| `eth_subscribe` (connect) | 10 | One-time on subscribe |
| `eth_subscribe` (per event) | 1 | Per newHeads/logs emitted |

### CU Calculation Implementation

```elixir
defmodule Lasso.Metering.CostModel do
  @moduledoc """
  Calculates Compute Unit cost for RPC methods.
  """

  @simple_reads ~w(eth_blockNumber eth_chainId eth_gasPrice net_version web3_clientVersion)
  @standard_reads ~w(eth_getBalance eth_getTransactionCount eth_getCode eth_getStorageAt
                     eth_getBlockByNumber eth_getBlockByHash eth_getTransactionByHash
                     eth_getTransactionReceipt eth_getBlockTransactionCountByHash
                     eth_getBlockTransactionCountByNumber eth_getUncleByBlockHashAndIndex)
  @execution ~w(eth_call eth_estimateGas)
  @writes ~w(eth_sendRawTransaction eth_sendTransaction)
  @traces ~w(trace_block debug_traceBlock)

  def calculate_cost(method, params) do
    cond do
      method in @simple_reads -> 1
      method in @standard_reads -> 5
      method in @execution -> 10
      method in @writes -> 20
      method == "eth_getLogs" -> calculate_logs_cost(params)
      method in @traces -> 100
      method == "trace_transaction" -> 50
      method == "debug_traceTransaction" -> 100
      method == "debug_traceCall" -> 75
      method == "eth_createAccessList" -> 15
      true -> 5  # Default for unknown methods
    end
  end

  defp calculate_logs_cost(params) do
    case extract_block_range(params) do
      {:ok, range} ->
        # 10 base + 1 per 100 blocks, capped at 100
        min(100, 10 + div(range, 100))
      :error ->
        10  # Default if range can't be determined
    end
  end

  defp extract_block_range([%{"fromBlock" => from, "toBlock" => to} | _]) do
    with {:ok, from_num} <- parse_block_number(from),
         {:ok, to_num} <- parse_block_number(to) do
      {:ok, to_num - from_num}
    end
  end
  defp extract_block_range(_), do: :error

  defp parse_block_number("latest"), do: {:ok, 0}  # Will be resolved
  defp parse_block_number("pending"), do: {:ok, 0}
  defp parse_block_number("earliest"), do: {:ok, 0}
  defp parse_block_number("0x" <> hex), do: {:ok, String.to_integer(hex, 16)}
  defp parse_block_number(_), do: :error
end
```

### Chain-Specific Multipliers

```
[OPEN] Should different chains have different CU costs?

Analysis:
- L2s (Base, Arbitrum) have lower operational costs than mainnet
- But Lasso's costs are routing overhead, not node operation
- Simpler to have uniform pricing across chains

Decision: Start with uniform pricing. Add chain multipliers only if
          economic analysis shows material cost differences.

Timeline: Revisit 6 months post-launch with usage data
```

---

## Identity and Access System

### Evolution from API-Key-Only

Initial design proposed API keys as the sole identity mechanism. Review feedback suggests a lightweight account system provides tangible benefits:

| Benefit | API-Key-Only | With Accounts |
|---------|--------------|---------------|
| Multiple API keys | Can't group keys | Keys grouped under account |
| Key rotation | Generate new, update everywhere | Rotate with overlap period |
| Billing management | Per-key, no consolidation | Account-level billing |
| Dashboard persistence | Session cookie only | Saved preferences, history |
| Team access | Share key (security risk) | Team members, roles |
| Support context | "Which key?" | "Which account?" |

### Recommended: Lightweight Account Model

```
┌─────────────────────────────────────────────────────────────────┐
│                         Account                                  │
│  id: uuid                                                        │
│  email: string (unique)                                          │
│  password_hash: string (optional if wallet auth)                 │
│  wallet_address: string (optional, for wallet auth)              │
│  tier: free | pro | byoi                                         │
│  created_at: datetime                                            │
└─────────────────────────────────────────────────────────────────┘
         │
         │ has_many
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                         API Key                                  │
│  id: uuid                                                        │
│  account_id: uuid (FK)                                           │
│  key_id: string (public, e.g., "lasso_pk_...")                  │
│  secret_hash: string (bcrypt of secret)                          │
│  name: string (user-provided label)                              │
│  profile_id: uuid (which profile this key uses)                  │
│  rate_limit_rps: integer                                         │
│  enabled: boolean                                                │
│  created_at: datetime                                            │
│  last_used_at: datetime                                          │
│  expires_at: datetime (optional)                                 │
└─────────────────────────────────────────────────────────────────┘
         │
         │ belongs_to
         ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Profile                                  │
│  id: uuid                                                        │
│  account_id: uuid (FK, null for managed profiles)               │
│  name: string                                                    │
│  type: managed | byoi                                            │
│  config: jsonb (chains.yml equivalent)                           │
│  created_at: datetime                                            │
│  updated_at: datetime                                            │
└─────────────────────────────────────────────────────────────────┘
```

### Authentication Methods

**Email + Password** (Primary):
- Standard registration flow
- Email verification required
- Password reset via email

**Wallet Authentication** (Secondary):
- Sign message to prove wallet ownership
- No password needed
- Good for crypto-native users

**Implementation**: Support both, let user choose. Account can have password, wallet, or both.

```
[OPEN] Wallet Auth Priority

Question: Should wallet auth be prominent or secondary?
Arguments for prominent:
  - Every Lasso user is a crypto developer with a wallet
  - Reduces friction (no password to remember)
  - Signals crypto-native ethos
Arguments for secondary:
  - Adds complexity to auth flow
  - Some enterprise users prefer email/password
  - Wallet UX still has rough edges

Recommendation: Implement email/password first, add wallet auth in Phase 3
                as a "Connect Wallet" option in account settings.
```

### API Key Management

**Key Lifecycle**:

```
Create Key
    │
    ├── User provides: name, profile selection
    │
    ├── System generates: key_id (lasso_pk_...), secret (lasso_sk_...)
    │
    ├── Secret shown ONCE with:
    │   - Copy button
    │   - Download as .env file
    │   - "I've saved this" confirmation required
    │
    └── Key active immediately

Use Key
    │
    ├── Request includes: Authorization: Bearer lasso_sk_...
    │
    ├── Validation: ETS lookup by key_id prefix, verify secret hash
    │
    └── last_used_at updated (debounced, not every request)

Rotate Key
    │
    ├── User clicks "Rotate" on existing key
    │
    ├── New secret generated, old secret valid for 7 days
    │
    ├── Both secrets work during overlap period
    │
    └── Old secret auto-revoked after 7 days (or user manually revokes)

Revoke Key
    │
    ├── Immediate: Key stops working
    │
    └── Soft delete: Record retained for audit trail
```

**Key Display in Dashboard**:

```
Your API Keys
─────────────────────────────────────────────────────────────────────
Name              Key ID              Profile       Last Used    Actions
─────────────────────────────────────────────────────────────────────
Production        lasso_pk_abc12...   My Infra      2 min ago    [Rotate] [Revoke]
Staging           lasso_pk_def34...   My Infra      3 days ago   [Rotate] [Revoke]
Development       lasso_pk_ghi56...   Lasso Public  1 hour ago   [Rotate] [Revoke]
─────────────────────────────────────────────────────────────────────
                                                    [+ Create New Key]
```

### Session Management

**Dashboard Access**:
1. User logs in with email/password or wallet
2. Session cookie set (httpOnly, secure, 7-day expiry)
3. Dashboard fetches account's accessible profiles
4. API keys never shown in dashboard (only key_id, never secret)

**API Access**:
1. Every request includes API key in Authorization header
2. No session required for API calls
3. Key → Account → Profile resolution on each request

---

## Request Flow (Managed Service)

```
Client Request (POST /rpc/ethereum)
    │
    │ Headers: Authorization: Bearer lasso_sk_...
    │          Content-Type: application/json
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│ 1. API Key Extraction Plug                            < 0.1ms  │
│    - Extract key from Authorization header                      │
│    - Parse key_id from "lasso_sk_" prefix                      │
│    - Attach raw key to conn for validation                     │
└─────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. API Key Validation Plug                            < 0.2ms  │
│    - ETS lookup: key_id → {secret_hash, account_id, profile_id}│
│    - [SECURITY] Constant-time hash comparison                  │
│    - Reject if invalid (401 before JSON parsing)               │
│    - Attach account_id, profile_id to conn                     │
└─────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. Rate Limit Check Plug                              < 0.1ms  │
│    - ETS counter: {account_id, :rps} with sliding window       │
│    - Reject if over limit (429 with Retry-After)               │
│    - For Pro: Also check CU balance (see below)                │
└─────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. JSON-RPC Parsing                                   < 2ms    │
│    - Parse request body                                         │
│    - Extract method, params, id                                 │
│    - Validate JSON-RPC 2.0 structure                           │
└─────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. CU Pre-Authorization (Pro/BYOI with Lasso providers)        │
│    - Calculate CU cost for method                     < 0.1ms  │
│    - [SECURITY] Atomic: UPDATE credits SET balance =           │
│                         balance - cost WHERE balance >= cost    │
│    - If insufficient: 402 Payment Required                     │
│    - Store reserved CU in RequestContext                       │
└─────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│ 6. Request Pipeline (Core - from OSS)                 < 5ms    │
│    - Chain resolution (chain name → config)                    │
│    - Provider selection (strategy + circuit breaker gating)    │
│    - Upstream request with timeout                             │
│    - Retry/failover on failure                                 │
│    - Response handling                                         │
└─────────────────────────────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────────────────────────────┐
│ 7. Post-Request Processing                            async    │
│    - Record provider that served request                       │
│    - If provider.ownership == :lasso → CU already deducted     │
│    - If provider.ownership == :user → refund reserved CU       │
│    - Emit telemetry events                                     │
│    - Update last_used_at (debounced)                          │
└─────────────────────────────────────────────────────────────────┘
    │
    ▼
Response to Client

Total Lasso overhead target: < 10ms (excluding upstream latency)
```

### CU Deduction Strategy

The key insight: we don't know which provider will serve the request until after selection. But we need to prevent overdraw.

**Solution: Reserve-and-Reconcile**

```elixir
# In CU Pre-Authorization plug
def call(conn, _opts) do
  method = conn.assigns.jsonrpc_method
  params = conn.assigns.jsonrpc_params
  profile = conn.assigns.profile
  account_id = conn.assigns.account_id

  # Calculate max possible CU (assumes Lasso provider serves it)
  max_cu = CostModel.calculate_cost(method, params)

  # Check if profile has any Lasso providers
  has_lasso_providers = Enum.any?(profile.providers, & &1.ownership == :lasso)

  if has_lasso_providers do
    # Reserve CU atomically
    case CreditBalance.reserve(account_id, max_cu) do
      {:ok, reservation_id} ->
        conn
        |> assign(:cu_reservation, {reservation_id, max_cu})

      {:error, :insufficient_credits} ->
        conn
        |> put_status(402)
        |> json(%{error: %{code: -32000, message: "Insufficient CU credits"}})
        |> halt()
    end
  else
    # Pure BYOI profile, no CU needed
    conn
  end
end

# In Post-Request Processing
def finalize_cu(conn) do
  case conn.assigns[:cu_reservation] do
    nil ->
      :ok  # No reservation to finalize

    {reservation_id, reserved_cu} ->
      provider = conn.assigns.selected_provider
      provider_config = get_provider_config(conn.assigns.profile, provider.id)

      case provider_config.ownership do
        :user ->
          # Request served by user's node, refund the reservation
          CreditBalance.refund(reservation_id)

        :lasso ->
          # Request served by Lasso provider, confirm the charge
          CreditBalance.confirm(reservation_id)
      end
  end
end
```

**Why This Works**:
1. CU reserved before request (prevents overdraw)
2. Reservation is atomic (DB constraint: balance >= 0)
3. Reconciliation determines actual charge
4. User nodes = refund, Lasso nodes = confirm

---

## Dashboard Architecture

### Multi-Tenant Event Model

The dashboard shows real-time events scoped to the user's accessible profiles.

**Event Flow**:

```
Request Pipeline
    │
    ├── On routing decision:
    │   Phoenix.PubSub.broadcast(
    │     Lasso.PubSub,
    │     "routing:#{profile_id}",
    │     {:routing_decision, %{provider_id, latency, success, ...}}
    │   )
    │
    ├── On circuit breaker event:
    │   Phoenix.PubSub.broadcast(
    │     Lasso.PubSub,
    │     "circuit:#{profile_id}",
    │     {:circuit_event, %{provider_id, state, reason, ...}}
    │   )
    │
    └── On provider health update:
        Phoenix.PubSub.broadcast(
          Lasso.PubSub,
          "health:#{profile_id}",
          {:health_update, %{provider_id, block_height, latency, ...}}
        )

Dashboard LiveView
    │
    ├── On mount:
    │   accessible_profiles = get_accessible_profiles(current_user)
    │   for profile <- accessible_profiles do
    │     Phoenix.PubSub.subscribe(Lasso.PubSub, "routing:#{profile.id}")
    │     Phoenix.PubSub.subscribe(Lasso.PubSub, "circuit:#{profile.id}")
    │     Phoenix.PubSub.subscribe(Lasso.PubSub, "health:#{profile.id}")
    │   end
    │
    └── On event:
        handle_info({:routing_decision, data}, socket) ->
          # Update UI with new event
```

### Scaling Considerations

```
[NOTE] Dashboard Scaling (User Feedback Integration)

Initial concern: High-volume API keys could overwhelm dashboard with events.

Resolution: Since events are scoped to profile_id, and each dashboard
connection only subscribes to profiles the user can access, the load
is naturally distributed:

- Free tier users: 1 profile (Lasso Public), low volume (rate limited)
- Pro tier users: 1 profile (Lasso Pro), moderate volume
- BYOI users: 1 profile (their config), varies by usage

Sampling is NOT needed initially because:
1. Each user sees only their own events
2. Rate limits cap event volume per key
3. LiveView already handles client-side buffering

When to revisit:
- If single API keys exceed 1K RPS sustained
- If we add shared/team profiles with multiple viewers
- If we add aggregate views across all profiles

For now: Ship without sampling, monitor LiveView memory per connection.
```

### Dashboard Features by Tier

| Feature | Free | Pro | BYOI |
|---------|------|-----|------|
| Real-time topology view | ✓ (Public profile) | ✓ (Pro profile) | ✓ (Custom profile) |
| Request routing stream | ✓ | ✓ | ✓ |
| Provider health status | ✓ | ✓ | ✓ |
| Circuit breaker state | ✓ | ✓ | ✓ |
| CU usage graphs | ✓ (limited data) | ✓ | ✓ |
| Profile editor | - | - | ✓ |
| API key management | ✓ | ✓ | ✓ |
| Cost breakdown | - | ✓ | ✓ |
| Provider attribution | - | ✓ | ✓ |

### BYOI Profile Editor

```
┌─────────────────────────────────────────────────────────────────────────┐
│ Profile Configuration: Production Infrastructure                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  [Visual Editor]  [YAML]  [Import]                                     │
│  ═══════════════                                                        │
│                                                                         │
│  Ethereum Mainnet                                           [+ Add Chain]│
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ Providers (drag to reorder priority)                            │   │
│  │                                                                   │   │
│  │ ⣿ 1. my-primary-node                              [Your Node]   │   │
│  │      https://eth-node-1.mycompany.internal                       │   │
│  │      Status: ● Healthy (block 19234567, 45ms)                   │   │
│  │      Cost: Included in subscription                              │   │
│  │                                                       [Edit] [×] │   │
│  │                                                                   │   │
│  │ ⣿ 2. lasso-pro-alchemy                        [Lasso Premium]   │   │
│  │      Failover provider (activates when #1 unavailable)          │   │
│  │      Cost: Per-request CU metering                               │   │
│  │      Est. usage: ~5% of traffic                                  │   │
│  │                                                       [Edit] [×] │   │
│  │                                                                   │   │
│  │ [+ Add Your Provider]  [+ Add Lasso Provider]                   │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  Base                                                                   │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ ... (similar structure)                                          │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  Validation                                                             │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ ✓ YAML syntax valid                                              │   │
│  │ ✓ Required fields present                                        │   │
│  │ ✓ Provider URLs valid format                                     │   │
│  │ ○ Connectivity check (optional)  [Test Connections]             │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│                                            [Cancel]  [Save Profile]    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Security Considerations

### API Key Security

**[SECURITY] Constant-Time Validation**

```elixir
# WRONG - timing attack vulnerable
def validate_key(provided_secret, stored_hash) do
  Bcrypt.verify_pass(provided_secret, stored_hash)
end

# RIGHT - constant time comparison
def validate_key(provided_secret, stored_hash) do
  # Bcrypt.verify_pass is already constant-time, but document this
  # If using custom comparison, use :crypto.hash_equals/2
  Bcrypt.verify_pass(provided_secret, stored_hash)
end
```

**[SECURITY] Key Logging Prevention**

```elixir
# In Plug pipeline, redact secrets from logs
defmodule Lasso.Plugs.SanitizeLogging do
  def call(conn, _opts) do
    conn
    |> put_private(:lasso_key_id, extract_key_id(conn))  # Safe to log
    |> delete_req_header("authorization")                 # Don't log secret
  end
end
```

### BYOI Endpoint Security

**[SECURITY] SSRF Prevention**

Users can configure arbitrary URLs in BYOI profiles. Must prevent:
- Access to internal networks (169.254.x.x, 10.x.x.x, etc.)
- Access to cloud metadata services (169.254.169.254)
- Access to localhost

```elixir
defmodule Lasso.Config.EndpointValidator do
  @blocked_ranges [
    # IPv4 private ranges
    {10, 0, 0, 0, 8},
    {172, 16, 0, 0, 12},
    {192, 168, 0, 0, 16},
    # Loopback
    {127, 0, 0, 0, 8},
    # Link-local (includes AWS metadata)
    {169, 254, 0, 0, 16},
    # IPv6 equivalents...
  ]

  def validate_endpoint(url) do
    uri = URI.parse(url)

    with {:ok, ip} <- resolve_host(uri.host),
         :ok <- check_not_blocked(ip),
         :ok <- check_scheme(uri.scheme) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_scheme(scheme) when scheme in ["http", "https", "ws", "wss"], do: :ok
  defp check_scheme(_), do: {:error, :invalid_scheme}

  defp check_not_blocked(ip) do
    if ip_in_blocked_range?(ip, @blocked_ranges) do
      {:error, :blocked_ip_range}
    else
      :ok
    end
  end
end
```

### Credit System Security

**[SECURITY] Atomic Credit Operations**

```elixir
defmodule Lasso.Billing.CreditBalance do
  @doc """
  Atomically reserve credits. Returns error if insufficient.
  """
  def reserve(account_id, amount) do
    # Single atomic query - no race condition possible
    case Repo.query("""
      UPDATE credit_balances
      SET balance = balance - $1,
          reserved = reserved + $1
      WHERE account_id = $2
        AND balance >= $1
      RETURNING id
    """, [amount, account_id]) do
      {:ok, %{num_rows: 1, rows: [[id]]}} ->
        {:ok, id}
      {:ok, %{num_rows: 0}} ->
        {:error, :insufficient_credits}
    end
  end

  def confirm(reservation_id) do
    # Move from reserved to consumed
    Repo.query("""
      UPDATE credit_balances
      SET reserved = reserved - (
        SELECT amount FROM reservations WHERE id = $1
      )
      WHERE account_id = (
        SELECT account_id FROM reservations WHERE id = $1
      )
    """, [reservation_id])
  end

  def refund(reservation_id) do
    # Return reserved credits to balance
    Repo.query("""
      UPDATE credit_balances
      SET balance = balance + (
        SELECT amount FROM reservations WHERE id = $1
      ),
      reserved = reserved - (
        SELECT amount FROM reservations WHERE id = $1
      )
      WHERE account_id = (
        SELECT account_id FROM reservations WHERE id = $1
      )
    """, [reservation_id])
  end
end
```

### Rate Limit Security

**[SECURITY] Distributed Rate Limiting**

For geo-distributed edge deployment, rate limits must be synchronized:

```
[OPEN] Distributed Rate Limiting Strategy

Options:
a) Centralized Redis (simple, adds latency ~5ms)
b) Local ETS with periodic sync (fast, eventually consistent)
c) Token bucket with distributed refill (complex, accurate)
d) Per-region limits that sum to global limit (simple, wastes capacity)

Recommendation: Start with (a) Redis for simplicity. Latency acceptable
               for rate limit checks. Migrate to (c) if Redis becomes
               bottleneck.

Timeline: Implement during Phase 3 (Rate Limiting)
```

---

## Data Model

### Database Schema (PostgreSQL)

```sql
-- Accounts (identity)
CREATE TABLE accounts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email VARCHAR(255) UNIQUE NOT NULL,
  password_hash VARCHAR(255),  -- NULL if wallet-only auth
  wallet_address VARCHAR(42),  -- NULL if email-only auth
  tier VARCHAR(20) NOT NULL DEFAULT 'free',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT valid_tier CHECK (tier IN ('free', 'pro', 'byoi'))
);

-- API Keys
CREATE TABLE api_keys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  key_id VARCHAR(50) UNIQUE NOT NULL,  -- lasso_pk_...
  secret_hash VARCHAR(255) NOT NULL,
  name VARCHAR(100) NOT NULL,
  profile_id UUID NOT NULL REFERENCES profiles(id),
  rate_limit_rps INTEGER NOT NULL DEFAULT 10,
  enabled BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_used_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ,

  -- For key rotation: old secret hash valid until this time
  old_secret_hash VARCHAR(255),
  old_secret_expires_at TIMESTAMPTZ
);

CREATE INDEX idx_api_keys_key_id ON api_keys(key_id);
CREATE INDEX idx_api_keys_account_id ON api_keys(account_id);

-- Profiles
CREATE TABLE profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID REFERENCES accounts(id) ON DELETE CASCADE,  -- NULL for managed profiles
  name VARCHAR(100) NOT NULL,
  type VARCHAR(20) NOT NULL,
  config JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT valid_type CHECK (type IN ('managed', 'byoi'))
);

-- Managed profiles (seeded, no account_id)
INSERT INTO profiles (id, name, type, config) VALUES
  ('00000000-0000-0000-0000-000000000001', 'Lasso Public', 'managed', '...'),
  ('00000000-0000-0000-0000-000000000002', 'Lasso Pro', 'managed', '...');

-- Credit Balances
CREATE TABLE credit_balances (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID UNIQUE NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  balance BIGINT NOT NULL DEFAULT 0,
  reserved BIGINT NOT NULL DEFAULT 0,  -- Currently reserved for in-flight requests
  lifetime_purchased BIGINT NOT NULL DEFAULT 0,
  lifetime_used BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT non_negative_balance CHECK (balance >= 0),
  CONSTRAINT non_negative_reserved CHECK (reserved >= 0)
);

-- Credit Reservations (for in-flight requests)
CREATE TABLE credit_reservations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  amount INTEGER NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ NOT NULL,  -- Auto-expire stale reservations

  CONSTRAINT positive_amount CHECK (amount > 0)
);

CREATE INDEX idx_credit_reservations_expires ON credit_reservations(expires_at);

-- Usage Records (for analytics, not real-time metering)
CREATE TABLE usage_daily (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  date DATE NOT NULL,
  profile_id UUID NOT NULL REFERENCES profiles(id),

  -- Aggregate metrics
  request_count BIGINT NOT NULL DEFAULT 0,
  cu_consumed BIGINT NOT NULL DEFAULT 0,

  -- Breakdown by provider ownership
  user_provider_requests BIGINT NOT NULL DEFAULT 0,
  lasso_provider_requests BIGINT NOT NULL DEFAULT 0,

  -- Error tracking
  error_count BIGINT NOT NULL DEFAULT 0,

  UNIQUE (account_id, date, profile_id)
);

CREATE INDEX idx_usage_daily_account_date ON usage_daily(account_id, date);

-- Subscriptions (for BYOI tier)
CREATE TABLE subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID UNIQUE NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  plan VARCHAR(50) NOT NULL,
  status VARCHAR(20) NOT NULL,
  stripe_subscription_id VARCHAR(100),
  current_period_start TIMESTAMPTZ NOT NULL,
  current_period_end TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT valid_status CHECK (status IN ('active', 'past_due', 'cancelled', 'trialing'))
);

-- Audit Log (for security and debugging)
CREATE TABLE audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id UUID REFERENCES accounts(id),
  action VARCHAR(50) NOT NULL,
  details JSONB,
  ip_address INET,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_log_account ON audit_log(account_id, created_at);
```

### ETS Caching Layer

```elixir
# API Key Cache (hot path)
# Table: :lasso_api_keys
# Key: key_id (string)
# Value: {secret_hash, account_id, profile_id, rate_limit_rps, enabled}
# Invalidation: On key update/revoke, broadcast to all nodes

# Profile Cache (hot path)
# Table: :lasso_profiles (existing ConfigStore pattern)
# Key: {:chains, profile_id}
# Value: %{chain_name => ChainConfig}
# Invalidation: On profile update, broadcast to all nodes

# Rate Limit Counters (hot path)
# Table: :lasso_rate_limits
# Key: {account_id, window_start_second}
# Value: request_count
# No invalidation needed; entries expire naturally

# Credit Balance Cache (warm path)
# Table: :lasso_credits
# Key: account_id
# Value: {balance, reserved, last_sync_time}
# Invalidation: After DB write, update cache
# Note: Authoritative balance is in DB; cache is for read optimization
```

---

## Implementation Roadmap

### Phase 0: Foundation (Current State → Multi-Profile OSS)

**Goal**: Enable profile switching in OSS dashboard and routing

**Changes to `lasso-rpc`**:

| Task | Description | Complexity |
|------|-------------|------------|
| Extend ConfigStore | Composite keys `{:chains, profile_id}` | Low |
| Thread profile_id | Pass through Selection, RequestPipeline (~30 call sites) | Medium |
| Dashboard profile selector | Dropdown to switch viewed profile | Low |
| Profile-scoped events | Topics include profile_id | Low |
| Documentation | Self-hosting guide with multi-profile examples | Low |

**Outcome**: Self-hosters can define multiple profiles in config and switch between them in dashboard.

**Duration estimate**: [Not providing time estimates per CLAUDE.md]

---

### Phase 1: Identity Foundation

**Goal**: User accounts and API key generation

**New in `lasso-cloud`**:

| Task | Description | Complexity |
|------|-------------|------------|
| Account model | Users table, registration, login | Medium |
| Email verification | Send verification email, confirm flow | Low |
| Session management | JWT or cookie sessions for dashboard | Low |
| API key generation | Create keys, show-once secret | Medium |
| Key management UI | List, name, revoke keys | Low |
| Key validation plug | ETS-cached lookup, constant-time verify | Medium |
| Key → Profile mapping | Free keys → Public, Pro keys → Pro | Low |

**Security requirements**:
- [ ] Constant-time secret comparison
- [ ] Secrets never logged
- [ ] HTTPS only for key transmission

**Outcome**: Users can register, generate API keys, and make authenticated requests.

---

### Phase 2: Metering and Rate Limiting

**Goal**: Track usage and enforce limits

**New in `lasso-cloud`**:

| Task | Description | Complexity |
|------|-------------|------------|
| CU cost calculation | Method → CU lookup with params consideration | Medium |
| Rate limiting plug | Per-account RPS limits, sliding window | Medium |
| Usage recording | Async writes to usage_daily table | Medium |
| Credit balance table | Track CU balance per account | Low |
| Dashboard usage view | Graphs of CU usage over time | Medium |
| Low balance alerts | Email when CU drops below threshold | Low |

**Security requirements**:
- [ ] Atomic credit reservation (DB constraint)
- [ ] Rate limit cannot be bypassed by multiple keys

**Outcome**: Free tier is rate-limited; usage is tracked; foundation for paid tiers.

---

### Phase 3: Pro Tier Launch

**Goal**: Paid tier with credit purchases

**New in `lasso-cloud`**:

| Task | Description | Complexity |
|------|-------------|------------|
| Stripe integration | Customer creation, payment methods | Medium |
| Credit purchase flow | Select package, checkout, credit account | Medium |
| Credit deduction | Reserve-and-reconcile per request | High |
| Pro profile assignment | On purchase, switch key to Pro profile | Low |
| Receipts/invoices | Generate for purchases | Low |
| Balance dashboard | Show credits remaining, usage rate | Medium |

**Outcome**: Users can purchase CU credits and use premium providers.

---

### Phase 4: BYOI Tier Launch

**Goal**: Custom profile creation and hybrid model

**New in `lasso-cloud`**:

| Task | Description | Complexity |
|------|-------------|------------|
| Profile editor UI | Visual + YAML modes | High |
| Provider reference system | `ref: lasso-*` syntax, catalog lookup | Medium |
| BYOI endpoint validation | Format + SSRF protection | Medium |
| Subscription billing | Monthly charge via Stripe | Medium |
| Hybrid metering | Track provider ownership, conditional CU charge | High |
| Cost visibility dashboard | Your nodes vs Lasso breakdown | Medium |

**Security requirements**:
- [ ] SSRF prevention on user endpoints
- [ ] Provider namespace protection
- [ ] Ownership cannot be spoofed

**Outcome**: Full BYOI tier with hybrid provider support.

---

### Phase 5: Polish and Scale

**Goal**: Production hardening

| Task | Description | Complexity |
|------|-------------|------------|
| Key rotation | Overlap period, graceful deprecation | Medium |
| Wallet authentication | Sign-to-login flow | Medium |
| Team/org support | Multiple users per account | High |
| Distributed rate limiting | Redis or distributed counters | High |
| Geo-distributed edge | Multi-region deployment config | High |
| Public status page | Provider uptime transparency | Medium |

**Outcome**: Production-ready managed service.

---

## Success Metrics

### Product Metrics

| Metric | Target | Notes |
|--------|--------|-------|
| Account registrations | Track growth | Leading indicator |
| Free → Pro conversion | > 5% | Key monetization metric |
| BYOI adoption | Track as % of revenue | Validates positioning |
| Monthly active accounts | Track retention | Health indicator |
| CU consumption growth | Month-over-month | Usage health |

### Technical Metrics

| Metric | Target | Notes |
|--------|--------|-------|
| P50 Lasso overhead | < 5ms | Excluding upstream |
| P99 Lasso overhead | < 15ms | Excluding upstream |
| Availability | 99.9% | SLA target |
| Failed requests (Lasso fault) | < 0.1% | Not counting upstream failures |
| API key validation latency | < 1ms P99 | Hot path |
| Credit operation latency | < 5ms P99 | DB round-trip |

### Business Metrics

| Metric | Target | Notes |
|--------|--------|-------|
| Monthly Recurring Revenue | Track | Primary business metric |
| Customer Acquisition Cost | Track | Marketing efficiency |
| Lifetime Value | Track | Retention health |
| Gross Margin | > 60% | After provider costs |

---

## Open Questions Summary

| Question | Category | Expected Resolution |
|----------|----------|---------------------|
| Credit pricing ($/M CU) | Business | Market research + cost analysis |
| BYOI subscription price | Business | Competitive analysis |
| Premium infrastructure source | Operations | Partner conversations |
| Key farming prevention approach | Security | Phase 2 implementation |
| Wallet auth priority | Product | Phase 3 decision |
| Chain cost multipliers | Business | 6 months post-launch |
| Distributed rate limiting approach | Technical | Phase 5 implementation |
| Free tier key expiration policy | Product | Based on abuse patterns |
| Team/org pricing model | Business | Phase 5 planning |

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Public provider rate limiting/blocking | Medium | High | Diversify providers, run fallback nodes |
| Credit system race conditions | Low | Critical | Atomic DB operations, extensive testing |
| SSRF via BYOI endpoints | Medium | Critical | IP blocklist validation |
| Alchemy launches BYOI tier | Medium | High | Move fast, build community moat |
| Key farming abuse | High | Medium | Email verification, monitoring |
| Fork competition (AGPL) | Low | Medium | Stay ahead on features, build brand |
| Silent failover cost surprise | High | High | Proactive notifications, budget limits |

---

## Appendix A: Glossary

| Term | Definition |
|------|------------|
| **CU (Compute Unit)** | Unit of metering; different RPC methods cost different CUs |
| **BYOI** | Bring Your Own Infrastructure; users configure their own RPC endpoints |
| **Profile** | A complete configuration set (chains, providers, settings) |
| **Provider** | An upstream RPC endpoint (e.g., Alchemy, user's node) |
| **Circuit Breaker** | Mechanism to stop sending requests to a failing provider |
| **Selection Strategy** | Algorithm for choosing which provider handles a request |
| **Managed Profile** | Lasso-operated profile (Public, Pro) |
| **User Profile** | BYOI profile created by user |

---

## Appendix B: API Reference (Preview)

### Authentication

All API requests require an API key in the Authorization header:

```
Authorization: Bearer lasso_sk_...
```

### RPC Endpoint

```
POST /rpc/{chain}
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
    "provider": "lasso-pro-alchemy",
    "latency_ms": 45,
    "cu_cost": 1,
    "cu_remaining": 999999
  }
}
```

### WebSocket Endpoint

```
wss://api.lasso.sh/ws/{chain}?key=lasso_sk_...
```

Supports standard `eth_subscribe` methods.

---

## Appendix C: Competitive Positioning

### Lasso vs Alchemy

| Dimension | Alchemy | Lasso |
|-----------|---------|-------|
| Core offering | Full-stack RPC + APIs | Routing + Observability |
| Enhanced APIs | NFT, Token, Webhooks | Not planned |
| Multi-provider | No | Yes (core value) |
| BYOI | No | Yes (key differentiator) |
| OSS | No | Yes (AGPL core) |
| Dashboard | Static metrics | Real-time topology |
| Target user | All developers | Infrastructure teams |

**Positioning**: Lasso is not an Alchemy replacement; it's an Alchemy enhancer. Use Lasso in front of Alchemy (+ Infura + your nodes) for intelligent routing.

### Lasso vs dRPC

| Dimension | dRPC | Lasso |
|-----------|------|-------|
| Decentralization | Core focus | Not a focus |
| Provider network | Permissionless | Curated |
| BYOI | Limited | Full support |
| OSS | No | Yes |
| Dashboard | Basic | Advanced |

**Positioning**: dRPC is for decentralization maximalists. Lasso is for teams who want reliability and control without the decentralization overhead.

---

## Document History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Dec 2024 | Initial draft |
| 2.0 | Dec 2024 | Post-review revision: CU pricing, account system, security hardening, detailed implementation guidance |

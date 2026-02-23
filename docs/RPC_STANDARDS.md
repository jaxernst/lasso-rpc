# Lasso RPC: JSON-RPC Standards & Method Support

## Overview

Lasso provides production-grade routing for stateless Ethereum JSON-RPC reads and subscriptions with intelligent failover, performance-based selection, and comprehensive observability.

**In Scope:**

- Stateless read methods with strategy-based routing
- WebSocket subscriptions with multiplexing and gap-filling
- Transport-agnostic routing (HTTP ↔ WebSocket failover)
- Circuit breakers, rate limit handling, benchmarking

**Out of Scope (Current):**

- Transaction writes without guarantees (nonce management, deduplication)
- Wallet/signing methods (client-side per EIP-1193)
- Stateful filters (require sticky sessions)

---

## Supported Methods by Protocol

### HTTP: Stateless Reads

All standard Ethereum read methods are supported with failover, circuit breakers, and performance-based routing.

**Blocks & Transactions:**

- `eth_blockNumber`, `eth_getBlockByNumber`, `eth_getBlockByHash`
- `eth_getTransactionByHash`, `eth_getTransactionReceipt`, `eth_getBlockTransactionCountByNumber`

**Account State:**

- `eth_getBalance`, `eth_getTransactionCount`, `eth_getCode`, `eth_getStorageAt`

**Execution & Gas:**

- `eth_call`, `eth_estimateGas`, `eth_gasPrice`, `eth_maxPriorityFeePerGas`, `eth_feeHistory`

**Logs & Events:**

- `eth_getLogs` (note: large ranges subject to upstream limits; see best practices below)

**Network Info:**

- `eth_chainId`, `net_version`, `net_listening`, `web3_clientVersion`

**Advanced:**

- `eth_getProof` (EIP-1186 state proofs)
- EIP-1898 block parameter objects (`{blockNumber, blockHash, requireCanonical}`)
- `finalized` and `safe` block tags

**Non-Standard Methods:**

- Debug/tracing: `debug_*`, `trace_*`, `parity_*`, `erigon_*`, `arbtrace_*`
- Chain-specific: `eth_getBlockReceipts` (Alchemy/Erigon), `optimism_*`, etc.
- **Policy:** Forwarded when upstream supports them; no guarantees; may be expensive

### WebSocket: Subscriptions & Reads

**Subscriptions (WS only):**

- `eth_subscribe(["newHeads"])` - Block headers with gap-filling on failover
- `eth_subscribe(["logs", {...filter}])` - Transaction logs with gap-filling on failover
- `eth_subscribe(["newPendingTransactions"])` - Pending tx hashes (no gap-filling)
- `eth_unsubscribe([subscriptionId])`

**WebSocket Reads:**

- All stateless read methods listed above
- **Transport-agnostic routing:** Can route to either HTTP or WS providers based on performance
- Automatic failover across transports (WS → HTTP or HTTP → WS)

---

## Blocked Methods

### Subscriptions Over HTTP ❌

- `eth_subscribe`, `eth_unsubscribe` - Use WebSocket

### Wallet/Signing ❌

- `eth_sign`, `eth_signTransaction`, `eth_signTypedData*`
- `personal_sign`, `personal_*` namespace
- `wallet_*` namespace (EIP-1193 client APIs)
- `eth_accounts` (server-side enumeration insecure)

**Why:** Server-side key management is out of scope

### Transaction Writes ❌

- `eth_sendTransaction`, `eth_sendRawTransaction`

**Why:** Multi-provider routing requires nonce management, tx deduplication, and sticky routing. Enabling writes without these guarantees causes nonce gaps and duplicate transactions.

**Roadmap:** May support writes with proper nonce queue, sticky sessions, and idempotency tracking.

### Stateful Filters ❌

- `eth_newFilter`, `eth_newBlockFilter`, `eth_newPendingTransactionFilter`
- `eth_getFilterChanges`, `eth_getFilterLogs`, `eth_uninstallFilter`

**Why:** Filters are stateful per-provider. Failover breaks filter state.

**Alternative:** Use WebSocket subscriptions (`eth_subscribe`) for real-time events.

### Transaction Pool ❌

- `txpool_content`, `txpool_inspect`, `txpool_status`

**Why:** Provider-specific internal state; no standardization.

---

## Advanced Features

### Batching (HTTP)

Lasso supports JSON-RPC batch requests:

```json
POST /rpc/ethereum
[
  {"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]},
  {"jsonrpc":"2.0","id":2,"method":"eth_gasPrice","params":[]}
]
```

**Behavior:**

- Responses preserve request order
- Each item returns individual `result` or `error`
- Default limit: 50 requests per batch (configurable)
- ID echoing: Exact `id` type and value preserved

### Provider Override

Pin a request to specific provider:

```bash
POST /rpc/ethereum?provider=alchemy_eth
# or
POST /rpc/ethereum
X-Lasso-Provider: alchemy_eth
```

**Failover on override:**

- Default: Return provider's error if it fails
- `?allow_failover=true`: Fall back to strategy-based selection on failure

### Region Biasing

Prefer providers in a specific region:

```bash
POST /rpc/ethereum
X-Lasso-Region: us-east
```

**Behavior:** Filters candidates to specified region before strategy selection (when providers have region tags configured).

---

## Error Handling

Lasso normalizes all responses to JSON-RPC 2.0 format:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32601,
    "message": "Method not found or blocked in this context",
    "data": { "hint": "Use WebSocket for eth_subscribe" }
  }
}
```

**Standard Error Codes:**

- `-32700` Parse error
- `-32600` Invalid Request
- `-32601` Method not found (or blocked)
- `-32602` Invalid params
- `-32603` Internal error (upstream failure)
- `-32000` Server error (proxy/failover errors)

**Context Hints:** Blocked methods include suggestions (e.g., "Use WebSocket for subscriptions").

---

## WebSocket Subscriptions: Reliability

### Gap-Filling on Failover

When a provider fails mid-stream, Lasso automatically:

1. **Detects gap:** Computes missed blocks between last received and current head
2. **HTTP backfill:** Fetches missing blocks/logs via `eth_getBlockByNumber` or `eth_getLogs`
3. **Injects events:** Delivers backfilled events to clients
4. **Resumes stream:** Subscribes to new provider and continues

**Supported Subscription Types:**

- ✅ `newHeads` - Full gap-filling with `eth_getBlockByNumber` backfill
- ✅ `logs` - Full gap-filling with `eth_getLogs` backfill
- ⚠️ `newPendingTransactions` - No gap-filling (pending txs are ephemeral)

**Configuration:**

```elixir
config :lasso, :subscriptions,
  max_backfill_blocks: 32,       # Max blocks to backfill
  backfill_timeout_ms: 30_000,   # Timeout per backfill request
  enable_gap_filling: true       # Enable/disable gap-filling
```

### Multiplexing

Lasso multiplexes client subscriptions to minimize upstream connections:

**Example:** 100 clients subscribe to `newHeads`

- Without multiplexing: 100 upstream WS connections
- With Lasso: 1 upstream connection, fanned out to 100 clients

**Benefits:** Reduced bandwidth, lower rate limit consumption, better scalability.

---

## Best Practices

### Large `eth_getLogs` Queries

**Challenge:** Providers cap log results by block range (typically 2,000-10,000 blocks).

**Recommendations:**

- Page by block range: Query 2,000 blocks at a time
- Filter aggressively: Use `address` and `topics` to narrow results
- Monitor provider signals: Back off on rate limit errors
- Use `:priority` strategy for consistency across paginated queries

**Roadmap:** Automatic pagination/splitting helper.

### Gas Estimation Consistency

`eth_estimateGas` and `eth_call` can vary across providers due to:

- Different node implementations (Geth, Erigon, etc.)
- Timing of state (block lag)
- Gas limit buffers

**Recommendations:**

- Pin estimates to single provider using `?provider=<id>`
- Use `:priority` strategy for consistency
- Add buffer (10-20%) on client side

### Non-Standard Methods

**Policy:** Forward on best-effort basis; no guarantees.

**Examples:**

- `eth_getBlockReceipts` (Alchemy/Erigon) - May not be available on all providers
- `trace_*` methods - Expensive; provider may reject or rate-limit
- Chain-specific methods (`arbtrace_*`, `optimism_*`) - Chain-dependent

**Check Availability:** Use provider override to test specific provider support.

---

## EIP Compatibility

### Supported EIPs

**EIP-1474** (JSON-RPC) - Full baseline method set
**EIP-1898** (Block Params) - Object block identifiers with `blockHash`, `blockNumber`, `requireCanonical`
**EIP-1186** (`eth_getProof`) - State proofs for account/storage
**EIP-1193** (Provider API) - Recognized (wallet methods blocked server-side)
**EIP-4844** (Blobs) - Pass-through support; blob extras provider-specific

### Account Abstraction (EIP-4337)

**Bundler RPC Methods:**

- `eth_sendUserOperation`, `eth_estimateUserOperationGas`
- `eth_getUserOperationByHash`, `eth_getUserOperationReceipt`
- `eth_supportedEntryPoints`

**Policy:** Maintain separate bundler provider pools; do not mix with node pools. Bundler methods require different routing policies and SLAs.

**Status:** Not yet implemented; roadmap item.

---

## Implementation Details

### MethodRegistry

**Location:** `lib/lasso/rpc/method_registry.ex`

The MethodRegistry provides a canonical categorization of 100+ Ethereum JSON-RPC methods based on real-world provider support patterns:

```elixir
Lasso.RPC.MethodRegistry.category_methods(:core)
# => ["eth_blockNumber", "eth_chainId", "eth_getBalance", ...]

Lasso.RPC.MethodRegistry.method_category("eth_getLogs")
# => :filters

Lasso.RPC.MethodRegistry.default_support_assumption("debug_traceTransaction")
# => false (conservative for debug methods)
```

**Categories:**

- `:core` - Universal support (99%+ providers): `eth_blockNumber`, `eth_getBalance`, etc.
- `:state` - Common support (90%+ providers): `eth_call`, `eth_estimateGas`, etc.
- `:filters` - Restricted support (~60% providers): `eth_getLogs`, `eth_newFilter`, etc.
- `:debug/:trace` - Rare support (<10% providers): `debug_traceTransaction`, `trace_block`, etc.
- `:local_only` - Never supported on hosted providers: `eth_accounts`, `eth_sign`, etc.
- `:subscriptions` - WebSocket-only: `eth_subscribe`, `eth_unsubscribe`
- `:eip1559`, `:eip4844`, `:batch`, `:mempool`, `:network`, `:txpool` - Specialized categories

**Usage in capabilities system:**

The capabilities engine uses MethodRegistry to map methods to categories for filtering. When a provider declares `unsupported_categories: [debug, trace]`, the engine checks each method against MethodRegistry to determine if it should be blocked.

---

## Roadmap

### Near-Term (P0)

**Enhanced Subscription Policies**

- Formalize WS provider stickiness and failover rules
- Per-subscription-type SLO tracking
- Better handling of subscription conflicts on failover

### Mid-Term (P1)

**Stateful Filter Support (Optional)**

- Sticky session routing with TTLs
- Explicit opt-in required
- Recommend WS subscriptions as primary path

**Provider Capability Registry**

- Static capabilities: `supports_trace`, `supports_eip_1186`, etc.
- Active probing for feature detection
- Selection/failover aware of capabilities

**Enhanced Error Normalization**

- Map provider-specific error codes to standard taxonomy
- Consistent error messages across providers

### Long-Term (P2)

**Transaction Write Support**

- Per-account sticky routing
- Nonce manager with queuing
- Transaction deduplication store
- Controlled rebroadcast logic
- Receipt binding to same provider

**`eth_getLogs` Pagination**

- Automatic range splitting for large queries
- Provider-aware batching
- Parallel fetching with ordering guarantees

**OpenRPC/JSON Schema**

- Auto-generate API docs from MethodRegistry
- Interactive API explorer
- Client SDK generation

---

## Implementation Alignment

### Current Blocklist Enforcement

Located in `lib/lasso_web/controllers/rpc_controller.ex`:

**Recommended additions to HTTP blocklist:**

- `eth_signTypedData`, `eth_signTypedData_v3`, `eth_signTypedData_v4`
- All `wallet_*` methods
- All `personal_*` methods
- Filter methods: `eth_newFilter`, `eth_newBlockFilter`, `eth_getFilterChanges`, `eth_uninstallFilter`

### Configuration

```elixir
# config/config.exs
config :lasso,
  max_batch_requests: 50,
  provider_selection_strategy: :fastest

config :lasso, :circuit_breaker,
  failure_threshold: 5,
  recovery_timeout: 60_000,
  success_threshold: 2

config :lasso, :subscriptions,
  max_backfill_blocks: 32,
  backfill_timeout_ms: 30_000,
  enable_gap_filling: true
```

---

## Summary: What Lasso Allows

**✅ Allow with Failover:**

- All stateless read methods over HTTP or WebSocket
- Non-standard methods (best-effort)
- Batch requests (HTTP)

**✅ Allow with Special Handling:**

- Subscriptions over WebSocket (multiplexing + gap-filling)
- Provider override with optional failover
- Region-biased routing

**❌ Block:**

- Subscriptions over HTTP
- Wallet/signing/account methods
- Transaction writes (until write-path implementation)
- Stateful filters (until sticky routing implementation)
- Transaction pool introspection

**⚠️ Forward But No Guarantees:**

- Debug/trace methods (expensive, non-standard)
- Chain-specific extensions
- Bundler RPCs (requires separate pool)

---

**Last Updated:** February 2026
